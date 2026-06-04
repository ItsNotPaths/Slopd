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
        draw_git(t, lay.aux, win_w, win_h, a)
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
    if f32(b.scroll) != b.scroll_anim.to {
        anim_start(&b.scroll_anim, now, anim_value(&b.scroll_anim, now), f32(b.scroll), SCROLL_DUR)
    }
    disp := anim_value(&b.scroll_anim, now)
    top := int(disp) // disp >= 0, so this floors to the first (partial) row
    off := i32((disp - f32(top)) * f32(row_h)) // pixels of `top` scrolled above the fold

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

// The git aux mode (Sublime-Merge-lite, KB-only). The aux pane carries two sub-columns
// parted by a hairline: a SIDEBAR (branch strip + Status + Log, ported from Prawk) on
// the left and a DIFF VIEWER / COMMIT EDITOR on the right. Each column composites under
// its own scissor so text can't bleed across the rule. SCAFFOLD: the two-column layout,
// the divider, and the per-region focus tint are in; the git data, the diff, and
// staging are Phase 1 (see the "Git (aux mode)" section of plan.txt).
draw_git :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }

    // Split into the sidebar (left) and the diff / commit column (right), parted by a
    // one-pixel rule. `right` spans the rule + the diff so they composite under one
    // scissor; the diff content insets past the rule.
    div_w := max(i32(1), i32(a.scale))
    side_w := clamp(i32(f32(area.w) * GIT_SIDEBAR_FRAC), 0, area.w)
    sidebar := Rect{area.x, area.y, side_w, area.h}
    right := Rect{area.x + side_w, area.y, area.w - side_w, area.h}
    diff := Rect{right.x + div_w, area.y, max(0, right.w - div_w), area.h}

    git_draw_sidebar(t, sidebar, a)
    flush_pane(t, sidebar, win_w, win_h)

    fill(t, Rect{right.x, area.y, div_w, area.h}, th.border_light) // the column rule
    git_draw_diff(t, diff, a)
    flush_pane(t, right, win_w, win_h)
}

// One left-aligned text row, vertically centred in a row_h band whose top is at y.
@(private = "file")
git_row :: proc(t: ^Text, s: string, x: f32, y, row_h: i32, lh: f32, color: [3]f32) {
    text_draw(t, s, x, f32(y) + (f32(row_h) - lh) / 2, color)
}

// The sidebar: Prawk's three stacked zones — a branch strip, the working-tree Status,
// and the Log. SCAFFOLD: zone headers + placeholders; the headers light (accent) when
// the sidebar holds the git pane's region focus.
@(private = "file")
git_draw_sidebar :: proc(t: ^Text, area: Rect, a: ^App) {
    g := &a.git
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin
    head := a.focus == .Aux && a.aux_mode == .Git && g.region == .Sidebar ? th.accent : th.muted

    y := area.y
    git_row(t, "⎇ branch", x0, y, row_h, lh, head) // branch strip
    y += row_h + row_h / 2

    git_row(t, "status", x0, y, row_h, lh, head) // working tree
    y += row_h
    git_row(t, "working tree", x0 + cw, y, row_h, lh, th.muted)
    y += row_h + row_h / 2

    git_row(t, "log", x0, y, row_h, lh, head) // commits on the selected branch
    y += row_h
    git_row(t, "commits", x0 + cw, y, row_h, lh, th.muted)
}

// The diff viewer / commit editor: the working diff up top, the commit message in a
// bottom strip. SCAFFOLD: headers + placeholders; the diff header lights when region
// is Diff, the commit strip when region is Commit.
@(private = "file")
git_draw_diff :: proc(t: ^Text, area: Rect, a: ^App) {
    g := &a.git
    th := &a.theme
    lh := t.font.line_height
    cw := t.font.cell_w
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw
    focused := a.focus == .Aux && a.aux_mode == .Git

    // Diff viewer — the live working tree by default, or the sidebar's selection.
    diff_head := focused && g.region == .Diff ? th.accent : th.muted
    git_row(t, "diff", x0, area.y, row_h, lh, diff_head)
    git_row(t, "live working tree", x0 + cw, area.y + row_h, row_h, lh, th.muted)

    // Commit editor — a bottom strip (rule + header + the message line). The message
    // becomes a live Doc in Phase 2; the placeholder marks where it sits.
    strip_h := row_h * 3
    sy := area.y + area.h - strip_h
    if sy <= area.y + row_h * 2 {
        return // pane too short for the commit strip
    }
    fill(t, Rect{area.x, sy, area.w, max(i32(1), i32(a.scale))}, th.border_light)
    commit_head := focused && g.region == .Commit ? th.accent : th.muted
    git_row(t, "commit", x0, sy + row_h / 2, row_h, lh, commit_head)
    git_row(t, "commit message…", x0 + cw, sy + row_h / 2 + row_h, row_h, lh, th.muted)
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
