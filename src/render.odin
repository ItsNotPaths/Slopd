package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import gl "vendor:OpenGL"

// Rendering: solid-colour quads (fill/caret) plus glyph text, both batched per pane
// (see text.odin). Every colour comes from the active Theme (a.theme); this file maps
// palette slots to UI usage:
//   border_dark -> window gutter / overlay bg   bg -> pane background
//   accent      -> focus outline / active item  border_light -> status strip
//   fg / muted  -> text (active / dim)           selection -> selected text
//   line_highlight -> current-line bar           separator -> filetree selection
//   code_return_type -> filetree directory rows  urgent -> ringed-file marker
//
// A pane appends its quads + glyphs, then calls flush_pane to composite and clip
// them in one go (under-quads -> glyphs -> carets). render() lays down the window
// background and the pane chrome first, then hands each region to its draw_* proc.

aux_mode_name :: proc(m: AuxMode) -> string {
    switch m {
    case .FileTree:
        return "filetree"
    case .Terminal:
        return "terminal"
    case .Procmon:
        return "procmon"
    case .Git:
        return "git"
    case .Config:
        return "config"
    case .Grep:
        return "grep"
    }
    return ""
}

inset :: proc(r: Rect, by: i32) -> Rect {
    return Rect{r.x + by, r.y + by, r.w - 2 * by, r.h - 2 * by}
}

// A pane: filled with bg, ringed with the focus colour when focused.
panel :: proc(t: ^Text, r: Rect, bg, focus: [3]f32, focused: bool, scale: f32) {
    if focused {
        fill(t, r, focus)
        fill(t, inset(r, i32(2 * scale)), bg)
    } else {
        fill(t, r, bg)
    }
}

render :: proc(a: ^App, t: ^Text, win_w, win_h: i32, now: f64) {
    th := &a.theme
    t.frame_verts = 0 // the perf log tallies this frame's submitted vertices
    // Viewport must track the framebuffer or the shaders (NDC -> viewport) distort
    // on resize.
    gl.Viewport(0, 0, win_w, win_h)

    // Window background — shows through the inter-pane gutter the panels leave.
    gl.Disable(gl.SCISSOR_TEST)
    gl.ClearColor(th.border_dark.r, th.border_dark.g, th.border_dark.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    lay := compute_layout(win_w, win_h, a, now)
    pad := i32(8 * a.scale)

    // The focus ring only disambiguates which of two panes is active; with a single
    // pane on screen (Zen-editor / Util) it is just a full-window border, so drop
    // it. Hidden panes carry a zero rect and the draw guards skip them.
    show_ring := lay.vis.editor && lay.vis.aux

    // Chrome: both pane backgrounds/rings + the status strip, composited in one flush.
    panel(t, lay.editor, th.bg, th.accent, show_ring && a.focus == .Editor, a.scale)
    panel(t, lay.aux, th.bg, th.accent, show_ring && a.focus == .Aux, a.scale)
    fill(t, lay.strip, th.border_light)
    flush_pane(t, Rect{0, 0, win_w, win_h}, win_w, win_h)

    draw_editor(t, lay.editor, win_w, win_h, a, now)

    if a.aux_mode == .FileTree {
        draw_filetree(t, lay.aux, win_w, win_h, a)
    } else if a.aux_mode == .Config {
        draw_config(t, lay.aux, win_w, win_h, a, now)
    } else if a.aux_mode == .Terminal {
        draw_terminal(t, lay.aux, win_w, win_h, a)
    } else if a.aux_mode == .Git {
        draw_git(t, lay.aux, win_w, win_h, a, now)
    } else if a.aux_mode == .Grep {
        draw_grep(t, lay.aux, win_w, win_h, a)
    } else if a.aux_mode == .Procmon {
        draw_procmon(t, lay.aux, win_w, win_h, a, now)
    } else {
        label(t, aux_mode_name(a.aux_mode), lay.aux, pad, focus_fg(a, .Aux))
        flush_pane(t, lay.aux, win_w, win_h)
    }

    // Switcher overlay: plain Alt only. Alt+Ctrl / Alt+Shift drive the terminal
    // copy-cursor, so the switcher stays hidden then.
    if a.alt_held && !a.ctrl_held && !a.shift_held && a.aux_mode == .Terminal {
        draw_term_overlay(t, lay.aux, win_w, win_h, a, now)
    }

    // Bottom status / command strip: the command line while active, else an
    // emacs-style modeline for the editor buffer.
    if a.cl_active {
        draw_command_line(t, lay.strip, a, now)
    } else {
        draw_status(t, lay.strip, a)
    }
    flush_pane(t, lay.strip, win_w, win_h)
}

@(private = "file")
focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// How long a scroll step takes to settle (seconds). Short by design — spartan.
@(private = "file")
SCROLL_DUR :: 0.09

// Smooth-scroll bookkeeping shared by the editor and the diff viewer: re-aim `anim` at
// the integer target `to` when it changes, then return the floored top row + the sub-row
// pixel offset to shift drawing by (the partial top row is clipped by the pane scissor).
// `top` may be negative when over-scrolled past the first row, so floor (not trunc).
@(private = "file")
smooth_scroll :: proc(anim: ^Anim, to: int, now: f64, row_h: i32) -> (top: int, off: i32) {
    if f32(to) != anim.to {
        anim_start(anim, now, anim_value(anim, now), f32(to), SCROLL_DUR)
    }
    disp := anim_value(anim, now)
    top = int(disp)
    if disp < f32(top) { // int() truncates toward zero; step down for a true floor
        top -= 1
    }
    off = i32((disp - f32(top)) * f32(row_h))
    return
}

// The editor: a line-number gutter, the active buffer's lines, the current-line
// bar, and a caret. Scrolls to keep the cursor visible, the view sliding smoothly
// toward the target top line. (Tabs currently advance one cell — fine for the
// space-indent default; proper tab width is a TODO.)
draw_editor :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    b := editor_current(&a.editor)
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)

    buffer_sync_folds(b) // drop folds invalidated by an edit; keep the scroll on a real line

    cur_line := b.cursors[b.primary].head.line // primary cursor drives scroll + the gutter
    rows := max(1, int(area.h / row_h))

    // Scroll-follow in VISIBLE rows (folded lines don't take a row): keep the cursor
    // within the window, sliding the top down only as far as a real visible line.
    b.scroll = buffer_prev_visible(b, clamp(b.scroll, 0, len(b.lines) - 1))
    if cur_line < b.scroll {
        b.scroll = cur_line
    } else if buffer_visible_count(b, b.scroll, cur_line) > rows {
        b.scroll = buffer_back_visible(b, cur_line, rows - 1)
    }

    // Smooth scroll: b.scroll is the target top line; the visual top tweens toward
    // it. Re-arm only when the target moves, so a settled view never re-renders.
    top, off := smooth_scroll(&b.scroll_anim, b.scroll, now, row_h)

    gutter := i32(max(2, num_digits(len(b.lines)))) // digits wide
    text_x := f32(area.x) + f32(gutter + 2) * cw // margin + gutter + gap

    // The visible lines to fill the viewport (plus the partial rows a mid-scroll
    // offset exposes top and bottom), walking past folded lines. The visual row index
    // counts only drawn lines, while line indices skip the hidden ones.
    count := rows + 2
    unit := indent_unit(a.indent)
    scope: Scope
    if a.show_guides {
        scope = buffer_active_scope(b, cur_line, unit)
    }

    draw_lines := make([dynamic]int, 0, count, context.temp_allocator)
    for i := top; i < len(b.lines) && len(draw_lines) < count; i += 1 {
        if !buffer_line_hidden(b, i) {
            append(&draw_lines, i)
        }
    }
    // Highlight over the absolute span the drawn lines occupy (hl is indexed by
    // line-top, so folded gaps inside the span are simply never read).
    span := len(draw_lines) > 0 ? draw_lines[len(draw_lines) - 1] - top + 1 : 0
    hl := highlight_visible(a, b, top, span)

    for line, vrow in draw_lines {
        l := &b.lines[line]
        y := area.y + i32(vrow) * row_h - off
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := line == cur_line

        if on_cur_line {
            fill(t, Rect{area.x, y, area.w, row_h}, th.line_highlight) // current-line bar
        }

        // Selection spans: highlight each cursor's selection that covers this line
        // (first/last line clip to the cursor's columns, interior lines fill out).
        for c in b.cursors {
            if !cursor_has_selection(c) {
                continue
            }
            lo, hi := cursor_range(c)
            if line < lo.line || line > hi.line {
                continue
            }
            start := line == lo.line ? lo.col : 0
            end := line == hi.line ? hi.col : len(l.text)
            if end > start {
                sx := i32(text_x + cw * f32(start))
                fill(t, Rect{sx, y, i32(cw * f32(end - start)), row_h}, th.selection)
            }
        }

        // Indent guides: a thin vertical rail at each indent level, the cursor's
        // scope drawn in the active colour. Then the ghosted whitespace markers.
        if a.show_guides {
            draw_indent_guides(t, b, line, text_x, y, row_h, cw, unit, th, scope)
        }
        if a.show_whitespace {
            draw_whitespace(t, l, text_x, f32(y), row_h, cw, a.scale, th.whitespace)
        }

        buf: [12]u8
        s := strconv.write_int(buf[:], i64(line_number(a.line_numbers, line, cur_line)), 10)
        nx := f32(area.x) + cw + f32(gutter - i32(len(s))) * cw // right-align in gutter
        text_draw(t, s, nx, ty, on_cur_line ? th.fg : th.muted)

        k := line - top // index into the highlight rows (absolute-line based)
        if hl != nil && k < len(hl) && hl[k] != nil {
            draw_runes_colored(t, l.text[:], hl[k], text_x, ty, th.fg)
        } else {
            text_draw_runes(t, l.text[:], text_x, ty, th.fg)
        }

        // A folded header carries a marker after its text so the collapse is visible.
        if buffer_fold_index(b, line) >= 0 {
            draw_fold_marker(t, text_x + cw * (f32(len(l.text)) + 0.5), f32(y), lh, a.scale, th.accent)
        }

        // A caret for every cursor sitting on this line (single-cursor = one), shown
        // on the blink's "on" phase.
        if caret_blink_on(a, now) {
            for c in b.cursors {
                if c.head.line == line {
                    // Align the caret with the glyph cell (at ty), not the padded row top.
                    caret(t, Rect{i32(text_x + cw * f32(c.head.col)), i32(ty), i32(2 * a.scale), i32(lh)}, th.fg)
                }
            }
        }
    }

    flush_pane(t, area, win_w, win_h)
}

// Indent guides for one line: a thin vertical rail at the left edge of each indent
// level the line sits at. The rail of the cursor's enclosing scope (sc_level, over
// rows [sc_lo, sc_hi]) is drawn in the active colour so the current block stands out.
@(private = "file")
draw_indent_guides :: proc(t: ^Text, b: ^Buffer, line: int, text_x: f32, y, row_h: i32, cw: f32, unit: int, th: ^Theme, scope: Scope) {
    levels := buffer_indent_levels(b, line, unit)
    gw := max(i32(1), i32(cw) / 16) // hairline, ~1px
    aw := gw * 2 // the active scope rail is a touch thicker so it reads as the focus
    for lvl in 0 ..< levels {
        // Sit the rail half a cell into the indentation it marks, not hard against the
        // glyph grid — it reads as a guide between columns rather than under them.
        gx := i32(text_x + cw * (f32(lvl * unit) + 0.5))
        if scope_highlights(scope, line, lvl) {
            fill(t, Rect{gx - (aw - gw) / 2, y, aw, row_h}, th.indent_guide_active) // centred on the rail
        } else {
            fill(t, Rect{gx, y, gw, row_h}, th.indent_guide)
        }
    }
}

// Ghosted whitespace markers over a line's LEADING indentation: a small centred dot
// per space, a short horizontal stroke per tab. Only the indent run is marked — inner
// spacing between words stays clean. y is the row top; row_h the padded row height.
@(private = "file")
draw_whitespace :: proc(t: ^Text, l: ^Line, text_x, y: f32, row_h: i32, cw, scale: f32, color: [3]f32) {
    for r, col in l.text {
        if r != ' ' && r != '\t' {
            break
        }
        cx := text_x + cw * f32(col)
        if r == ' ' {
            d := max(i32(2), i32(2 * scale)) // a small square dot
            dx := i32(cx + (cw - f32(d)) / 2)
            dy := i32(y) + (row_h - d) / 2
            fill(t, Rect{dx, dy, d, d}, color)
        } else { // tab: a short stroke across the cell, vertically centred
            h := max(i32(1), i32(scale))
            sx := i32(cx + cw * 0.2)
            sy := i32(y) + (row_h - h) / 2
            fill(t, Rect{sx, sy, i32(cw * 0.6), h}, color)
        }
    }
}

// The collapsed-block marker: three dots trailing a folded header line, in accent.
@(private = "file")
draw_fold_marker :: proc(t: ^Text, x, y, lh: f32, scale: f32, color: [3]f32) {
    d := max(i32(2), i32(2 * scale))
    cy := i32(y + lh / 2) - d / 2
    for k in 0 ..< 3 {
        dx := i32(x + f32(k) * (f32(d) + 2 * scale))
        fill(t, Rect{dx, cy, d, d}, color)
    }
}

// Draws a line's runes split into runs of one colour each (syntax highlighting).
// Monospace makes each run's x pure arithmetic. Falls back to a single fallback-colour
// draw if the colour count doesn't match (belt-and-suspenders; they always match).
@(private = "file")
draw_runes_colored :: proc(t: ^Text, runes: []rune, colors: Row_Colors, x, y: f32, fallback: [3]f32) {
    if len(colors) != len(runes) {
        text_draw_runes(t, runes, x, y, fallback)
        return
    }
    cw := t.font.cell_w
    for i := 0; i < len(runes); {
        j := i + 1
        for j < len(runes) && colors[j] == colors[i] {
            j += 1
        }
        text_draw_runes(t, runes[i:j], x + cw * f32(i), y, colors[i])
        i = j
    }
}

@(private = "file")
num_digits :: proc(n: int) -> int {
    d := 1
    for m := n; m >= 10; m /= 10 {
        d += 1
    }
    return d
}

@(private = "file")
line_number :: proc(mode: Line_Numbers, line, cursor: int) -> int {
    if mode == .Relative && line != cursor {
        return abs(line - cursor)
    }
    return line + 1 // absolute (and the cursor line under relative/hybrid)
}

// Draws a label inside a pane at the top-left. (Caller flushes the region.)
label :: proc(t: ^Text, s: string, r: Rect, pad: i32, color: [3]f32) {
    text_draw(t, s, f32(r.x + pad), f32(r.y + pad), color)
}

// The command line as it lives in the status strip: prompt, the editable runes,
// a selection highlight, and a caret. Monospace makes every x pure arithmetic.
// The caller flushes the strip region after this returns.
draw_command_line :: proc(t: ^Text, strip: Rect, a: ^App, now: f64) {
    PROMPT :: "> "
    th := &a.theme
    l := &a.cl.lines[0] // the command line is one line
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    text_draw(t, PROMPT, f32(strip.x + pad), y, th.muted)
    ox := f32(strip.x + pad) + cw * f32(len(PROMPT)) // text origin, after the prompt

    // Selection spans, then text, then a caret per cursor (single-cursor = one).
    for c in a.cl.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(t, Rect{i32(ox + cw * f32(lo.col)), i32(y), i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
        }
    }

    text_draw_runes(t, l.text[:], ox, y, th.fg)

    if caret_blink_on(a, now) {
        for c in a.cl.cursors {
            caret(t, Rect{i32(ox + cw * f32(c.head.col)), i32(y), i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
}

// The idle strip: an emacs-style modeline for the editor buffer. File name + a
// modified marker on the left (brighter when dirty); language, caret line:col, line
// count, any multi-cursor count, and a scroll indicator right-aligned. Monospace
// makes the right-alignment pure arithmetic. The caller flushes the strip region.
@(private = "file")
draw_status :: proc(t: ^Text, strip: Rect, a: ^App) {
    th := &a.theme
    cw := t.font.cell_w
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - t.font.line_height) / 2

    // Util has no editor on screen; just name the aux pane there.
    if a.view == .Util {
        text_draw(t, aux_mode_name(a.aux_mode), f32(strip.x + pad), y, th.muted)
        return
    }

    b := editor_current(&a.editor)

    // Left: modified marker + file name (basename; "untitled" when unnamed).
    name := b.path == "" ? "untitled" : filepath.base(b.path)
    left := fmt.tprintf("%s %s", b.dirty ? "*" : " ", name)
    text_draw(t, left, f32(strip.x + pad), y, b.dirty ? th.fg : th.muted)

    // Right (right-aligned): lang   Lline:col   N lines   [N cursors]   scroll. All
    // ASCII, so the byte length is the cell count for placement.
    head := b.cursors[b.primary].head
    nlines := len(b.lines)
    pos := fmt.tprintf("L%d:%d", head.line + 1, head.col + 1)
    cursors := len(b.cursors) > 1 ? fmt.tprintf("   %d cursors", len(b.cursors)) : ""
    right := fmt.tprintf(
        "%s   %s   %d lines%s   %s",
        status_lang(a, b.path), pos, nlines, cursors, scroll_label(head.line, nlines),
    )
    rx := f32(strip.x + strip.w - pad) - cw * f32(len(right))
    text_draw(t, right, rx, y, th.muted)

    // Center: the project root (~-abbreviated), so the `cd`-captured root the git pane
    // and `tu` use is always visible while the command line is idle.
    root := home_abbrev(a.project_root, context.temp_allocator)
    if root != "" {
        rootx := f32(strip.x) + (f32(strip.w) - cw * f32(len(root))) / 2
        text_draw(t, root, rootx, y, th.muted)
    }
}

// Abbreviate a leading $HOME to ~ for display (e.g. /home/me/src -> ~/src). Returns a
// borrowed slice of `path` when nothing changes, else a fresh string in `alloc`.
@(private = "file")
home_abbrev :: proc(path: string, alloc := context.allocator) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && strings.has_prefix(path, home) {
        return strings.concatenate({"~", path[len(home):]}, alloc)
    }
    return path
}

// Modeline language label: the registry's name for the file's extension, else the
// bare extension, else "text" (unnamed/extension-less buffers).
@(private = "file")
status_lang :: proc(a: ^App, path: string) -> string {
    ext := strings.trim_prefix(filepath.ext(path), ".")
    if ext == "" {
        return "text"
    }
    if name, ok := grammar_for_ext(a.grammars, ext); ok {
        return name
    }
    return ext
}

// Emacs-style scroll indicator from the caret line: Top / Bot / All, else percent
// through the buffer.
@(private = "file")
scroll_label :: proc(line, nlines: int) -> string {
    if nlines <= 1 {
        return "All"
    }
    if line == 0 {
        return "Top"
    }
    if line >= nlines - 1 {
        return "Bot"
    }
    return fmt.tprintf("%d%%", line * 100 / (nlines - 1))
}

// The filetree listing: a dired-style header (current dir) then rows, each
// prefixed '*' (in the unsaved ring) or '-' (not). The selection is highlighted
// and kept centered as the list scrolls; directories are tinted.
draw_filetree :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    ft := &a.tree
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin

    text_draw(t, ft.dir, x0, f32(area.y) + (f32(row_h) - lh) / 2, th.muted)

    list_top := area.y + row_h
    max_rows := max(1, int((area.y + area.h - list_top) / row_h))
    first := clamp(ft.selected - max_rows / 2, 0, max(0, len(ft.entries) - max_rows))
    visible := min(len(ft.entries) - first, max_rows)

    for k in 0 ..< visible {
        i := first + k
        e := &ft.entries[i]
        y := list_top + i32(k) * row_h
        if i == ft.selected {
            fill(t, Rect{area.x, y, area.w, row_h}, th.separator)
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        ringed := ring_contains(a, e.path)
        prefix := ringed ? "*" : "-"
        text_draw(t, prefix, x0, ty, ringed ? th.urgent : th.muted)
        text_draw(t, e.display, x0 + cw * 2, ty, e.is_dir ? th.code_return_type : th.fg)
    }

    flush_pane(t, area, win_w, win_h)
}

// Lines of extra vertical padding per grep row — a touch airier than the editor / filetree
// (i32(2)) so the stacked context blocks don't read as one packed wall of text.
GREP_ROW_PAD :: 5

// One flattened display row of the grep pane: a block's "path:line" title (header), one of
// its context lines (with a line-number gutter; `match` marks the hit line), or a blank
// spacer between blocks. `sel` tags every row of the selected block.
@(private = "file")
GrepRow :: struct {
    gutter: string, // the context line's number; "" for a header / spacer
    text:   string,
    color:  [3]f32,
    sel:    bool, // part of the selected block (faint background)
    match:  bool, // the matched line (accent rail when its block is selected)
    header: bool, // the block's "path:line" title row (drawn flush-left)
}

// The grep results pane (the FIND aux mode): a header naming the query + hit count, then each
// hit as a `grep -rn`-style CONTEXT BLOCK — a project-relative "path:line" title over the
// lines around the match (line-number gutter, the hit line lit), blocks parted by a blank
// row. The selected block carries a faint bar + an accent rail on its hit line, and the list
// centre-scrolls to keep it visible (like the filetree). Up/Down move the selection and Enter
// jumps to it (grep_key -> grep_open_selected). Results come from the CL `grep` builtin or
// Alt+Enter's multi-definition goto; an empty set shows a placeholder.
draw_grep :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    g := &a.grep
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(GREP_ROW_PAD * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin

    header := g.query == "" ? "grep" : fmt.tprintf("grep: %s   (%d)", g.query, len(g.hits))
    text_draw(t, header, x0, f32(area.y) + (f32(row_h) - lh) / 2, focus_fg(a, .Aux))

    list_top := area.y + row_h
    if len(g.hits) == 0 {
        text_draw(t, "(no matches)", x0 + cw, f32(list_top) + (f32(row_h) - lh) / 2, th.muted)
        flush_pane(t, area, win_w, win_h)
        return
    }

    // The line-number gutter is as wide as the largest line number any block prints.
    maxln := 1
    for h in g.hits {
        maxln = max(maxln, h.line + GREP_CONTEXT)
    }
    gutw := num_digits(maxln)

    // Flatten the hits into display rows (title + context block + spacer), noting the row the
    // selected block opens at so the scroll can centre on it.
    rows := make([dynamic]GrepRow, 0, len(g.hits) * (2 * GREP_CONTEXT + 3), context.temp_allocator)
    sel_anchor := 0
    for h, hi in g.hits {
        selected := hi == g.selected
        if selected {
            sel_anchor = len(rows)
        }
        loc := fmt.tprintf("%s:%d", grep_relpath(h.path, a.project_root), h.line)
        append(&rows, GrepRow{text = loc, color = selected ? th.fg : th.muted, sel = selected, header = true})
        if len(h.ctx) == 0 {
            append(&rows, GrepRow{text = h.text, color = th.fg, sel = selected, match = true})
        } else {
            for c, k in h.ctx {
                ln := h.ctx_first + k
                is_match := ln == h.line
                append(
                    &rows,
                    GrepRow {
                        gutter = fmt.tprintf("%d", ln),
                        text = c,
                        color = is_match ? th.fg : th.muted,
                        sel = selected,
                        match = is_match,
                    },
                )
            }
        }
        append(&rows, GrepRow{}) // blank spacer between blocks
    }

    max_rows := max(1, int((area.y + area.h - list_top) / row_h))
    first := clamp(sel_anchor - max_rows / 2, 0, max(0, len(rows) - max_rows))
    visible := min(len(rows) - first, max_rows)
    text_x := x0 + cw * f32(gutw + 1) // gutter then a one-cell gap

    for k in 0 ..< visible {
        r := rows[first + k]
        y := list_top + i32(k) * row_h
        if r.sel {
            fill(t, Rect{area.x, y, area.w, row_h}, th.line_highlight) // selected block band
            if r.match {
                fill(t, Rect{area.x, y, i32(2 * a.scale), row_h}, th.accent) // rail on the hit line
            }
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        if r.header {
            text_draw(t, r.text, x0, ty, r.color) // block title, flush-left
            continue
        }
        if r.gutter != "" { // right-align the line number in the gutter
            gx := x0 + cw * f32(gutw - len(r.gutter))
            text_draw(t, r.gutter, gx, ty, th.muted)
        }
        text_draw(t, r.text, text_x, ty, r.color)
    }

    flush_pane(t, area, win_w, win_h)
}

// A hit's path made project-relative for display ("/root/proj/src/x.odin" -> "src/x.odin"),
// falling back to the full path when it isn't under the root. Borrows `path`'s storage.
@(private = "file")
grep_relpath :: proc(path, root: string) -> string {
    if root != "" && strings.has_prefix(path, root) {
        rel := path[len(root):]
        return strings.has_prefix(rel, "/") ? rel[1:] : rel
    }
    return path
}

// The procmon (process monitor) aux mode: a GRAPH BAND up top (a tab-enum of CPU /
// Memory / Disk / GPU history graphs, or the signal selector when armed) over a
// btop-style PROCESS LIST (cpu% / mem / pid / user / name / command). Data is the
// lock-free snapshot drained from the sampler thread (procmon.odin); this only reads
// pm.cur + pm.view. Up/Down move the selection, crossing into the band at the top
// (procmon_key); Space opens the bottom filter bar.
draw_procmon :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    pm := &a.procmon
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw

    // Top band: graph(s) or the signal selector. Tall enough for the 1..31 grid while
    // arming a signal, but always leaving a couple of list rows below.
    band_rows := pm.sig_open ? i32(9) : i32(7)
    band_h := min(row_h * band_rows, max(row_h * 2, area.h - row_h * 3))
    band := Rect{area.x, area.y, area.w, band_h}
    if pm.sig_open {
        procmon_draw_signals(t, band, a, row_h)
    } else {
        procmon_draw_graph(t, band, a, row_h)
    }

    // Column header. Offsets are in cells, so they track the font zoom.
    cpu_x := x0
    mem_x := x0 + cw * 7
    pid_x := x0 + cw * 16
    user_x := x0 + cw * 24
    name_x := x0 + cw * 34
    cmd_x := x0 + cw * 52
    hdr_y := area.y + band_h
    hty := f32(hdr_y) + (f32(row_h) - lh) / 2
    text_draw(t, "CPU%", cpu_x, hty, th.muted)
    text_draw(t, "MEM", mem_x, hty, th.muted)
    text_draw(t, "PID", pid_x, hty, th.muted)
    text_draw(t, "USER", user_x, hty, th.muted)
    text_draw(t, "NAME", name_x, hty, th.muted)
    text_draw(t, "COMMAND", cmd_x, hty, th.muted)

    // The scrollable process list, centre-scrolled on the selection (smooth, like the
    // editor / diff). The filter bar, when open, claims the bottom row.
    list_top := hdr_y + row_h
    filter_h := pm.filtering ? row_h : 0
    bottom := area.y + area.h - filter_h
    max_rows := max(1, int((bottom - list_top) / row_h))
    n := len(pm.view)
    target_top := clamp(pm.sel - max_rows / 2, 0, max(0, n - max_rows))
    top, off := smooth_scroll(&pm.scroll_anim, target_top, now, row_h)

    list_focus := pm.focus == .List && a.focus == .Aux
    for k in 0 ..< max_rows + 1 {
        i := top + k
        if i < 0 || i >= n {
            continue
        }
        y := list_top + i32(k) * row_h - off
        if y + row_h <= list_top || y >= bottom {
            continue // partial row scrolled out of the list band
        }
        r := &pm.cur.procs[pm.view[i]]
        ty := f32(y) + (f32(row_h) - lh) / 2
        // The kill confirm replaces its row with a one-key prompt (urgent band).
        if pm.kill_armed && r.pid == pm.kill_pid {
            fill(t, Rect{area.x, y, area.w, row_h}, th.urgent)
            text_draw(t, fmt.tprintf("kill %s (%d)?   enter/y = confirm    esc = cancel", proc_trunc(r.name, 24), r.pid), cpu_x, ty, th.bg)
            continue
        }
        if i == pm.sel {
            fill(t, Rect{area.x, y, area.w, row_h}, list_focus ? th.selection : th.line_highlight)
        }
        // Tint hot processes: green past 10% of a core, red past 50%.
        cpu_col := r.cpu_pct >= 50 ? th.urgent : (r.cpu_pct >= 10 ? th.code_return_type : th.fg)
        text_draw(t, fmt.tprintf("%5.1f", r.cpu_pct), cpu_x, ty, cpu_col)
        text_draw(t, proc_human_kb(r.rss_kb), mem_x, ty, th.fg)
        text_draw(t, fmt.tprintf("%d", r.pid), pid_x, ty, th.muted)
        text_draw(t, proc_trunc(r.user, 9), user_x, ty, th.muted)
        text_draw(t, proc_trunc(r.name, 17), name_x, ty, th.fg)
        text_draw(t, r.cmd, cmd_x, ty, th.muted) // long commands clip on the pane scissor
    }

    if pm.filtering {
        fy := area.y + area.h - row_h
        fill(t, Rect{area.x, fy, area.w, row_h}, th.line_highlight)
        fty := f32(fy) + (f32(row_h) - lh) / 2
        text_draw(t, "filter ", x0, fty, th.accent)
        ftext_x := x0 + cw * 7
        text_draw_runes(t, pm.filter.lines[0].text[:], ftext_x, fty, th.fg)
        if caret_blink_on(a, now) {
            col := pm.filter.cursors[pm.filter.primary].head.col
            caret(t, Rect{i32(ftext_x + cw * f32(col)), fy + i32(2 * a.scale), max(i32(2 * a.scale), 1), row_h - i32(4 * a.scale)}, th.fg)
        }
    }

    flush_pane(t, area, win_w, win_h)
}

// The active graph for the selected category.
@(private = "file")
procmon_graphview :: proc(pm: ^ProcmonPane) -> ^GraphView {
    switch pm.cat {
    case .CPU:    return &pm.cur.cpu
    case .Memory: return &pm.cur.mem
    case .Disk:   return &pm.cur.disk
    case .GPU:    return &pm.cur.gpu
    }
    return &pm.cur.cpu
}

// The graph band: a category-tab row (active lit, the current readout in accent at
// the right) over the selected metric's history, drawn as columns rising from the
// baseline (newest at the right edge). A faint bg-derived tint marks it focused.
@(private = "file")
procmon_draw_graph :: proc(t: ^Text, band: Rect, a: ^App, row_h: i32) {
    pm := &a.procmon
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    x0 := f32(band.x) + cw

    if pm.focus == .Graphs && a.focus == .Aux {
        fill(t, band, lerp3(th.bg, th.accent, 0.08))
    }

    cats := [4]string{"cpu", "mem", "disk", "gpu"}
    gv := procmon_graphview(pm)
    tty := f32(band.y) + (f32(row_h) - lh) / 2
    cx := x0
    for name, i in cats {
        text_draw(t, name, cx, tty, GraphCat(i) == pm.cat ? th.fg : th.muted)
        cx += cw * f32(len(name) + 2)
    }
    if gv.label != "" {
        text_draw(t, gv.label, f32(band.x + band.w) - cw - cw * f32(len(gv.label)), tty, th.accent)
    }

    gtop := band.y + row_h
    gh := band.y + band.h - gtop
    if gh <= 0 {
        return
    }
    if !gv.avail {
        text_draw(t, "unavailable", x0, f32(gtop) + (f32(gh) - lh) / 2, th.muted)
        return
    }
    bar_col := lerp3(th.bg, th.accent, 0.55)
    colw := f32(band.w) / f32(PROC_HIST)
    right := band.x + band.w
    floor := gtop + gh
    for age in 0 ..< gv.hist.n {
        v := gv.hist.vals[(gv.hist.head - age + PROC_HIST) % PROC_HIST]
        bh := i32(v * f32(gh))
        x := right - i32(f32(age + 1) * colw)
        fill(t, Rect{x, floor - bh, max(i32(colw) + 1, 1), bh}, bar_col)
    }
}

// The signal selector, replacing the graph band (btop-style). A header names the
// target, then signals 1..31 in a grid with the armed one highlighted.
@(private = "file")
procmon_draw_signals :: proc(t: ^Text, band: Rect, a: ^App, row_h: i32) {
    pm := &a.procmon
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    x0 := f32(band.x) + cw

    fill(t, band, lerp3(th.bg, th.urgent, 0.10)) // arming a kill: a danger tint
    name := ""
    if pm.sel >= 0 && pm.sel < len(pm.view) {
        name = pm.cur.procs[pm.view[pm.sel]].name
    }
    tty := f32(band.y) + (f32(row_h) - lh) / 2
    text_draw(t, fmt.tprintf("signal -> %s (%d)   enter=send  q=cancel", name, procmon_sel_pid(pm)), x0, tty, th.fg)

    gtop := band.y + row_h
    cellw := cw * 13
    for s in 1 ..= 31 {
        col := (s - 1) % SIG_COLS
        rowi := (s - 1) / SIG_COLS
        cellx := x0 + f32(col) * cellw
        celly := gtop + i32(rowi) * row_h
        if s == pm.sig_sel {
            fill(t, Rect{i32(cellx) - i32(cw / 2), celly, i32(cellw), row_h}, th.accent)
        }
        text_draw(t, fmt.tprintf("%2d %s", s, SIG_NAMES[s]), cellx, f32(celly) + (f32(row_h) - lh) / 2, s == pm.sig_sel ? th.bg : th.fg)
    }
}

// The config / syntax pane: a "settings" block (editable key: value rows) then a
// "syntax" block listing each known language with its grammar status (✓/✗) and, when
// a row is opened, its install-options dropdown (nested under the language). Section
// headers are flanked by rules; setting values share one column. One selection
// highlight (separator), centre-scrolled like the filetree.
draw_config :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    cp := &a.config_pane
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin

    // Pad every setting key to the widest so all the values (and editors) start in
    // the same column: "<widest key>: ".
    keycol := 0
    for si in 0 ..< SETTING_COUNT {
        keycol = max(keycol, len(setting_key(Setting(si))))
    }
    val_off := f32(keycol + 2) // key + ": "

    // The flat list of display rows; cursor_row tracks the selection's display index
    // so the scroll can follow it.
    Row :: struct {
        text:   string,
        value:  string, // setting value, drawn at the shared value column; "" otherwise
        color:  [3]f32,
        sel:    bool, // draw the selection bar behind this row
        edit:   bool, // an open inline editor (draw `doc` at the value column)
        doc:    ^Doc, // the editor to draw when `edit` (the search box, cp.search)
        flush:  bool, // a header line (rule or title): drawn flush-left, no value column
        indent: i32, // extra left margin, in cells
    }
    rows := make([dynamic]Row, 0, 48, context.temp_allocator)
    cursor_row := 0

    // Section headers are a title in accent, flanked by full-width rules.
    rule_row := Row {
        text  = strings.repeat("-", max(1, int(f32(area.w) / cw) - 1), context.temp_allocator),
        color = th.border_light,
        flush = true,
    }

    append(&rows, rule_row)
    append(&rows, Row{text = "settings", color = th.accent, flush = true})
    append(&rows, rule_row)
    for si in 0 ..< SETTING_COUNT {
        s := Setting(si)
        open := cp.open == .Setting && cp.open_idx == si
        selected := cp.sel == si
        if selected && !open {
            cursor_row = len(rows) // when open, the highlighted option drives the scroll
        }
        val := setting_value(a, s)
        append(
            &rows,
            Row {
                text = fmt.tprintf("%s:", setting_key(s)),
                value = val == "" ? "(default)" : val,
                color = selected ? th.fg : th.muted,
                sel = selected && !open, // while open the highlight is on the chosen option
                indent = 1,
            },
        )
        if open {
            for o, oi in setting_options(a, s) {
                osel := cp.opt_sel == oi
                if osel {
                    cursor_row = len(rows)
                }
                append(&rows, Row{text = o, color = osel ? th.fg : th.muted, sel = osel, indent = 4})
            }
        }
    }

    append(&rows, rule_row)
    append(&rows, Row{text = "syntax", color = th.accent, flush = true})
    append(&rows, rule_row)

    // Search box: filters the long language list. Edited like a setting (Enter to
    // focus, type to filter live, Esc to browse the results).
    search_sel := cp.sel == SETTING_COUNT
    if search_sel {
        cursor_row = len(rows)
    }
    append(
        &rows,
        Row {
            text = "search:",
            value = doc_string(&cp.search, context.temp_allocator),
            color = search_sel ? th.fg : th.muted,
            sel = search_sel,
            edit = search_sel, // the search box is live whenever it's highlighted
            doc = &cp.search,
            indent = 1,
        },
    )

    for fi, idx in cp.filtered {
        l := &cp.langs[fi]
        row := SETTING_COUNT + 1 + idx
        open := cp.open == .Lang && cp.open_idx == fi
        if cp.sel == row {
            cursor_row = len(rows)
        }
        mark := l.present ? "✓" : "✗"
        append(
            &rows,
            Row {
                text = fmt.tprintf("%s %s", mark, l.name),
                color = l.present ? th.code_return_type : th.fg,
                sel = cp.sel == row && (!open || cp.opt_sel == -1), // root stays selectable while open
                indent = 1,
            },
        )
        if open {
            buf: [len(LangOption)]LangOption
            opts := lang_options(l.present, buf[:])
            for o, oi in opts {
                osel := cp.opt_sel == oi
                if osel {
                    cursor_row = len(rows)
                }
                // Indented past the language name (mark + space) so options nest under it.
                append(&rows, Row{text = lang_option_label(o), color = osel ? th.fg : th.muted, sel = osel, indent = 4})
            }
        }
    }

    // Centre-scroll on the cursor, clamped at the ends (like the filetree).
    max_rows := max(1, int(area.h / row_h))
    first := clamp(cursor_row - max_rows / 2, 0, max(0, len(rows) - max_rows))
    visible := min(len(rows) - first, max_rows)

    for k in 0 ..< visible {
        r := rows[first + k]
        y := area.y + i32(k) * row_h
        if r.sel {
            fill(t, Rect{area.x, y, area.w, row_h}, th.separator)
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        rx := x0 + cw * f32(r.indent)
        if r.flush {
            text_draw(t, r.text, x0, ty, r.color)
            continue
        }
        text_draw(t, r.text, rx, ty, r.color)
        valx := x0 + cw * (f32(r.indent) + val_off)
        if r.edit {
            config_draw_edit(t, r.doc, valx, ty, a, now)
        } else if r.value != "" {
            text_draw(t, r.value, valx, ty, th.fg)
        }
    }

    flush_pane(t, area, win_w, win_h)
}

// The inline settings editor: the edit buffer's runes at `ex` (the value column),
// with per-cursor selection spans and carets — the command-line treatment, reused.
@(private = "file")
config_draw_edit :: proc(t: ^Text, edit: ^Doc, ex, ty: f32, a: ^App, now: f64) {
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    line := &edit.lines[0]
    y := i32(ty) // selection/caret share the glyph cell's top
    for c in edit.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(t, Rect{i32(ex + cw * f32(lo.col)), y, i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
        }
    }
    text_draw_runes(t, line.text[:], ex, ty, th.fg)
    if caret_blink_on(a, now) {
        for c in edit.cursors {
            caret(t, Rect{i32(ex + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
}

// The git pane's sidebar takes this fraction of the aux pane's width; the diff viewer
// / commit editor gets the rest. (The editor itself is GIT_EDITOR_SPLIT — layout.odin.)
GIT_SIDEBAR_FRAC :: f32(0.40)

// Draw the selection playhead line. Off for now (selection still works off its row) —
// kept as a switch for a future idea.
DIFF_SHOW_PLAYHEAD :: false

// The commit message box grows line by line from COMMIT_MIN_ROWS tall, capped at
// COMMIT_MAX_ROWS (then it scrolls within itself — handled by the field renderer).
COMMIT_MIN_ROWS :: 2
COMMIT_MAX_ROWS :: 16

// The git aux mode (Sublime-Merge-lite, KB-only). The aux pane carries two sub-columns
// parted by a hairline: a SIDEBAR (branch strip + folder-grouped Status + Log, ported from
// Prawk) on the left and a persistent DIFF VIEWER + COMMIT EDITOR on the right. Each column
// composites under its own scissor so text can't bleed across the rule (see the "Git (aux
// mode)" section of plan.txt).
draw_git :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }

    // Split into the sidebar (left) and the diff / commit column (right), parted by a
    // one-pixel rule. The diff column manages its own flushes (it scissors the scrolled
    // content separately from the static title/commit chrome — see git_draw_diff).
    div_w := max(i32(1), i32(a.scale))
    side_w := clamp(i32(f32(area.w) * GIT_SIDEBAR_FRAC), 0, area.w)
    sidebar := Rect{area.x, area.y, side_w, area.h}
    rule := Rect{area.x + side_w, area.y, div_w, area.h}
    diff := Rect{rule.x + div_w, area.y, max(0, area.w - side_w - div_w), area.h}

    git_draw_sidebar(t, sidebar, a)
    flush_pane(t, sidebar, win_w, win_h)

    fill(t, rule, th.border_light) // the column rule
    flush_pane(t, rule, win_w, win_h)

    git_draw_diff(t, diff, a, win_w, win_h, now)
}

// One left-aligned text row, vertically centred in a row_h band whose top is at y.
@(private = "file")
git_row :: proc(t: ^Text, s: string, x: f32, y, row_h: i32, lh: f32, color: [3]f32) {
    text_draw(t, s, x, f32(y) + (f32(row_h) - lh) / 2, color)
}

// A sidebar zone row: display text + its colour, plus its selectable item index (the
// g.status / g.commits row it stands for; -1 for a non-selectable folder header) and a
// cell indent (files nested under a directory header). Built per-frame in temp memory.
@(private = "file")
ZoneRow :: struct {
    text:   string,
    color:  [3]f32,
    item:   int,
    indent: i32,
}

// Draws a titled sidebar zone within `zone`: the title, then its rows centre-scrolled to
// keep the selected ITEM visible (like the filetree). `sel` is an item index (a g.status /
// g.commits row); the zone finds the display row standing for it, since folder headers sit
// between file rows. When `active`, that row carries the selection bar. `sel` < 0 means no
// selection (e.g. an empty list's placeholder). The title uses `head`; rows use their own
// colours and per-row indent.
@(private = "file")
git_draw_zone :: proc(
    t: ^Text,
    title: string,
    rows: []ZoneRow,
    zone: Rect,
    row_h: i32,
    lh: f32,
    head: [3]f32,
    th: ^Theme,
    sel: int,
    active: bool,
) {
    cw := t.font.cell_w
    x0 := f32(zone.x) + cw // header at one cell; rows indent one more
    // An empty title means the caller draws its own heading (the modal sidebar's breadcrumb):
    // skip the title row so the list fills the whole zone.
    list_top := zone.y
    if title != "" {
        git_row(t, title, x0, zone.y, row_h, lh, head)
        list_top += row_h
    }
    max_rows := int(max(i32(0), (zone.y + zone.h - list_top) / row_h))
    if max_rows == 0 || len(rows) == 0 {
        return
    }
    // The display row standing for the selected item (headers carry item == -1).
    sel_row := -1
    if sel >= 0 {
        for r, i in rows {
            if r.item == sel {
                sel_row = i
                break
            }
        }
    }
    anchor := max(0, sel_row)
    first := clamp(anchor - max_rows / 2, 0, max(0, len(rows) - max_rows))
    visible := min(len(rows) - first, max_rows)
    for k in 0 ..< visible {
        i := first + k
        y := list_top + i32(k) * row_h
        if active && i == sel_row {
            fill(t, Rect{zone.x, y, zone.w, row_h}, th.separator)
        }
        git_row(t, rows[i].text, x0 + cw + f32(rows[i].indent) * cw, y, row_h, lh, rows[i].color)
    }
}

// The directory portion of a status path ("src/tests/x" -> "src/tests"), or "" for a
// top-level file. Drives the sidebar's folder grouping.
@(private = "file")
git_dir_of :: proc(path: string) -> string {
    if i := strings.last_index_byte(path, '/'); i >= 0 {
        return path[:i]
    }
    return ""
}

// Colour a working-tree entry by its porcelain code: staged entries green (the "directory
// slot" — in the index), untracked dim, an unstaged deletion urgent, other unstaged changes
// in the normal foreground.
@(private = "file")
git_status_color :: proc(code: string, th: ^Theme) -> [3]f32 {
    switch {
    case git_is_conflict(code):
        return th.urgent // unmerged path — needs resolving
    case git_is_staged(code):
        return th.code_return_type
    case strings.contains(code, "?"):
        return th.muted
    case strings.contains(code, "D"):
        return th.urgent
    case:
        return th.fg
    }
}

// Status-page rows: working-tree changes grouped by parent directory — a dim folder header
// per directory, then its files indented under it (basename only). Entries are pre-sorted by
// path (git_load_status) so one pass clusters them; each file row keeps its g.status index
// for selection. Empty -> a "(clean)" placeholder.
@(private = "file")
git_status_rows :: proc(g: ^GitPane, th: ^Theme) -> []ZoneRow {
    rows := make([dynamic]ZoneRow, 0, max(1, len(g.status)), context.temp_allocator)
    if len(g.status) == 0 {
        append(&rows, ZoneRow{text = "(clean)", color = th.muted, item = -1})
        return rows[:]
    }
    prev_dir := "\x00" // sentinel: unequal to any real dir, so the first row emits one
    for e, i in g.status {
        dir := git_dir_of(e.path)
        if dir != prev_dir && dir != "" {
            append(&rows, ZoneRow{text = fmt.tprintf("%s/", dir), color = th.muted, item = -1})
        }
        prev_dir = dir
        name := dir == "" ? e.path : e.path[len(dir) + 1:] // basename under the header
        append(&rows, ZoneRow {
            text = fmt.tprintf("%s %s", e.code, name),
            color = git_status_color(e.code, th),
            item = i,
            indent = dir == "" ? 0 : 1,
        })
    }
    return rows[:]
}

// Log-page rows: the recent commits, flat — hash + subject, each tagged with its index.
@(private = "file")
git_log_rows :: proc(g: ^GitPane, th: ^Theme) -> []ZoneRow {
    rows := make([dynamic]ZoneRow, 0, len(g.commits), context.temp_allocator)
    for c, i in g.commits {
        append(&rows, ZoneRow{text = fmt.tprintf("%s %s", c.hash, c.subject), color = th.fg, item = i})
    }
    return rows[:]
}

// Branch-page rows: every local branch (the checked-out one marked "*" in accent), then a
// trailing "new branch" row (item == len(branches)) that Enter turns into a `checkout -b`
// prefill. Selection (g.sel_branch) indexes this whole list.
@(private = "file")
git_branch_rows :: proc(g: ^GitPane, th: ^Theme) -> []ZoneRow {
    rows := make([dynamic]ZoneRow, 0, len(g.branches) + 1, context.temp_allocator)
    for b, i in g.branches {
        cur := b == g.branch
        append(&rows, ZoneRow {
            text = fmt.tprintf("%s %s", cur ? "*" : " ", b),
            color = cur ? th.accent : th.fg,
            item = i,
        })
    }
    append(&rows, ZoneRow{text = "+ new branch", color = th.muted, item = len(g.branches)})
    return rows[:]
}

// Remote-page rows: a non-selectable upstream detail line, then the push / pull / fetch
// actions (a GitRemoteRow each), push/pull annotated with the ahead/behind they'd move.
@(private = "file")
git_remote_rows :: proc(g: ^GitPane, th: ^Theme) -> []ZoneRow {
    rows := make([dynamic]ZoneRow, 0, len(GitRemoteRow) + 1, context.temp_allocator)
    detail := g.has_upstream ? fmt.tprintf("→ %s", g.upstream) : "(no upstream)"
    append(&rows, ZoneRow{text = detail, color = th.muted, item = -1})
    push := g.ahead > 0 ? fmt.tprintf("push   ↑%d", g.ahead) : "push"
    pull := g.behind > 0 ? fmt.tprintf("pull   ↓%d", g.behind) : "pull"
    append(&rows, ZoneRow{text = push, color = th.fg, item = int(GitRemoteRow.Push)})
    append(&rows, ZoneRow{text = pull, color = th.fg, item = int(GitRemoteRow.Pull)})
    append(&rows, ZoneRow{text = "fetch", color = th.fg, item = int(GitRemoteRow.Fetch)})
    return rows[:]
}

// The sidebar is MODAL (see GitSection): a persistent two-line header — the checked-out
// branch with its ahead/behind, then a page breadcrumb with the active page lit — sits above
// one full-height page (Status / Log / Branch / Remote), drawn by the shared git_draw_zone.
// Tab swaps the page; the selection bar shows on the active page when the sidebar is focused.
// When the project root resolves to no repo, the sidebar says so.
@(private = "file")
git_draw_sidebar :: proc(t: ^Text, area: Rect, a: ^App) {
    g := &a.git
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin

    if !g.is_repo {
        git_row(t, "not a git repository", x0, area.y, row_h, lh, th.muted)
        return
    }

    side_focused := a.focus == .Aux && a.aux_mode == .Git && g.region == .Sidebar

    // Header line: the checked-out branch (accent), then ahead/behind vs upstream (faint) —
    // always visible so "you are here" never scrolls away with a page swap.
    bname := g.branch == "" ? "(detached)" : g.branch
    git_row(t, bname, x0, area.y, row_h, lh, th.accent)
    if g.has_upstream && (g.ahead > 0 || g.behind > 0) {
        ab := fmt.tprintf("↑%d ↓%d", g.ahead, g.behind)
        git_row(t, ab, x0 + f32(len(bname) + 1) * cw, area.y, row_h, lh, th.muted)
    }

    // Breadcrumb line (the modal tab strip): the four page names, the active one lit. Drawn
    // segment by segment so each carries its own colour; advance assumes the monospace cell.
    crumbs := [?]struct {
        sec:   GitSection,
        label: string,
    }{{.Status, "status"}, {.Log, "log"}, {.Branch, "branches"}, {.Remote, "remote"}}
    cx := x0
    crumb_y := area.y + row_h
    for c in crumbs {
        git_row(t, c.label, cx, crumb_y, row_h, lh, g.section == c.sec ? th.accent : th.muted)
        cx += f32(len(c.label) + 2) * cw // two-cell gap between crumbs
    }

    // The active page fills the rest of the sidebar (title "" — the breadcrumb is the head).
    body_top := crumb_y + row_h + row_h / 2
    body := Rect{area.x, body_top, area.w, max(i32(0), area.y + area.h - body_top)}
    rows: []ZoneRow
    sel: int
    switch g.section {
    case .Status: rows, sel = git_status_rows(g, th), len(g.status) > 0 ? g.sel_status : -1
    case .Log:    rows, sel = git_log_rows(g, th), len(g.commits) > 0 ? g.sel_log : -1
    case .Branch: rows, sel = git_branch_rows(g, th), g.sel_branch
    case .Remote: rows, sel = git_remote_rows(g, th), g.sel_remote
    }
    git_draw_zone(t, "", rows, body, row_h, lh, th.muted, th, sel, side_focused)
}

// Colour a diff line by kind: additions green (the directory slot), deletions urgent,
// hunk headers in accent, file headers dim, context in the normal foreground.
@(private = "file")
git_diff_color :: proc(kind: DiffLineKind, th: ^Theme) -> [3]f32 {
    switch kind {
    case .Add:
        return th.code_return_type
    case .Del:
        return th.urgent
    case .Hunk:
        return th.accent
    case .Header:
        return th.muted
    case .Context:
        return th.fg
    case:
        return th.fg
    }
}

// The checkbox-slot label for a conflict hunk's header: the current resolution, or "[ ? ]"
// while unresolved. Fixed-ish width so the body text after it stays roughly aligned.
@(private = "file")
git_choice_label :: proc(c: ConflictChoice) -> string {
    switch c {
    case .Ours:   return "[ours]"
    case .Theirs: return "[theirs]"
    case .Both:   return "[both]"
    case .Unresolved:
        return "[ ? ]"
    }
    return "[ ? ]"
}

// One display row of the diff column, flattened for scrolling. hunk = -1 for preamble /
// file-title rows; header marks the @@ line (carries the checkbox).
@(private = "file")
DiffRow :: struct {
    text:     string,
    color:    [3]f32,
    hunk:     int,
    header:   bool,
    selected: bool, // checked (normal) / resolved (conflict) — drives the diagonal hatch
    conflict: bool, // a conflict hunk's rows: the header shows the resolution label, not a checkbox
    label:    string, // the conflict header's resolution label ("[ours]" / "[ ? ]" …)
}

// A faint hatch shade derived from the block background: brighten a dark bg / darken a
// light one. The nudge is exaggerated for mid-luminance backgrounds (where a fixed shift
// reads weakest) and never zero, but kept small so text stays readable over it.
@(private = "file")
git_stripe_color :: proc(bg: [3]f32) -> [3]f32 {
    lum := 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
    d := lum - 0.5
    if d < 0 {
        d = -d
    }
    amt := 0.05 + 0.10 * (1 - d * 2) // 0.05 at the extremes, 0.15 at mid-luminance
    target := lum < 0.5 ? [3]f32{1, 1, 1} : [3]f32{0, 0, 0}
    return lerp3(bg, target, amt)
}

// Diagonal hatch over a row's rect — repeating 45° parallelograms, phased by the row's
// absolute y so they connect across rows. Marks a CHECKED (staged-selection) hunk so it
// reads as included even when its header checkbox is scrolled out of view. The content
// scissor clips the slant overhang.
@(private = "file")
git_draw_stripes :: proc(t: ^Text, r: Rect, c: [3]f32, scale: f32) {
    P := max(i32(8), i32(16 * scale)) // stripe period
    thick := P / 3 // stripe width
    rh := r.h
    // Bands lie where (x + y) is a multiple of P; per row, one parallelogram per band
    // (top-left x = k*P - y), slanted down-left by rh (45°). Padding covers the slant.
    kmin := (r.x - thick + r.y) / P - 1
    kmax := (r.x + r.w + rh + r.y) / P + 1
    for k := kmin; k <= kmax; k += 1 {
        lx := k * P - r.y
        top, bot := f32(r.y), f32(r.y + rh)
        fill_quad(t, {f32(lx), top}, {f32(lx + thick), top}, {f32(lx - rh + thick), bot}, {f32(lx - rh), bot}, c)
    }
}

// The diff viewer / commit editor (the aux pane's right column). Top chrome: the diff
// title, then a grep filter bar + select-all/none actions. Middle: the always-on diff as
// hunk BLOCKS (checkbox + @@ header + tinted body), SMOOTH-scrolled, a centred PLAYHEAD
// picking the selected hunk (rail-marked); hunks filtered out by grep take no rows. Bottom
// chrome: the commit message box (grows line by line). Chrome and the scrolled content are
// flushed under separate scissors so the content can't bleed over the bars.
@(private = "file")
git_draw_diff :: proc(t: ^Text, area: Rect, a: ^App, win_w, win_h: i32, now: f64) {
    g := &a.git
    if !g.is_repo {
        return // nothing to diff/commit; the sidebar already says "not a git repository"
    }
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw
    focused := a.focus == .Aux && a.aux_mode == .Git
    diff_focused := focused && g.region == .Diff

    // The commit strip grows with the message; the diff fills the band between the top
    // chrome (title + grep bar) and the strip.
    msg_rows := clamp(len(g.commit_msg.lines), COMMIT_MIN_ROWS, COMMIT_MAX_ROWS)
    strip_h := row_h * i32(1 + msg_rows)
    list_top := area.y + row_h * 2 // title row + grep/actions bar
    sy := area.y + area.h - strip_h
    has_strip := sy > list_top + row_h
    diff_bottom := has_strip ? sy : area.y + area.h

    // --- chrome: title, grep bar, commit strip — all flushed clipped to the whole column ---
    git_row(t, g.diff_title == "" ? "working tree" : g.diff_title, x0, area.y, row_h, lh, diff_focused ? th.accent : th.muted)
    git_draw_grepbar(t, area, a, now)
    if has_strip {
        git_draw_commit(t, Rect{area.x, sy, area.w, strip_h}, a, msg_rows, now)
    }
    flush_pane(t, area, win_w, win_h)

    // --- scrolled content, clipped to the band between the bars ---
    content := Rect{area.x, list_top, area.w, max(i32(0), diff_bottom - list_top)}
    max_rows := int(max(i32(0), content.h / row_h))
    g.diff_view_rows = max_rows // publish so nav knows the playhead offset
    offset := max_rows / 2

    // Flatten the VISIBLE files -> rows (preamble, then per file a title + each visible
    // hunk block: its @@ header row, its body lines, then a spacer row). Hidden files/hunks
    // (filtered by grep) are skipped; the hk index counts visible hunks to match hunk_cur.
    // Must match git_diff_rows' counting.
    rows := make([dynamic]DiffRow, 0, 128, context.temp_allocator)
    for s in g.diff_preamble {
        append(&rows, DiffRow{text = s, color = th.muted, hunk = -1})
    }
    hk := 0
    for f in g.diff_files {
        if f.hidden {
            continue
        }
        title := f.path != "" ? f.path : (len(f.header) > 0 ? f.header[0] : "(file)")
        append(&rows, DiffRow{text = title, color = th.code_return_type, hunk = -1})
        for h in f.hunks {
            if h.hidden {
                continue
            }
            // A conflict hunk's "selected" (the hatch) reads off its resolution: marked once a
            // side is chosen. Its header carries a label instead of a checkbox.
            mark := h.conflict ? h.choice != .Unresolved : h.selected
            append(&rows, DiffRow{text = h.header, hunk = hk, header = true, selected = mark, conflict = h.conflict, label = git_choice_label(h.choice)})
            for l in h.lines {
                append(&rows, DiffRow{text = l.text, color = git_diff_color(l.kind, th), hunk = hk, selected = mark, conflict = h.conflict})
            }
            append(&rows, DiffRow{text = "", hunk = -1}) // spacer between blocks
            hk += 1
        }
    }

    if len(rows) == 0 {
        empty := git_grep_query(g) != "" ? "(no matches)" : "(no changes)"
        git_row(t, empty, x0 + cw, list_top, row_h, lh, th.muted)
        flush_pane(t, content, win_w, win_h)
        return
    }

    // A fresh diff (or filter change) centres its first visible hunk on the playhead, once
    // (snap, no slide).
    if g.diff_recenter && git_hunk_count(g) > 0 {
        g.diff_scroll = clamp(git_hunk_top_row(g, 0) - offset, git_scroll_lo(g), git_scroll_hi(g))
        g.diff_scroll_anim = Anim{to = f32(g.diff_scroll)}
        g.diff_recenter = false
    }
    // Scroll position. While the reels are SPINNING it's driven straight off the spin's easing
    // (a fractional row position) so it glides; otherwise the smooth-scroll anim tweens it (top
    // may go negative — over-scrolled to centre an edge hunk; later rows skip the blanks).
    spinning := g.spin.active && !g.spin.landed
    top: int
    off: i32
    if spinning {
        disp := git_spin_disp(&g.spin, now)
        top = int(disp)
        if disp < f32(top) { // floor (int() truncates toward zero)
            top -= 1
        }
        off = i32((disp - f32(top)) * f32(row_h))
        g.diff_scroll = top // keep the target near the visible position
    } else {
        top, off = smooth_scroll(&g.diff_scroll_anim, g.diff_scroll, now, row_h)
    }
    g.hunk_cur = git_hunk_at_row(g, g.diff_scroll + offset) // the hunk under the playhead

    // The playhead is a fixed centre reticle and the hunks scroll under it (CS2 case-opening,
    // vertical) — so the per-hunk rail/accent is held back until they land (then it reveals
    // the winner sitting under the reticle).
    for k in 0 ..< max_rows + 2 {
        ri := top + k
        if ri < 0 || ri >= len(rows) {
            continue
        }
        r := rows[ri]
        y := list_top + i32(k) * row_h - off
        marked := !spinning && r.hunk == g.hunk_cur
        if r.hunk >= 0 {
            fill(t, Rect{area.x, y, area.w, row_h}, th.line_highlight) // block background
            if r.selected { // checked for the commit: faint diagonal hatch (visible without the header)
                git_draw_stripes(t, Rect{area.x, y, area.w, row_h}, git_stripe_color(th.line_highlight), a.scale)
            }
            if marked {
                fill(t, Rect{area.x, y, i32(2 * a.scale), row_h}, th.accent) // focus rail
            }
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        tx := x0
        if r.header && r.conflict {
            // The resolution label stands in for the checkbox; green once a side is chosen,
            // urgent while still unresolved.
            text_draw(t, r.label, tx, ty, r.selected ? th.code_return_type : th.urgent)
            tx += cw * f32(len(r.label) + 1)
        } else if r.header && g.diff_stageable {
            text_draw(t, r.selected ? "[x]" : "[ ]", tx, ty, r.selected ? th.code_return_type : th.muted)
            tx += cw * 4 // box + a gap
        }
        text_draw(t, r.text, tx, ty, r.header ? (marked ? th.accent : th.muted) : r.color)
    }
    // The playhead: a horizontal line at the viewport's vertical centre (over the text). Off
    // in normal use (selection works off its row regardless), but always lit during a spin —
    // the fixed reticle the reels stop under.
    if DIFF_SHOW_PLAYHEAD || g.spin.active {
        caret(t, Rect{area.x, list_top + i32(offset) * row_h, area.w, max(i32(1), i32(2 * a.scale))}, th.accent)
    }
    flush_pane(t, content, win_w, win_h)
}

// The grep filter bar (the diff column's second chrome row): a magnifier + the live query
// (or a hint), and right-aligned select-all / unselect-all actions with the checked/visible
// hunk counts. The actions show only for a stageable diff (a working tree, not a browsed
// commit).
@(private = "file")
// The filter bar row, split into two equal halves at the search-bar height, divided by a
// short rule with a small buffer: the GREP field on the left, the select-all / deselect-all
// toggle button on the right. Each half lights when its region is focused.
git_draw_grepbar :: proc(t: ^Text, area: Rect, a: ^App, now: f64) {
    g := &a.git
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    gy := area.y + row_h
    top := f32(gy) + (f32(row_h) - lh) / 2
    focused := a.focus == .Aux && a.aux_mode == .Git
    grep_focused := focused && g.region == .Grep

    mid := area.x + area.w / 2
    buf := i32(cw) // buffer between the divider and each half's content
    // The divider rule between the two halves.
    fill(t, Rect{mid, gy + i32(3 * a.scale), max(i32(1), i32(a.scale)), row_h - i32(6 * a.scale)}, th.border_light)

    // Left half: the grep field (or a hint when empty + unfocused), highlighted when focused.
    left := Rect{area.x, gy, mid - area.x - buf, row_h}
    if grep_focused {
        fill(t, left, th.line_highlight)
    }
    lx := f32(left.x) + cw
    if line_len(&g.grep.lines[0]) == 0 && !grep_focused {
        git_row(t, "filter (/)", lx, gy, row_h, lh, th.muted)
    } else {
        git_draw_field(t, &g.grep, 0, lx, top, a, grep_focused, now)
    }

    // Right half (region .Select): the select-all / deselect-all toggle for a stageable diff,
    // or the merge ABORT button while a merge is being resolved (that slot's only action then).
    if g.diff_stageable || g.op == .Merge {
        sel_focused := focused && g.region == .Select
        right := Rect{mid + buf, gy, area.x + area.w - (mid + buf), row_h}
        if sel_focused {
            fill(t, right, th.line_highlight)
        }
        label := g.op == .Merge ? "abort merge" : (git_any_checked(g) ? "deselect all" : "select all")
        col := g.op == .Merge ? th.urgent : (sel_focused ? th.accent : th.muted)
        text_draw(t, label, f32(right.x) + cw, top, col)
    }
}


// The commit strip (the diff column's bottom chrome): a divider, a "commit" header, then
// the message Doc — msg_rows lines tall (grown from COMMIT_MIN_ROWS as you type), editable
// when the Commit region is focused; a hint while empty and unfocused.
@(private = "file")
git_draw_commit :: proc(t: ^Text, strip: Rect, a: ^App, msg_rows: int, now: f64) {
    g := &a.git
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(strip.x) + cw
    focused := a.focus == .Aux && a.aux_mode == .Git
    commit_focused := focused && g.region == .Commit

    merging := g.op == .Merge
    fill(t, Rect{strip.x, strip.y, strip.w, max(i32(1), i32(a.scale))}, th.border_light)
    git_row(t, merging ? "finish merge" : "commit", x0, strip.y, row_h, lh, commit_focused ? th.accent : th.muted)

    msg_top := strip.y + row_h
    empty := len(g.commit_msg.lines) == 1 && line_len(&g.commit_msg.lines[0]) == 0
    if empty && !commit_focused {
        git_row(t, merging ? "Enter: stage resolved files / complete the merge" : "commit message…", x0 + cw, msg_top, row_h, lh, th.muted)
        return
    }
    // Show a window of msg_rows lines anchored at the tail, scrolled up if the caret sits
    // above it so a message longer than the cap stays navigable. (msg_rows == line count
    // until the message exceeds COMMIT_MAX_ROWS, so the window is usually the whole thing.)
    first := max(0, len(g.commit_msg.lines) - msg_rows)
    if caret_line := g.commit_msg.cursors[g.commit_msg.primary].head.line; caret_line < first {
        first = caret_line
    }
    for li in first ..< min(len(g.commit_msg.lines), first + msg_rows) {
        y := msg_top + i32(li - first) * row_h
        git_draw_field(t, &g.commit_msg, li, x0 + cw, f32(y) + (f32(row_h) - lh) / 2, a, commit_focused, now)
    }
}

// One line of a Doc text field at (x, top): its runes, plus a selection span + caret only
// while `active` (the focused region) so idle fields don't blink. The single-line variant
// of config_draw_edit, shared by the grep bar and the commit box.
@(private = "file")
git_draw_field :: proc(t: ^Text, d: ^Doc, li: int, x, top: f32, a: ^App, active: bool, now: f64) {
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    y := i32(top)
    if active {
        for c in d.cursors {
            lo, hi := cursor_range(c)
            if cursor_has_selection(c) && lo.line == li && hi.line == li {
                fill(t, Rect{i32(x + cw * f32(lo.col)), y, i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
            }
        }
    }
    text_draw_runes(t, d.lines[li].text[:], x, top, th.fg)
    if active && caret_blink_on(a, now) {
        for c in d.cursors {
            if c.head.line == li {
                caret(t, Rect{i32(x + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}, th.fg)
            }
        }
    }
}

// The terminal: the active session's libvterm cell grid. Snap the pane to whole
// cells, resize the session to match (no-op when unchanged), fill the default
// background once, then paint each cell — a per-cell bg fill only when it differs
// from the default (terminals are mostly default-bg, so that stays cheap), the
// glyph on top, and a reverse-video block at the cursor. Colours come from the
// session (theme fg/bg for default cells); reverse attr swaps fg/bg.
draw_terminal :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    term := term_current(a)
    if term == nil { // pane shown before a session exists (shouldn't happen — lazy spawn)
        flush_pane(t, area, win_w, win_h)
        return
    }

    cw := t.font.cell_w
    rh := max(i32(1), i32(t.font.line_height))
    cols := max(1, int(f32(area.w) / cw))
    rows := max(1, int(area.h / rh))
    terminal_resize(term, rows, cols)
    terminal_set_default_colors(term, th.fg, th.bg) // follow theme/font changes

    fill(t, area, th.bg) // default background for the whole grid in one quad
    cur_row, cur_col := terminal_cursor(term)

    // Scroll-aware view: each on-screen row maps to an absolute line (top + row),
    // pulling from the live grid or scrollback. While selecting, the block cursor is
    // suppressed and the selected line range tints with th.selection.
    top := terminal_view_top(term)
    sel_lo, sel_hi := terminal_sel_range(term)
    selecting := term.sel_active && sel_lo != sel_hi

    glyph: [1]rune
    for row in 0 ..< rows {
        n := top + row
        row_sel := selecting && n >= sel_lo && n <= sel_hi
        cy := area.y + i32(row) * rh
        for col in 0 ..< cols {
            cell := terminal_view_cell(term, n, col) or_continue

            fg, fdef := terminal_color(term, cell.fg)
            if fdef {
                fg = th.fg
            }
            bg, bdef := terminal_color(term, cell.bg)
            if bdef {
                bg = th.bg
            }
            // The block cursor is reverse video (live grid only, not while scrolling);
            // XOR with the cell's own reverse attr.
            is_cursor := !term.sel_active && n == term.sb_total + cur_row && col == cur_col
            if cell.attrs.reverse != is_cursor {
                fg, bg = bg, fg
            }
            if row_sel { // selected lines tint uniformly; the glyph stays on top
                bg = th.selection
            }

            // Tile cell x-edges off the same fractional grid as the glyphs so the bg
            // fills meet exactly (no seams, no overlap).
            x0 := i32(f32(area.x) + cw * f32(col))
            x1 := i32(f32(area.x) + cw * f32(col + 1))
            if bg != th.bg {
                fill(t, Rect{x0, cy, x1 - x0, rh}, bg)
            }
            if r := rune(cell.chars[0]); r >= 0x20 {
                glyph[0] = r
                text_draw_runes(t, glyph[:], f32(x0), f32(cy), fg)
            }
        }
    }

    // The copy cursor: a thin line drawn at the top edge of its line (sitting between
    // it and the line above), marking where a copy reads from. Hidden at the bottom
    // input line (sel_active off).
    if term.sel_active {
        if sr := term.sel_head - top; sr >= 0 && sr < rows {
            caret(t, Rect{area.x, area.y + i32(sr) * rh, area.w, max(1, i32(2 * a.scale))}, th.accent)
        }
    }
    flush_pane(t, area, win_w, win_h)
}

// The terminal switcher: a slim i3-style numbered column shown while Alt is held.
// It is inset within the pane's focus outline (so it sits seamlessly inside the
// highlight rather than covering it), two digits wide, and scrolls to keep the
// active session visible. Drawn as its own flush, on top of the aux content.
draw_term_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale)) // sit inside the focus outline
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    colw := min(i32(cw * 2) + i32(12 * a.scale), area.w) // two digits + padding
    row_h := i32(lh) + i32(6 * a.scale)

    // Fade in from the pane background (opaque lerp, so no alpha needed): every colour
    // tweens out of th.bg as the switcher appears while Alt is held.
    f := clamp(anim_value(&a.switcher_anim, now), 0, 1)
    col_bg := lerp3(th.bg, th.border_dark, f)
    col_active := lerp3(th.bg, th.accent, f)
    col_fg := lerp3(th.bg, th.fg, f)
    col_lock := lerp3(th.bg, th.muted, f) // a locked session's number is greyed (Alt+L)

    // Scroll so the active session stays centered, clamped at the list ends.
    n := term_count(a)
    max_rows := max(1, int(area.h / row_h))
    first := clamp(a.term_active - max_rows / 2, 0, max(0, n - max_rows))
    visible := min(n - first, max_rows)

    fill(t, Rect{area.x, area.y, colw, i32(visible) * row_h}, col_bg)

    for k in 0 ..< visible {
        i := first + k
        y := area.y + i32(k) * row_h
        if i == a.term_active {
            fill(t, Rect{area.x, y, colw, row_h}, col_active)
        }
        buf: [8]u8
        s := strconv.write_int(buf[:], i64(i + 1), 10)
        tx := f32(area.x) + (f32(colw) - cw * f32(len(s))) / 2 // centered
        ty := f32(y) + (f32(row_h) - lh) / 2
        text_draw(t, s, tx, ty, a.terminals[i].locked ? col_lock : col_fg)
    }

    flush_pane(t, area, win_w, win_h)
}
