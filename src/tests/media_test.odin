package tests

import app ".."
import "core:testing"

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
    testing.expect(t, !app.is_media_path("archive.png.zip")) // ext is the LAST segment
}

// --- fit geometry (media_fit_rect) ---

@(test)
test_media_fit_contain :: proc(t: ^testing.T) {
    pane := app.Rect{0, 0, 100, 100}

    // Wide image (2:1) in a square pane: fits to full width, letterboxed top+bottom.
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 1, {0, 0}), app.Rect{0, 25, 100, 50})
    // Tall image (1:2): fits to full height, pillarboxed left+right.
    testing.expect_value(t, app.media_fit_rect(pane, 100, 200, 1, {0, 0}), app.Rect{25, 0, 50, 100})
    // Exact square fills the pane.
    testing.expect_value(t, app.media_fit_rect(pane, 50, 50, 1, {0, 0}), app.Rect{0, 0, 100, 100})
}

@(test)
test_media_fit_zoom_and_pan :: proc(t: ^testing.T) {
    pane := app.Rect{0, 0, 100, 100}

    // Zoom 2x the wide image: doubles the fitted size, recentred (overflows left/right).
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 2, {0, 0}), app.Rect{-50, 0, 200, 100})
    // Pan shifts the placement by whole pixels on top of the centred fit.
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 1, {10, -5}), app.Rect{10, 20, 100, 50})
}

@(test)
test_media_fit_pane_offset_and_degenerate :: proc(t: ^testing.T) {
    // The fit is relative to the pane's own origin (not the window's).
    off := app.Rect{5, 5, 100, 100}
    testing.expect_value(t, app.media_fit_rect(off, 200, 100, 1, {0, 0}), app.Rect{5, 30, 100, 50})

    // Degenerate inputs yield a zero-size rect at the pane origin (nothing drawn).
    pane := app.Rect{0, 0, 100, 100}
    testing.expect_value(t, app.media_fit_rect(pane, 0, 100, 1, {0, 0}), app.Rect{0, 0, 0, 0})
    testing.expect_value(t, app.media_fit_rect(pane, 200, 100, 0, {0, 0}), app.Rect{0, 0, 0, 0})
    testing.expect_value(t, app.media_fit_rect(app.Rect{0, 0, 0, 100}, 200, 100, 1, {0, 0}), app.Rect{0, 0, 0, 0})
}

// --- zoom about a point (media_zoom_at) ---

// C8d's wheel zoom. The claim is one sentence and it is the whole feature: **the image pixel
// under the pointer is still under the pointer afterwards.** That is what makes a wheel zoom
// read as a lens over the picture rather than as a slider beside it.
//
// Asserted by round-tripping through media_fit_rect rather than by checking the pan against a
// hand-computed number, because the pan is a means: what is being claimed is where the
// picture ENDS UP, and a test that restated the arithmetic would agree with a wrong
// implementation as readily as with a right one.
@(test)
test_media_zoom_at_pins_the_pointer :: proc(t: ^testing.T) {
    pane := app.Rect{0, 0, 100, 100}
    m := app.Media {
        w    = 200,
        h    = 100,
        zoom = 1,
    }

    // Fit at zoom 1: {0, 25, 100, 50}. Point at a spot well off the image's centre — the
    // top-left quarter — so a correction of zero would be visibly wrong.
    px, py := i32(25), i32(37)
    before := app.media_fit_rect(pane, m.w, m.h, m.zoom, m.pan)
    ux := f32(px - before.x) / f32(before.w) // the image coordinate under the pointer, 0..1
    uy := f32(py - before.y) / f32(before.h)

    app.media_zoom_at(&m, 2, pane, px, py)
    testing.expect_value(t, m.zoom, f32(2))

    after := app.media_fit_rect(pane, m.w, m.h, m.zoom, m.pan)
    gx := f32(after.x) + ux * f32(after.w)
    gy := f32(after.y) + uy * f32(after.h)
    // One pixel of slack: media_fit_rect rounds its placement to whole pixels, twice.
    testing.expect(t, abs(gx - f32(px)) <= 1, "the grabbed column drifted")
    testing.expect(t, abs(gy - f32(py)) <= 1, "the grabbed row drifted")
}

// Zooming about the CENTRE needs no correction at all, which is the degenerate case the
// formula has to get right for free — the pan must come back untouched rather than by
// cancelling two errors. It is also the keyboard's behaviour (media_zoom), so this is the
// assertion that the two verbs agree wherever they overlap.
@(test)
test_media_zoom_at_centre_leaves_the_pan_alone :: proc(t: ^testing.T) {
    pane := app.Rect{0, 0, 100, 100}
    m := app.Media {
        w    = 200,
        h    = 100,
        zoom = 1,
    }
    fit := app.media_fit_rect(pane, m.w, m.h, m.zoom, m.pan)

    app.media_zoom_at(&m, 2, pane, fit.x + fit.w / 2, fit.y + fit.h / 2)
    testing.expect_value(t, m.zoom, f32(2))
    testing.expect_value(t, m.pan, [2]f32{0, 0})
}

// The clamp and the empty cases. A step that MEDIA_ZOOM_MAX swallowed must correct by what
// the clamp allowed rather than by what was asked for — otherwise the image slides sideways
// every time the wheel is turned at the end of its range, which is the state a user leans on.
@(test)
test_media_zoom_at_respects_the_clamp :: proc(t: ^testing.T) {
    pane := app.Rect{0, 0, 100, 100}
    m := app.Media {
        w    = 200,
        h    = 100,
        zoom = app.MEDIA_ZOOM_MAX,
    }
    pan := m.pan

    app.media_zoom_at(&m, 4, pane, 10, 10) // already at the ceiling: nothing moves
    testing.expect_value(t, m.zoom, app.MEDIA_ZOOM_MAX)
    testing.expect_value(t, m.pan, pan)

    // Nothing loaded: there is no image to keep under the pointer, and the zoom still takes
    // (so the view is where the user left it when one opens).
    e := app.Media{zoom = 1}
    app.media_zoom_at(&e, 2, pane, 10, 10)
    testing.expect_value(t, e.zoom, f32(2))
    testing.expect_value(t, e.pan, [2]f32{0, 0})
}
