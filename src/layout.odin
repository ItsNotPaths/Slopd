package main

// Layout is the producer: window pixel size + app state -> pane rectangles.
// It knows nothing about fonts, cells, or rendering. Views that host a glyph
// grid snap these rects to whole cells themselves.
//
// There is no maximize: the editor and aux panes are always both present, split
// vertically, with the status strip along the bottom.

Layout :: struct {
    editor: Rect, // left pane (always the text editor)
    aux:    Rect, // right pane (the aux pane)
    strip:  Rect, // bottom status / command strip
    gutter: i32,
}

compute_layout :: proc(win_w, win_h: i32, a: ^App) -> Layout {
    out: Layout
    out.gutter = i32(2 * a.scale)

    // Status strip spans the full width along the bottom; the panes fill above.
    strip_h := i32(24 * a.scale)
    if strip_h > win_h {
        strip_h = win_h
    }
    content_h := win_h - strip_h
    out.strip = Rect{0, content_h, win_w, strip_h}

    g := out.gutter
    editor_w := i32(f32(win_w) * a.split) - g / 2
    if editor_w < 0 {
        editor_w = 0
    }
    aux_x := editor_w + g
    aux_w := win_w - aux_x
    if aux_w < 0 {
        aux_w = 0
    }
    out.editor = Rect{0, 0, editor_w, content_h}
    out.aux = Rect{aux_x, 0, aux_w, content_h}
    return out
}
