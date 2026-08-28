package ui

import clay "../../bindings/clay"
import "../gfx"

// The chrome every pane shares: which side has the keys, how a list follows its selection, the
// pane box, and the two colours a hovered or focused pane is drawn with. Small, and named here
// so no pane invents its own.

Focus :: enum {
    Editor,
    Aux,
}


Scroll_Mode :: enum {
    Follow,
    Middle,
}



inset :: proc(r: gfx.Rect, by: i32) -> gfx.Rect {
    return gfx.Rect{r.x + by, r.y + by, r.w - 2 * by, r.h - 2 * by}
}

panel :: proc(t: ^gfx.Text, r: gfx.Rect, bg, focus: [3]f32, focused: bool, scale: f32) {
    if focused {
        gfx.fill(t, r, focus)
        gfx.fill(t, inset(r, i32(2 * scale)), bg)
    } else {
        gfx.fill(t, r, bg)
    }
}

// How far the hover tint travels from the background toward the selection bar. Well short on
// purpose: the pointer resting somewhere is not a selection.
HOVER_MIX :: 0.35

// The row under the pointer (`hover: on|off`). Mixes rather than blends: the quad shader
// writes opaque, so a translucent wash has to be baked into the colour.
hover_bg :: proc(th: ^gfx.Theme) -> [3]f32 {
    return th.bg + (th.separator - th.bg) * HOVER_MIX
}


// Attached to the root by the top-left corner, so the offset IS the pane's origin. Passthrough:
// one that captured would stop the root answering for the gutter.
clay_pane_float :: proc(area: gfx.Rect) -> clay.FloatingElementConfig {
    return {
        attachTo           = .Root,
        offset             = {f32(area.x), f32(area.y)},
        attachment         = {element = .LeftTop, parent = .LeftTop},
        pointerCaptureMode = .Passthrough,
    }
}

// Fixed to the content area, floating at its origin, clipping its own content, stacking
// downward. One call, so the panes cannot disagree.
clay_pane_box :: proc(area: gfx.Rect) -> clay.ElementDeclaration {
    return {
        layout = {
            sizing          = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
            layoutDirection = .TopToBottom,
        },
        floating = clay_pane_float(area),
        clip     = {horizontal = true, vertical = true},
    }
}
