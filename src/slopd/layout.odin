package main
import "../gfx"
import "../ui"

// Window pixel size + app state -> pane rectangles. Knows nothing about fonts, cells or
// rendering; a view hosting a glyph grid snaps these rects to whole cells itself.
//
// The strip spans the bottom; the editor and aux panes split the space above. A hidden pane
// gets a zero rect rather than any stored state — see panes_visible.

// Named here because there are two writers — Alt+[ / Alt+] and the divider drag — and a
// pointer must not reach a width the keyboard cannot.
SPLIT_MIN :: 0.15
SPLIT_MAX :: 0.85

Layout :: struct {
    editor: gfx.Rect, // zero rect when hidden (Full on the aux surface)
    aux:    gfx.Rect, // zero rect when hidden (Zen while editing)
    strip:  gfx.Rect,
    gutter: i32,
    vis:    Pane_Vis, // which panes these rects are for; computed once, here
}

compute_layout :: proc(win_w, win_h: i32, a: ^App, now: f64) -> Layout {
    out: Layout
    out.gutter = i32(2 * a.scale)

    // The strip's height tracks the font zoom as well as the DPI, since the command line
    // lives in it.
    strip_h := i32(24 * a.scale * font_zoom_ratio(a))
    if strip_h > win_h {
        strip_h = win_h
    }
    content_h := win_h - strip_h
    out.strip = gfx.Rect{0, content_h, win_w, strip_h}
    content := gfx.Rect{0, 0, win_w, content_h}

    // Eased rather than snapped when Alt+[ / Alt+] adjust it, re-aimed on change like smooth
    // scroll so it self-corrects each frame.
    if a.split != a.split_anim.to {
        ui.anim_start(&a.split_anim, now, ui.anim_value(&a.split_anim, now), a.split, ui.SPLIT_DUR)
    }
    split := ui.anim_value(&a.split_anim, now)

    // Zen: the editor keeps the full width and the aux pane slides in over its right edge
    // while focused. The editor rect shrinks to the uncovered strip — with no soft wrap its
    // glyphs are clipped there, never reflowed.
    if a.view == .Zen {
        r := ui.anim_value(&a.zen_anim, now) // 0 hidden .. 1 docked
        // The animated `split`, so an adjustment eases in Zen too.
        aux_w := max(0, win_w - i32(f32(win_w) * split))
        aux_x := win_w - i32(f32(aux_w) * r)
        if r > 0.001 {
            out.editor = gfx.Rect{0, 0, aux_x, content_h}
            out.aux = gfx.Rect{aux_x, 0, win_w - aux_x, content_h}
            out.vis = {true, true}
        } else {
            out.editor = content
            out.vis = {true, false}
        }
        return out
    }

    // Visibility is derived (panes_visible), so there is no hidden state here: two panes split
    // by a.split, a lone one filling the content area, a hidden one left a zero rect.
    out.vis = panes_visible(a)
    vis := out.vis
    switch {
    case vis.editor && vis.aux:
        g := out.gutter
        editor_w := max(0, i32(f32(win_w) * split) - g / 2)
        aux_x := editor_w + g
        out.editor = gfx.Rect{0, 0, editor_w, content_h}
        out.aux = gfx.Rect{aux_x, 0, max(0, win_w - aux_x), content_h}
    case vis.aux:
        out.aux = content
    case vis.editor:
        out.editor = content
    }
    return out
}
