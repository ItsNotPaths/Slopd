package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "vendor:glfw"

// Procmon — a btop-lite process monitor for the aux pane. A top GRAPH BAND (a
// tab-enum of CPU / Memory / Disk / GPU history graphs) sits over a PROCESS LIST
// (cpu% / mem / pid / user / name / cmd). A background thread samples /proc once a
// second while the pane is on screen; the main thread draws a lock-free snapshot.
//
// Threading model (mirrors terminal.odin's reader thread):
//   - The sampler thread builds a fresh ProcSnapshot (procs + graph series, all
//     heap-owned), then under `lock` hands it off as `pending` and PostEmptyEvents.
//   - procmon_drain (main thread, each frame) moves `pending` into `cur` and rebuilds
//     the filtered `view`. `cur` + `view` are MAIN-THREAD-ONLY, so draw needs no lock.
//   - Sampling only runs while `wanted` (the pane is the visible aux mode), so the
//     event-driven loop returns to 0% idle when procmon isn't shown.

PROC_HIST :: 120 // history samples kept per graph (~2 min at the 1s tick)
SIG_COLS :: 4 // signal-selector grid width (Up/Down step by this many)

// How long a multi-digit signal number stays open to a second digit (seconds). Without a
// bound, "1" typed a minute ago silently makes the next "5" mean 15 rather than 5 — the run
// only ever ended on an arrow key. Three seconds is well past a deliberate two-key number
// and well short of "I came back to this pane and typed a signal".
PROC_SIG_RUN_S :: 3.0

GraphCat :: enum {
    CPU,
    Memory,
    Disk,
    GPU,
}

// Which band owns the keys. The graph band is a single focusable unit ("one extra
// row" above the list, per the design); the list owns Up/Down selection.
ProcFocus :: enum {
    Graphs,
    List,
}

// List scope, toggled by Tab. All = every process; Slopd = only this process and
// its descendants (a spawned terminal shell and whatever it ran).
ProcScope :: enum {
    All,
    Slopd,
}

// One sampled process. Strings are OWNED (cloned out of the temp /proc buffers) and
// freed by procmon_snapshot_free.
ProcRow :: struct {
    pid, ppid: int,
    name:      string,
    cmd:       string,
    user:      string,
    rss_kb:    u64,
    cpu_pct:   f32, // share of one core, btop-style (a busy thread reads ~100%)
    is_child:  bool, // a descendant of the Slopd process
}

// A graph's ring buffer: normalised values in [0,1], newest at `head`, `n` filled.
Series :: struct {
    vals: [PROC_HIST]f32,
    head: int,
    n:    int,
}

// One graph as the snapshot presents it: the ring plus an owned human-readable
// readout and whether the metric is available on this machine (GPU may not be).
GraphView :: struct {
    hist:  Series,
    label: string, // owned
    avail: bool,
}

// The drawn state, swapped wholesale each tick. Everything here is heap-owned and
// freed by procmon_snapshot_free.
ProcSnapshot :: struct {
    procs:                [dynamic]ProcRow,
    cpu, mem, disk, gpu: GraphView,
}

ProcmonPane :: struct {
    // navigation (main thread)
    focus:       ProcFocus,
    cat:         GraphCat,
    scope:       ProcScope,
    sel:         int, // selected row, index into `view`
    sel_pid:     int, // the selected process's PID — selection identity across re-sorts
    scroll:      int, // first visible row — the viewport TARGET top (see list_scroll_target)
    // A wheel gesture DETACHES the view from the selection (glfw time; 0 = following it),
    // the flat-row twin of Buffer.scroll_detached. While it is set neither viewport policy
    // runs, so the wheel moves the view rather than the cursor; the next keystroke that
    // reaches this pane re-attaches it. See list_scroll_apply (scroll.odin).
    scroll_detached: f64,
    scroll_anim: Anim, // list smooth-scroll: the visual top tweening toward `scroll`
    hover:       ProcHit, // what the pointer is over, resolved once per frame (procmon_ui.odin)

    // live name filter (Space opens; reuses the shared Doc editing core)
    filtering: bool,
    filter:    Doc,

    // signal selector (replaces the graph band; btop-style 1..31)
    sig_open:  bool,
    sig_sel:   int, // 1..31
    sig_multi: bool, // last keypress was a digit (so a second digit extends it)
    sig_typed_at: f64, // glfw time of that keypress; the run expires PROC_SIG_RUN_S later

    // `k` confirm: armed by k when App.kill_confirm is on; the armed row shows a
    // one-key confirm prompt instead of its columns until Enter/y or Esc.
    kill_armed: bool,
    kill_pid:   int,

    // Display order as a list of PIDs, refreshed ONLY on (re)open (Alt+P) — the list
    // does NOT re-sort live, so a spiking process stays put and is easy to catch. Rows
    // hold their slot as values update; new processes append at the bottom.
    order: [dynamic]int,

    // sampler <-> main handoff
    lock:        sync.Mutex,
    pending:     ProcSnapshot, // lock-guarded
    has_pending: bool, // lock-guarded
    wanted:      bool, // sample only while the pane is visible

    // main-thread-only (drawn without a lock)
    cur:  ProcSnapshot,
    view: [dynamic]int, // indices into cur.procs after scope + filter

    // sampler thread
    sampler: ^thread.Thread,
    running: bool,

    // sampler-private state (only the sampler touches these after init)
    ncpu:        int,
    last_total:  u64, // /proc/stat total jiffies at the previous tick
    last_idle:   u64,
    last_jiff:   map[int]u64, // per-pid utime+stime at the previous tick
    s_cpu, s_mem, s_disk, s_gpu: Series, // authoritative rings, copied into each snapshot
    last_dsect:  u64, // disk sectors read+written at the previous tick
    last_dtime:  f64, // wall clock of the previous disk sample
    disk_peak:   f32, // running peak throughput, for the auto-scaled disk graph
    users:       map[int]string, // uid -> name (loaded once from /etc/passwd; owned)
}

// --- lifecycle ---

procmon_init :: proc(pm: ^ProcmonPane) {
    doc_init(&pm.filter)
    pm.focus = .List
    pm.cat = .CPU
    pm.scope = .All
    pm.sig_sel = 9 // default highlight SIGKILL, btop's `k`
    pm.ncpu = proc_count_cpus()
    pm.last_jiff = make(map[int]u64)
    pm.users = proc_load_users()
    pm.running = true
    procmon_sample(pm) // prime: instant first paint + the CPU% delta baseline
    pm.sampler = thread.create(procmon_sampler_proc)
    if pm.sampler != nil {
        pm.sampler.data = pm
        thread.start(pm.sampler)
    }
}

procmon_destroy :: proc(pm: ^ProcmonPane) {
    pm.running = false
    if pm.sampler != nil {
        thread.join(pm.sampler) // returns within one sleep slice (<=100ms)
        thread.destroy(pm.sampler)
        pm.sampler = nil
    }
    doc_destroy(&pm.filter)
    procmon_snapshot_free(&pm.cur)
    if pm.has_pending {
        procmon_snapshot_free(&pm.pending)
    }
    delete(pm.view)
    delete(pm.order)
    delete(pm.last_jiff)
    for _, name in pm.users {
        delete(name)
    }
    delete(pm.users)
}

// Frees a snapshot's owned storage (process strings, graph labels). Safe on a
// zero-value snapshot: an empty string's data pointer is nil, so delete is a no-op.
procmon_snapshot_free :: proc(s: ^ProcSnapshot) {
    for r in s.procs {
        delete(r.name)
        delete(r.cmd)
        delete(r.user)
    }
    delete(s.procs)
    delete(s.cpu.label)
    delete(s.mem.label)
    delete(s.disk.label)
    delete(s.gpu.label)
    s^ = {}
}

// --- sampler thread ---

// Loops while running: when the pane is visible, sample /proc and wake the main
// loop; otherwise idle. Sleeps in short slices so destroy joins promptly. Its temp
// allocations use a private growing arena (the default temp allocator is not safe to
// share with the main thread), reset after every tick.
procmon_sampler_proc :: proc(th: ^thread.Thread) {
    pm := (^ProcmonPane)(th.data)
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil {
        return
    }
    defer virtual.arena_destroy(&arena)
    context.temp_allocator = virtual.arena_allocator(&arena)

    for pm.running {
        if pm.wanted {
            procmon_sample(pm)
            free_all(context.temp_allocator)
            glfw.PostEmptyEvent()
        }
        for i := 0; i < 10 && pm.running; i += 1 {
            time.sleep(100 * time.Millisecond)
        }
    }
}

// Read /proc, build a fresh snapshot, hand it off. Runs on the sampler thread (and
// once on the main thread at init, before the thread starts — never concurrently).
procmon_sample :: proc(pm: ^ProcmonPane) {
    // System CPU aggregate: the busy fraction is 1 - didle/dtotal, and dtotal is the
    // denominator for every process's share too.
    total, idle := proc_cpu_totals()
    dtotal := total - pm.last_total
    didle := idle - pm.last_idle
    cpu_busy: f32 = 0
    if dtotal > 0 {
        cpu_busy = 1 - f32(didle) / f32(dtotal)
    }

    me := int(posix.getpid())
    fresh := make([dynamic]ProcRow, 0, 512)
    new_jiff := make(map[int]u64)
    parent := make(map[int]int, 512, context.temp_allocator)

    if dir, oerr := os.open("/proc"); oerr == nil {
        defer os.close(dir)
        it := os.read_directory_iterator_create(dir)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            if !proc_is_number(fi.name) {
                continue
            }
            pid := strconv.parse_int(fi.name, 10) or_continue
            ppid, jiff, ok := proc_read_stat(pid)
            if !ok {
                continue // the process vanished between readdir and read
            }
            new_jiff[pid] = jiff
            prev := pm.last_jiff[pid] or_else jiff // a new process shows 0% this tick
            dproc := jiff > prev ? jiff - prev : 0
            cpu_pct: f32 = 0
            if dtotal > 0 {
                cpu_pct = 100 * f32(dproc) * f32(pm.ncpu) / f32(dtotal)
            }

            name, uid, rss := proc_read_status(pid)
            append(
                &fresh,
                ProcRow {
                    pid = pid,
                    ppid = ppid,
                    name = strings.clone(name),
                    cmd = proc_read_cmdline(pid, name),
                    user = proc_user_name(pm, uid),
                    rss_kb = rss,
                    cpu_pct = cpu_pct,
                },
            )
            parent[pid] = ppid
        }
    }

    // Tag Slopd's descendants (the Slopd scope filter) by walking each pid's parent
    // chain. Sort by PID ascending for a STABLE identity order — the display order is
    // the main thread's `order` (set on open), so the snapshot itself must not churn.
    for &r in fresh {
        r.is_child = proc_is_descendant(r.pid, me, parent)
    }
    slice.sort_by(fresh[:], proc(a, b: ProcRow) -> bool {
        return a.pid < b.pid
    })

    // Memory.
    memtotal, memavail := proc_meminfo()
    memused := memtotal > memavail ? memtotal - memavail : 0
    mem_frac: f32 = memtotal > 0 ? f32(memused) / f32(memtotal) : 0

    // Disk: throughput from the sector delta over wall-clock dt, auto-scaled to its
    // own running peak; capacity from statvfs on the root.
    now := glfw.GetTime()
    dsect := proc_disk_sectors()
    disk_bps: f32 = 0
    if pm.last_dtime > 0 && now > pm.last_dtime && dsect >= pm.last_dsect {
        disk_bps = f32(f64(dsect - pm.last_dsect) * 512 / (now - pm.last_dtime))
    }
    pm.last_dsect = dsect
    pm.last_dtime = now
    if disk_bps > pm.disk_peak {
        pm.disk_peak = disk_bps
    }
    disk_frac: f32 = pm.disk_peak > 0 ? disk_bps / pm.disk_peak : 0
    cap_frac, cap_ok := proc_disk_capacity()

    // GPU: best-effort sysfs busy percent (AMD / some Intel); absent on NVIDIA/others.
    gpu_busy, gpu_ok := proc_gpu_busy()

    series_push(&pm.s_cpu, cpu_busy)
    series_push(&pm.s_mem, mem_frac)
    series_push(&pm.s_disk, disk_frac)
    series_push(&pm.s_gpu, gpu_ok ? gpu_busy : 0)

    snap: ProcSnapshot
    snap.procs = fresh
    snap.cpu = {pm.s_cpu, fmt.aprintf("%.0f%%", cpu_busy * 100), true}
    snap.mem = {pm.s_mem, fmt.aprintf("%s / %s", proc_human_kb(memused), proc_human_kb(memtotal)), true}
    snap.disk = {
        pm.s_disk,
        cap_ok \
        ? fmt.aprintf("%s/s   %.0f%% full", proc_human_bps(disk_bps), cap_frac * 100) \
        : fmt.aprintf("%s/s", proc_human_bps(disk_bps)),
        true,
    }
    snap.gpu = {pm.s_gpu, gpu_ok ? fmt.aprintf("%.0f%%", gpu_busy * 100) : strings.clone("unavailable"), gpu_ok}

    // Hand off under the lock; drop any snapshot the main thread hasn't consumed yet.
    sync.mutex_lock(&pm.lock)
    if pm.has_pending {
        procmon_snapshot_free(&pm.pending)
    }
    pm.pending = snap
    pm.has_pending = true
    sync.mutex_unlock(&pm.lock)

    // Advance the sampler-private baselines for the next tick's deltas.
    delete(pm.last_jiff)
    pm.last_jiff = new_jiff
    pm.last_total = total
    pm.last_idle = idle
}

series_push :: proc(s: ^Series, v: f32) {
    s.head = (s.head + 1) % PROC_HIST
    s.vals[s.head] = clamp(v, 0, 1)
    if s.n < PROC_HIST {
        s.n += 1
    }
}

// --- main-thread drain + view ---

// Each frame: move a freshly sampled snapshot into `cur` and rebuild the view. Cheap
// (an early return) when the sampler produced nothing new.
procmon_drain :: proc(a: ^App) {
    pm := &a.procmon
    sync.mutex_lock(&pm.lock)
    if !pm.has_pending {
        sync.mutex_unlock(&pm.lock)
        return
    }
    snap := pm.pending
    pm.has_pending = false
    sync.mutex_unlock(&pm.lock)

    procmon_snapshot_free(&pm.cur)
    pm.cur = snap
    procmon_view_rebuild(pm)
}

// Rebuild `view` from cur.procs in the frozen `order` (scope + name filter applied),
// appending any process not in `order` (newly appeared) at the bottom in PID order.
// Then re-anchor the selection to the same PID, since rows shift as procs come and go.
procmon_view_rebuild :: proc(pm: ^ProcmonPane) {
    clear(&pm.view)
    q := strings.to_lower(strings.trim_space(doc_string(&pm.filter, context.temp_allocator)), context.temp_allocator)

    idx_of := make(map[int]int, len(pm.cur.procs), context.temp_allocator)
    for r, i in pm.cur.procs {
        idx_of[r.pid] = i
    }
    placed := make(map[int]bool, len(pm.cur.procs), context.temp_allocator)
    for pid in pm.order {
        if i, ok := idx_of[pid]; ok && procmon_visible(pm, pm.cur.procs[i], q) {
            append(&pm.view, i)
            placed[pid] = true
        }
    }
    for r, i in pm.cur.procs {
        if !placed[r.pid] && procmon_visible(pm, r, q) {
            append(&pm.view, i)
        }
    }

    newsel := 0
    if pm.sel_pid != 0 {
        for vi, k in pm.view {
            if pm.cur.procs[vi].pid == pm.sel_pid {
                newsel = k
                break
            }
        }
    }
    pm.sel = clamp(newsel, 0, max(0, len(pm.view) - 1))
    pm.sel_pid = len(pm.view) > 0 ? pm.cur.procs[pm.view[pm.sel]].pid : 0
}

// Whether a row passes the current scope + (already-lowercased) name/cmd filter.
@(private = "file")
procmon_visible :: proc(pm: ^ProcmonPane, r: ProcRow, q: string) -> bool {
    if pm.scope == .Slopd && !r.is_child {
        return false
    }
    if q != "" {
        name_l := strings.to_lower(r.name, context.temp_allocator)
        cmd_l := strings.to_lower(r.cmd, context.temp_allocator)
        if !strings.contains(name_l, q) && !strings.contains(cmd_l, q) {
            return false
        }
    }
    return true
}

// Re-sort the display order by CPU% desc (ties: memory desc, pid asc). Called only on
// (re)open — Alt+P — so the live list never reorders under the user's cursor.
procmon_resort :: proc(pm: ^ProcmonPane) {
    Key :: struct {
        cpu: f32,
        rss: u64,
        pid: int,
    }
    keys := make([]Key, len(pm.cur.procs), context.temp_allocator)
    for r, i in pm.cur.procs {
        keys[i] = {r.cpu_pct, r.rss_kb, r.pid}
    }
    slice.sort_by(keys, proc(a, b: Key) -> bool {
        if a.cpu != b.cpu {
            return a.cpu > b.cpu
        }
        if a.rss != b.rss {
            return a.rss > b.rss
        }
        return a.pid < b.pid
    })
    clear(&pm.order)
    for k in keys {
        append(&pm.order, k.pid)
    }
    pm.kill_armed = false
    procmon_view_rebuild(pm)
}

// Move the selection, clamped, keeping sel_pid in step.
procmon_select :: proc(pm: ^ProcmonPane, idx: int) {
    n := len(pm.view)
    if n == 0 {
        pm.sel = 0
        pm.sel_pid = 0
        return
    }
    pm.sel = clamp(idx, 0, n - 1)
    pm.sel_pid = pm.cur.procs[pm.view[pm.sel]].pid
}

// The graph the band is currently showing. Package-level and here rather than in the UI
// half, because "which series does this category name" is a property of the snapshot, not
// of how it is drawn.
procmon_graphview :: proc(pm: ^ProcmonPane) -> ^GraphView {
    switch pm.cat {
    case .CPU:    return &pm.cur.cpu
    case .Memory: return &pm.cur.mem
    case .Disk:   return &pm.cur.disk
    case .GPU:    return &pm.cur.gpu
    }
    return &pm.cur.cpu
}

// The selected process's PID, or 0 when the list is empty.
procmon_sel_pid :: proc(pm: ^ProcmonPane) -> int {
    if pm.sel >= 0 && pm.sel < len(pm.view) {
        return pm.cur.procs[pm.view[pm.sel]].pid
    }
    return 0
}

// Send a signal to the selected process. A denied/foreign target (EPERM) is a quiet
// no-op — exactly btop's behaviour.
procmon_kill :: proc(pm: ^ProcmonPane, signum: int) {
    if pid := procmon_sel_pid(pm); pid > 0 {
        posix.kill(posix.pid_t(pid), posix.Signal(signum))
    }
}

// Fire the armed signal and close the selector — the selector's one commit, reached by
// its Enter and by a double click on a cell (procmon_click). Split out so the two paths
// cannot drift: sending without closing would leave a selector over a process that may no
// longer exist, which is the kind of thing only one of two copies ever remembers.
procmon_sig_send :: proc(pm: ^ProcmonPane) {
    procmon_kill(pm, pm.sig_sel)
    pm.sig_open = false
}

// Point the graph band at a category. Trivial, and that is the point: the keyboard STEPS
// through the enum (Tab / Left / Right) while a click PICKS one outright, so the two
// paths share the destination rather than the motion. Focus follows, because clicking a
// tab is an unambiguous statement that the band is what you are looking at — the same
// reasoning that makes a click on a process row focus the list.
procmon_pick_cat :: proc(pm: ^ProcmonPane, cat: GraphCat) {
    pm.cat = cat
    pm.focus = .Graphs
}

// --- input ---

procmon_key :: proc(a: ^App, key, mods: i32) {
    pm := &a.procmon
    if pm.sig_open {
        procmon_sig_key(pm, key)
        return
    }
    if pm.filtering {
        procmon_filter_key(pm, key, mods)
        return
    }
    if pm.kill_armed {
        // The confirm prompt owns the keys: Enter/y fires SIGKILL, Esc/n/q backs out;
        // anything else is ignored so a stray key can't dismiss or trigger it.
        switch key {
        case glfw.KEY_ENTER, glfw.KEY_KP_ENTER, glfw.KEY_Y:
            if pm.kill_pid > 0 {
                posix.kill(posix.pid_t(pm.kill_pid), posix.Signal(9))
            }
            pm.kill_armed = false
        case glfw.KEY_ESCAPE, glfw.KEY_N, glfw.KEY_Q:
            pm.kill_armed = false
        }
        return
    }

    ctrl := mods & glfw.MOD_CONTROL != 0
    switch pm.focus {
    case .Graphs:
        switch key {
        case glfw.KEY_DOWN:
            pm.focus = .List
        case glfw.KEY_TAB, glfw.KEY_RIGHT:
            procmon_pick_cat(pm, GraphCat((int(pm.cat) + 1) % len(GraphCat)))
        case glfw.KEY_LEFT:
            procmon_pick_cat(pm, GraphCat((int(pm.cat) + len(GraphCat) - 1) % len(GraphCat)))
        }
    case .List:
        switch key {
        case glfw.KEY_UP:
            if ctrl || pm.sel == 0 {
                pm.focus = .Graphs // Ctrl+Up jumps up; plain Up at the top crosses in
            } else {
                procmon_select(pm, pm.sel - 1)
            }
        case glfw.KEY_DOWN:
            procmon_select(pm, pm.sel + 1)
        case glfw.KEY_TAB:
            pm.scope = pm.scope == .All ? .Slopd : .All
            procmon_view_rebuild(pm)
        case glfw.KEY_SPACE:
            pm.filtering = true
        case glfw.KEY_K:
            // SIGKILL (btop parity). With kill_confirm on, arm a one-key confirm row
            // first; off kills immediately.
            if a.kill_confirm {
                pm.kill_armed = true
                pm.kill_pid = procmon_sel_pid(pm)
            } else {
                procmon_kill(pm, 9)
            }
        case glfw.KEY_S:
            pm.sig_open = true
            pm.sig_sel = 9
            pm.sig_multi = false
        }
    }
}

// Filter-bar editing: printable text arrives via char_callback; here we handle
// motion, backspace/delete (re-filtering live) and Esc/Enter to leave the bar.
@(private = "file")
procmon_filter_key :: proc(pm: ^ProcmonPane, key, mods: i32) {
    d := &pm.filter
    if edit_motion(d, key, mods, false) {
        return
    }
    ctrl := mods & glfw.MOD_CONTROL != 0
    switch key {
    case glfw.KEY_ESCAPE:
        pm.filtering = false
        doc_clear(d) // Esc cancels: drop the query
        procmon_view_rebuild(pm)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        pm.filtering = false // keep the query, just close the bar
    case glfw.KEY_BACKSPACE:
        if ctrl {doc_delete_word_back(d)} else {doc_backspace(d)}
        procmon_view_rebuild(pm)
    case glfw.KEY_DELETE:
        if ctrl {doc_delete_word_forward(d)} else {doc_delete(d)}
        procmon_view_rebuild(pm)
    }
}

// A digit typed at the open signal selector. Digits accumulate into a run, so "1" then "5"
// arms 15; a run that would overshoot 31 restarts from the digit just typed, because a
// number you did not ask for is worse than starting over. A run also EXPIRES — see
// PROC_SIG_RUN_S — so a digit typed long after the last one starts a fresh number rather
// than becoming the units of a half-forgotten one.
//
// A LEADING ZERO IS IGNORED, and that is the whole of the bug this proc was extracted to
// fix. It used to fall through to `clamp(0, 1, 31)`, so a bare "0" armed signal 1 AND armed
// the run — which made "0" then "9" compute 1*10+9 and arm 19 (SIGSTOP) when you had asked
// for 9 (SIGKILL). Sending the wrong signal because of a keystroke that should not have
// counted is about the worst failure this pane has available. Leading zeros carry no
// information in a 1..31 number, so the fix is to drop them rather than to clamp them.
procmon_sig_digit :: proc(pm: ^ProcmonPane, d: int, now: f64) {
    if pm.sig_multi && now - pm.sig_typed_at > PROC_SIG_RUN_S {
        pm.sig_multi = false // the run went stale; this digit starts a new number
    }
    if d == 0 && !pm.sig_multi {
        return // no run in progress: "0" is not a signal and must not start one
    }
    cand := pm.sig_multi ? pm.sig_sel * 10 + d : d
    pm.sig_sel = (cand >= 1 && cand <= 31) ? cand : clamp(d, 1, 31)
    pm.sig_multi = true
    pm.sig_typed_at = now
}

// Move the armed signal by `d` cells through the 1..31 grid, clamped at both ends —
// a closed choice, so walking off the end stays put rather than stepping out (the same
// distinction config's two dropdown kinds draw). Shared by the selector's arrows and by a
// wheel notch over it, which is what let wheel_apply's .Procmon branch stop refusing.
// Typing a digit is the other way in, and any move ends a multi-digit run.
procmon_sig_move :: proc(pm: ^ProcmonPane, d: int) {
    pm.sig_sel = clamp(pm.sig_sel + d, 1, 31)
    pm.sig_multi = false
}

// Signal-selector keys (btop-style): arrows walk the 1..31 grid, digits type a
// number, Enter sends it to the selected process, q/Esc close without sending.
@(private = "file")
procmon_sig_key :: proc(pm: ^ProcmonPane, key: i32) {
    switch key {
    case glfw.KEY_ESCAPE, glfw.KEY_Q:
        pm.sig_open = false
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        procmon_sig_send(pm)
    case glfw.KEY_LEFT:
        procmon_sig_move(pm, -1)
    case glfw.KEY_RIGHT:
        procmon_sig_move(pm, 1)
    case glfw.KEY_UP:
        procmon_sig_move(pm, -SIG_COLS)
    case glfw.KEY_DOWN:
        procmon_sig_move(pm, SIG_COLS)
    case:
        if d, ok := proc_digit(key); ok {
            procmon_sig_digit(pm, d, glfw.GetTime())
        }
    }
}

// --- /proc parsing helpers ---

// Reads a whole file. /proc files report size 0, so os.read_entire_file (which trusts
// the stat size) yields nothing — read in a loop until EOF instead.
@(private = "file")
proc_read :: proc(path: string, alloc := context.temp_allocator) -> (string, bool) {
    f, err := os.open(path)
    if err != nil {
        return "", false
    }
    defer os.close(f)
    buf := make([dynamic]u8, 0, 2048, alloc)
    chunk: [4096]u8
    for {
        n, rerr := os.read(f, chunk[:])
        if n > 0 {
            append(&buf, ..chunk[:n])
        }
        if rerr != nil || n <= 0 {
            break
        }
    }
    return string(buf[:]), true
}

@(private = "file")
proc_is_number :: proc(s: string) -> bool {
    if len(s) == 0 {
        return false
    }
    for c in s {
        if c < '0' || c > '9' {
            return false
        }
    }
    return true
}

// ppid + total scheduled jiffies (utime+stime) from /proc/<pid>/stat. The comm field
// is parenthesised and may itself hold spaces and ')', so split AFTER the last ')':
// the remaining fields are state, ppid, ..., utime(14), stime(15) — 1-based — which
// land at indices 1, 11, 12 of the tail.
@(private = "file")
proc_read_stat :: proc(pid: int) -> (ppid: int, jiffies: u64, ok: bool) {
    data := proc_read(fmt.tprintf("/proc/%d/stat", pid)) or_return
    rp := strings.last_index_byte(data, ')')
    if rp < 0 {
        return
    }
    f := strings.fields(data[rp + 1:], context.temp_allocator)
    if len(f) < 13 {
        return
    }
    ppid = strconv.parse_int(f[1], 10) or_else 0
    ut := strconv.parse_u64(f[11], 10) or_else 0
    st := strconv.parse_u64(f[12], 10) or_else 0
    return ppid, ut + st, true
}

// Name, real uid, and resident memory (kB) from /proc/<pid>/status. VmRSS is absent
// for kernel threads (no address space) — they report 0. `name` aliases `data`'s temp
// storage; the caller clones it.
@(private = "file")
proc_read_status :: proc(pid: int) -> (name: string, uid: int, rss_kb: u64) {
    data, ok := proc_read(fmt.tprintf("/proc/%d/status", pid))
    if !ok {
        return "", 0, 0
    }
    s := data
    for line in strings.split_lines_iterator(&s) {
        switch {
        case strings.has_prefix(line, "Name:"):
            name = strings.trim_space(line[5:])
        case strings.has_prefix(line, "Uid:"):
            if f := strings.fields(line[4:], context.temp_allocator); len(f) > 0 {
                uid = strconv.parse_int(f[0], 10) or_else 0
            }
        case strings.has_prefix(line, "VmRSS:"):
            if f := strings.fields(line[6:], context.temp_allocator); len(f) > 0 {
                rss_kb = strconv.parse_u64(f[0], 10) or_else 0
            }
        }
    }
    return
}

// The full command line (NUL-separated argv with the NULs turned to spaces), or
// "[name]" for a kernel thread / empty cmdline. Returns OWNED storage.
@(private = "file")
proc_read_cmdline :: proc(pid: int, name: string) -> string {
    data, ok := proc_read(fmt.tprintf("/proc/%d/cmdline", pid))
    if ok && len(data) > 0 {
        b := strings.builder_make(context.temp_allocator)
        for i in 0 ..< len(data) {
            strings.write_byte(&b, data[i] == 0 ? ' ' : data[i])
        }
        if cmd := strings.trim_space(strings.to_string(b)); cmd != "" {
            return strings.clone(cmd)
        }
    }
    return strings.clone(fmt.tprintf("[%s]", name))
}

// Walks the parent chain from `pid`; true if it reaches the Slopd process `me`. The
// step cap guards against a malformed cycle.
@(private = "file")
proc_is_descendant :: proc(pid, me: int, parent: map[int]int) -> bool {
    p := pid
    for _ in 0 ..< 4096 {
        if p == me {
            return true
        }
        pp, ok := parent[p]
        if !ok || pp == p || pp <= 0 {
            return false
        }
        p = pp
    }
    return false
}

// uid -> username via the cache; falls back to the numeric uid. Returns OWNED storage.
@(private = "file")
proc_user_name :: proc(pm: ^ProcmonPane, uid: int) -> string {
    if name, ok := pm.users[uid]; ok {
        return strings.clone(name)
    }
    return strings.clone(fmt.tprintf("%d", uid))
}

// Total and idle (idle+iowait) jiffies from the aggregate `cpu` line of /proc/stat.
@(private = "file")
proc_cpu_totals :: proc() -> (total, idle: u64) {
    data, ok := proc_read("/proc/stat")
    if !ok {
        return
    }
    nl := strings.index_byte(data, '\n')
    first := nl < 0 ? data : data[:nl]
    f := strings.fields(first, context.temp_allocator) // cpu user nice system idle iowait ...
    for i in 1 ..< len(f) {
        total += strconv.parse_u64(f[i], 10) or_else 0
    }
    if len(f) > 5 {
        idle = (strconv.parse_u64(f[4], 10) or_else 0) + (strconv.parse_u64(f[5], 10) or_else 0)
    }
    return
}

// Logical CPU count: the per-core `cpuN` lines of /proc/stat (min 1).
@(private = "file")
proc_count_cpus :: proc() -> int {
    data, ok := proc_read("/proc/stat")
    if !ok {
        return 1
    }
    n := 0
    s := data
    for line in strings.split_lines_iterator(&s) {
        if strings.has_prefix(line, "cpu") && len(line) > 3 && line[3] >= '0' && line[3] <= '9' {
            n += 1
        }
    }
    return max(n, 1)
}

// MemTotal and MemAvailable (kB) from /proc/meminfo.
@(private = "file")
proc_meminfo :: proc() -> (total, avail: u64) {
    data, ok := proc_read("/proc/meminfo")
    if !ok {
        return
    }
    s := data
    for line in strings.split_lines_iterator(&s) {
        if strings.has_prefix(line, "MemTotal:") {
            total = proc_first_u64(line[9:])
        } else if strings.has_prefix(line, "MemAvailable:") {
            avail = proc_first_u64(line[13:])
        }
    }
    return
}

@(private = "file")
proc_first_u64 :: proc(s: string) -> u64 {
    f := strings.fields(s, context.temp_allocator)
    return len(f) > 0 ? (strconv.parse_u64(f[0], 10) or_else 0) : 0
}

// Sectors read+written across whole disks (the names in /sys/block — partitions and
// loop/ram devices are excluded). One sector is 512 bytes.
@(private = "file")
proc_disk_sectors :: proc() -> (sectors: u64) {
    disks := make(map[string]bool, 16, context.temp_allocator)
    if dir, oerr := os.open("/sys/block"); oerr == nil {
        defer os.close(dir)
        it := os.read_directory_iterator_create(dir)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            disks[strings.clone(fi.name, context.temp_allocator)] = true
        }
    }
    data, ok := proc_read("/proc/diskstats")
    if !ok {
        return
    }
    s := data
    for line in strings.split_lines_iterator(&s) {
        f := strings.fields(line, context.temp_allocator) // major minor name reads .. sect_rd .. sect_wr
        if len(f) < 10 || !(f[2] in disks) {
            continue
        }
        sectors += (strconv.parse_u64(f[5], 10) or_else 0) + (strconv.parse_u64(f[9], 10) or_else 0)
    }
    return
}

// Used fraction of the root filesystem via statvfs.
@(private = "file")
proc_disk_capacity :: proc() -> (used_frac: f32, ok: bool) {
    st: posix.statvfs_t
    if posix.statvfs("/", &st) != .OK || st.f_blocks == 0 {
        return 0, false
    }
    return 1 - f32(st.f_bavail) / f32(st.f_blocks), true
}

// Best-effort GPU busy fraction from sysfs (AMD / some Intel). Absent on NVIDIA and
// many others — returns ok=false, and the pane shows "unavailable".
@(private = "file")
proc_gpu_busy :: proc() -> (busy: f32, ok: bool) {
    for card in ([]string{
        "/sys/class/drm/card0/device/gpu_busy_percent",
        "/sys/class/drm/card1/device/gpu_busy_percent",
    }) {
        if data, rok := proc_read(card); rok {
            if v, vok := strconv.parse_int(strings.trim_space(data), 10); vok && v >= 0 {
                return f32(v) / 100, true
            }
        }
    }
    return 0, false
}

// Loads uid -> username from /etc/passwd (name:passwd:uid:...). Names are OWNED.
@(private = "file")
proc_load_users :: proc() -> map[int]string {
    out := make(map[int]string)
    data, ok := proc_read("/etc/passwd", context.allocator)
    if !ok {
        return out
    }
    defer delete(data)
    s := data
    for line in strings.split_lines_iterator(&s) {
        f := strings.split(line, ":", context.temp_allocator)
        if len(f) < 3 {
            continue
        }
        if uid, uok := strconv.parse_int(f[2], 10); uok {
            if _, seen := out[uid]; !seen {
                out[uid] = strings.clone(f[0])
            }
        }
    }
    return out
}

// --- formatting helpers (shared with draw_procmon in render.odin) ---

// Human kB (1234567 -> "1.2 GB"). Temp-allocated.
proc_human_kb :: proc(kb: u64) -> string {
    f := f64(kb)
    if kb >= 1024 * 1024 {
        return fmt.tprintf("%.1f GB", f / (1024 * 1024))
    }
    if kb >= 1024 {
        return fmt.tprintf("%.0f MB", f / 1024)
    }
    return fmt.tprintf("%d KB", kb)
}

// Human bytes-per-second. Temp-allocated.
proc_human_bps :: proc(b: f32) -> string {
    if b >= 1024 * 1024 * 1024 {
        return fmt.tprintf("%.1f GB", b / (1024 * 1024 * 1024))
    }
    if b >= 1024 * 1024 {
        return fmt.tprintf("%.1f MB", b / (1024 * 1024))
    }
    if b >= 1024 {
        return fmt.tprintf("%.0f KB", b / 1024)
    }
    return fmt.tprintf("%.0f B", b)
}

// First n runes of s (for fixed-width columns). Returns a slice of s.
proc_trunc :: proc(s: string, n: int) -> string {
    if utf8.rune_count_in_string(s) <= n {
        return s
    }
    count, i := 0, 0
    for i < len(s) && count < n {
        _, w := utf8.decode_rune_in_string(s[i:])
        i += w
        count += 1
    }
    return s[:i]
}

// glfw digit-key -> 0..9 (main row and keypad).
@(private = "file")
proc_digit :: proc(key: i32) -> (int, bool) {
    if key >= glfw.KEY_0 && key <= glfw.KEY_9 {
        return int(key - glfw.KEY_0), true
    }
    if key >= glfw.KEY_KP_0 && key <= glfw.KEY_KP_9 {
        return int(key - glfw.KEY_KP_0), true
    }
    return 0, false
}

// Signal names indexed by number (1..31, Linux). Index 0 is unused.
SIG_NAMES := [32]string {
    0  = "",
    1  = "HUP",
    2  = "INT",
    3  = "QUIT",
    4  = "ILL",
    5  = "TRAP",
    6  = "ABRT",
    7  = "BUS",
    8  = "FPE",
    9  = "KILL",
    10 = "USR1",
    11 = "SEGV",
    12 = "USR2",
    13 = "PIPE",
    14 = "ALRM",
    15 = "TERM",
    16 = "STKFLT",
    17 = "CHLD",
    18 = "CONT",
    19 = "STOP",
    20 = "TSTP",
    21 = "TTIN",
    22 = "TTOU",
    23 = "URG",
    24 = "XCPU",
    25 = "XFSZ",
    26 = "VTALRM",
    27 = "PROF",
    28 = "WINCH",
    29 = "IO",
    30 = "PWR",
    31 = "SYS",
}
