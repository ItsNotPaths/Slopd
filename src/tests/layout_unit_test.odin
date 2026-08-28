package tests

import "core:c"
import "core:testing"
import stbtt "vendor:stb/truetype"
import "../gfx"

// gfx.pad is the layout's only unit below a text row, so a zero one silently deletes every gap,
// inset and focus ring in the program at once. The rest of the suite cannot see that: it measures
// against a synthetic 16px face, which is exactly the value that hides a rounding bug.
//
// This asserts against the REAL vendored font, whose line box at the default 15px size is 15.89 —
// the number that floors to nothing if the unit is rounded before it is scaled.

@(private = "file")
line_height_at :: proc(px: f32) -> f32 {
    ttf, _ := gfx.choose_font()
    info: stbtt.fontinfo
    if !bool(stbtt.InitFont(&info, raw_data(ttf), 0)) {
        return 0
    }
    s := stbtt.ScaleForPixelHeight(&info, px)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
    return f32(ascent - descent + line_gap) * s
}

@(test)
test_layout_unit_survives_the_real_font :: proc(t: ^testing.T) {
    // FONT_BASE_PX, the size the window opens at.
    lh := line_height_at(15)
    testing.expect(t, lh > 15 && lh < 16, "the fixture assumes a line box just under 16")
    testing.expect_value(t, gfx.hairline(lh), i32(2)) // the focus ring it has always been
    testing.expect_value(t, gfx.pad(lh, 8), i32(8)) // and an 8px margin is still 8px

    // FONT_PX_MIN. Chrome may thin out with the text, but it may not vanish.
    small := line_height_at(8)
    testing.expect(t, gfx.hairline(small) >= 1, "the focus ring disappeared at the smallest font")
}

// The DPI scale reaches the layout only through the line box, since the atlas bakes at
// logical_px * scale. Doubling the scale must double every gap, or a HiDPI window draws
// desktop-sized chrome around doubled text.
@(test)
test_layout_unit_tracks_dpi :: proc(t: ^testing.T) {
    one := line_height_at(15)
    two := line_height_at(15 * 2)
    testing.expect_value(t, gfx.hairline(two), 2 * gfx.hairline(one))
    testing.expect_value(t, gfx.pad(two, 8), 2 * gfx.pad(one, 8))
}

// A cell backend's line box is 1, and nothing below a whole cell can be drawn.
@(test)
test_layout_unit_collapses_in_a_grid :: proc(t: ^testing.T) {
    testing.expect_value(t, gfx.hairline(1), i32(0))
    testing.expect_value(t, gfx.pad(1, 5), i32(0))
}
