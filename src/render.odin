package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import gl "vendor:OpenGL"

// Rendering: solid-colour fills (scissor+clear) plus glyph text. Every colour
// comes from the active Theme (a.theme); this file maps palette slots to UI usage:
//   border_dark -> window gutter / overlay bg   bg -> pane background
//   accent      -> focus outline / active item  border_light -> status strip
//   fg / muted  -> text (active / dim)           selection -> selected text
//   line_highlight -> current-line bar           separator -> filetree selection
//   code_return_type -> filetree directory rows  urgent -> ringed-file marker

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

// scissor uses a bottom-left origin; our rects are top-left, so flip y.
//
// One glClear per rect. Cheap here because redraw is event-driven (WaitEvents),
// not per-frame. When syntax highlighting lands it will batch glyphs by colour in
// a renderer pass; fold these fills into that pass then (layered: bg fills -> text
// -> carets/overlays, preserving the current draw order), not before.
fill :: proc(r: Rect, win_h: i32, c: [3]f32) {
    if r.w <= 0 || r.h <= 0 {
        return
    }
    gl.Scissor(r.x, win_h - (r.y + r.h), r.w, r.h)
    gl.ClearColor(c.r, c.g, c.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

inset :: proc(r: Rect, by: i32) -> Rect {
    return Rect{r.x + by, r.y + by, r.w - 2 * by, r.h - 2 * by}
}

// A pane: filled with bg, ringed with the focus colour when focused.
panel :: proc(r: Rect, win_h: i32, bg, focus: [3]f32, focused: bool, scale: f32) {
    if focused {
        fill(r, win_h, focus)
        fill(inset(r, i32(2 * scale)), win_h, bg)
    } else {
        fill(r, win_h, bg)
    }
}

render :: proc(a: ^App, t: ^Text, win_w, win_h: i32) {
    th := &a.theme
    // Viewport must track the framebuffer or the text shader (NDC -> viewport)
    // distorts on resize. Scissor fills use framebuffer coords and don't care.
    gl.Viewport(0, 0, win_w, win_h)
    gl.Enable(gl.SCISSOR_TEST)
    fill(Rect{0, 0, win_w, win_h}, win_h, th.border_dark) // gutter / background

    lay := compute_layout(win_w, win_h, a)
    pad := i32(8 * a.scale)

    // The focus ring only disambiguates which of two panes is active; with a single
    // pane on screen (Zen-editor / Util) it is just a full-window border, so drop
    // it. Hidden panes carry a zero rect and the draw guards skip them.
    show_ring := lay.vis.editor && lay.vis.aux

    panel(lay.editor, win_h, th.bg, th.accent, show_ring && a.focus == .Editor, a.scale)
    draw_editor(t, lay.editor, win_w, win_h, a)

    panel(lay.aux, win_h, th.bg, th.accent, show_ring && a.focus == .Aux, a.scale)
    if a.aux_mode == .FileTree {
        draw_filetree(t, lay.aux, win_w, win_h, a)
    } else if a.aux_mode == .Config {
        draw_config(t, lay.aux, win_w, win_h, a)
    } else {
        label(t, aux_mode_name(a.aux_mode), lay.aux, pad, win_w, win_h, focus_fg(a, .Aux))
    }

    if a.alt_held && a.aux_mode == .Terminal {
        draw_term_overlay(t, lay.aux, win_w, win_h, a)
    }

    // Bottom status / command strip.
    fill(lay.strip, win_h, th.border_light)
    if a.cl_active {
        draw_command_line(t, lay.strip, a, win_w, win_h)
    } else {
        sx := f32(lay.strip.x + pad)
        sy := f32(lay.strip.y) + (f32(lay.strip.h) - t.font.line_height) / 2
        text_draw(t, "Slopd", sx, sy, lay.strip, win_w, win_h, th.fg)
        text_draw(t, aux_mode_name(a.aux_mode), sx + t.font.cell_w * 8, sy, lay.strip, win_w, win_h, th.muted)
    }
}

@(private = "file")
focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// The editor: a line-number gutter, the active buffer's lines, the current-line
// bar, and a caret. Scrolls to keep the cursor visible. (Tabs currently advance
// one cell — fine for the space-indent default; proper tab width is a TODO.)
draw_editor :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    b := editor_current(&a.editor)
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)

    cur_line := b.cursors[b.primary].head.line // primary cursor drives scroll + the gutter
    rows := max(1, int(area.h / row_h))
    if cur_line < b.scroll { // keep the cursor on screen
        b.scroll = cur_line
    } else if cur_line >= b.scroll + rows {
        b.scroll = cur_line - rows + 1
    }

    gutter := i32(max(2, num_digits(len(b.lines)))) // digits wide
    text_x := f32(area.x) + f32(gutter + 2) * cw // margin + gutter + gap

    visible := min(rows, len(b.lines) - b.scroll)
    for k in 0 ..< visible {
        i := b.scroll + k
        l := &b.lines[i]
        y := area.y + i32(k) * row_h
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := i == cur_line

        if on_cur_line {
            fill(Rect{area.x, y, area.w, row_h}, win_h, th.line_highlight) // current-line bar
        }

        // Selection spans: highlight each cursor's selection that covers this line
        // (first/last line clip to the cursor's columns, interior lines fill out).
        for c in b.cursors {
            if !cursor_has_selection(c) {
                continue
            }
            lo, hi := cursor_range(c)
            if i < lo.line || i > hi.line {
                continue
            }
            start := i == lo.line ? lo.col : 0
            end := i == hi.line ? hi.col : len(l.text)
            if end > start {
                sx := i32(text_x + cw * f32(start))
                fill(Rect{sx, y, i32(cw * f32(end - start)), row_h}, win_h, th.selection)
            }
        }

        buf: [12]u8
        s := strconv.write_int(buf[:], i64(line_number(a.line_numbers, i, cur_line)), 10)
        nx := f32(area.x) + cw + f32(gutter - i32(len(s))) * cw // right-align in gutter
        text_draw(t, s, nx, ty, area, win_w, win_h, on_cur_line ? th.fg : th.muted)

        text_draw_runes(t, l.text[:], text_x, ty, area, win_w, win_h, th.fg)

        // A caret for every cursor sitting on this line (single-cursor = one).
        for c in b.cursors {
            if c.head.line == i {
                caret := Rect{i32(text_x + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}
                fill(caret, win_h, th.fg)
            }
        }
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

// Draws a label inside a pane at the top-left.
label :: proc(t: ^Text, s: string, r: Rect, pad: i32, win_w, win_h: i32, color: [3]f32) {
    text_draw(t, s, f32(r.x + pad), f32(r.y + pad), r, win_w, win_h, color)
}

// The command line as it lives in the status strip: prompt, the editable runes,
// a selection highlight, and a caret. Monospace makes every x pure arithmetic.
draw_command_line :: proc(t: ^Text, strip: Rect, a: ^App, win_w, win_h: i32) {
    PROMPT :: "> "
    th := &a.theme
    l := &a.cl.lines[0] // the command line is one line
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    text_draw(t, PROMPT, f32(strip.x + pad), y, strip, win_w, win_h, th.muted)
    ox := f32(strip.x + pad) + cw * f32(len(PROMPT)) // text origin, after the prompt

    // Selection spans, then text, then a caret per cursor (single-cursor = one).
    for c in a.cl.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            sel := Rect{i32(ox + cw * f32(lo.col)), i32(y), i32(cw * f32(hi.col - lo.col)), i32(lh)}
            fill(sel, win_h, th.selection)
        }
    }

    text_draw_runes(t, l.text[:], ox, y, strip, win_w, win_h, th.fg)

    for c in a.cl.cursors {
        caret := Rect{i32(ox + cw * f32(c.head.col)), i32(y), i32(2 * a.scale), i32(lh)}
        fill(caret, win_h, th.fg)
    }
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

    text_draw(t, ft.dir, x0, f32(area.y) + (f32(row_h) - lh) / 2, area, win_w, win_h, th.muted)

    list_top := area.y + row_h
    max_rows := max(1, int((area.y + area.h - list_top) / row_h))
    first := clamp(ft.selected - max_rows / 2, 0, max(0, len(ft.entries) - max_rows))
    visible := min(len(ft.entries) - first, max_rows)

    for k in 0 ..< visible {
        i := first + k
        e := &ft.entries[i]
        y := list_top + i32(k) * row_h
        if i == ft.selected {
            fill(Rect{area.x, y, area.w, row_h}, win_h, th.separator)
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        ringed := ring_contains(a, e.path)
        prefix := ringed ? "*" : "-"
        text_draw(t, prefix, x0, ty, area, win_w, win_h, ringed ? th.urgent : th.muted)
        text_draw(t, e.display, x0 + cw * 2, ty, area, win_w, win_h, e.is_dir ? th.code_return_type : th.fg)
    }
}

// The config / syntax pane: a "settings" block (editable key: value rows) then a
// "syntax" block listing each known language with its grammar status (✓/✗) and, when
// a row is opened, its install-options dropdown (nested under the language). Section
// headers are flanked by rules; setting values share one column. One selection
// highlight (separator), centre-scrolled like the filetree.
draw_config :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
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
        edit:   bool, // the open settings editor (draw `cp.edit` at the value column)
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
        selected := cp.sel == si
        if selected {
            cursor_row = len(rows)
        }
        val := setting_value(a, s)
        append(
            &rows,
            Row {
                text = fmt.tprintf("%s:", setting_key(s)),
                value = val == "" ? "(default)" : val,
                color = selected ? th.fg : th.muted,
                sel = selected,
                edit = selected && cp.editing,
                indent = 1,
            },
        )
    }

    append(&rows, rule_row)
    append(&rows, Row{text = "syntax", color = th.accent, flush = true})
    append(&rows, rule_row)
    for &l, i in cp.langs {
        row := SETTING_COUNT + i
        open := cp.expanded == row
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
            fill(Rect{area.x, y, area.w, row_h}, win_h, th.separator)
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        rx := x0 + cw * f32(r.indent)
        if r.flush {
            text_draw(t, r.text, x0, ty, area, win_w, win_h, r.color)
            continue
        }
        text_draw(t, r.text, rx, ty, area, win_w, win_h, r.color)
        valx := x0 + cw * (f32(r.indent) + val_off)
        if r.edit {
            config_draw_edit(t, &cp.edit, valx, y, ty, area, win_w, win_h, a)
        } else if r.value != "" {
            text_draw(t, r.value, valx, ty, area, win_w, win_h, th.fg)
        }
    }
}

// The inline settings editor: the edit buffer's runes at `ex` (the value column),
// with per-cursor selection spans and carets — the command-line treatment, reused.
@(private = "file")
config_draw_edit :: proc(t: ^Text, edit: ^Doc, ex: f32, y: i32, ty: f32, area: Rect, win_w, win_h: i32, a: ^App) {
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    line := &edit.lines[0]
    for c in edit.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(Rect{i32(ex + cw * f32(lo.col)), y, i32(cw * f32(hi.col - lo.col)), i32(lh)}, win_h, th.selection)
        }
    }
    text_draw_runes(t, line.text[:], ex, ty, area, win_w, win_h, th.fg)
    for c in edit.cursors {
        fill(Rect{i32(ex + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}, win_h, th.fg)
    }
}

// The terminal switcher: a slim i3-style numbered column shown while Alt is held.
// It is inset within the pane's focus outline (so it sits seamlessly inside the
// highlight rather than covering it), two digits wide, and scrolls to keep the
// active session visible.
draw_term_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale)) // sit inside the focus outline
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    colw := min(i32(cw * 2) + i32(12 * a.scale), area.w) // two digits + padding
    row_h := i32(lh) + i32(6 * a.scale)

    // Scroll so the active session stays centered, clamped at the list ends.
    max_rows := max(1, int(area.h / row_h))
    first := clamp(a.term_active - max_rows / 2, 0, max(0, a.term_count - max_rows))
    visible := min(a.term_count - first, max_rows)

    fill(Rect{area.x, area.y, colw, i32(visible) * row_h}, win_h, th.border_dark)

    for k in 0 ..< visible {
        i := first + k
        y := area.y + i32(k) * row_h
        if i == a.term_active {
            fill(Rect{area.x, y, colw, row_h}, win_h, th.accent)
        }
        buf: [8]u8
        label := strconv.write_int(buf[:], i64(i + 1), 10)
        tx := f32(area.x) + (f32(colw) - cw * f32(len(label))) / 2 // centered
        ty := f32(y) + (f32(row_h) - lh) / 2
        text_draw(t, label, tx, ty, Rect{area.x, y, colw, row_h}, win_w, win_h, th.fg)
    }
}
