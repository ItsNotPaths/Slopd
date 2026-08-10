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

// A hollow rectangle: four edge bars of `w` thickness inset just inside `r`, leaving
// whatever is already drawn there untouched (used for the command-line injection alert).
outline :: proc(t: ^Text, r: Rect, color: [3]f32, w: i32) {
    fill(t, Rect{r.x, r.y, r.w, w}, color)                 // top
    fill(t, Rect{r.x, r.y + r.h - w, r.w, w}, color)       // bottom
    fill(t, Rect{r.x, r.y, w, r.h}, color)                 // left
    fill(t, Rect{r.x + r.w - w, r.y, w, r.h}, color)       // right
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
    a.lay = lay // pointer events arriving before the next frame route against these rects

    // Clay tracks the framebuffer the same way the GL viewport above does, and is handed
    // this frame's pointer before anything is declared — SetPointerState resolves against
    // the tree Clay already holds, so feeding it after the declarations would hit-test one
    // frame late (see docs/clay-refactor.md, C1).
    clay_resize(win_w, win_h)
    mouse_feed_clay(a)

    pad := i32(8 * a.scale)

    // The focus ring only disambiguates which of two panes is active; with a single
    // pane on screen (Zen-editor / Full) it is just a full-window border, so drop
    // it. Hidden panes carry a zero rect and the draw guards skip them.
    show_ring := lay.vis.editor && lay.vis.aux

    // Chrome: both pane backgrounds/rings + the status strip, composited in one flush.
    panel(t, lay.editor, th.bg, th.accent, show_ring && a.focus == .Editor, a.scale)
    panel(t, lay.aux, th.bg, th.accent, show_ring && a.focus == .Aux, a.scale)
    fill(t, lay.strip, th.border_light)
    flush_pane(t, Rect{0, 0, win_w, win_h}, win_w, win_h)

    // The main pane is the document: a text editor or, for an image, the media viewer.
    // Both guard on a zero rect internally (hidden under Full on the aux surface).
    if a.main == .Image {
        draw_media(t, lay.editor, win_w, win_h, a)
    } else {
        draw_editor(t, lay.editor, win_w, win_h, a, now)
    }

    if a.aux_mode == .FileTree {
        draw_filetree(t, lay.aux, win_w, win_h, a) // Clay-declared (C3), see filetree_ui.odin
    } else if a.aux_mode == .Config {
        draw_config(t, lay.aux, win_w, win_h, a, now)
    } else if a.aux_mode == .Terminal {
        draw_terminal(t, lay.aux, win_w, win_h, a)
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

    // Filetree bottom overlay: the Ctrl-held chord cheat-sheet, inside the filetree pane
    // so the command-line strip is never co-opted.
    if a.aux_mode == .FileTree && a.ctrl_held && a.focus == .Aux {
        draw_filetree_overlay(t, lay.aux, win_w, win_h, a, now)
    }

    // Bottom status / command strip: the command line while active, else an
    // emacs-style modeline for the editor buffer. (The filetree chord bar is NOT
    // here — it overlays the filetree pane itself, see above.)
    if a.cl_active {
        draw_command_line(t, lay.strip, a, now)
    } else if a.focus == .Editor && a.main == .Text && editor_current(&a.editor).conflict {
        draw_conflict_prompt(t, lay.strip, a) // disk changed under unsaved edits: reload-vs-keep
    } else {
        draw_status(t, lay.strip, a)
    }
    flush_pane(t, lay.strip, win_w, win_h)

    // A press nobody claimed dies here. Clicks are offered to the panes as they draw
    // (mouse_take_click), and one that hit nothing must not survive into the next frame,
    // where the pointer may be over something else entirely — a click is an event at a
    // place, not a mode.
    a.mouse.click = false
}

// Package-level, not file-private: the *_ui.odin panes declare their own chrome and need
// the same focused/unfocused text rule the hand-drawn panes use (see the tests invariant in
// docs/clay-refactor.md — anything a layout proc touches has to be reachable from tests).
focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// How far the hover tint travels from the pane background toward the selection bar. Well
// short of it on purpose: the pointer resting somewhere is not a selection, and a list with
// two equally loud bars in it is a list you have to read twice to find your place in.
HOVER_MIX :: 0.35

// The backdrop of the row under the pointer (open decision 5, settled in C5b: wanted, but
// subtle and toggleable — `hover: on|off`, App.hover_on). Every list pane reads this one
// proc, so the whole chrome agrees on what "the pointer is here" looks like.
//
// It MIXES rather than blending because the quad shader writes opaque: alpha is a
// visibility bit, not a blend factor (clay_render.odin), so a translucent wash has to be
// baked into the colour here or it does not exist at all.
hover_bg :: proc(th: ^Theme) -> [3]f32 {
    return th.bg + (th.separator - th.bg) * HOVER_MIX
}

// smooth_scroll lives in scroll.odin, beside the list viewport policy it animates: C5c's
// procmon pane needs it from procmon_ui.odin, and a layout proc cannot call something
// file-private to render.odin.

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

    // The scroll policy — follow the caret at the edges, or keep the topmost cursor on the
    // middle row (config `scroll_mode`) — unless the wheel has detached the view, in which
    // case it stays where the wheel left it until the next keystroke. Lives in buffer.odin,
    // GL-free and tested.
    buffer_scroll_apply(b, rows, a.scroll_mode == .Middle, a.last_input_at)

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

    // A pristine injected (staged, not user-typed) line rings the strip in the alert
    // colour — "review this before Enter". Any edit bumps doc.version past the mark and
    // the ring clears itself, so no per-edit hook is needed.
    if a.cl.injected && a.cl.doc.version == a.cl.inject_ver {
        outline(t, strip, th.cl_inject, i32(2 * a.scale))
    }

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

    // Ghosted per-command argument hint (e.g. `reload` -> "(y/n)"), one cell past the typed
    // text, until an argument is entered. cl_ghost_hint is the extensible registry.
    if hint := cl_ghost_hint(line_string(l, context.temp_allocator)); hint != "" {
        text_draw(t, hint, ox + cw * f32(len(l.text) + 1), y, th.muted)
    }

    if caret_blink_on(a, now) {
        for c in a.cl.cursors {
            caret(t, Rect{i32(ox + cw * f32(c.head.col)), i32(y), i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
}

// The media viewer: the decoded image fit into the pane (contain letterbox), zoomable
// and pannable. The pane bg + focus ring are already laid down by render's chrome pass,
// so this just blits the texture over it, clipped to the inset content area so a zoomed
// image never paints over the focus ring. The filename/dims/zoom show in the modeline.
@(private = "file")
draw_media :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    m := &a.media
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    if m.tex != 0 {
        image_push(t, m.tex, media_fit_rect(area, m.w, m.h, m.zoom, m.pan))
    } else {
        pad := i32(8 * a.scale)
        y := f32(area.y) + (f32(area.h) - t.font.line_height) / 2
        text_draw(t, "(no image)", f32(area.x + pad), y, th.muted)
    }
    flush_pane(t, area, win_w, win_h)
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

    // No editor on screen (Full on the aux surface); just name the aux pane there.
    if !panes_visible(a).editor {
        text_draw(t, aux_mode_name(a.aux_mode), f32(strip.x + pad), y, th.muted)
        return
    }

    // Image surface: the main pane shows media, not a buffer — so the modeline reports
    // the image (name, pixel dimensions, zoom%) instead of line:col / language.
    if a.main == .Image {
        m := &a.media
        name := m.path == "" ? "(no image)" : filepath.base(m.path)
        text_draw(t, fmt.tprintf("  %s", name), f32(strip.x + pad), y, th.muted)
        right := fmt.tprintf("image   %dx%d   %d%%", m.w, m.h, int(m.zoom * 100 + 0.5))
        rx := f32(strip.x + strip.w - pad) - cw * f32(len(right))
        text_draw(t, right, rx, y, th.muted)
        root := home_abbrev(a.project_root, context.temp_allocator)
        if root != "" {
            rootx := f32(strip.x) + (f32(strip.w) - cw * f32(len(root))) / 2
            text_draw(t, root, rootx, y, th.muted)
        }
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

    // Center: the project root (~-abbreviated), so the `cd`-captured root the tools
    // and `tu` use is always visible while the command line is idle.
    root := home_abbrev(a.project_root, context.temp_allocator)
    if root != "" {
        rootx := f32(strip.x) + (f32(strip.w) - cw * f32(len(root))) / 2
        text_draw(t, root, rootx, y, th.muted)
    }
}

// The filetree's bottom overlay, sitting INSIDE the filetree pane (never the command
// strip): the Ctrl-held chord cheat-sheet. A filled bar anchored to the pane bottom; the
// chord list left-flows and wraps to as many rows as the (possibly narrow) pane needs.
// Colours fade up from the pane bg via chord_anim, the Ctrl-hold analogue of the terminal
// switcher fade.
@(private = "file")
draw_filetree_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale)) // sit inside the focus outline
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(6 * a.scale)
    pad := i32(8 * a.scale)

    // Opaque lerp out of the pane bg (so no alpha is needed) as Ctrl is held.
    f := clamp(anim_value(&a.chord_anim, now), 0, 1)
    bar_bg := lerp3(th.bg, th.border_dark, f)
    key_col := lerp3(th.bg, th.accent, f)
    lbl_col := lerp3(th.bg, th.muted, f)

    // Keys carry a "^" so the bar reads as the Ctrl menu; the state readout (paste mode +
    // marked count) is the final flow item, so it wraps with everything else.
    hints := [?][2]string {
        {"^y", "yank"},
        {"^u", "reset"},
        {"^c", "copy"},
        {"^x", "cut"},
        {"^p", "paste"},
        {"^d", "del"},
        {"^D", "del-set"},
        {"^w", "path"},
        {"^W", "dir"},
    }
    mode := a.tree.yank_mode == .Cut ? "cut" : "copy"
    state := fmt.tprintf("[%s · %d marked]", mode, len(a.tree.yanked))

    // Pack items (each "key label", plus the state) into rows of the available width,
    // recording each item's row + start column. cur_x in cells; GAP cells between items.
    GAP :: 2
    maxw := max(1, int(f32(area.w - 2 * pad) / cw))
    item_w: [len(hints) + 1]int
    for h, i in hints {
        item_w[i] = len(h[0]) + 1 + len(h[1]) // key + space + label (ASCII: bytes == cells)
    }
    item_w[len(hints)] = len(state) // "·" is multi-byte but renders one cell — close enough for layout
    row_of: [len(hints) + 1]int
    x_of: [len(hints) + 1]int
    cur_row, cur_x := 0, 0
    for w, i in item_w {
        if cur_x > 0 && cur_x + w > maxw {
            cur_row += 1
            cur_x = 0
        }
        row_of[i] = cur_row
        x_of[i] = cur_x
        cur_x += w + GAP
    }
    nrows := cur_row + 1

    bar_h := i32(nrows) * row_h
    by := area.y + area.h - bar_h
    fill(t, Rect{area.x, by, area.w, bar_h}, bar_bg)

    item_xy :: proc(area: Rect, by, row_h, pad: i32, cw, lh: f32, col, row: int) -> (x, y: f32) {
        return f32(area.x + pad) + cw * f32(col), f32(by + i32(row) * row_h) + (f32(row_h) - lh) / 2
    }
    for h, i in hints {
        x, y := item_xy(area, by, row_h, pad, cw, lh, x_of[i], row_of[i])
        text_draw(t, h[0], x, y, key_col)
        text_draw(t, h[1], x + cw * f32(len(h[0]) + 1), y, lbl_col)
    }
    sx, sy := item_xy(area, by, row_h, pad, cw, lh, x_of[len(hints)], row_of[len(hints)])
    text_draw(t, state, sx, sy, lbl_col)

    flush_pane(t, area, win_w, win_h)
}

// The unsaved-edits-vs-disk-change hint, shown IN the command strip (taking the place of
// the idle modeline) when the conflict is pending but the CL is closed — e.g. you cancelled
// the auto-staged `reload ` line. Rung in the alert colour, it reminds you the answer is a
// command: run `reload y` (re-read, losing edits) or `reload n` (keep + cache, stops asking
// until the file changes again). It stays up until answered or the file is saved. The caller
// flushes the strip region.
@(private = "file")
draw_conflict_prompt :: proc(t: ^Text, strip: Rect, a: ^App) {
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    outline(t, strip, th.cl_inject, i32(2 * a.scale)) // ring it like a staged line — needs a decision

    name := filepath.base(editor_current(&a.editor).path)
    msg := fmt.tprintf("%s changed on disk - ", name) // ASCII only: byte length == cell count for placement
    keys := "run: reload y (lose edits) / reload n (keep mine)"
    text_draw(t, msg, f32(strip.x + pad), y, th.urgent)
    text_draw(t, keys, f32(strip.x + pad) + cw * f32(len(msg)), y, th.muted)
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

// draw_filetree lives in filetree_ui.odin: the filetree is declared in Clay (C3), so its
// geometry, its hit-testing and its paint are one tree rather than three copies of the
// same arithmetic. Its Ctrl-chord overlay is still hand-drawn and stays here until C8.

// draw_grep lives in grep_ui.odin: the results pane is declared in Clay (C5a), and its
// display-row flattening moved to grep.odin, where the model it flattens already lives.

// draw_procmon lives in procmon_ui.odin: the process monitor is declared in Clay (C5c),
// with its graph band and its live filter bar as the first Custom surfaces outside the
// editor and the terminal.

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
