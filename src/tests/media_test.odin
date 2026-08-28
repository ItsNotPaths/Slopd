package tests

import app "../slopd"
import "core:testing"
import "../gfx"

// --- extension routing (is_media_path) ---

@(test)
test_is_media_path :: proc(t: ^testing.T) {
    testing.expect(t, app.is_media_path("pic.png"))
    testing.expect(t, app.is_media_path("a/b/photo.jpg"))
    testing.expect(t, app.is_media_path("x.jpeg"))
    testing.expect(t, app.is_media_path("SHOUT.PNG")) // case-insensitive
    testing.expect(t, app.is_media_path("scan.GiF"))

    testing.expect(t, !app.is_media_path("main.odin"))
    testing.expect(t, !app.is_media_path("notes.txt"))
    testing.expect(t, !app.is_media_path("Makefile")) // no extension
    testing.expect(t, !app.is_media_path("")) // empty
    testing.expect(t, !app.is_media_path("archive.png.zip")) // the ext is the LAST segment
}

// --- fit geometry (media_fit_rect) ---

@(test)
test_media_fit_contain :: proc(t: ^testing.T) {
    pane := gfx.Rect{0, 0, 100, 100}

    // Wide (2:1) in a square pane: full width, letterboxed top and bottom.
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 1, {0, 0}), gfx.Rect{0, 25, 100, 50})
    // Tall (1:2): full height, pillarboxed left and right.
    testing.expect_value(t, app.media_fit_rect(pane, 100, 200, 1, {0, 0}), gfx.Rect{25, 0, 50, 100})
    testing.expect_value(t, app.media_fit_rect(pane, 50, 50, 1, {0, 0}), gfx.Rect{0, 0, 100, 100})
}

@(test)
test_media_fit_zoom_and_pan :: proc(t: ^testing.T) {
    pane := gfx.Rect{0, 0, 100, 100}

    // Zoom 2x: double the fitted size, recentred, overflowing left and right.
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 2, {0, 0}), gfx.Rect{-50, 0, 200, 100})
    // Pan shifts the placement by whole pixels on top of the centred fit.
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 1, {10, -5}), gfx.Rect{10, 20, 100, 50})
}

@(test)
test_media_fit_pane_offset_and_degenerate :: proc(t: ^testing.T) {
    // Relative to the pane's own origin, not the window's.
    off := gfx.Rect{5, 5, 100, 100}
    testing.expect_value(t, app.media_fit_rect(off, 200, 100, 1, {0, 0}), gfx.Rect{5, 30, 100, 50})

    // Degenerate inputs yield a zero-size rect at the pane origin.
    pane := gfx.Rect{0, 0, 100, 100}
    testing.expect_value(t, app.media_fit_rect(pane, 0, 100, 1, {0, 0}), gfx.Rect{0, 0, 0, 0})
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 0, {0, 0}), gfx.Rect{0, 0, 0, 0})
    testing.expect_value(t, app.media_fit_rect(gfx.Rect{0, 0, 0, 100}, 200, 100, 1, {0, 0}), gfx.Rect{0, 0, 0, 0})
}

// --- zoom about a point (media_zoom_at) ---

// The whole feature in one sentence: the image pixel under the pointer is still under the
// pointer afterwards.
//
// Asserted by round-tripping through media_fit_rect rather than against a hand-computed pan: the
// claim is where the picture ENDS UP, and a test restating the arithmetic would agree with a
// wrong implementation as readily as a right one.
@(test)
test_media_zoom_at_pins_the_pointer :: proc(t: ^testing.T) {
    pane := gfx.Rect{0, 0, 100, 100}
    m := app.Media {
        img  = gfx.Image{w = 200, h = 100},
        zoom = 1,
    }

    // Fit at zoom 1: {0, 25, 100, 50}. A spot well off centre, so a zero correction is wrong.
    px, py := i32(25), i32(37)
    before := app.media_fit_rect(pane, m.img.w, m.img.h, m.zoom, m.pan)
    ux := f32(px - before.x) / f32(before.w) // the image coordinate under the pointer
    uy := f32(py - before.y) / f32(before.h)

    app.media_zoom_at(&m, 2, pane, px, py)
    testing.expect_value(t, m.zoom, f32(2))

    after := app.media_fit_rect(pane, m.img.w, m.img.h, m.zoom, m.pan)
    gx := f32(after.x) + ux * f32(after.w)
    gy := f32(after.y) + uy * f32(after.h)
    // One pixel of slack: media_fit_rect rounds its placement twice.
    testing.expect(t, abs(gx - f32(px)) <= 1, "the grabbed column drifted")
    testing.expect(t, abs(gy - f32(py)) <= 1, "the grabbed row drifted")
}

// Zooming about the centre needs no correction, and the pan must come back untouched rather
// than by cancelling two errors. Also the keyboard's behaviour, so this pins the two agreeing.
@(test)
test_media_zoom_at_centre_leaves_the_pan_alone :: proc(t: ^testing.T) {
    pane := gfx.Rect{0, 0, 100, 100}
    m := app.Media {
        img  = gfx.Image{w = 200, h = 100},
        zoom = 1,
    }
    fit := app.media_fit_rect(pane, m.img.w, m.img.h, m.zoom, m.pan)

    app.media_zoom_at(&m, 2, pane, fit.x + fit.w / 2, fit.y + fit.h / 2)
    testing.expect_value(t, m.zoom, f32(2))
    testing.expect_value(t, m.pan, [2]f32{0, 0})
}

// A step MEDIA_ZOOM_MAX swallowed must correct by what the clamp allowed, not what was asked, or
// the image slides sideways every time the wheel turns at the end of its range.
@(test)
test_media_zoom_at_respects_the_clamp :: proc(t: ^testing.T) {
    pane := gfx.Rect{0, 0, 100, 100}
    m := app.Media {
        img  = gfx.Image{w = 200, h = 100},
        zoom = app.MEDIA_ZOOM_MAX,
    }
    pan := m.pan

    app.media_zoom_at(&m, 4, pane, 10, 10) // already at the ceiling: nothing moves
    testing.expect_value(t, m.zoom, app.MEDIA_ZOOM_MAX)
    testing.expect_value(t, m.pan, pan)

    // Nothing loaded: no image to keep under the pointer, and the zoom still takes, so the view
    // is where the user left it when one opens.
    e := app.Media{zoom = 1}
    app.media_zoom_at(&e, 2, pane, 10, 10)
    testing.expect_value(t, e.zoom, f32(2))
    testing.expect_value(t, e.pan, [2]f32{0, 0})
}
