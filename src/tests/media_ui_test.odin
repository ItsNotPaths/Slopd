package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"

// The media surface, the last thing in the program painted by hand. Two claims:
//
//   1. The image is an element at media_fit_rect's rect, floating inside the pane box and
//      clipped to it. That clip is what the hand painter's trailing flush_pane was; a zoomed
//      image is LARGER than its pane, so losing it paints over the ring and into the aux pane.
//   2. The pointer moves it: a drag pans by the total travel since the press, a notch zooms
//      about the pointer, and a click claims the press.
//
// The texture name is a made-up non-zero u32: nothing dereferences it, since Clay carries a GL
// name in the imageData pointer and the bridge casts it straight back out.

@(private = "file")
WIN_W :: 400
@(private = "file")
WIN_H :: 300
@(private = "file")
PANE :: gfx.Rect{0, 0, 200, 280}
@(private = "file")
AREA :: gfx.Rect{2, 2, 196, 276} // inset by the 2px focus ring
@(private = "file")
FAKE_TEX :: 7

// A 200x100 image on the main surface, with the pointer live over the pane.
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

// As mouse_button_callback would have left it.
@(private = "file")
press :: proc(a: ^app.App, count: int) {
    a.mouse.down = true
    a.mouse.click = true
    a.mouse.click_count = count
}

// The content area inside the focus ring: the same inset the pane backdrop leaves.
@(test)
test_media_geom_is_the_ring_inset :: proc(t: ^testing.T) {
    testing.expect_value(t, app.media_geom(PANE, 1), AREA)
    testing.expect_value(t, app.media_geom(PANE, 2), gfx.Rect{4, 4, 192, 272})
    // Too small to have an inside yields a rect with no area, which every phase refuses.
    testing.expect(t, app.media_geom(gfx.Rect{}, 1).w <= 0, "a hidden pane has no content area")
}

// The image lands at media_fit_rect's answer, inside the pane's clip group: what used to be an
// image_push and a flush_pane is now one element and one config field. Dropping
// `clipTo = .AttachedParent` leaves the image command outside any scissor pair.
@(test)
test_media_declares_the_image_at_its_fit_rect :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a := media_app(100, 100)
    a.media.zoom = 2 // bigger than the pane: the clip is the whole question
    cmds := app.media_layout(&a, &f, PANE, WIN_W, WIN_H)

    want := app.media_fit_rect(AREA, 200, 100, 2, {0, 0})
    image: gfx.Rect
    tex: u32
    depth, image_depth := 0, -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Image:
            image = ui.clay_rect(c.boundingBox)
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

// A placeholder and no image command. Clay skips an Image whose imageData is null and a GL
// texture name of 0 IS null, so "no image" needs no branch in the bridge — but it needs one
// here, because a placeholder says something an empty picture does not.
@(test)
test_media_declares_a_placeholder_when_empty :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a := media_app(100, 100)
    a.media = app.Media{zoom = 1} // nothing decoded
    cmds := app.media_layout(&a, &f, PANE, WIN_W, WIN_H)

    images, texts := 0, 0
    label: gfx.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Image:
            images += 1
        case .Text:
            texts += 1
            label = ui.clay_rect(c.boundingBox)
        }
    }

    testing.expect_value(t, images, 0)
    testing.expect_value(t, texts, 1)
    // Centred in the content area, one 8px margin in: the hand painter's arithmetic, by the
    // solver now.
    testing.expect_value(t, label.x, AREA.x + 8)
    testing.expect_value(t, label.y, AREA.y + (AREA.h - 16) / 2)
}

// The pan is a RE-DERIVATION from the press-time view rather than an accumulation of per-frame
// deltas, so a dropped frame costs nothing and a wheel zoom mid-drag composes. Panning from the
// CURRENT pan each frame makes the second drag frame land at the sum of both deltas.
@(test)
test_media_click_captures_and_drag_pans :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    a.media.pan = {12, -4} // a view the user had already moved
    press(&a, 1)

    app.media_click(app.ctx_of(&a), &a.media, AREA, a.main == .Image)
    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Media_Pan, 0), "a press on the image must capture")
    testing.expect(t, !a.mouse.click, "and must claim the press, so the pane behind it does not")
    testing.expect_value(t, a.drag.origin_pan, [2]f32{12, -4})

    a.mouse.x, a.mouse.y = 140, 130
    app.media_drag(app.ctx_of(&a), &a.media, a.main == .Image)
    testing.expect_value(t, a.media.pan, [2]f32{12 + 40, -4 + 30})

    // A second frame at a new position is measured from the press, not the last frame.
    a.mouse.x, a.mouse.y = 110, 90
    app.media_drag(app.ctx_of(&a), &a.media, a.main == .Image)
    testing.expect_value(t, a.media.pan, [2]f32{12 + 10, -4 - 10})

    // Back where it started: a drag returned to the press point is the identity.
    a.mouse.x, a.mouse.y = 100, 100
    app.media_drag(app.ctx_of(&a), &a.media, a.main == .Image)
    testing.expect_value(t, a.media.pan, [2]f32{12, -4})
}

// The mouse twin of `0` / `f`, running BEFORE the capture so a double-click-and-drag pans from
// the view the reset just established.
@(test)
test_media_double_click_fits_then_captures :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    a.media.zoom, a.media.pan = 3, {50, 50}
    press(&a, 2)

    app.media_click(app.ctx_of(&a), &a.media, AREA, a.main == .Image)
    testing.expect_value(t, a.media.zoom, f32(1))
    testing.expect_value(t, a.media.pan, [2]f32{0, 0})
    testing.expect_value(t, a.drag.origin_pan, [2]f32{0, 0})

    a.mouse.x += 20
    app.media_drag(app.ctx_of(&a), &a.media, a.main == .Image)
    testing.expect_value(t, a.media.pan, [2]f32{20, 0})
}

// Three ways not to be this surface's: outside the content area, the mouse switched off, and the
// main surface showing TEXT — which matters because the editor and the viewer share a pane rect.
@(test)
test_media_refuses_presses_that_are_not_its_own :: proc(t: ^testing.T) {
    outside := media_app(300, 100) // over the aux side of the window
    press(&outside, 1)
    app.media_click(app.ctx_of(&outside), &outside.media, AREA, outside.main == .Image)
    testing.expect(t, outside.mouse.click, "a press outside the pane must stay pending")
    testing.expect_value(t, outside.drag.kind, ui.Drag_Kind.None)

    off := media_app(100, 100)
    off.mouse_on = false
    press(&off, 1)
    app.media_click(app.ctx_of(&off), &off.media, AREA, off.main == .Image)
    testing.expect_value(t, off.drag.kind, ui.Drag_Kind.None)

    text := media_app(100, 100)
    text.main = .Text
    press(&text, 1)
    app.media_click(app.ctx_of(&text), &text.media, AREA, text.main == .Image)
    testing.expect(t, text.mouse.click, "the editor's press must not be eaten by the viewer")
    testing.expect_value(t, text.drag.kind, ui.Drag_Kind.None)
}

// Kind AND target here too: a pan does not write while another gesture holds the button, and
// switching to text mid-drag leaves it held but inert.
@(test)
test_media_drag_only_writes_its_own_capture :: proc(t: ^testing.T) {
    a := media_app(100, 100)
    press(&a, 1)
    app.media_click(app.ctx_of(&a), &a.media, AREA, a.main == .Image)

    a.mouse.x += 30
    a.main = .Text // the surface swapped with the button still down
    app.media_drag(app.ctx_of(&a), &a.media, a.main == .Image)
    testing.expect_value(t, a.media.pan, [2]f32{0, 0})

    b := media_app(100, 100)
    b.mouse.down = true
    ui.drag_begin(app.ctx_of(&b), .Editor_Text, 0, 1, txt.Pos{}, 0) // somebody else's gesture
    b.mouse.x += 30
    app.media_drag(app.ctx_of(&b), &b.media, b.main == .Image)
    testing.expect_value(t, b.media.pan, [2]f32{0, 0})
}
