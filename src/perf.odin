package main

import "core:fmt"
import "core:os"
import "core:slice"
import gl "vendor:OpenGL"
import "vendor:glfw"

// Performance log — opt-in via the `--perflog` launch flag, otherwise dormant at zero
// cost (every entry point early-returns on !enabled). The point is persistence: rather
// than an on-screen counter, we append numbers to perf.log so a regression can be
// hunted down after the fact.
//
// Three numbers per frame:
//   cpu  — wall time inside render() (the vertex assembly: layout, highlight, batching)
//   gpu  — a GL_TIME_ELAPSED timer query around the frame's draw submission. This is the
//          one that matters for the 240fps-at-4k goal: vsync pins wall-clock frame time
//          to the refresh interval, hiding GPU cost, so only a timer query reveals the
//          real headroom (target: well under 4.17ms @ 240Hz).
//   swap — time blocked in SwapBuffers (mostly the vsync wait; a spike here that isn't
//          the refresh interval means the GPU is behind).
//
// The GPU query is double-buffered: each frame issues into one of two query objects and
// reads back the OTHER (the previous frame's, ready by now since we just waited on vsync),
// so the read never stalls the pipeline. Samples accumulate for a second, then one line
// of avg / p99 / max is appended and the window resets — p99 is what surfaces the latency
// spikes a per-frame average would smear away.

PERF_FLUSH_INTERVAL :: 1.0 // seconds of samples per aggregated log line

Perf :: struct {
    enabled:   bool,
    file:      ^os.File, // perf.log append handle (nil -> falls back to stderr)
    queries:   [2]u32, // double-buffered GL_TIME_ELAPSED timer queries
    issued:    [2]bool, // slot i holds an un-read timer result
    parity:    int, // which slot the current frame writes
    win_start: f64, // glfw time the open aggregation window began (0 = not yet opened)
    cpu:       [dynamic]f32, // per-frame samples (ms) for the open window; heap (cross-frame)
    gpu:       [dynamic]f32,
    swap:      [dynamic]f32,
    input:     [dynamic]f32, // keystroke->present latency (ms), only on frames that consumed fresh input
    input_seen: f64, // last keystroke timestamp already sampled, so each keystroke counts once
    w, h:      i32, // last framebuffer size, for the line
    verts:     int, // last frame's submitted vertex count
}

// Arms the log when `enabled` (the `--perflog` flag). Generates the timer queries and
// opens perf.log for append; a failed open degrades to stderr rather than disabling.
perf_init :: proc(p: ^Perf, enabled: bool) {
    p.enabled = enabled
    if !enabled {
        return
    }
    gl.GenQueries(2, &p.queries[0])
    path := asset_path("perf.log", context.temp_allocator) // beside the exe (self-contained release)
    if f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND); err == nil {
        p.file = f
    } else {
        fmt.eprintfln("perf: could not open %s (%v); logging to stderr", path, err)
    }
}

perf_destroy :: proc(p: ^Perf) {
    if !p.enabled {
        return
    }
    perf_flush(p, glfw.GetTime()) // emit a final partial window so the tail isn't lost (real now: keeps fps honest)
    gl.DeleteQueries(2, &p.queries[0])
    if p.file != nil {
        os.close(p.file)
    }
    delete(p.cpu)
    delete(p.gpu)
    delete(p.swap)
    delete(p.input)
}

// Brackets the frame's GPU work: begin before render's draw calls, end after them. The
// query measures the GPU timeline for the commands issued between, independent of vsync.
perf_gpu_begin :: proc(p: ^Perf) {
    if !p.enabled {
        return
    }
    gl.BeginQuery(gl.TIME_ELAPSED, p.queries[p.parity])
}

perf_gpu_end :: proc(p: ^Perf) {
    if !p.enabled {
        return
    }
    gl.EndQuery(gl.TIME_ELAPSED)
    p.issued[p.parity] = true
}

// Records one frame's CPU/swap samples, reads back the previous frame's GPU timer, and
// flushes an aggregated line once the window fills a second. Call once per frame, after
// SwapBuffers.
perf_frame :: proc(p: ^Perf, now: f64, cpu_ms, swap_ms: f32, w, h: i32, verts: int, input_at: f64) {
    if !p.enabled {
        return
    }
    if p.win_start == 0 {
        p.win_start = now
    }
    p.w, p.h, p.verts = w, h, verts
    append(&p.cpu, cpu_ms)
    append(&p.swap, swap_ms)

    // Keystroke->present latency: this frame is the one that displays the result of the
    // most recent keystroke (we render exactly one frame per input). `now` is just past
    // SwapBuffers, so it's the moment the frame is handed to the display — count the
    // keystroke once, the frame after it landed.
    if input_at > p.input_seen {
        append(&p.input, f32((now - input_at) * 1000))
        p.input_seen = input_at
    }

    // Read the OTHER slot — last frame's timer, ready now (this frame just blocked on
    // vsync, so its GPU work is done). The availability guard keeps the read non-blocking
    // even if a non-vsync swap left it pending; that frame's sample is simply dropped.
    other := p.parity ~ 1
    if p.issued[other] {
        avail: i32
        gl.GetQueryObjectiv(p.queries[other], gl.QUERY_RESULT_AVAILABLE, &avail)
        if avail != 0 {
            ns: u64
            gl.GetQueryObjectui64v(p.queries[other], gl.QUERY_RESULT, &ns)
            append(&p.gpu, f32(f64(ns) / 1e6))
            p.issued[other] = false
        }
    }
    p.parity = other // next frame writes the slot we just drained

    if now - p.win_start >= PERF_FLUSH_INTERVAL {
        perf_flush(p, now)
    }
}

// Appends one aggregated line (avg/p99/max per metric) and reopens the window. A window
// with no frames just resets its clock.
@(private = "file")
perf_flush :: proc(p: ^Perf, now: f64) {
    n := len(p.cpu)
    if n == 0 {
        p.win_start = now
        return
    }
    elapsed := now - p.win_start
    fps := f64(n) / max(elapsed, 1e-6)
    ca, cp, cm := perf_stat(p.cpu[:])
    ga, gp, gm := perf_stat(p.gpu[:])
    sa, sp, sm := perf_stat(p.swap[:])
    ia, ip, im := perf_stat(p.input[:]) // keystroke->present; 0/0/0 in a window with no typing
    line := fmt.tprintf(
        "t=%.1f dims=%dx%d frames=%d fps=%.1f cpu_ms=%.3f/%.3f/%.3f gpu_ms=%.3f/%.3f/%.3f swap_ms=%.2f/%.2f/%.2f input_ms=%.2f/%.2f/%.2f(n%d) verts=%d\n",
        now, p.w, p.h, n, fps, ca, cp, cm, ga, gp, gm, sa, sp, sm, ia, ip, im, len(p.input), p.verts,
    )
    if p.file != nil {
        os.write_string(p.file, line)
    } else {
        fmt.eprint(line)
    }
    clear(&p.cpu)
    clear(&p.gpu)
    clear(&p.swap)
    clear(&p.input)
    p.win_start = now
}

// Average, 99th percentile, and max of a sample set (all ms). p99 over a sorted copy —
// the windows are at most a few hundred samples, so the sort is trivial.
@(private = "file")
perf_stat :: proc(xs: []f32) -> (avg, p99, mx: f32) {
    if len(xs) == 0 {
        return 0, 0, 0
    }
    sum: f32
    for x in xs {
        sum += x
        mx = max(mx, x)
    }
    avg = sum / f32(len(xs))
    tmp := slice.clone(xs, context.temp_allocator)
    slice.sort(tmp)
    idx := int(f32(len(tmp) - 1) * 0.99 + 0.5) // nearest-rank, rounded
    p99 = tmp[idx]
    return
}
