package tests

import app ".."
import "core:fmt"
import "core:testing"
import "core:strings"
import "core:time"
import "../txt"

// E8's keep-the-numbers-honest bench, in budget_test's spirit: measure rather than reason,
// assert a CEILING rather than an exact figure, and print the measurement so drift is visible.
//
// Covers the three costs the E work bought down: a load (was doc_set_text 2.48 ms at 300KB),
// a keystroke's full re-derivation through the funnel (splice, line index, change log, undo
// journal — was O(file)), and a save's serialisation (was doc_string 2.14 ms, per keystroke).
//
// The ceilings sit far above the figures measured here at -o:none (load 0.27 ms, keystroke
// 22.5 us, serialise 0.01 ms) and below the O(file) costs they guard against, so a slow CI
// machine cannot fail them and a real regression cannot pass them.

@(private = "file")
PERF_KEYSTROKES :: 1000

// Deterministic odin-ish text, ~10k lines / ~300KB — the clay.h class of file the E figures
// were measured against, without depending on one from disk.
@(private = "file")
perf_source :: proc() -> string {
    sb := strings.builder_make(context.temp_allocator)
    for i in 0 ..< 2000 {
        fmt.sbprintfln(&sb, "// block %d, padding the line out to something code-shaped", i)
        fmt.sbprintfln(&sb, "proc_%d :: proc(a: int, b: int) -> int {{", i)
        fmt.sbprintfln(&sb, "    x := a + b * %d", i)
        fmt.sbprintfln(&sb, "    return x")
        fmt.sbprintfln(&sb, "}}")
    }
    return strings.to_string(sb)
}

@(test)
test_perf_ceilings :: proc(t: ^testing.T) {
    src := perf_source()
    testing.expect(t, len(src) > 200 * 1024, "the fixture did not produce a big file")

    // Load: best of three, so a cold first run does not decide the figure.
    load := time.MAX_DURATION
    for _ in 0 ..< 3 {
        b: app.Buffer
        start := time.tick_now()
        app.buffer_set_text(&b, src)
        load = min(load, time.tick_since(start))
        app.buffer_destroy(&b)
    }

    b: app.Buffer
    app.buffer_set_text(&b, src)
    defer app.buffer_destroy(&b)

    // A typed run mid-file, through the whole funnel. The average IS the smoothing.
    txt.doc_reset_cursor(&b.doc, txt.Pos{txt.doc_line_count(&b.doc) / 2, 4})
    start := time.tick_now()
    for _ in 0 ..< PERF_KEYSTROKES {
        txt.doc_insert_rune(&b.doc, 'x')
    }
    keystroke := time.tick_since(start) / PERF_KEYSTROKES

    // The save's serialisation, piece by piece. The disk stays out: its speed is the
    // machine's, not this code's.
    save := time.MAX_DURATION
    for _ in 0 ..< 3 {
        start = time.tick_now()
        _ = app.buffer_bytes(&b)
        save = min(save, time.tick_since(start))
    }

    fmt.printfln(
        "[perf] %d KB / %d lines: load %.2f ms, keystroke %.1f us, serialise %.2f ms",
        len(src) / 1024,
        txt.doc_line_count(&b.doc),
        time.duration_milliseconds(load),
        f64(time.duration_microseconds(keystroke)),
        time.duration_milliseconds(save),
    )

    testing.expectf(t, load < 10 * time.Millisecond, "load took %v — O(file) work is back on the load path", load)
    testing.expectf(t, keystroke < 2 * time.Millisecond, "a keystroke took %v — O(file) work is back on the edit path", keystroke)
    testing.expectf(t, save < 10 * time.Millisecond, "serialising took %v — the save path regressed", save)
}
