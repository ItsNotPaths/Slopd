package main

import "core:math"
import clay "../../bindings/clay"
import "../gfx"
import "../ui"

// The media surface's UI half. A panned and zoomed image sits at an arbitrary rect inside its
// pane, so it is a floating child rather than a laid-out one — the flow has nothing to say about
// where a zoomed picture goes. `clipTo = .AttachedParent` keeps it off the focus ring.
//
// No media_scroll_apply: an image has no viewport policy, and a wheel here zooms rather than
// scrolls. The pan is where the user put it, and that is the whole of its state.

// Inside the focus ring panel() draws — the one geometry source every phase sizes itself from.
// No row grid, because there is nothing here to divide into rows.
MEDIA_LABEL_PAD :: 8 // the "(no image)" indent, in layout units

media_geom :: proc(pane: gfx.Rect, line_h: f32) -> gfx.Rect {
    return ui.inset(pane, gfx.edge(line_h))
}

// rect_hit rather than PointerOver: one box, no tree lookup, and callable from a test that
// declares nothing. A press on the letterbox margin pans too — the view is what is grabbed.
// `shown` is the caller's answer to "is the image surface the one on screen": a pointer over
// the rect of a hidden surface is not over this pane.
media_hit :: proc(u: ui.UI_Ctx, area: gfx.Rect, shown: bool) -> bool {
    if !u.mouse_on || !u.mouse.known || !shown {
        return false
    }
    return gfx.rect_hit(area, u.mouse.x, u.mouse.y)
}

// Two verbs, each the twin of a key the pane has:
//   press + drag   pan the view      the arrow keys
//   double click   reset to fit      `0` / `f`
// The press captures unconditionally, carrying the view's position at press time so every later
// frame re-derives the pan from the total travel. The reset runs BEFORE the capture, so a
// double-click-and-drag pans from the view the double click just established.
media_click :: proc(u: ui.UI_Ctx, m: ^Media, area: gfx.Rect, shown: bool) {
    if !media_hit(u, area, shown) {
        return
    }
    count, ok := ui.mouse_take_click(u)
    if !ok {
        return
    }
    if count >= 2 {
        media_fit(m)
    }
    // One media surface, so the target is a constant.
    ui.drag_begin(u, .Media_Pan, 0, count, {}, 0, m.pan)
}

// A re-derivation, not an accumulation: press-time pan plus total travel, so a dropped frame
// costs nothing and a wheel zoom mid-drag composes.
media_drag :: proc(u: ui.UI_Ctx, m: ^Media, shown: bool) {
    if !u.mouse_on || !u.mouse.known || !shown {
        return
    }
    if !ui.drag_live(u, .Media_Pan, 0) {
        return
    }
    d := u.drag
    m.pan = d.origin_pan + [2]f32{f32(u.mouse.x - d.origin_x), f32(u.mouse.y - d.origin_y)}
}

// Zoom about the pointer. Positive is DOWN, which zooms out. Notches compound; the pane rect
// comes from `a.lay`, the layout the last frame painted.
media_wheel :: proc(a: ^App, notch: int) {
    if notch == 0 || a.main != .Image {
        return
    }
    media_zoom_at(
        &a.media,
        math.pow(MEDIA_ZOOM_STEP, f32(-notch)),
        media_geom(a.lay.editor, a.face.line_height),
        a.mouse.x,
        a.mouse.y,
    )
}

// Declare the surface into the window's tree. Reads App, writes only Clay.
//
//   md_pane    the content area inside the focus ring, floating and clipping its own content
//     md_image the decoded image at media_fit_rect's answer, clipped to the pane box. Declared
//              only when the backend actually holds one, which is what selects the branch below
//     md_empty the "(no image)" placeholder otherwise, centred by the solver
media_declare :: proc(u: ui.UI_Ctx, m: ^Media, face: gfx.Face, pane: gfx.Rect) {
    th := u.theme
    area := media_geom(pane, face.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    lh := i32(face.line_height)

    if clay.UI(clay.ID("md_pane"))(ui.clay_pane_box(area)) {
        if gfx.image_valid(m.img) {
            fit := media_fit_rect(area, m.img.w, m.img.h, m.zoom, m.pan)
            if fit.w > 0 && fit.h > 0 {
                if clay.UI(clay.ID("md_image"))(
                    {
                        layout   = {sizing = {clay.SizingFixed(f32(fit.w)), clay.SizingFixed(f32(fit.h))}},
                        image    = {imageData = rawptr(&m.img)},
                        floating = media_image_float(fit, area),
                    },
                ) {}
            }
        } else {
            if clay.UI(clay.ID("md_empty"))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow(), clay.SizingGrow()},
                        padding        = {left = u16(gfx.pad(face.line_height, MEDIA_LABEL_PAD))},
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                clay.Text("(no image)", ui.clay_text_config(th.muted, lh))
            }
        }
    }
}

// LeftTop-attached inside the pane box, so the offset IS its origin. `clipTo = .AttachedParent`
// is load-bearing: a zoomed image is larger than the pane and would paint over the focus ring.
media_image_float :: proc(fit, area: gfx.Rect) -> clay.FloatingElementConfig {
    return {
        attachTo           = .Parent,
        attachment         = {element = .LeftTop, parent = .LeftTop},
        offset             = {f32(fit.x - area.x), f32(fit.y - area.y)},
        clipTo             = .AttachedParent,
        pointerCaptureMode = .Passthrough,
    }
}

// The image letterboxed into the pane, pannable by drag and zoomable by wheel within
// MEDIA_ZOOM_MIN/MAX. Frame order: geometry, click, drag, declare. No scroll apply.
media_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect) {
    u := ctx_of(a)
    area := media_geom(pane, u.face.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    shown := a.main == .Image
    media_click(u, &a.media, area, shown)
    media_drag(u, &a.media, shown)
    media_declare(u, &a.media, gfx.face(t), pane)
}

// Test-facing wrapper; see filetree_layout.
media_layout :: proc(a: ^App, face: gfx.Face, pane: gfx.Rect, win_w, win_h: i32) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        media_declare(ctx_of(a), &a.media, face, pane)
    }
    return clay.EndLayout(0)
}
