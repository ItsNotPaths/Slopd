package main

import "core:math"
import clay "../bindings/clay"

// The media surface's UI half. **A panned and zoomed image sits at an arbitrary rect INSIDE
// its pane**, which is a floating child rather than a laid-out one — the flow has nothing to
// say about where a zoomed picture goes. It floats at `media_fit_rect`'s answer, offset from
// the pane box it is declared inside; `clipTo = .AttachedParent` is what keeps it off the
// focus ring, the float's clip being the pane box rather than its own.
//
// There is no `media_scroll_apply` — an image has no viewport policy to run. The pan is where
// the user put it, and that is the whole of its state.

// **A wheel here does not scroll.** A picture has no rows, so WHEEL_LINES names nothing over
// it, and zoom is what a wheel means over an image everywhere else on the desktop. The step is
// MEDIA_ZOOM_STEP (media.odin), so the two verbs cannot drift about what one step in means.

// The pane's content area, inside the focus ring `panel()` draws — the single geometry
// source every phase of the frame sizes itself from, exactly as `<p>_geom` is for a list
// pane. It carries no row grid because there is nothing here to divide into rows.
media_geom :: proc(pane: Rect, scale: f32) -> Rect {
    return inset(pane, i32(2 * scale))
}

// Whether the pointer is over the media surface. `rect_hit` rather than `PointerOver`: this is
// ONE box, needs no tree lookup, and stays callable from a test that declares nothing. A press
// on the letterbox margin pans too — what is grabbed is the VIEW, not the pixels.
media_hit :: proc(a: ^App, area: Rect) -> bool {
    if !a.mouse_on || !a.mouse.known || a.main != .Image {
        return false
    }
    return rect_hit(area, a.mouse.x, a.mouse.y)
}

// Apply a pending click. Two verbs, each the twin of a key the pane already has:
//
//   press + drag   pan the view      the arrow keys
//   double click   reset to fit      `0` / `f`
//
// The press captures unconditionally, as the editor's does: whether this is a click or a drag
// is not something the press can know. It carries the view's position at press time
// (Drag.origin_pan) so every later frame re-derives the pan from the total travel.
//
// The reset runs BEFORE the capture, so a double-click-and-drag pans from the fitted view
// the double click just established rather than from the one it replaced.
media_click :: proc(a: ^App, area: Rect) {
    if !media_hit(a, area) {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    m := &a.media
    if count >= 2 {
        media_fit(m)
    }
    // One media surface, so the target is a constant — the field earns its place on the
    // clients that have several (buffers, terminal sessions), and costs nothing here.
    drag_begin(a, .Media_Pan, 0, count, {}, 0, m.pan)
}

// Pan a live drag to wherever the pointer is now. A RE-DERIVATION, not an accumulation: the pan
// is the press-time pan plus total travel, so a dropped frame costs nothing and a wheel zoom
// mid-drag composes. No autoscroll — a pan already moves the surface a pixel per pixel.
media_drag :: proc(a: ^App) {
    if !a.mouse_on || !a.mouse.known || a.main != .Image {
        return
    }
    if !drag_live(a, .Media_Pan, 0) {
        return
    }
    d := &a.drag
    a.media.pan = d.origin_pan + [2]f32{f32(a.mouse.x - d.origin_x), f32(a.mouse.y - d.origin_y)}
}

// Spend `notch` wheel notches over the image: zoom, about the pointer. Positive is DOWN
// (mouse.odin normalises GLFW's sign), which zooms OUT. Notches compound rather than multiply
// linearly; the pane rect comes from `a.lay`, the layout the LAST FRAME PAINTED (mouse.odin).
media_wheel :: proc(a: ^App, notch: int) {
    if notch == 0 || a.main != .Image {
        return
    }
    media_zoom_at(
        &a.media,
        math.pow(MEDIA_ZOOM_STEP, f32(-notch)),
        media_geom(a.lay.editor, a.scale),
        a.mouse.x,
        a.mouse.y,
    )
}

// Declare the surface into the window's tree. Reads App, writes only Clay.
//
//   md_pane    the content area inside the focus ring, floating at the pane's own rect and
//              clipping its own content (the fill and the ring are panel()'s, not here)
//     md_image the decoded texture at media_fit_rect's answer: a floating child, offset from
//              the pane box, clipped to it. Emitted only when a texture exists — Clay skips
//              an Image element whose imageData is null (clay.h:3023), and a GL texture name
//              of 0 IS null, so "nothing loaded" needs no branch of its own in the bridge
//     md_empty the "(no image)" placeholder otherwise, centred in the pane the way the hand
//              painter centred it, by the solver rather than by (area.h - line_height) / 2
media_declare :: proc(a: ^App, f: ^Font, pane: Rect) {
    m := &a.media
    th := &a.theme
    area := media_geom(pane, a.scale)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    lh := i32(f.line_height)

    if clay.UI(clay.ID("md_pane"))(clay_pane_box(area)) {
        if m.tex != 0 {
            fit := media_fit_rect(area, m.w, m.h, m.zoom, m.pan)
            if fit.w > 0 && fit.h > 0 {
                if clay.UI(clay.ID("md_image"))(
                    {
                        layout   = {sizing = {clay.SizingFixed(f32(fit.w)), clay.SizingFixed(f32(fit.h))}},
                        image    = {imageData = rawptr(uintptr(m.tex))},
                        floating = media_image_float(fit, area),
                    },
                ) {}
            }
        } else {
            if clay.UI(clay.ID("md_empty"))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow(), clay.SizingGrow()},
                        padding        = {left = u16(8 * a.scale)},
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                clay.Text("(no image)", clay_text_config(th.muted, lh))
            }
        }
    }
}

// The image's placement: LeftTop-attached inside the pane box, so the offset IS its origin.
// `clipTo = .AttachedParent` is the load-bearing one — a zoomed image is LARGER than the pane
// and would paint over the focus ring. Passthrough, not Capture: media_hit never asks the tree.
media_image_float :: proc(fit, area: Rect) -> clay.FloatingElementConfig {
    return {
        attachTo           = .Parent,
        attachment         = {element = .LeftTop, parent = .LeftTop},
        offset             = {f32(fit.x - area.x), f32(fit.y - area.y)},
        clipTo             = .AttachedParent,
        pointerCaptureMode = .Passthrough,
    }
}

// The media viewer: the decoded image fit into the pane (contain letterbox), pannable by drag
// and zoomable by wheel, both bounded by MEDIA_ZOOM_MIN/MAX. Arrows pan, =/- zoom, 0/f reset
// (media_key). Frame order: geometry, claim the click, apply the drag, declare. No scroll apply.
media_frame :: proc(t: ^Text, a: ^App, pane: Rect) {
    area := media_geom(pane, a.scale)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    media_click(a, area)
    media_drag(a)
    media_declare(a, &t.font, pane)
}

// Test-facing wrapper; see filetree_layout.
media_layout :: proc(a: ^App, f: ^Font, pane: Rect, win_w, win_h: i32) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        media_declare(a, f, pane)
    }
    return clay.EndLayout(0)
}
