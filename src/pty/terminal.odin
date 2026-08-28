package pty

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import vt "../../bindings/libvterm"
import "vendor:glfw"
import "../wake"
import "../txt"
import "../ui"

// A terminal session: the libvterm VT state machine plus the PTY and child shell. A
// per-session reader thread does the one blocking read() on the master fd; vterm_* stays
// main-thread-only. The VT core is GL-free and shell-free, so terminal_test drives it alone.
Terminal :: struct {
    term:   vt.VTerm,
    screen: vt.Screen,
    state:  vt.State,
    rows:   int,
    cols:   int,

    // PTY + child shell. pty is the master fd (-1 when there is no child, e.g. a
    // headless test Terminal); alive drops to false when the shell exits (read EOF). It is the
    // one field the reader thread writes that is not `inbuf`, so it is touched atomically --
    // see terminal_alive.
    pty:   posix.FD,
    pid:   posix.pid_t,
    alive: bool,

    // Alt+L. A locked session keeps its own cwd: `:tu` skips it, the switcher greys its
    // number. Advisory only.
    locked: bool,

    // Reader thread -> main loop: the thread appends under lock and wakes the loop, which
    // drains into the parser. Only raw bytes cross threads, never a vterm_* call.
    reader:  ^thread.Thread,
    lock:    sync.Mutex,
    inbuf:   [dynamic]u8,
    feedbuf: [dynamic]u8,

    // For the CL chain runner: a wrapped command emits its exit code in a private OSC
    // (OSC_EXIT_TAG), recorded here with exit_id correlating it to the injection.
    fallbacks:  vt.StateFallbacks,
    osc_buf:    [64]u8,
    osc_len:    int,
    exit_ready: bool,
    exit_id:    u64,
    exit_code:  int,

    // Scrollback + the keyboard's row-only copy cursor. `sb_total` counts every line ever
    // pushed, giving each a stable absolute number: scrollback[i] is sb_total-len+i, live row
    // r is sb_total+r.
    callbacks:  vt.ScreenCallbacks,
    sb_ctx:     runtime.Context, // context the sb_* "c" callbacks allocate under
    scrollback: [dynamic]ScrollLine,
    sb_total:   int,
    sel_active: bool, // line-select / scroll mode on (cursor shown)
    sel_head:   int,  // absolute line of the copy cursor (the moving edge)
    sel_anchor: int,  // absolute line the selection is pinned at (== head: no span)
    view_top:   int,  // absolute line drawn at the top row while scrolled
    // The wheel cut the view loose from the live bottom — the twin of every list pane's
    // `scroll_detached`. Cleared by any keystroke reaching the shell, or a notch back down.
    view_detached: bool,

    // The mouse's per-character selection, beside the keyboard's copy cursor. `Cursor`/`Pos`
    // are the editor's — shared algebra, separate storage. Pos.line is absolute; Pos.col is a
    // boundary between cells, 0..=width.
    msel:    txt.Cursor,
    msel_on: bool,
    // A TUI on the alt buffer owns its own scrolling, so these route scroll input there.
    on_altscreen: bool,
    mouse_on:     bool, // the TUI enabled mouse tracking
}

// A clone of the cells libvterm handed us as the line scrolled off. Owned by the Terminal.
ScrollLine :: struct {
    cells:        []vt.ScreenCell,
    // The line above wrapped (libvterm's sb_pushline4) — what makes a copied soft-wrapped
    // command paste back as one line. Captured because libvterm forgets a row in history.
    continuation: bool,
}

// Lines kept, and the slack before trimming the oldest in one batch (amortised O(1) per line
// rather than an O(n) shift on every scrolled line).
SCROLLBACK_MAX  :: 5000
SCROLLBACK_TRIM :: SCROLLBACK_MAX / 8

// UTF-8 in, hard-reset to a clean screen. Colours stay libvterm's palette until
// terminal_set_default_colors seeds the theme.
terminal_vt_init :: proc(t: ^Terminal, rows, cols: int) {
    t.rows = max(rows, 1)
    t.cols = max(cols, 1)
    t.pty = -1 // no child until terminal_spawn
    t.term = vt.new(c.int(t.rows), c.int(t.cols))
    vt.set_utf8(t.term, 1)
    t.screen = vt.obtain_screen(t.term)
    t.state = vt.obtain_state(t.term)
    // Without this DECSET 1049 is a no-op and a TUI paints over the primary grid, spilling
    // every redraw into our scrollback.
    vt.screen_enable_altscreen(t.screen, 1)
    vt.screen_reset(t.screen, 1)
}

terminal_vt_destroy :: proc(t: ^Terminal) {
    if t.term != nil {
        vt.free(t.term) // frees its screen + state too
        t.term = nil
        t.screen = nil
        t.state = nil
    }
    for line in t.scrollback {
        delete(line.cells)
    }
    delete(t.scrollback)
    t.scrollback = nil
}

// Called from draw; no-op when unchanged. TIOCSWINSZ makes the shell reflow (SIGWINCH).
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

// The colours cells with no SGR request resolve to, so a fresh shell paints in our palette.
terminal_set_default_colors :: proc(t: ^Terminal, fg, bg: [3]f32) {
    vfg := vt_color(fg)
    vbg := vt_color(bg)
    vt.screen_set_default_colors(t.screen, &vfg, &vbg)
}

// Raw output bytes through the parser; the cell grid updates in place. flush_damage is a
// no-op for our poll-the-grid model, but keeps libvterm's bookkeeping tidy.
terminal_feed :: proc(t: ^Terminal, bytes: []u8) {
    if len(bytes) == 0 {
        return
    }
    vt.input_write(t.term, raw_data(bytes), c.size_t(len(bytes)))
    vt.screen_flush_damage(t.screen)
}

// ok=false out of range. Carries libvterm's raw fg/bg + attrs; the host resolves colours at
// draw time.
terminal_cell :: proc(t: ^Terminal, row, col: int) -> (cell: vt.ScreenCell, ok: bool) {
    if row < 0 || row >= t.rows || col < 0 || col >= t.cols {
        return {}, false
    }
    vt.screen_get_cell(t.screen, vt.Pos{row = c.int(row), col = c.int(col)}, &cell)
    return cell, true
}

// The primary rune (0 when blank). Combining marks are ignored on the monospace grid.
terminal_cell_rune :: proc(t: ^Terminal, row, col: int) -> rune {
    cell := terminal_cell(t, row, col) or_else vt.ScreenCell{}
    return rune(cell.chars[0])
}

terminal_cursor :: proc(t: ^Terminal) -> (row, col: int) {
    p: vt.Pos
    vt.state_get_cursorpos(t.state, &p)
    return int(p.row), int(p.col)
}

// Default fg/bg keep their flag for the caller to map onto the theme; the rest convert
// through libvterm's palette.
terminal_color :: proc(t: ^Terminal, col: vt.Color) -> (rgb: [3]f32, is_default: bool) {
    col := col
    if vt.color_is_default_fg(col) || vt.color_is_default_bg(col) {
        return {}, true
    }
    vt.screen_convert_color_to_rgb(t.screen, &col)
    return {f32(col.red) / 255, f32(col.green) / 255, f32(col.blue) / 255}, false
}

// For seeding the theme defaults.
@(private = "file")
vt_color :: proc(rgb: [3]f32) -> vt.Color {
    return vt.Color {
        type  = 0, // RGB: type bit clear, no default flags
        red   = u8(clamp(rgb.r, 0, 1) * 255),
        green = u8(clamp(rgb.g, 0, 1) * 255),
        blue  = u8(clamp(rgb.b, 0, 1) * 255),
    }
}

// --- scrollback view + keyboard line-selection ---
// An absolute-numbered space: [oldest, sb_total) is scrollback, [sb_total, bottom] the live
// grid. A row-only copy cursor walks it and the view follows; Esc / typing snap to the bottom.

terminal_oldest :: proc(t: ^Terminal) -> int {
    return t.sb_total - len(t.scrollback)
}

terminal_bottom :: proc(t: ^Terminal) -> int {
    return t.sb_total + t.rows - 1
}

// From the live grid when `n` is on-screen, else from captured scrollback.
terminal_view_cell :: proc(t: ^Terminal, n, col: int) -> (cell: vt.ScreenCell, ok: bool) {
    if n >= t.sb_total {
        return terminal_cell(t, n - t.sb_total, col)
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return {}, false
    }
    line := t.scrollback[idx]
    if col < 0 || col >= len(line.cells) {
        return {}, false
    }
    return line.cells[col], true
}

// The scrolled position while selecting, else the live grid top. A mouse selection pins it
// too, or a click retiring the copy cursor would throw away the scroll that enabled it.
terminal_view_top :: proc(t: ^Terminal) -> int {
    top := t.sel_active || t.msel_on || t.view_detached ? t.view_top : t.sb_total
    return clamp(top, terminal_oldest(t), t.sb_total)
}

// The wheel's verb: the view only. A wheel is not a cursor movement, so a mouse selection
// survives a scroll.
terminal_scroll_by :: proc(t: ^Terminal, delta: int) {
    if delta == 0 {
        return
    }
    t.view_top = clamp(terminal_view_top(t) + delta, terminal_oldest(t), t.sb_total)
    // Detached means parked above the live bottom, not "the wheel was touched": a notch back
    // onto the bottom means follow again.
    t.view_detached = t.view_top < t.sb_total
}

// A captured line keeps its capture width, a live row is the current grid width. One
// definition: the copy walk, the clamp and the blank trim all need it to agree.
terminal_line_width :: proc(t: ^Terminal, n: int) -> int {
    if n >= t.sb_total {
        return t.cols
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return 0
    }
    return len(t.scrollback[idx].cells)
}

// Did the line above wrap? A live row is libvterm's (state_get_lineinfo), a scrolled-off row
// is ours. Unanswerable after a resize pops one back — sb_popline has no 4-argument form.
terminal_continuation :: proc(t: ^Terminal, n: int) -> bool {
    if n >= t.sb_total {
        row := n - t.sb_total
        if row < 0 || row >= t.rows || t.state == nil {
            return false
        }
        li := vt.state_get_lineinfo(t.state, c.int(row))
        return li != nil && li.continuation
    }
    idx := n - terminal_oldest(t)
    if idx < 0 || idx >= len(t.scrollback) {
        return false
    }
    return t.scrollback[idx].continuation
}

// The run of rows one wrapped command occupies. What a triple click selects.
terminal_logical_line :: proc(t: ^Terminal, n: int) -> (first, last: int) {
    first, last = n, n
    for first > terminal_oldest(t) && terminal_continuation(t, first) {
        first -= 1
    }
    for last < terminal_bottom(t) && terminal_continuation(t, last + 1) {
        last += 1
    }
    return
}

// Half-open [lo, hi), lo==hi being the bare copy cursor: the cursor is a boundary, not a line,
// drawn as a rule along the top edge. Inclusive would pick up the line the anchor left.
terminal_sel_range :: proc(t: ^Terminal) -> (lo, hi: int) {
    return min(t.sel_anchor, t.sel_head), max(t.sel_anchor, t.sel_head)
}

// Negative delta goes into history; the first move off the live bottom enters select mode.
// `extend` (Shift) keeps the anchor. Returning to the bottom with no span leaves select mode.
terminal_sel_move :: proc(t: ^Terminal, delta: int, extend: bool) {
    // The two selections are alternatives, not layers. Only ever a real keystroke — the wheel
    // has terminal_scroll_by.
    terminal_msel_reset(t)
    if !t.sel_active {
        // Read before sel_active flips — terminal_view_top answers differently once set.
        // Seeding from the on-screen bottom stops a wheel-scrolled view snapping back.
        top := terminal_view_top(t)
        t.sel_active = true
        t.sel_head = clamp(top + t.rows - 1, terminal_oldest(t), terminal_bottom(t))
        t.sel_anchor = t.sel_head
        t.view_top = top
    }
    t.view_detached = false // the keyboard owns the view again
    // On the alt screen the history is the TUI's, so the floor is the top live row and pushing
    // past an edge tells the TUI to scroll.
    floor := terminal_oldest(t)
    if t.on_altscreen {
        floor = t.sb_total
        if t.sel_head + delta < t.sb_total {
            terminal_scroll_tui(t, -1)
        } else if t.sel_head + delta > terminal_bottom(t) {
            terminal_scroll_tui(t, 1)
        }
    }
    t.sel_head = clamp(t.sel_head + delta, floor, terminal_bottom(t))
    if !extend {
        t.sel_anchor = t.sel_head
    }
    // Bottom with nothing selected: nothing to copy, so leave select mode.
    if t.sel_head == terminal_bottom(t) && t.sel_anchor == terminal_bottom(t) {
        t.sel_active = false
        return
    }
    if t.sel_head < t.view_top {
        t.view_top = t.sel_head
    } else if t.sel_head > t.view_top + t.rows - 1 {
        t.view_top = t.sel_head - t.rows + 1
    }
    t.view_top = clamp(t.view_top, floor, t.sb_total)
}

// Esc, or any real keystroke to the shell: hide the cursor, snap back to the live bottom, and
// drop the mouse's selection with it.
terminal_sel_reset :: proc(t: ^Terminal) {
    t.sel_active = false
    t.view_detached = false
    terminal_msel_reset(t)
}

// --- the mouse's per-character selection: pointer twins of the Doc's four verbs ---
//   terminal_clamp_pos  doc_clamp_pos     terminal_msel_head   doc_set_head
//   terminal_msel_set   doc_select_span   terminal_grade_span  doc_drag_span

// doc_clamp_pos's twin: a resize between the press and the frame applying it costs a selection
// end on the wrong line, never an index off the scrollback.
terminal_clamp_pos :: proc(t: ^Terminal, p: txt.Pos) -> txt.Pos {
    floor := t.on_altscreen ? t.sb_total : terminal_oldest(t)
    line := clamp(p.line, floor, terminal_bottom(t))
    return txt.Pos{line, clamp(p.col, 0, terminal_line_width(t, line))}
}

// doc_select_span's twin. Retires the copy cursor and carries the view over: reading through
// terminal_view_top before msel_on flips keeps a scrolled view where it is.
terminal_msel_set :: proc(t: ^Terminal, anchor, head: txt.Pos) {
    a := terminal_clamp_pos(t, anchor)
    h := terminal_clamp_pos(t, head)
    if !t.msel_on {
        t.view_top = terminal_view_top(t)
    }
    t.sel_active = false
    t.msel = txt.Cursor{anchor = a, head = h, goal = h.col}
    t.msel_on = true
}

// doc_set_head with select=true: Shift+click, and every frame of a character-grade drag. With
// nothing selected it starts an empty one there, to extend from.
terminal_msel_head :: proc(t: ^Terminal, p: txt.Pos) {
    if !t.msel_on {
        terminal_msel_set(t, p, p)
        return
    }
    h := terminal_clamp_pos(t, p)
    t.msel.head = h
    t.msel.goal = h.col
}

// The view is not restored here: terminal_view_top falls back to the live bottom once neither
// selection is live, and a caller wanting it kept sets one up in the same frame.
terminal_msel_reset :: proc(t: ^Terminal) {
    t.msel_on = false
    t.msel = {}
}

// A span, not just a resting caret, so a click that selected nothing does not make
// Ctrl+Shift+C yield "".
terminal_msel_has_span :: proc(t: ^Terminal) -> bool {
    return t.msel_on && txt.cursor_has_selection(t.msel)
}

// The run of one character class around `col`, using src/txt's word_span (the editor's double
// click). That answers in bytes, so the row is materialised as a Cells to convert the column in
// and the span back out. Blanks normalise to spaces.
terminal_word_span :: proc(t: ^Terminal, n, col: int) -> (lo, hi: int) {
    w := terminal_line_width(t, n)
    if w <= 0 {
        return 0, 0
    }
    rs := make([]rune, w, context.temp_allocator)
    offs := make([]int, w + 1, context.temp_allocator)
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< w {
        r := terminal_view_rune(t, n, i)
        rs[i] = r >= 0x20 ? r : ' '
        offs[i] = strings.builder_len(b)
        strings.write_rune(&b, rs[i])
    }
    offs[w] = strings.builder_len(b)
    cells := txt.Cells{rs, offs}
    blo, bhi := txt.word_span(transmute([]u8)strings.to_string(b), txt.cells_off(cells, col))
    return txt.cells_col(cells, blo), txt.cells_col(cells, bhi)
}

// doc_drag_span's twin: word (2) or line (3+). `press` and `at` carry cell columns, not
// boundaries. Line grade takes the whole logical line, so a triple click gets a wrapped
// command whole.
terminal_grade_span :: proc(t: ^Terminal, grade: int, press, at: txt.Pos) -> (anchor, head: txt.Pos) {
    p := terminal_clamp_pos(t, press)
    q := terminal_clamp_pos(t, at)
    if grade >= 3 {
        if q.line >= p.line {
            first, _ := terminal_logical_line(t, p.line)
            _, last := terminal_logical_line(t, q.line)
            return txt.Pos{first, 0}, txt.Pos{last, terminal_line_width(t, last)}
        }
        _, last := terminal_logical_line(t, p.line)
        first, _ := terminal_logical_line(t, q.line)
        return txt.Pos{last, terminal_line_width(t, last)}, txt.Pos{first, 0}
    }
    plo, phi := terminal_word_span(t, p.line, p.col)
    qlo, qhi := terminal_word_span(t, q.line, q.col)
    if !txt.pos_less(q, p) {
        return txt.Pos{p.line, plo}, txt.Pos{q.line, qhi}
    }
    return txt.Pos{p.line, phi}, txt.Pos{q.line, qlo}
}

// Caller owns the result. Two selections, one walk: the keyboard's row range becomes the pair
// of boundaries spanning whole lines, which is what the mouse's already is.
terminal_selection_text :: proc(t: ^Terminal, alloc := context.allocator) -> string {
    if t.msel_on {
        lo, hi := txt.cursor_range(t.msel)
        return terminal_range_text(t, lo, hi, alloc)
    }
    if !t.sel_active {
        return ""
    }
    // [lo, hi) in lines: the whole of hi-1 is the last thing in it.
    lo, hi := terminal_sel_range(t)
    if lo == hi {
        return ""
    }
    return terminal_range_text(t, txt.Pos{lo, 0}, txt.Pos{hi - 1, terminal_line_width(t, hi - 1)}, alloc)
}

// Clipped per line and joined by newlines, except a flow continuation which joins with
// nothing, or a wrapped shell line comes back unpasteable. The trailing-blank trim applies
// only where a segment runs to the row's edge.
terminal_range_text :: proc(t: ^Terminal, lo, hi: txt.Pos, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    if hi.line < lo.line {
        return strings.to_string(b)
    }
    for n in lo.line ..= hi.line {
        w := terminal_line_width(t, n)
        start := n == lo.line ? clamp(lo.col, 0, w) : 0
        end := n == hi.line ? clamp(hi.col, 0, w) : w
        if end >= w {
            last := start - 1 // last visible glyph
            for col in start ..< w {
                if r := terminal_view_rune(t, n, col); r > 0x20 {
                    last = col
                }
            }
            end = last + 1
        }
        for col in start ..< end {
            r := terminal_view_rune(t, n, col)
            strings.write_rune(&b, r >= 0x20 ? r : ' ')
        }
        if n < hi.line && !terminal_continuation(t, n + 1) {
            strings.write_byte(&b, '\n')
        }
    }
    return strings.to_string(b)
}

@(private = "file")
terminal_view_rune :: proc(t: ^Terminal, n, col: int) -> rune {
    cell := terminal_view_cell(t, n, col) or_else vt.ScreenCell{}
    return rune(cell.chars[0])
}

// --- PTY + child shell --- Pure core:sys/posix; TIOCSWINSZ is the one foreign bit.

TIOCSWINSZ :: 0x5414 // Linux ioctl: set terminal window size

Winsize :: struct {
    ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, argp: rawptr) -> c.int ---
}

// The VT machine, a master/slave PTY pair, and a forked child running $SHELL with the slave as
// its controlling terminal. On success a reader thread is pumping the master fd.
terminal_spawn :: proc(t: ^Terminal, rows, cols: int, cwd := "") -> bool {
    terminal_vt_init(t, rows, cols)
    vt.output_set_callback(t.term, term_output_cb, t) // query replies -> PTY master
    t.fallbacks = vt.StateFallbacks{osc = term_osc_cb} // exit-code OSC -> t.exit_*
    vt.screen_set_unrecognised_fallbacks(t.screen, &t.fallbacks, t)
    terminal_enable_scrollback(t)

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

    // Everything the child needs, built BEFORE the fork: in a multithreaded process it may only
    // touch pre-allocated memory until exec. ptsname returns a static buffer, so clone it.
    name := strings.clone_to_cstring(string(slave_name))
    shell := term_shell()
    argv := []cstring{shell, nil}
    envp := term_build_env()
    // The child chdir's here before exec; empty leaves it in our own cwd.
    dir := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd)
    defer {
        delete(name)
        delete(shell)
        delete(dir)
        term_free_env(envp)
    }

    pid := posix.fork()
    if pid < 0 {
        posix.close(master)
        return false
    }
    if pid == 0 {
        // CHILD — pre-allocated cstrings only, no Odin allocation, ending in exec.
        if dir != nil {
            posix.chdir(dir) // best effort
        }
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

    t.pty = master
    t.pid = pid
    sync.atomic_store(&t.alive, true)
    terminal_set_winsize(t, rows, cols)
    t.reader = thread.create(term_reader_proc)
    if t.reader == nil {
        terminal_close(t) // reaps the child, closes the master, frees the vt
        return false
    }
    t.reader.data = t
    thread.start(t.reader)
    return true
}

// Safe on a half-built or already-dead session.
terminal_close :: proc(t: ^Terminal) {
    if t.pid > 0 {
        posix.kill(t.pid, .SIGHUP)
    }
    if t.reader != nil {
        thread.join(t.reader) // its read() hits EOF once the child's slave closes
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
    delete(t.feedbuf)
    t.inbuf, t.feedbuf = nil, nil
    terminal_vt_destroy(t)
}

terminal_write :: proc(t: ^Terminal, bytes: []u8) {
    if t.pty < 0 || len(bytes) == 0 {
        return
    }
    posix.write(t.pty, raw_data(bytes), c.size_t(len(bytes)))
}

// Clipboard text made safe to send as keystrokes. Newlines become CR (what Enter sends; CRLF
// is one ending), tabs survive, every other C0 control is dropped — an ESC could otherwise
// forge the paste end marker and hand the shell the rest as commands.
terminal_paste_sanitize :: proc(text: string, alloc := context.allocator) -> []u8 {
    out := make([dynamic]u8, 0, len(text), alloc)
    for i := 0; i < len(text); i += 1 {
        switch b := text[i]; {
        case b == '\r' || b == '\n':
            append(&out, '\r')
            if b == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
                i += 1
            }
        case b == '\t' || b >= 0x20 && b != 0x7f: // >= 0x80 is UTF-8 and passes
            append(&out, b)
        }
    }
    return out[:]
}

// Sanitised bytes to the PTY inside bracketed-paste markers, so a multi-line paste lands in
// the line editor instead of executing line by line.
terminal_paste :: proc(t: ^Terminal, text: string) {
    bytes := terminal_paste_sanitize(text, context.temp_allocator)
    if len(bytes) == 0 {
        return
    }
    terminal_sel_reset(t) // a paste is input
    vt.keyboard_start_paste(t.term)
    terminal_write(t, bytes)
    vt.keyboard_end_paste(t.term)
}

// Reader bytes into the parser (main thread). The lock is held across the swap only — holding
// it through terminal_feed's whole state machine is backpressure on the PTY for no gain.
terminal_drain :: proc(t: ^Terminal) {
    sync.mutex_lock(&t.lock)
    if len(t.inbuf) == 0 {
        sync.mutex_unlock(&t.lock)
        return
    }
    t.inbuf, t.feedbuf = t.feedbuf, t.inbuf // feedbuf was cleared after the last parse
    sync.mutex_unlock(&t.lock)

    terminal_feed(t, t.feedbuf[:])
    clear(&t.feedbuf)
}

@(private = "file")
terminal_set_winsize :: proc(t: ^Terminal, rows, cols: int) {
    ws := Winsize {
        ws_row = u16(rows),
        ws_col = u16(cols),
    }
    ioctl(t.pty, TIOCSWINSZ, &ws)
}

// One blocking read() on the master fd, append under lock, wake the loop. EOF or an error
// means the shell exited — mark dead and wake once more so the last bytes are drained. EINTR
// is retried: the child's SIGCHLD can land on this thread.
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
            wake.post()
            continue
        }
        if n < 0 && posix.get_errno() == .EINTR {
            continue
        }
        break // n == 0 (EOF) or a real error
    }
    sync.atomic_store(&t.alive, false)
    wake.post()
}

// Stores a self-pointer in libvterm, so call it only once `t` has a stable address — the test
// core returns a Terminal by value and must call it on the settled copy.
terminal_enable_scrollback :: proc(t: ^Terminal) {
    // The "c" callbacks carry no Odin context; capture the caller's so scrollback is allocated
    // under the same allocator terminal_vt_destroy frees it with.
    t.sb_ctx = context
    t.callbacks = vt.ScreenCallbacks {
        sb_pushline4 = term_sb_pushline_cb,
        sb_popline   = term_sb_popline_cb,
        settermprop  = term_settermprop_cb,
    }
    vt.screen_set_callbacks(t.screen, &t.callbacks, t)
    // The 4-argument pushline: the 3-argument form drops the wrapped bit, and a copied
    // soft-wrapped command comes back in two pieces. Must precede the first scroll-off.
    vt.screen_callbacks_has_pushline4(t.screen)
}

// We track ALTSCREEN and MOUSE. While a TUI is up it owns scrolling, so PageUp routes there
// (src/slopd/input.odin). "c" callback on the main thread — a flag write, no context needed.
@(private = "file")
term_settermprop_cb :: proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    switch prop {
    case vt.PROP_ALTSCREEN:
        t.on_altscreen = (^c.int)(val)^ != 0
    case vt.PROP_MOUSE:
        t.mouse_on = (^c.int)(val)^ != 0
    }
    return 1
}

// Does a wheel notch belong to the child? Asked by the wheel and the click alike: yes if it
// asked for either mouse reports or the alt screen (splitting them disagrees over an inline
// `fzf --height`). Shift overrides.
terminal_wheel_forwards :: proc(t: ^Terminal, shift: bool) -> bool {
    if t == nil || shift {
        return false
    }
    return t.mouse_on || t.on_altscreen
}

// Button 4/5 when the TUI tracks the mouse, else the page key. Others send arrows, gated on
// DECSET 1007, which libvterm lacks.
terminal_scroll_tui :: proc(t: ^Terminal, dir: int) {
    if t.pty < 0 {
        return
    }
    if t.mouse_on {
        vt.mouse_move(t.term, c.int(dir < 0 ? 0 : t.rows - 1), 0, vt.MOD_NONE)
        vt.mouse_button(t.term, dir < 0 ? 4 : 5, true, vt.MOD_NONE)
    } else {
        vt.keyboard_key(t.term, dir < 0 ? .PageUp : .PageDown, vt.MOD_NONE)
    }
}

// Clone the scrolled-off cells and bump the running total so absolute numbers stay stable,
// trimming the oldest in a batch past the cap. "c" callback — needs a context to alloc.
@(private = "file")
term_sb_pushline_cb :: proc "c" (cols: c.int, cells: [^]vt.ScreenCell, continuation: bool, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    context = t.sb_ctx
    n := int(cols)
    line := ScrollLine {
        cells        = make([]vt.ScreenCell, n),
        continuation = continuation,
    }
    copy(line.cells, cells[:n])
    append(&t.scrollback, line)
    // A view at the live bottom rides with it. `view_top` is absolute and sb_total is about to
    // move, so leaving it alone drops the view a line behind per scrolled-off line and the pane
    // freezes. A view parked above the bottom is below sb_total and keeps its line.
    following := t.view_top >= t.sb_total
    t.sb_total += 1
    if following {
        t.view_top = t.sb_total
    }
    if len(t.scrollback) > SCROLLBACK_MAX + SCROLLBACK_TRIM {
        for i in 0 ..< SCROLLBACK_TRIM {
            delete(t.scrollback[i].cells)
        }
        remove_range(&t.scrollback, 0, SCROLLBACK_TRIM)
    }
    return 1
}

// The screen grew taller: hand back the newest scrollback line, decrementing sb_total so its
// absolute number resolves to the live row it became. 0 on empty history leaves the row blank.
@(private = "file")
term_sb_popline_cb :: proc "c" (cols: c.int, cells: [^]vt.ScreenCell, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    context = t.sb_ctx
    if len(t.scrollback) == 0 {
        return 0
    }
    line := pop(&t.scrollback)
    n := min(int(cols), len(line.cells))
    copy(cells[:n], line.cells[:n]) // libvterm pre-blanks the rest
    delete(line.cells)
    t.sb_total -= 1
    return 1
}

// libvterm's reply bytes (cursor reports, device attributes) straight to the shell.
@(private = "file")
term_output_cb :: proc "c" (s: [^]u8, len: c.size_t, user: rawptr) {
    t := (^Terminal)(user)
    if t.pty >= 0 {
        posix.write(t.pty, s, len)
    }
}

// The private OSC the CL chain runner wraps commands with: `OSC 697 ; <id> ; <code> ST`. The
// id correlates the report with the injection.
OSC_EXIT_TAG :: 697

// The payload may arrive in fragments; parse on the final piece.
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

// Contextless so the "c" callback can call it; hence the hand-rolled digit parsing.
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
        return // malformed
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

// $SHELL when absolute, else /bin/sh. Absolute lets the child exec without a PATH search,
// which would allocate — forbidden across the fork.
@(private = "file")
term_shell :: proc() -> cstring {
    sh := os.get_env("SHELL", context.temp_allocator)
    if len(sh) > 0 && sh[0] == '/' {
        return strings.clone_to_cstring(sh)
    }
    return strings.clone_to_cstring("/bin/sh")
}

// The environment with TERM forced to xterm-256color, as execve wants it. Built pre-fork.
@(private = "file")
term_build_env :: proc() -> [^]cstring {
    env := make([dynamic]cstring)
    for e := posix.environ; e[0] != nil; e = e[1:] {
        if !strings.has_prefix(string(e[0]), "TERM=") {
            append(&env, e[0]) // borrow the static C string
        }
    }
    append(&env, strings.clone_to_cstring("TERM=xterm-256color"))
    append(&env, nil) // execve terminator
    return raw_data(env)
}

@(private = "file")
term_free_env :: proc(envp: [^]cstring) {
    // Only the TERM entry was cloned by us.
    for e := envp; e[0] != nil; e = e[1:] {
        if strings.has_prefix(string(e[0]), "TERM=") {
            delete(e[0])
        }
    }
    free(envp)
}

// --- session list on App --- Stored by pointer, so growing the array never moves a Terminal
// out from under its reader thread or invalidates its Mutex.

TERM_MAX :: 99
TERM_INIT_ROWS :: 24 // spawn size; terminal_frame resizes to the real pane next frame
TERM_INIT_COLS :: 80





// The reader thread clears this at EOF while everyone else reads it per frame, so it crosses
// threads atomically rather than under t.lock: live-or-dead is the whole answer, and taking the
// lock for it would put the paint behind the shell's output.
terminal_alive :: proc(t: ^Terminal) -> bool {
    return sync.atomic_load(&t.alive)
}



// --- input routing --- A focused live terminal owns bare + Ctrl keys; Alt stays global
// (src/slopd/input.odin takes it first), so the shell never sees an Alt-chord.



// From char_callback. Shift is already baked into the codepoint, so the modifier is none.
terminal_input_rune :: proc(t: ^Terminal, r: rune) {
    terminal_sel_reset(t) // typing returns to the live bottom
    vt.keyboard_unichar(t.term, u32(r), vt.MOD_NONE)
}

// The specials plus Ctrl+letter, which GLFW emits no char event for. Printable keys are
// char_callback's.
terminal_input_key :: proc(t: ^Terminal, key, mods: i32) {
    // A bare modifier press must not reset, or Ctrl+Shift+C would drop the selection before
    // the copy fires.
    if !ui.key_is_modifier(key) {
        terminal_sel_reset(t)
    }
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
        // Ctrl+<letter> as a control unichar (Ctrl+C -> 0x03). Alt never reaches here.
        if mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_ALT == 0 {
            if key >= glfw.KEY_A && key <= glfw.KEY_Z {
                vt.keyboard_unichar(t.term, u32(key - glfw.KEY_A + 'a'), vt.MOD_CTRL)
            }
        }
        return
    }
    vt.keyboard_key(t.term, vk, term_mods(mods))
}

// 0-based; libvterm adds the protocol's +1. Safe every frame — unchanged cells return at once.
// A button report reads its coordinates from here, so every tap moves first.
terminal_mouse_at :: proc(t: ^Terminal, row, col: int) {
    vt.mouse_move(t.term, c.int(row), c.int(col), vt.MOD_NONE)
}

// Move, press, release. A press with no release leaves libvterm's button state set and the TUI
// reads later motion as a drag. The click count is not forwarded — xterm sends one press per
// press and the application does its own timing.
terminal_mouse_tap :: proc(t: ^Terminal, row, col: int, ctrl: bool) {
    terminal_mouse_at(t, row, col)
    mod := ctrl ? vt.MOD_CTRL : vt.MOD_NONE
    vt.mouse_button(t.term, 1, true, mod)
    vt.mouse_button(t.term, 1, false, mod)
}

// Shift/Ctrl only; Alt stays global.
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
