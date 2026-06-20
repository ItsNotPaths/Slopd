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
