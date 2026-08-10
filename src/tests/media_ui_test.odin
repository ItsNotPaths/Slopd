package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// C8d's media surface — the last thing in the program that was painted by hand, now declared
// like everything else. Two claims, and the first one is the checkpoint's:
//
//   1. **The image is an element at media_fit_rect's rect**, floating inside the pane box and
//      clipped to it. That clip is what the hand painter's trailing `flush_pane(t, area, …)`
//      was; a zoomed image is LARGER than its pane, so losing it means painting over the focus
//      ring and into the aux pane.
//   2. **The pointer moves it.** A drag pans by the total travel since the press, a notch
//      zooms about the pointer (media_test.odin owns that arithmetic), and a click on the
//      surface claims the press so the pane behind it does not also act on it.
//
// The texture name is a made-up non-zero u32 throughout: nothing here dereferences it — Clay
// carries a GL name in the imageData pointer and the bridge casts it straight back out
// (clay_render.odin) — so the declaration is testable without a GL context.

@(private = "file")
WIN_W :: 400
@(private = "file")
WIN_H :: 300
@(private = "file")
PANE :: app.Rect{0, 0, 200, 280}
@(private = "file")
AREA :: app.Rect{2, 2, 196, 276} // inset by the 2px focus ring
@(private = "file")
FAKE_TEX :: 7

// An App showing a 200x100 image on the main surface, with the pointer live over the pane.
@(private = "file")
media_app :: proc(x, y: i32) -> app.App {
    a := app.App {
        main     = .Image,
        scale    = 1,
        mouse_on = true,
        lay      = app.Layout{editor = PANE, vis = {editor = true}},
    }
    a.media = app.Media {
        tex  = FAKE_TEX,
        w    = 200,
        h    = 100,
        zoom = 1,
    }
    a.mouse.known = true
    a.mouse.x, a.mouse.y = x, y
    return a
}

// A press parked for a pane to claim, as mouse_button_callback would have left it.
@(private = "file")
press :: proc(a: ^app.App, count: int) {
    a.mouse.down = true
    a.mouse.click = true
    a.mouse.click_count = count
}

// The geometry every phase sizes itself from: the content area inside the focus ring, which
// is the same inset the pane backdrop leaves and the same rect the old painter clipped to.
@(test)
test_media_geom_is_the_ring_inset :: proc(t: ^testing.T) {
    testing.expect_value(t, app.media_geom(PANE, 1), AREA)
    testing.expect_value(t, app.media_geom(PANE, 2), app.Rect{4, 4, 192, 272})
    // A pane too small to have an inside yields a rect with no area, which every phase
    // refuses — this is the Full-on-the-aux-surface case, where the editor rect is zero.
    testing.expect(t, app.media_geom(app.Rect{}, 1).w <= 0, "a hidden pane has no content area")
}

// THE POINT OF THE MOVE. The image lands at media_fit_rect's answer, inside the pane's clip
// group — so the two things that used to be a `image_push` and a `flush_pane` at the bottom
// of render.odin are now one element and one config field.
//
// The mutation this pins: dropping `clipTo = .AttachedParent` from media_image_float leaves
// the image command outside any scissor pair, and the second half of this test fails.
@(test)
test_media_declares_the_image_at_its_fit_rect :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a := media_app(100, 100)
    a.media.zoom = 2 // bigger than the pane: the clip is the whole question
    cmds := app.media_layout(&a, &f, PANE, WIN_W, WIN_H)

    want := app.media_fit_rect(AREA, 200, 100, 2, {0, 0})
    image: app.Rect
    tex: u32
    depth, image_depth := 0, -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Image:
            image = app.clay_rect(c.boundingBox)
            tex = u32(uintptr(c.renderData.image.imageData))
            image_depth = depth
        case .ScissorStart:
            depth += 1
        case .ScissorEnd:
            depth -= 1
        }
    }

    testing.expect_value(t, image, want)
    testing.expect_value(t, tex, u32(FAKE_TEX))
    testing.expect(t, want.w > AREA.w, "the fixture must actually overflow its pane")
    testing.expect(t, image_depth > 0, "the image painted outside every clip group")
    testing.expect_value(t, depth, 0) // balanced, or the bridge latches a scissor
}

// Nothing loaded is a placeholder and no image command at all. Clay skips an Image element
// whose imageData is null (clay.h:3023) and a GL texture name of 0 IS null, so "no image"
// needs no branch in the bridge — but it does need one here, because a placeholder is a
// different thing to say than an empty picture.
@(test)
test_media_declares_a_placeholder_when_empty :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a := media_app(100, 100)
    a.media = app.Media{zoom = 1} // nothing decoded
    cmds := app.media_layout(&a, &f, PANE, WIN_W, WIN_H)

    images, texts := 0, 0
    label: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Image:
            images += 1
        case .Text:
            texts += 1
            label = app.clay_rect(c.boundingBox)
        }
    }

    testing.expect_value(t, images, 0)
    testing.expect_value(t, texts, 1)
    // Vertically centred in the content area, one 8px margin in — the placement the hand
    // painter computed as `area.y + (area.h - line_height) / 2`, by the solver now.
    testing.expect_value(t, label.x, AREA.x + 8)
    testing.expect_value(t, label.y, AREA.y + (AREA.h - 16) / 2)
}

// A press on the surface captures, and the pan is a RE-DERIVATION from the press-time view
// rather than an accumulation of per-frame deltas — so a frame the loop happened not to run
// costs nothing, and a wheel zoom mid-drag composes instead of fighting.
//
// The mutation this pins: panning from the CURRENT pan each frame instead of from
// origin_pan makes the second drag frame land at the sum of both deltas.
@(test)
test_media_click_captures_and_drag_pans :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    a.media.pan = {12, -4} // a view the user had already moved
    press(&a, 1)

    app.media_click(&a, AREA)
    testing.expect(t, app.drag_live(&a, .Media_Pan, 0), "a press on the image must capture")
    testing.expect(t, !a.mouse.click, "and must claim the press, so the pane behind it does not")
    testing.expect_value(t, a.drag.origin_pan, [2]f32{12, -4})

    a.mouse.x, a.mouse.y = 140, 130
    app.media_drag(&a)
    testing.expect_value(t, a.media.pan, [2]f32{12 + 40, -4 + 30})

    // A second frame at a NEW position is measured from the press, not from the last frame.
    a.mouse.x, a.mouse.y = 110, 90
    app.media_drag(&a)
    testing.expect_value(t, a.media.pan, [2]f32{12 + 10, -4 - 10})

    // And back exactly where it started: a drag returned to the press point is the identity.
    a.mouse.x, a.mouse.y = 100, 100
    app.media_drag(&a)
    testing.expect_value(t, a.media.pan, [2]f32{12, -4})
}

// A double click resets to fit — the mouse twin of the `0` / `f` key — and it runs BEFORE the
// capture, so a double-click-and-drag pans from the view the reset just established rather
// than from the one it replaced.
@(test)
test_media_double_click_fits_then_captures :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    a.media.zoom, a.media.pan = 3, {50, 50}
    press(&a, 2)

    app.media_click(&a, AREA)
    testing.expect_value(t, a.media.zoom, f32(1))
    testing.expect_value(t, a.media.pan, [2]f32{0, 0})
    testing.expect_value(t, a.drag.origin_pan, [2]f32{0, 0})

    a.mouse.x += 20
    app.media_drag(&a)
    testing.expect_value(t, a.media.pan, [2]f32{20, 0})
}

// A press that is not this surface's is left alone. Three ways to not be it: outside the
// content area (the focus ring is not the picture), the mouse switched off, and the main
// surface showing TEXT — the last one matters because the editor and the media viewer share
// a pane rect and exactly one of them is on screen.
@(test)
test_media_refuses_presses_that_are_not_its_own :: proc(t: ^testing.T) {
    outside := media_app(300, 100) // over the aux side of the window
    press(&outside, 1)
    app.media_click(&outside, AREA)
    testing.expect(t, outside.mouse.click, "a press outside the pane must stay pending")
    testing.expect_value(t, outside.drag.kind, app.Drag_Kind.None)

    off := media_app(100, 100)
    off.mouse_on = false
    press(&off, 1)
    app.media_click(&off, AREA)
    testing.expect_value(t, off.drag.kind, app.Drag_Kind.None)

    text := media_app(100, 100)
    text.main = .Text
    press(&text, 1)
    app.media_click(&text, AREA)
    testing.expect(t, text.mouse.click, "the editor's press must not be eaten by the viewer")
    testing.expect_value(t, text.drag.kind, app.Drag_Kind.None)
}

// Capture is kind AND target here too: a pan does not write while some other gesture holds
// the button, and switching the main surface to text mid-drag leaves it held but inert.
@(test)
test_media_drag_only_writes_its_own_capture :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    press(&a, 1)
    app.media_click(&a, AREA)

    a.mouse.x += 30
    a.main = .Text // the surface swapped with the button still down
    app.media_drag(&a)
    testing.expect_value(t, a.media.pan, [2]f32{0, 0})

    b := media_app(100, 100)
    b.mouse.down = true
    app.drag_begin(&b, .Editor_Text, 0, 1, app.Pos{}, 0) // somebody else's gesture
    b.mouse.x += 30
    app.media_drag(&b)
    testing.expect_value(t, b.media.pan, [2]f32{0, 0})
}
