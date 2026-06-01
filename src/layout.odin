package main

// Layout is the producer: window pixel size + app state -> pane rectangles.
// It knows nothing about fonts, cells, or rendering. Views that host a glyph
// grid snap these rects to whole cells themselves.
//
// There is no maximize: the editor and aux panes are always both present, split
// vertically, with the status strip along the bottom.

Layout :: struct {
    editor: Rect, // the text editor pane (zero rect when hidden: Util)
    aux:    Rect, // the aux pane (zero rect when hidden: Zen while editing)
    strip:  Rect, // bottom status / command strip
    gutter: i32,
    vis:    Pane_Vis, // which panes these rects are for — computed once, here
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
    content := Rect{0, 0, win_w, content_h}

    // Pane visibility is derived (see panes_visible), so the layout has no hidden
    // state to track: two panes split by a.split; a lone visible pane fills the
    // content area; a hidden pane is left a zero rect (render's guards skip it).
    out.vis = panes_visible(a)
    vis := out.vis
    switch {
    case vis.editor && vis.aux:
        g := out.gutter
        editor_w := max(0, i32(f32(win_w) * a.split) - g / 2)
        aux_x := editor_w + g
        out.editor = Rect{0, 0, editor_w, content_h}
        out.aux = Rect{aux_x, 0, max(0, win_w - aux_x), content_h}
    case vis.aux:
        out.aux = content
    case vis.editor:
        out.editor = content
    }
    return out
}
