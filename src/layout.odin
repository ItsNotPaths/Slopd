package main

// Layout is the producer: window pixel size + app state -> pane rectangles.
// It knows nothing about fonts, cells, or rendering. Views that host a glyph
// grid snap these rects to whole cells themselves.
//
// The status strip always spans the bottom; above it the editor and aux panes are split
// vertically. A pane hidden by the view (Zen's retracted aux, Full's other surface) gets a
// zero rect rather than any stored hidden state — see panes_visible.

// How far the editor/aux split may be pushed either way. Named here because there are two
// writers — Alt+`[` / Alt+`]` (input.odin) and the divider drag (window_ui.odin) — and a
// pointer must not be able to reach a width the keyboard cannot.
SPLIT_MIN :: 0.15
SPLIT_MAX :: 0.85

Layout :: struct {
    editor: Rect, // the text editor pane (zero rect when hidden: Full on the aux surface)
    aux:    Rect, // the aux pane (zero rect when hidden: Zen while editing)
    strip:  Rect, // bottom status / command strip
    gutter: i32,
    vis:    Pane_Vis, // which panes these rects are for — computed once, here
}

compute_layout :: proc(win_w, win_h: i32, a: ^App, now: f64) -> Layout {
    out: Layout
    out.gutter = i32(2 * a.scale)

    // Status strip spans the full width along the bottom; the panes fill above. Its
    // height tracks the font zoom (the command line lives here) so big text doesn't
    // clip, on top of the DPI scale.
    strip_h := i32(24 * a.scale * font_zoom_ratio(a))
    if strip_h > win_h {
        strip_h = win_h
    }
    content_h := win_h - strip_h
    out.strip = Rect{0, content_h, win_w, strip_h}
    content := Rect{0, 0, win_w, content_h}

    // The editor's width fraction, eased rather than snapped when Alt+[ / Alt+] adjust
    // it. Re-aimed on change like smooth scroll (anim.odin) so it self-corrects each
    // frame; read in the Split arrangement below.
    if a.split != a.split_anim.to {
        anim_start(&a.split_anim, now, anim_value(&a.split_anim, now), a.split, SPLIT_DUR)
    }
    split := anim_value(&a.split_anim, now)

    // Zen: the editor keeps the full width and the aux pane slides in over its right edge
    // while it holds focus (zen_anim, driven by set_focus). The editor rect shrinks to the
    // uncovered strip — with no soft-wrap its glyphs are clipped at that edge, never reflowed.
    if a.view == .Zen {
        r := anim_value(&a.zen_anim, now) // 0 hidden .. 1 docked
        // Use the animated `split` rather than the raw a.split so an adjustment EASES
        // in Zen too rather than snapping.
        aux_w := max(0, win_w - i32(f32(win_w) * split))
        aux_x := win_w - i32(f32(aux_w) * r)
        if r > 0.001 {
            out.editor = Rect{0, 0, aux_x, content_h}
            out.aux = Rect{aux_x, 0, win_w - aux_x, content_h}
            out.vis = {true, true}
        } else {
            out.editor = content
            out.vis = {true, false}
        }
        return out
    }

    // Pane visibility is derived (see panes_visible), so the layout has no hidden
    // state to track: two panes split by a.split; a lone visible pane fills the
    // content area; a hidden pane is left a zero rect (render's guards skip it).
    out.vis = panes_visible(a)
    vis := out.vis
    switch {
    case vis.editor && vis.aux:
        g := out.gutter
        editor_w := max(0, i32(f32(win_w) * split) - g / 2)
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
