package main

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import vt "../bindings/libvterm"
import "vendor:glfw"
import "wake"

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
    // headless test Terminal); alive drops to false when the shell exits (read EOF).
    pty:   posix.FD,
    pid:   posix.pid_t,
    alive: bool,

    // Directory lock (Alt+L). A locked session keeps its own cwd: the `tu` builtin
    // skips it, and the switcher draws its number greyed. Purely advisory state —
    // nothing else reads it.
    locked: bool,

    // Reader thread -> main loop handoff: the thread appends under lock and wakes the loop,
    // which drains into the parser. Only raw bytes cross threads, never a vterm_* call.
    // `feedbuf` is the main half of a double buffer — see terminal_drain.
    reader:  ^thread.Thread,
    lock:    sync.Mutex,
    inbuf:   [dynamic]u8,
    feedbuf: [dynamic]u8,

    // Shell-command completion for the CL chain runner: a wrapped command emits its exit
    // code in a private OSC (OSC_EXIT_TAG) and the fallback records it here, exit_id
    // correlating it with the injection. Main-thread-only (the callback fires in a drain).
    fallbacks:  vt.StateFallbacks,
    osc_buf:    [64]u8,
    osc_len:    int,
    exit_ready: bool,
    exit_id:    u64,
    exit_code:  int,

    // Scrollback + the keyboard's row-only copy cursor. `sb_total` counts every line ever
    // pushed, giving each a STABLE absolute number: scrollback[i] is sb_total-len+i, live row
    // r is sb_total+r. Main-thread-only. See terminal_sel_* below.
    callbacks:  vt.ScreenCallbacks,
    sb_ctx:     runtime.Context, // context the sb_* "c" callbacks allocate under
    scrollback: [dynamic]ScrollLine,
    sb_total:   int,
    sel_active: bool, // line-select / scroll mode on (cursor shown)
    sel_head:   int,  // absolute line of the copy cursor (the moving edge)
    sel_anchor: int,  // absolute line the selection is pinned at (== head: no span)
    view_top:   int,  // absolute line drawn at the top row while scrolled
    // The WHEEL cut the view loose from the live bottom (terminal_scroll_by) — the twin of
    // every list pane's `scroll_detached` and of the editor's. Cleared by any keystroke that
    // reaches the shell, exactly as they all are, and by a notch that walks it back down.
    view_detached: bool,

    // The MOUSE's per-character selection, beside the keyboard's copy cursor rather than
    // replacing it. `Cursor`/`Pos` are the editor's deliberately — the algebra is shared, the
    // storage is not. Pos.line is ABSOLUTE; Pos.col is a BOUNDARY between cells, 0..=width.
    msel:    Cursor,
    msel_on: bool,
    // A full-screen TUI on the alt buffer owns its own scrolling, so its mode bits (tracked
    // via settermprop) route scroll input there instead of to our scrollback.
    on_altscreen: bool, // the TUI switched to the alternate screen
    mouse_on:     bool, // the TUI enabled mouse tracking (so we can wheel-scroll it)
}

// One captured scrollback row: a clone of the cells libvterm handed us as the line
// scrolled off the top. Owned by the Terminal; freed in terminal_vt_destroy (and as
// the oldest lines are trimmed past SCROLLBACK_MAX).
ScrollLine :: struct {
    cells:        []vt.ScreenCell,
    // Whether this line exists because the one ABOVE it wrapped (libvterm's sb_pushline4) —
    // the bit that makes a copied soft-wrapped command paste back as one line. Captured here
    // because libvterm forgets a row once it is in history.
    continuation: bool,
}

// How many scrolled-off lines to keep, and the slack we let the buffer overshoot
// before trimming the oldest in one batch (so trimming is amortised O(1) per line,
// not an O(n) shift on every single scrolled line under heavy output).
SCROLLBACK_MAX  :: 5000
SCROLLBACK_TRIM :: SCROLLBACK_MAX / 8

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
    // Give full-screen TUIs their own alternate buffer. Without it DECSET 1049 is a no-op and
    // the TUI paints over the PRIMARY grid, spilling every redraw into our real scrollback.
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
        type  = 0, // RGB: the type bit is clear, no default flags
        red   = u8(clampf(rgb.r, 0, 1) * 255),
        green = u8(clampf(rgb.g, 0, 1) * 255),
        blue  = u8(clampf(rgb.b, 0, 1) * 255),
    }
}

// --- scrollback view + keyboard line-selection ---
// An absolute-numbered space: [oldest, sb_total) is scrollback, [sb_total, bottom] the live
// grid. A row-only copy cursor walks it and the view follows; Esc / typing snap to the bottom.

// The oldest absolute line still retained (start of scrollback).
terminal_oldest :: proc(t: ^Terminal) -> int {
    return t.sb_total - len(t.scrollback)
}

// The bottom-most selectable line: the last live grid row.
terminal_bottom :: proc(t: ^Terminal) -> int {
    return t.sb_total + t.rows - 1
}

// A cell at absolute line `n`, column `col`, drawn from the live grid when `n` is
// on-screen else from captured scrollback. ok=false past either end (blank cell).
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

// The absolute line at the top row: the scrolled position while selecting, else the live grid
// top. A mouse selection pins it too — `sel_active` doubles as "the view is scrolled", so a
// click retiring the copy cursor would otherwise throw away the scroll that enabled it.
terminal_view_top :: proc(t: ^Terminal) -> int {
    top := t.sel_active || t.msel_on || t.view_detached ? t.view_top : t.sb_total
    return clamp(top, terminal_oldest(t), t.sb_total)
}

// Scroll the VIEW by `delta` lines, touching nothing else — the wheel's verb. **A wheel is
// not a cursor movement**, so a mouse selection SURVIVES a scroll, as in both reference
// terminals.
terminal_scroll_by :: proc(t: ^Terminal, delta: int) {
    if delta == 0 {
        return
    }
    t.view_top = clamp(terminal_view_top(t) + delta, terminal_oldest(t), t.sb_total)
    // Detached means PARKED ABOVE the live bottom, never "the wheel was touched": a notch that
    // lands back on the bottom is the user saying "follow again", so the pane catches there.
    t.view_detached = t.view_top < t.sb_total
}

// The width of absolute line `n`: a captured line keeps the width it was captured at, a live
// row is the current grid width. One definition — a copy walk, a clamp and a trailing-blank
// trim all need it, and a disagreement is an off-by-one in the copied text.
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

// Whether absolute line `n` exists because the line above it WRAPPED. Two sources, one
// question: a live row is libvterm's (state_get_lineinfo), a scrolled-off row is ours.
// Unanswerable after a resize pops one back — sb_popline has no four-argument form.
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

// The first and last absolute line of the LOGICAL line containing `n` — the run of rows a
// single wrapped command occupies. What a triple click selects, because the row a wrapped
// command happens to land on is not a thing the user typed.
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

// The selected absolute line range, HALF-OPEN: [lo, hi), lo==hi being the bare copy cursor.
// Half-open because **the copy cursor is a BOUNDARY, not a line** — drawn as a rule along the
// TOP edge, so two of them span [min, max). Inclusive picks up the line the anchor left.
terminal_sel_range :: proc(t: ^Terminal) -> (lo, hi: int) {
    return min(t.sel_anchor, t.sel_head), max(t.sel_anchor, t.sel_head)
}

// Move the copy cursor by `delta` lines (negative = into history); the first move off the
// live bottom enters select mode. `extend` (Shift) keeps the anchor to grow a span, otherwise
// it follows. Returning to the bottom with no span drops back to input mode.
terminal_sel_move :: proc(t: ^Terminal, delta: int, extend: bool) {
    // The copy cursor and the mouse's character selection are alternatives, not layers, so
    // taking hold of one drops the other. The WHEEL no longer comes through here at all —
    // it has terminal_scroll_by — so this is only ever a real keystroke.
    terminal_msel_reset(t)
    if !t.sel_active {
        // Read BEFORE sel_active flips: terminal_view_top answers a different question once
        // it is set. Seeding from the bottom of what is ON SCREEN (not the live bottom) is
        // what stops a wheel-scrolled view snapping back when you reach for the keyboard.
        top := terminal_view_top(t)
        t.sel_active = true
        t.sel_head = clamp(top + t.rows - 1, terminal_oldest(t), terminal_bottom(t))
        t.sel_anchor = t.sel_head
        t.view_top = top
    }
    t.view_detached = false // the keyboard owns the view again, as in every other pane
    // On the alt screen the off-screen history is the TUI's, so the selection floor is the
    // top live row. Pushing past an edge tells the TUI to scroll rather than stopping dead.
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
    // Back at the bottom with nothing selected — there is nothing to copy, so leave
    // select mode and hide the cursor (the "inputting stuff" line).
    if t.sel_head == terminal_bottom(t) && t.sel_anchor == terminal_bottom(t) {
        t.sel_active = false
        return
    }
    // Keep the cursor on screen, then clamp to the valid scroll span.
    if t.sel_head < t.view_top {
        t.view_top = t.sel_head
    } else if t.sel_head > t.view_top + t.rows - 1 {
        t.view_top = t.sel_head - t.rows + 1
    }
    t.view_top = clamp(t.view_top, floor, t.sb_total)
}

// Leave select/scroll mode: hide the cursor and snap the view back to the live
// bottom (Esc, or any real keystroke to the shell). Drops the mouse's selection with it —
// typing is how you say "done looking at that", whichever way you made the selection.
terminal_sel_reset :: proc(t: ^Terminal) {
    t.sel_active = false
    t.view_detached = false // and the view snaps back to the live bottom with it
    terminal_msel_reset(t)
}

// --- the mouse's per-character selection: pointer twins of the Doc's four verbs ---
//   terminal_clamp_pos  doc_clamp_pos     terminal_msel_head   doc_set_head
//   terminal_msel_set   doc_select_span   terminal_grade_span  doc_drag_span

// Clamp a position into the selectable space (doc_clamp_pos's twin): a resize between the
// press and the frame applying it costs a selection end on the wrong line, never an index off
// the scrollback. The floor is the alt screen's, as terminal_sel_move's is.
terminal_clamp_pos :: proc(t: ^Terminal, p: Pos) -> Pos {
    floor := t.on_altscreen ? t.sb_total : terminal_oldest(t)
    line := clamp(p.line, floor, terminal_bottom(t))
    return Pos{line, clamp(p.col, 0, terminal_line_width(t, line))}
}

// Collapse the mouse selection to anchor..head (doc_select_span's twin). Entering one retires
// the copy cursor and CARRIES THE VIEW OVER: reading through terminal_view_top before msel_on
// flips keeps a scrolled view where it is, and refreshes a stale one after an Esc.
terminal_msel_set :: proc(t: ^Terminal, anchor, head: Pos) {
    a := terminal_clamp_pos(t, anchor)
    h := terminal_clamp_pos(t, head)
    if !t.msel_on {
        t.view_top = terminal_view_top(t)
    }
    t.sel_active = false
    t.msel = Cursor{anchor = a, head = h, goal = h.col}
    t.msel_on = true
}

// Move the selection's head, keeping its anchor (doc_set_head with select=true): Shift+click,
// and every frame of a character-grade drag. With nothing selected it starts an empty
// selection there, so a Shift+click into a bare terminal is a place to extend FROM.
terminal_msel_head :: proc(t: ^Terminal, p: Pos) {
    if !t.msel_on {
        terminal_msel_set(t, p, p)
        return
    }
    h := terminal_clamp_pos(t, p)
    t.msel.head = h
    t.msel.goal = h.col
}

// Drop the mouse selection. The view is NOT restored here — terminal_view_top falls back to
// the live bottom on its own once neither selection is live, and the callers that want the
// view kept (a new press) set one up again in the same frame.
terminal_msel_reset :: proc(t: ^Terminal) {
    t.msel_on = false
    t.msel = {}
}

// Whether there is anything to copy: a span, not just a resting caret. A click that selected
// nothing must not leave the pane in a state where Ctrl+Shift+C yields "".
terminal_msel_has_span :: proc(t: ^Terminal) -> bool {
    return t.msel_on && cursor_has_selection(t.msel)
}

// The run of one character class around `col` on absolute line `n`, over the grid. word_span
// is line.odin's — the editor's double click uses the same one. The row is materialised as
// runes, with blanks normalised to spaces so an unwritten cell is whitespace, not a NUL.
terminal_word_span :: proc(t: ^Terminal, n, col: int) -> (lo, hi: int) {
    w := terminal_line_width(t, n)
    if w <= 0 {
        return 0, 0
    }
    runes := make([]rune, w, context.temp_allocator)
    for i in 0 ..< w {
        r := terminal_view_rune(t, n, i)
        runes[i] = r >= 0x20 ? r : ' '
    }
    return word_span(runes, col)
}

// The span a drag covers at its fixed GRADE — word (2) or line (3+), doc_drag_span's twin.
// `press` and `at` carry CELL columns, not boundaries: a word names the character pointed at.
// Line grade takes the whole LOGICAL line, so a triple click selects a wrapped command whole.
terminal_grade_span :: proc(t: ^Terminal, grade: int, press, at: Pos) -> (anchor, head: Pos) {
    p := terminal_clamp_pos(t, press)
    q := terminal_clamp_pos(t, at)
    if grade >= 3 {
        if q.line >= p.line {
            first, _ := terminal_logical_line(t, p.line)
            _, last := terminal_logical_line(t, q.line)
            return Pos{first, 0}, Pos{last, terminal_line_width(t, last)}
        }
        _, last := terminal_logical_line(t, p.line)
        first, _ := terminal_logical_line(t, q.line)
        return Pos{last, terminal_line_width(t, last)}, Pos{first, 0}
    }
    plo, phi := terminal_word_span(t, p.line, p.col)
    qlo, qhi := terminal_word_span(t, q.line, q.col)
    if !pos_less(q, p) {
        return Pos{p.line, plo}, Pos{q.line, qhi}
    }
    return Pos{p.line, phi}, Pos{q.line, qlo}
}

// Whatever is currently selected, as text; caller owns the result. TWO selections, ONE walk:
// the mouse's is already a pair of boundary positions, the keyboard's row range becomes the
// pair spanning whole lines, and everything below the pair is written once for both.
terminal_selection_text :: proc(t: ^Terminal, alloc := context.allocator) -> string {
    if t.msel_on {
        lo, hi := cursor_range(t.msel)
        return terminal_range_text(t, lo, hi, alloc)
    }
    if !t.sel_active {
        return ""
    }
    // [lo, hi) in lines becomes a start boundary and an end boundary: the whole of hi-1 is
    // the last thing in it. An empty span copies nothing rather than a stray line.
    lo, hi := terminal_sel_range(t)
    if lo == hi {
        return ""
    }
    return terminal_range_text(t, Pos{lo, 0}, Pos{hi - 1, terminal_line_width(t, hi - 1)}, alloc)
}

// An absolute-position range as text, clipped per line and joined by newlines — **except a
// flow CONTINUATION, joined with nothing**, or a wrapped shell line comes back unpasteable.
// The trailing-blank trim applies only where a segment runs to the row's own edge.
terminal_range_text :: proc(t: ^Terminal, lo, hi: Pos, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    if hi.line < lo.line {
        return strings.to_string(b)
    }
    for n in lo.line ..= hi.line {
        w := terminal_line_width(t, n)
        start := n == lo.line ? clamp(lo.col, 0, w) : 0
        end := n == hi.line ? clamp(hi.col, 0, w) : w
        if end >= w {
            last := start - 1 // last column holding a visible glyph
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

// The primary rune at an absolute (line, col), 0 when blank/out of range.
@(private = "file")
terminal_view_rune :: proc(t: ^Terminal, n, col: int) -> rune {
    cell := terminal_view_cell(t, n, col) or_else vt.ScreenCell{}
    return rune(cell.chars[0])
}

// --- PTY + child shell ---
// Pure core:sys/posix; the TIOCSWINSZ ioctl and its struct are the one foreign bit.

TIOCSWINSZ :: 0x5414 // Linux ioctl: set terminal window size

Winsize :: struct {
    ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, argp: rawptr) -> c.int ---
}

// Bring up a session: the VT machine, a master/slave PTY pair, and a forked child running
// $SHELL with the slave as its controlling terminal. false (and pty == -1) if any step fails;
// on success a reader thread is pumping the master fd.
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

    // Build everything the child needs BEFORE the fork: in a multithreaded process it may
    // only touch pre-allocated memory until exec (another thread could hold the malloc lock).
    // ptsname returns a static buffer, so clone the name too.
    name := strings.clone_to_cstring(string(slave_name))
    shell := term_shell()
    argv := []cstring{shell, nil}
    envp := term_build_env()
    // The child chdir's here before exec so the shell starts in the project root; an
    // empty cwd leaves it in our own. Cloned up front — the child may not allocate.
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
            posix.chdir(dir) // start in the project root (best effort; ignore failure)
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
    delete(t.feedbuf)
    t.inbuf, t.feedbuf = nil, nil
    terminal_vt_destroy(t)
}

// Send keystrokes / responses to the shell. No-op on a session with no child.
terminal_write :: proc(t: ^Terminal, bytes: []u8) {
    if t.pty < 0 || len(bytes) == 0 {
        return
    }
    posix.write(t.pty, raw_data(bytes), c.size_t(len(bytes)))
}

// Clipboard text on its way INTO the shell, made safe to send as keystrokes. Newlines become
// CR (what Enter sends; readline turns it back into a newline inside a bracketed paste, and
// CRLF is one ending, not two), tabs survive, and every other C0 control is dropped — an ESC
// in the payload could otherwise forge the end marker and hand the shell the rest as commands.
terminal_paste_sanitize :: proc(text: string, alloc := context.allocator) -> []u8 {
    out := make([dynamic]u8, 0, len(text), alloc)
    for i := 0; i < len(text); i += 1 {
        switch b := text[i]; {
        case b == '\r' || b == '\n':
            append(&out, '\r')
            if b == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
                i += 1
            }
        case b == '\t' || b >= 0x20 && b != 0x7f: // >= 0x80 is UTF-8, and passes here
            append(&out, b)
        }
    }
    return out[:]
}

// Paste text into a shell: the sanitised bytes straight to the PTY, wrapped in libvterm's
// bracketed-paste markers so a multi-line paste lands in the line editor instead of executing
// line by line. No pty is not a special case — terminal_write already drops those bytes.
terminal_paste :: proc(t: ^Terminal, text: string) {
    bytes := terminal_paste_sanitize(text, context.temp_allocator)
    if len(bytes) == 0 {
        return
    }
    terminal_sel_reset(t) // a paste is input, so the view returns to the live bottom
    vt.keyboard_start_paste(t.term)
    terminal_write(t, bytes)
    vt.keyboard_end_paste(t.term)
}

// Drain the reader thread's buffered bytes into the parser (main thread). The lock is held
// across the SWAP ONLY: terminal_feed runs libvterm's whole state machine, and holding it
// through that is real backpressure on the PTY under heavy output, for no gain.
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

// The reader thread: one blocking read() on the master fd, append under lock, wake the loop.
// EOF or a real error means the shell exited — mark dead and wake once more so the loop
// drains the last bytes. EINTR is retried: the child's SIGCHLD can land on this thread.
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
            continue // interrupted by a signal — retry rather than treat as EOF
        }
        break // n == 0 (EOF) or a real error
    }
    sync.mutex_lock(&t.lock)
    t.alive = false
    sync.mutex_unlock(&t.lock)
    wake.post()
}

// Start capturing scrolled-off lines into this Terminal's scrollback. Stores a self-pointer
// in libvterm, so call it only once `t` has a stable address — the test core returns a
// Terminal by value and must call it on the settled copy, never inside the builder.
terminal_enable_scrollback :: proc(t: ^Terminal) {
    // The "c" callbacks carry no Odin context; capture the caller's so scrollback is
    // allocated under the same allocator terminal_vt_destroy frees it with (the heap
    // in the app, the test runner's tracking allocator under test).
    t.sb_ctx = context
    t.callbacks = vt.ScreenCallbacks {
        sb_pushline4 = term_sb_pushline_cb,
        sb_popline   = term_sb_popline_cb,
        settermprop  = term_settermprop_cb,
    }
    vt.screen_set_callbacks(t.screen, &t.callbacks, t)
    // The FOUR-argument pushline, opted into explicitly: the three-argument form drops the
    // wrapped bit, and a copied soft-wrapped command then comes back in two pieces. libvterm
    // keeps the flag on the screen, so this and the callbacks precede the first scroll-off.
    vt.screen_callbacks_has_pushline4(t.screen)
}

// Property change from libvterm; Slopd tracks ALTSCREEN and MOUSE. While a TUI is up it owns
// scrolling, so PageUp routes there rather than to our scrollback (input.odin). "c" callback
// on the main thread inside terminal_feed — a flag write, no context needed.
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

// Does a wheel notch belong to the CHILD? **One question, asked once** by the wheel and the
// click alike: the child gets it if it asked for EITHER mouse reports or the alt screen
// (splitting them disagrees over an inline `fzf --height`). **Shift overrides.**
terminal_wheel_forwards :: proc(t: ^Terminal, shift: bool) -> bool {
    if t == nil || shift {
        return false
    }
    return t.mouse_on || t.on_altscreen
}

// Scroll a focused full-screen TUI by one notch: button 4/5 when it tracks the mouse, else
// the page key. **The page key is a deliberate difference from the field** — alacritty, Zed
// and xterm.js send ARROWS, but gate that on DECSET 1007, which libvterm lacks.
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

// A line just scrolled off the top: clone its cells into scrollback and bump the running
// total so absolute numbers stay stable, trimming the oldest in a batch past the cap.
// "c" callback — establish a context to alloc; it runs on the main thread, so heap is fine.
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
    // A view sitting AT the live bottom rides with it. `view_top` is an ABSOLUTE line and
    // sb_total is about to move, so leaving it alone drops the view one line behind per
    // scrolled-off line: the pane freezes and reads as "still scrolled" though nobody scrolled
    // it. That is what a bare click (msel_on, pinning at the bottom) or a wheel walked back down
    // used to do. A view parked above the bottom is below sb_total and keeps its line.
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

// The screen grew taller and wants a line back at the top: hand over the newest scrollback
// line and drop it, sb_total decremented so its absolute number now resolves to the live row
// it has become. Return 0 on empty history so libvterm leaves the new row blank.
@(private = "file")
term_sb_popline_cb :: proc "c" (cols: c.int, cells: [^]vt.ScreenCell, user: rawptr) -> c.int {
    t := (^Terminal)(user)
    context = t.sb_ctx
    if len(t.scrollback) == 0 {
        return 0
    }
    line := pop(&t.scrollback)
    n := min(int(cols), len(line.cells))
    copy(cells[:n], line.cells[:n]) // libvterm pre-blanks the buffer; fill what we have
    delete(line.cells)
    t.sb_total -= 1
    return 1
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

// --- session list on App ---
// Heap-allocated and stored by pointer, so the array growing never moves a Terminal out from
// under its reader thread (which holds a ^Terminal) or invalidates its Mutex.

TERM_MAX :: 99
TERM_INIT_ROWS :: 24 // spawn size; terminal_frame resizes to the real pane next frame
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
    if !terminal_spawn(t, TERM_INIT_ROWS, TERM_INIT_COLS, a.project_root) {
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

// --- input routing ---
// A focused live terminal owns bare + Ctrl keys; Alt stays global (input.odin handles it
// first), so the shell never sees an Alt-chord. Keys feed vterm_keyboard_*.

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

// The session that owns the line-selection / copy keys: the active terminal when
// its pane is focused, alive or not (you can still copy a dead shell's output). nil
// while the command line overlays the pane or another pane has focus.
term_sel_target :: proc(a: ^App) -> ^Terminal {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Terminal {
        return nil
    }
    return term_current(a)
}

// A printable character typed at a focused terminal (from char_callback). Shift is
// already baked into the codepoint, so the modifier is none.
terminal_input_rune :: proc(t: ^Terminal, r: rune) {
    terminal_sel_reset(t) // typing returns to the live bottom
    vt.keyboard_unichar(t.term, u32(r), vt.MOD_NONE)
}

// A non-text key (or Ctrl-combo) at a focused terminal. Printable keys are char_callback's;
// this maps the specials — Enter/Tab/Backspace/Escape/arrows/Home/End/Ins/Del/PageUp/Down —
// plus Ctrl+letter, which GLFW emits no char event for, as a control unichar.
terminal_input_key :: proc(t: ^Terminal, key, mods: i32) {
    // A real key for the shell returns to the live bottom — but a bare modifier press
    // (e.g. the Ctrl/Shift of Ctrl+Shift+C) must NOT, or it would drop the selection
    // before the copy fires.
    if !key_is_modifier(key) {
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

// Point the TUI's mouse at a live grid cell (0-based; libvterm adds the protocol's +1). Safe
// every frame — unchanged cells return at once and nothing is emitted unless the TUI asked
// for motion. A button report reads its coordinates from here, so every tap moves first.
terminal_mouse_at :: proc(t: ^Terminal, row, col: int) {
    vt.mouse_move(t.term, c.int(row), c.int(col), vt.MOD_NONE)
}

// One left click at a live grid cell: move, press, release. A press with no release is a bug —
// libvterm tracks button state, so the TUI would read later motion as a DRAG. The COUNT is not
// forwarded: xterm sends one press per press and the application does its own timing.
terminal_mouse_tap :: proc(t: ^Terminal, row, col: int, ctrl: bool) {
    terminal_mouse_at(t, row, col)
    mod := ctrl ? vt.MOD_CTRL : vt.MOD_NONE
    vt.mouse_button(t.term, 1, true, mod)
    vt.mouse_button(t.term, 1, false, mod)
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
