package main

import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import vt "../vendor/libvterm"
import "vendor:glfw"

// A terminal session: the libvterm VT state machine (the pure parser — fed bytes,
// read back as a cell grid) plus the PTY and child shell Slopd owns itself. A
// per-session reader thread does the one blocking read() on the master fd and hands
// raw bytes to the main loop; vterm_* stays main-thread-only.
//
// The VT core (term/screen/state/rows/cols + terminal_feed/cell/cursor/color) is
// GL-free and shell-free, so it is unit-testable on its own (terminal_test). The
// PTY half below is the host integration.
Terminal :: struct {
    term:   vt.VTerm,
    screen: vt.Screen,
    state:  vt.State,
    rows:   int,
    cols:   int,

    // PTY + child shell. pty is the master fd (-1 when there is no child, e.g. a
    // headless test Terminal); alive drops to false when the shell exits (read EOF).
    pty:    posix.FD,
    pid:    posix.pid_t,
    alive:  bool,

    // Reader thread -> main loop handoff. The thread appends PTY output to inbuf
    // under lock and wakes the loop (PostEmptyEvent); the loop drains it into the
    // parser. Only the raw bytes cross threads — never a vterm_* call.
    reader: ^thread.Thread,
    lock:   sync.Mutex,
    inbuf:  [dynamic]u8,

    // Shell-command completion for the command-line chain runner. A wrapped shell
    // command emits its exit code in a private OSC (OSC_EXIT_TAG); the unrecognised-
    // OSC fallback records it here for the main thread to read. exit_id correlates a
    // report with the injection that requested it. All touched only on the main
    // thread (the OSC callback fires inside terminal_feed during a drain).
    fallbacks:  vt.StateFallbacks,
    osc_buf:    [64]u8,
    osc_len:    int,
    exit_ready: bool,
    exit_id:    u64,
    exit_code:  int,
}

// Bring up the VT state machine at the given grid size: UTF-8 in, hard-reset to a
// clean screen. Colours stay libvterm's built-in palette until the host seeds the
// theme defaults via terminal_set_default_colors.
terminal_vt_init :: proc(t: ^Terminal, rows, cols: int) {
    t.rows = max(rows, 1)
    t.cols = max(cols, 1)
    t.pty = -1 // no child until terminal_spawn
    t.term = vt.new(c.int(t.rows), c.int(t.cols))
    vt.set_utf8(t.term, 1)
    t.screen = vt.obtain_screen(t.term)
    t.state = vt.obtain_state(t.term)
    vt.screen_reset(t.screen, 1)
}

terminal_vt_destroy :: proc(t: ^Terminal) {
    if t.term != nil {
        vt.free(t.term) // frees its screen + state too
        t.term = nil
        t.screen = nil
        t.state = nil
    }
}

// Resize the cell grid to match the pane (called from draw). No-op when unchanged,
// so the common settled frame costs nothing. Resizes the parser and, if a child is
// attached, tells the kernel via TIOCSWINSZ so the shell reflows (SIGWINCH).
terminal_resize :: proc(t: ^Terminal, rows, cols: int) {
    rows, cols := max(rows, 1), max(cols, 1)
    if rows == t.rows && cols == t.cols {
        return
    }
    t.rows = rows
    t.cols = cols
    vt.set_size(t.term, c.int(rows), c.int(cols))
    if t.pty >= 0 {
        terminal_set_winsize(t, rows, cols)
    }
}

// Seed the default fg/bg (the colours cells with no SGR request resolve to) from
// the theme, so a fresh shell paints in Slopd's palette rather than white-on-black.
terminal_set_default_colors :: proc(t: ^Terminal, fg, bg: [3]f32) {
    vfg := vt_color(fg)
    vbg := vt_color(bg)
    vt.screen_set_default_colors(t.screen, &vfg, &vbg)
}

// Feed raw output bytes (from the PTY, or a test) through the parser; the cell grid
// updates in place. flush_damage is a no-op for our poll-the-grid model but keeps
// libvterm's internal damage bookkeeping tidy.
terminal_feed :: proc(t: ^Terminal, bytes: []u8) {
    if len(bytes) == 0 {
        return
    }
    vt.input_write(t.term, raw_data(bytes), c.size_t(len(bytes)))
    vt.screen_flush_damage(t.screen)
}

// The cell at (row, col); ok=false out of range. The cell carries libvterm's raw
// fg/bg + attrs — the host resolves colours against the theme at draw time.
terminal_cell :: proc(t: ^Terminal, row, col: int) -> (cell: vt.ScreenCell, ok: bool) {
    if row < 0 || row >= t.rows || col < 0 || col >= t.cols {
        return {}, false
    }
    vt.screen_get_cell(t.screen, vt.Pos{row = c.int(row), col = c.int(col)}, &cell)
    return cell, true
}

// The primary rune drawn in a cell (0 when blank). Combining marks (chars[1..]) are
// ignored for v1's monospace grid.
terminal_cell_rune :: proc(t: ^Terminal, row, col: int) -> rune {
    cell := terminal_cell(t, row, col) or_else vt.ScreenCell{}
    return rune(cell.chars[0])
}

// The current cursor position in cell coordinates.
terminal_cursor :: proc(t: ^Terminal) -> (row, col: int) {
    p: vt.Pos
    vt.state_get_cursorpos(t.state, &p)
    return int(p.row), int(p.col)
}

// Resolve a libvterm cell colour to RGB floats. Default fg/bg keep their flag for
// the caller to map onto the theme; indexed/RGB colours convert through libvterm's
// palette.
terminal_color :: proc(t: ^Terminal, col: vt.Color) -> (rgb: [3]f32, is_default: bool) {
    col := col
    if vt.color_is_default_fg(col) || vt.color_is_default_bg(col) {
        return {}, true
    }
    vt.screen_convert_color_to_rgb(t.screen, &col)
    return {f32(col.red) / 255, f32(col.green) / 255, f32(col.blue) / 255}, false
}

// Pack RGB floats into a libvterm RGB colour (for seeding the theme defaults).
@(private = "file")
vt_color :: proc(rgb: [3]f32) -> vt.Color {
    return vt.Color {
        type = 0, // RGB: the type bit is clear, no default flags
        red = u8(clampf(rgb.r, 0, 1) * 255),
        green = u8(clampf(rgb.g, 0, 1) * 255),
        blue = u8(clampf(rgb.b, 0, 1) * 255),
    }
}

// ---------------------------------------------------------------------------
// PTY + child shell (Slopd owns the PTY in pure core:sys/posix; only TIOCSWINSZ
// needs a foreign ioctl). The window-size ioctl and its struct are the one bit
// outside the posix package.
// ---------------------------------------------------------------------------

TIOCSWINSZ :: 0x5414 // Linux ioctl: set terminal window size

Winsize :: struct {
    ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, argp: rawptr) -> c.int ---
}

// Bring up a session: the VT machine, a master/slave PTY pair, and a forked child
// running $SHELL wired to the slave as its controlling terminal. Returns false (and
// leaves the Terminal with pty == -1) if any step fails. On success a reader thread
// is pumping the master fd.
terminal_spawn :: proc(t: ^Terminal, rows, cols: int) -> bool {
    terminal_vt_init(t, rows, cols)
    vt.output_set_callback(t.term, term_output_cb, t) // query replies -> PTY master
    t.fallbacks = vt.StateFallbacks{osc = term_osc_cb} // exit-code OSC -> t.exit_*
    vt.screen_set_unrecognised_fallbacks(t.screen, &t.fallbacks, t)

    master := posix.posix_openpt({.RDWR, .NOCTTY})
    if master < 0 {
        return false
    }
    if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
        posix.close(master)
        return false
    }
    slave_name := posix.ptsname(master)
    if slave_name == nil {
        posix.close(master)
        return false
    }

    // Build everything the child needs BEFORE the fork: in a multithreaded process
    // the child may only safely touch pre-allocated memory until exec (another
    // thread could hold the malloc lock). ptsname returns a static buffer, so clone
    // the name too.
    name := strings.clone_to_cstring(string(slave_name))
    shell := term_shell()
    argv := []cstring{shell, nil}
    envp := term_build_env()
    defer {
        delete(name)
        delete(shell)
        term_free_env(envp)
    }

    pid := posix.fork()
    if pid < 0 {
        posix.close(master)
        return false
    }
    if pid == 0 {
        // CHILD — pre-allocated cstrings only, no Odin allocation, ending in exec.
        posix.setsid() // new session; the first tty opened becomes controlling
        slave := posix.open(name, {.RDWR}) // no NOCTTY: claim it as the controlling tty
        if slave < 0 {
            posix._exit(127)
        }
        posix.dup2(slave, posix.STDIN_FILENO)
        posix.dup2(slave, posix.STDOUT_FILENO)
        posix.dup2(slave, posix.STDERR_FILENO)
        if slave > posix.STDERR_FILENO {
            posix.close(slave)
        }
        posix.close(master)
        posix.execve(shell, raw_data(argv), envp)
        posix._exit(127) // exec failed
    }

    // PARENT — keep the master fd, start pumping it.
    t.pty = master
    t.pid = pid
    t.alive = true
    terminal_set_winsize(t, rows, cols)
    t.reader = thread.create(term_reader_proc)
    if t.reader == nil {
        terminal_close(t) // reaps the orphaned child + closes the master + frees the vt
        return false
    }
    t.reader.data = t
    thread.start(t.reader)
    return true
}

// Kill the child, join the reader, reap the zombie, then free the VT machine. Safe
// to call on a half-built or already-dead session.
terminal_close :: proc(t: ^Terminal) {
    if t.pid > 0 {
        posix.kill(t.pid, .SIGHUP) // closing the slave drops the shell out of read()
    }
    if t.reader != nil {
        thread.join(t.reader) // its read() returns EOF once the child's slave closes
        thread.destroy(t.reader)
        t.reader = nil
    }
    if t.pid > 0 {
        status: c.int
        posix.waitpid(t.pid, &status, {})
        t.pid = 0
    }
    if t.pty >= 0 {
        posix.close(t.pty)
        t.pty = -1
    }
    delete(t.inbuf)
    t.inbuf = nil
    terminal_vt_destroy(t)
}

// Send keystrokes / responses to the shell. No-op on a session with no child.
terminal_write :: proc(t: ^Terminal, bytes: []u8) {
    if t.pty < 0 || len(bytes) == 0 {
        return
    }
    posix.write(t.pty, raw_data(bytes), c.size_t(len(bytes)))
}

// Drain the bytes the reader thread has buffered into the parser (main thread).
// Holds the lock only across the swap-and-feed; the buffer is normally small.
terminal_drain :: proc(t: ^Terminal) {
    sync.mutex_lock(&t.lock)
    defer sync.mutex_unlock(&t.lock)
    if len(t.inbuf) > 0 {
        terminal_feed(t, t.inbuf[:])
        clear(&t.inbuf)
    }
}

@(private = "file")
terminal_set_winsize :: proc(t: ^Terminal, rows, cols: int) {
    ws := Winsize {
        ws_row = u16(rows),
        ws_col = u16(cols),
    }
    ioctl(t.pty, TIOCSWINSZ, &ws)
}

// The reader thread: one blocking read() on the master fd, append under lock, wake
// the main loop. EOF (read 0) or a real error means the shell exited — mark dead and
// wake once more so the loop drains the final bytes and can reap. EINTR is retried
// (not treated as EOF): the child's own SIGCHLD can land on this thread and would
// otherwise cut the read short, dropping the shell's last output.
@(private = "file")
term_reader_proc :: proc(th: ^thread.Thread) {
    t := (^Terminal)(th.data)
    buf: [4096]u8
    for {
        n := posix.read(t.pty, raw_data(buf[:]), len(buf))
        if n > 0 {
            sync.mutex_lock(&t.lock)
            append(&t.inbuf, ..buf[:n])
            sync.mutex_unlock(&t.lock)
            glfw.PostEmptyEvent()
            continue
        }
        if n < 0 && posix.get_errno() == .EINTR {
            continue // interrupted by a signal — retry rather than treat as EOF
        }
        break // n == 0 (EOF) or a real error
    }
    sync.mutex_lock(&t.lock)
    t.alive = false
    sync.mutex_unlock(&t.lock)
    glfw.PostEmptyEvent()
}

// libvterm's reply bytes (cursor-position reports, device attributes, ...) go
// straight to the shell. "c" callback: no Odin context, only the foreign write.
@(private = "file")
term_output_cb :: proc "c" (s: [^]u8, len: c.size_t, user: rawptr) {
    t := (^Terminal)(user)
    if t.pty >= 0 {
        posix.write(t.pty, s, len)
    }
}

// The private OSC the command-line chain runner wraps shell commands with to learn
// their exit code: `OSC 697 ; <id> ; <code> ST`. libvterm parses (and hides) it,
// handing the payload here. The id correlates the report with the injection.
OSC_EXIT_TAG :: 697

// Unrecognised-OSC fallback: capture the exit-code payload (may arrive in fragments)
// into osc_buf, parse it on the final piece. "c" callback — no context.
@(private = "file")
term_osc_cb :: proc "c" (command: c.int, frag: vt.StringFragment, user: rawptr) -> c.int {
    if int(command) != OSC_EXIT_TAG {
        return 0
    }
    t := (^Terminal)(user)
    if frag.initial {
        t.osc_len = 0
    }
    for i in 0 ..< int(frag.len) {
        if t.osc_len < len(t.osc_buf) {
            t.osc_buf[t.osc_len] = frag.str[i]
            t.osc_len += 1
        }
    }
    if frag.final {
        term_parse_exit(t, t.osc_buf[:t.osc_len])
    }
    return 1
}

// Parse "<id>;<code>" from the OSC payload into the exit slot. Contextless so the
// "c" callback can call it; hand-rolled digit parsing for the same reason.
@(private = "file")
term_parse_exit :: proc "contextless" (t: ^Terminal, payload: []u8) {
    id: u64
    code: int
    neg := false
    i := 0
    for i < len(payload) && payload[i] != ';' {
        if d := payload[i]; d >= '0' && d <= '9' {
            id = id * 10 + u64(d - '0')
        }
        i += 1
    }
    if i >= len(payload) {
        return // no ';' — malformed, ignore
    }
    for i += 1; i < len(payload); i += 1 {
        switch d := payload[i]; {
        case d == '-':
            neg = true
        case d >= '0' && d <= '9':
            code = code * 10 + int(d - '0')
        }
    }
    t.exit_code = neg ? -code : code
    t.exit_id = id
    t.exit_ready = true
}

// $SHELL when it is an absolute path, else /bin/sh. Absolute lets the child exec
// without a PATH search (which would allocate) — important across the fork.
@(private = "file")
term_shell :: proc() -> cstring {
    sh := os.get_env("SHELL", context.temp_allocator)
    if len(sh) > 0 && sh[0] == '/' {
        return strings.clone_to_cstring(sh)
    }
    return strings.clone_to_cstring("/bin/sh")
}

// A copy of the current environment with TERM forced to xterm-256color, as a
// nil-terminated [^]cstring for execve. Built before the fork (see terminal_spawn).
@(private = "file")
term_build_env :: proc() -> [^]cstring {
    env := make([dynamic]cstring)
    for e := posix.environ; e[0] != nil; e = e[1:] {
        if !strings.has_prefix(string(e[0]), "TERM=") {
            append(&env, e[0]) // borrow the existing entry (static C strings)
        }
    }
    append(&env, strings.clone_to_cstring("TERM=xterm-256color"))
    append(&env, nil) // execve terminator
    return raw_data(env)
}

@(private = "file")
term_free_env :: proc(envp: [^]cstring) {
    // Only the TERM entry was cloned by us; it sits just before the nil terminator.
    for e := envp; e[0] != nil; e = e[1:] {
        if strings.has_prefix(string(e[0]), "TERM=") {
            delete(e[0])
        }
    }
    free(envp)
}

// ---------------------------------------------------------------------------
// Session list on App. Terminals are heap-allocated and stored by pointer so the
// dynamic array growing never moves a Terminal out from under its reader thread
// (which holds a ^Terminal) or invalidates its Mutex.
// ---------------------------------------------------------------------------

TERM_MAX :: 99
TERM_INIT_ROWS :: 24 // spawn size; draw_terminal resizes to the real pane next frame
TERM_INIT_COLS :: 80

term_count :: proc(a: ^App) -> int {
    return len(a.terminals)
}

term_current :: proc(a: ^App) -> ^Terminal {
    if a.term_active < 0 || a.term_active >= len(a.terminals) {
        return nil
    }
    return a.terminals[a.term_active]
}

// Lazily spawn the first session the moment the terminal pane is shown, so opening
// no terminal costs no shell process.
term_ensure :: proc(a: ^App) {
    if len(a.terminals) == 0 {
        term_new(a)
    }
}

// Add a session (Alt+N / lazy spawn) and focus it; capped at TERM_MAX.
term_new :: proc(a: ^App) {
    if len(a.terminals) >= TERM_MAX {
        return
    }
    t := new(Terminal)
    if !terminal_spawn(t, TERM_INIT_ROWS, TERM_INIT_COLS) {
        free(t)
        return
    }
    append(&a.terminals, t)
    a.term_active = len(a.terminals) - 1
}

// Close the active session (Alt+Q), keeping at least one alive.
term_close_active :: proc(a: ^App) {
    if len(a.terminals) <= 1 {
        return
    }
    t := a.terminals[a.term_active]
    if a.cl_chain.wait_term == t {
        cl_chain_clear(a) // a pending chain was waiting on this session — abandon it
    }
    terminal_close(t)
    free(t)
    ordered_remove(&a.terminals, a.term_active)
    if a.term_active >= len(a.terminals) {
        a.term_active = len(a.terminals) - 1
    }
}

// Tear down every session (app shutdown): kill children, join reader threads.
term_destroy_all :: proc(a: ^App) {
    for t in a.terminals {
        terminal_close(t)
        free(t)
    }
    delete(a.terminals)
}

// ---------------------------------------------------------------------------
// Input routing. When a live terminal is focused it owns bare + Ctrl keys; Alt
// stays global (handled before this in input.odin), so the shell never sees an
// Alt-chord. Keys feed vterm_keyboard_*, whose output callback writes the encoded
// bytes to the PTY master.
// ---------------------------------------------------------------------------

// The focused session if it is live (keys route here), else nil. `alive` is read
// without the lock — a benign race: a stale read just sends a keystroke to a shell
// that has exited, where the write to the closed master is harmlessly dropped.
term_focused :: proc(a: ^App) -> ^Terminal {
    if a.cl_active { // the command line overlays the terminal and owns keys while open
        return nil
    }
    if a.focus != .Aux || a.aux_mode != .Terminal {
        return nil
    }
    t := term_current(a)
    if t == nil || !t.alive {
        return nil
    }
    return t
}

// A printable character typed at a focused terminal (from char_callback). Shift is
// already baked into the codepoint, so the modifier is none.
terminal_input_rune :: proc(t: ^Terminal, r: rune) {
    vt.keyboard_unichar(t.term, u32(r), vt.MOD_NONE)
}

// A non-text key (or Ctrl-combo) at a focused terminal. Printable keys produce no
// char-less event and are left to char_callback; this maps the specials that do —
// Enter/Tab/Backspace/Escape/arrows/Home/End/Ins/Del/PageUp/Down — plus Ctrl+letter
// (which GLFW emits no char event for) as a control unichar.
terminal_input_key :: proc(t: ^Terminal, key, mods: i32) {
    vk: vt.Key
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        vk = .Enter
    case glfw.KEY_TAB:
        vk = .Tab
    case glfw.KEY_BACKSPACE:
        vk = .Backspace
    case glfw.KEY_ESCAPE:
        vk = .Escape
    case glfw.KEY_UP:
        vk = .Up
    case glfw.KEY_DOWN:
        vk = .Down
    case glfw.KEY_LEFT:
        vk = .Left
    case glfw.KEY_RIGHT:
        vk = .Right
    case glfw.KEY_HOME:
        vk = .Home
    case glfw.KEY_END:
        vk = .End
    case glfw.KEY_INSERT:
        vk = .Ins
    case glfw.KEY_DELETE:
        vk = .Del
    case glfw.KEY_PAGE_UP:
        vk = .PageUp
    case glfw.KEY_PAGE_DOWN:
        vk = .PageDown
    case:
        // Ctrl+<letter> has no char event; send it as a control unichar (Ctrl+C ->
        // 0x03, etc.). Alt is global, so it never reaches here.
        if mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_ALT == 0 {
            if key >= glfw.KEY_A && key <= glfw.KEY_Z {
                vt.keyboard_unichar(t.term, u32(key - glfw.KEY_A + 'a'), vt.MOD_CTRL)
            }
        }
        return
    }
    vt.keyboard_key(t.term, vk, term_mods(mods))
}

// GLFW modifier bits -> libvterm modifier (Shift/Ctrl only; Alt stays global).
@(private = "file")
term_mods :: proc(mods: i32) -> vt.Modifier {
    m := i32(0)
    if mods & glfw.MOD_SHIFT != 0 {
        m |= i32(vt.MOD_SHIFT)
    }
    if mods & glfw.MOD_CONTROL != 0 {
        m |= i32(vt.MOD_CTRL)
    }
    return vt.Modifier(m)
}
