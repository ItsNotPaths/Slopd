package main

import "core:math"
import clay "../bindings/clay"

// The media surface's UI half — C8d, and the last hand-drawn surface in the program.
//
// It is the one pane that sat outside the tree through all of C8a–c, and the reason was
// written down there rather than fudged: **a panned and zoomed image sits at an arbitrary
// rect INSIDE its pane**, which is a floating child rather than a laid-out one, and nothing
// before C8d gave the pointer a way to move it. Now that a drag pans it and a notch zooms
// it, the rect is the interesting thing about the pane, and a rect the layout engine does
// not know about is exactly the split-brain this refactor exists to close.
//
// So the image is `floating` at `media_fit_rect`'s answer, offset from the pane box it is
// declared inside — the same three lines the overlays use (C8c), spent on the opposite
// problem: an overlay floats because it must escape the flow, and this floats because the
// flow has nothing to say about where a zoomed picture goes.
//
// **`clipTo = .AttachedParent` replaces the painter's `flush_pane(t, area, …)` exactly.**
// draw_media ended with that call to keep a zoomed image off the focus ring; the float's
// clip is the pane box, which IS that area, so the pixels are the same and the rule is now
// stated on the element rather than at a call site in render.odin.
//
// The pane keeps SIX of the template's seven procs and drops one: there is no
// `media_scroll_apply`, because an image has no viewport policy to run. Nothing here chases
// anything — the pan is where the user put it, and that is the whole of its state.

// One more thing this pane is alone in: **a wheel here does not scroll.** That is not an
// exception being carved out — `Wheel_Target.Media` has sat in the routing table as a
// declared no-op since C2, waiting for exactly this. A picture has no rows, so WHEEL_LINES
// names nothing over it, and zoom is what a wheel means over an image everywhere else on the
// desktop. The step it zooms by is MEDIA_ZOOM_STEP (media.odin), shared with the =/- keys so
// the two verbs cannot drift about what one step in means.

// The pane's content area, inside the focus ring `panel()` draws — the single geometry
// source every phase of the frame sizes itself from, exactly as `<p>_geom` is for a list
// pane. It carries no row grid because there is nothing here to divide into rows.
media_geom :: proc(pane: Rect, scale: f32) -> Rect {
    return inset(pane, i32(2 * scale))
}

// Whether the pointer is over the media surface. `rect_hit` rather than `PointerOver`, for
// C8a's reason and not for its old workaround: this is ONE box, a rect test needs no tree
// lookup, and it keeps the proc callable from a test that declares nothing. The image
// element itself is not the target — a press on the letterbox margin pans just as well as
// one on the picture, because what is being grabbed is the VIEW, not the pixels.
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
// The press captures unconditionally, exactly as the editor's does and for the same reason:
// whether this is a click or a drag is not something the press can know, and a pan that
// never moves is a no-op rather than a special case. The pan carries the view's position at
// press time with it (Drag.origin_pan) so every later frame re-derives the pan from the
// total travel rather than accumulating deltas.
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

// Pan a live drag to wherever the pointer is now — the pointer's per-frame verb, and the
// simplest one in the program: an image has no rows to resolve, no selection to grow and no
// viewport policy to satisfy, so the whole gesture is one vector.
//
// It is a RE-DERIVATION, not an accumulation: the pan is the press-time pan plus the total
// travel since, so a frame the loop happened not to run costs nothing and no rounding
// compounds over a long drag. It also means a wheel zoom mid-drag composes correctly —
// media_zoom_at moves the pan, and the next motion adds the same delta on top of it.
//
// There is no autoscroll and no threshold. Neither is an omission: `drag_autoscrolling`
// answers "neither axis" for this kind (drag.odin), because a pan already moves the surface
// a pixel per pixel and past-the-edge has nothing left to mean; and a zero-length pan is a
// zero-length vector, which is the same picture, so a click on the image costs nothing.
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
// (mouse.odin normalises GLFW's sign), which zooms OUT — pushing the wheel away pulls the
// picture closer, as it does in every image viewer.
//
// The notches compound rather than multiply linearly, so a trackpad's several-at-once event
// lands where the same number of discrete notches would. The pane rect comes from `a.lay` —
// the layout the LAST FRAME PAINTED — for wheel_target's reason (mouse.odin, trap 2), and
// through media_geom so the zoom's idea of the pane is the declaration's.
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

// Declare the surface into the window's tree (C8a) — the move this checkpoint owed C8a.
// Reads App, writes only Clay.
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
                        layout = {sizing = {clay.SizingFixed(f32(fit.w)), clay.SizingFixed(f32(fit.h))}},
                        image = {imageData = rawptr(uintptr(m.tex))},
                        floating = media_image_float(fit, area),
                    },
                ) {}
            }
        } else {
            if clay.UI(clay.ID("md_empty"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingGrow()},
                        padding = {left = u16(8 * a.scale)},
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                clay.Text("(no image)", clay_text_config(th.muted, lh))
            }
        }
    }
}

// The image's placement: absolute inside the pane box it is declared in, out of the flow,
// and clipped to that box.
//
// `attachTo = .Parent` with a LeftTop/LeftTop attachment makes the offset the image's origin
// relative to the pane's content area, which is the difference media_fit_rect's answer and
// the pane rect already express — the same collapse C8a made when the panes stopped being
// full-window containers padded by their own origin.
//
// `clipTo = .AttachedParent` is the load-bearing one: a zoomed image is LARGER than the pane
// and would otherwise paint over the focus ring and into the aux pane. It gives the element
// a scissor group at the PANE's box (overlay_ui.odin's header for why the parent's box and
// not its own), which is precisely the `flush_pane(t, area, …)` the hand painter ended with.
//
// Passthrough, not Capture: this is inside a pane, media_hit is a rect test that never asks
// the tree, and a capturing image would take the pointer away from nothing while quietly
// making the pane's letterbox margin behave differently from its picture.
media_image_float :: proc(fit, area: Rect) -> clay.FloatingElementConfig {
    return {
        attachTo = .Parent,
        attachment = {element = .LeftTop, parent = .LeftTop},
        offset = {f32(fit.x - area.x), f32(fit.y - area.y)},
        clipTo = .AttachedParent,
        pointerCaptureMode = .Passthrough,
    }
}

// The media viewer: the decoded image fit into the pane (contain letterbox), pannable by
// drag and zoomable by wheel, both bounded by MEDIA_ZOOM_MIN/MAX. Arrows pan, =/- zoom and
// 0/f reset from the keyboard (media_key); the filename, dimensions and zoom show in the
// modeline. An empty surface shows a placeholder.
//
// The frame order is the template's, minus the phase this pane does not have: geometry,
// claim the click, apply the drag, declare. No scroll apply — see the header.
media_frame :: proc(t: ^Text, a: ^App, pane: Rect) {
    area := media_geom(pane, a.scale)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    media_click(a, area)
    media_drag(a)
    media_declare(a, &t.font, pane)
}

// The surface alone in a window, as a command list: the test-facing wrapper every declared
// surface keeps (see filetree_layout for why).
media_layout :: proc(a: ^App, f: ^Font, pane: Rect, win_w, win_h: i32) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        media_declare(a, f, pane)
    }
    return clay.EndLayout(0)
}
