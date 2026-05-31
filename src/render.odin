package main

import "core:strconv"
import gl "vendor:OpenGL"

// Rendering for this milestone is solid-color fills via scissor + clear — no
// shaders, no glyphs yet. Each mode is a distinct color so the layout, focus,
// split, and the Alt terminal overlay can all be felt before text rendering
// exists. Labels are stubbed as colored slots.

BG      :: [3]f32{0.06, 0.06, 0.07} // window background / gutter
EDITOR  :: [3]f32{0.12, 0.14, 0.18} // left pane
FOCUS   :: [3]f32{0.30, 0.55, 0.90} // focused-pane border
OVERLAY :: [3]f32{0.02, 0.02, 0.03} // terminal-session strip
SLOT    :: [3]f32{0.18, 0.18, 0.22} // a terminal session
SEL     :: [3]f32{0.30, 0.55, 0.90} // selected terminal session
STRIP   :: [3]f32{0.14, 0.14, 0.17} // bottom status / command strip
TEXT    :: [3]f32{0.85, 0.86, 0.90} // foreground text (focused)
TEXT_DIM :: [3]f32{0.45, 0.47, 0.52} // foreground text (unfocused)
SEL_BG  :: [3]f32{0.20, 0.30, 0.45} // text selection background

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
    }
    return ""
}

aux_mode_colors := [AuxMode][3]f32 {
    .FileTree = {0.09, 0.10, 0.12}, // neutral dark — it holds a real listing
    .Terminal = {0.05, 0.05, 0.06},
    .Procmon  = {0.18, 0.13, 0.20},
    .Git      = {0.22, 0.15, 0.10},
}

FT_DIR :: [3]f32{0.45, 0.70, 0.95} // directory rows in the filetree

// scissor uses a bottom-left origin; our rects are top-left, so flip y.
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

// A pane: filled with its color, ringed with the focus color when focused.
panel :: proc(r: Rect, win_h: i32, c: [3]f32, focused: bool, scale: f32) {
    if focused {
        fill(r, win_h, FOCUS)
        fill(inset(r, i32(2 * scale)), win_h, c)
    } else {
        fill(r, win_h, c)
    }
}

render :: proc(a: ^App, t: ^Text, win_w, win_h: i32) {
    // Viewport must track the framebuffer or the text shader (NDC -> viewport)
    // distorts on resize. Scissor fills use framebuffer coords and don't care.
    gl.Viewport(0, 0, win_w, win_h)
    gl.Enable(gl.SCISSOR_TEST)
    fill(Rect{0, 0, win_w, win_h}, win_h, BG)

    lay := compute_layout(win_w, win_h, a)
    pad := i32(8 * a.scale)

    panel(lay.editor, win_h, EDITOR, a.focus == .Editor, a.scale)
    label(t, "editor", lay.editor, pad, win_w, win_h, a.focus == .Editor)

    panel(lay.aux, win_h, aux_mode_colors[a.aux_mode], a.focus == .Aux, a.scale)
    if a.aux_mode == .FileTree {
        draw_filetree(t, lay.aux, win_w, win_h, a)
    } else {
        label(t, aux_mode_name(a.aux_mode), lay.aux, pad, win_w, win_h, a.focus == .Aux)
    }

    if a.alt_held && a.aux_mode == .Terminal {
        draw_term_overlay(t, lay.aux, win_w, win_h, a)
    }

    // Bottom status / command strip.
    fill(lay.strip, win_h, STRIP)
    if a.cl_active {
        draw_command_line(t, lay.strip, a, win_w, win_h)
    } else {
        sx := f32(lay.strip.x + pad)
        sy := f32(lay.strip.y) + (f32(lay.strip.h) - t.font.line_height) / 2
        text_draw(t, "PitEd", sx, sy, lay.strip, win_w, win_h, TEXT)
        text_draw(t, aux_mode_name(a.aux_mode), sx + t.font.cell_w * 8, sy, lay.strip, win_w, win_h, TEXT_DIM)
    }
}

// The command line as it lives in the status strip: prompt, the editable runes,
// a selection highlight, and a caret. Monospace makes every x pure arithmetic.
draw_command_line :: proc(t: ^Text, strip: Rect, a: ^App, win_w, win_h: i32) {
    PROMPT :: "> "
    l := &a.cl.line
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    text_draw(t, PROMPT, f32(strip.x + pad), y, strip, win_w, win_h, TEXT_DIM)
    ox := f32(strip.x + pad) + cw * f32(len(PROMPT)) // text origin, after the prompt

    if line_has_selection(l) {
        lo, hi := line_sel_range(l)
        sel := Rect{i32(ox + cw * f32(lo)), i32(y), i32(cw * f32(hi - lo)), i32(lh)}
        fill(sel, win_h, SEL_BG)
    }

    text_draw_runes(t, l.text[:], ox, y, strip, win_w, win_h, TEXT)

    caret := Rect{i32(ox + cw * f32(l.cursor)), i32(y), i32(2 * a.scale), i32(lh)}
    fill(caret, win_h, TEXT)
}

// Draws a top-left label inside a pane; brighter when the pane is focused.
label :: proc(t: ^Text, s: string, r: Rect, pad: i32, win_w, win_h: i32, focused: bool) {
    text_draw(t, s, f32(r.x + pad), f32(r.y + pad), r, win_w, win_h, focused ? TEXT : TEXT_DIM)
}

// The filetree listing: a dired-style header (current dir) then rows, each
// prefixed '*' (in the unsaved ring) or '-' (not). The selection is highlighted
// and kept centered as the list scrolls; directories are tinted.
draw_filetree :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    ft := &a.tree
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)
    x0 := f32(area.x) + cw // one-cell left margin

    text_draw(t, ft.dir, x0, f32(area.y) + (f32(row_h) - lh) / 2, area, win_w, win_h, TEXT_DIM)

    list_top := area.y + row_h
    max_rows := max(1, int((area.y + area.h - list_top) / row_h))
    first := clamp(ft.selected - max_rows / 2, 0, max(0, len(ft.entries) - max_rows))
    visible := min(len(ft.entries) - first, max_rows)

    for k in 0 ..< visible {
        i := first + k
        e := &ft.entries[i]
        y := list_top + i32(k) * row_h
        if i == ft.selected {
            fill(Rect{area.x, y, area.w, row_h}, win_h, SEL_BG)
        }
        ty := f32(y) + (f32(row_h) - lh) / 2
        prefix := ring_contains(a, e.path) ? "*" : "-"
        text_draw(t, prefix, x0, ty, area, win_w, win_h, TEXT_DIM)
        text_draw(t, e.display, x0 + cw * 2, ty, area, win_w, win_h, e.is_dir ? FT_DIR : TEXT)
    }
}

// The terminal switcher: a slim i3-style numbered column shown while Alt is held.
// It is inset within the pane's focus outline (so it sits seamlessly inside the
// highlight rather than covering it), two digits wide, and scrolls to keep the
// active session visible.
draw_term_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
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

    fill(Rect{area.x, area.y, colw, i32(visible) * row_h}, win_h, OVERLAY)

    for k in 0 ..< visible {
        i := first + k
        y := area.y + i32(k) * row_h
        if i == a.term_active {
            fill(Rect{area.x, y, colw, row_h}, win_h, SEL)
        }
        buf: [8]u8
        label := strconv.write_int(buf[:], i64(i + 1), 10)
        tx := f32(area.x) + (f32(colw) - cw * f32(len(label))) / 2 // centered
        ty := f32(y) + (f32(row_h) - lh) / 2
        text_draw(t, label, tx, ty, Rect{area.x, y, colw, row_h}, win_w, win_h, TEXT)
    }
}
