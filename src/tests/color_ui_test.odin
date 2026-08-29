package tests

import app "../slopd"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"

// The colour picker's geometry. ONE claim, and it is the bug the pane shipped with: the hit
// test, the drag and the paint all read `color_row`, so the rail you grab is the rail you see.
// The pane used to compute its rows twice — once for the hit rect and once for the paint —
// and the two disagreed by the top margin, then again by the live format line's height, so
// every rail moved out from under the pointer as soon as the picker was editing a buffer.

@(private = "file")
PANE :: gfx.Rect{0, 0, 200, 280}
@(private = "file")
LH :: f32(16) // the test font's line height; a row is sized from it, not from a fixed 28px

// An App with the picker open on pure red, the pointer live over the pane.
@(private = "file")
color_app :: proc(x, y: i32, has_alpha := false) -> app.App {
    a := app.App {
        scale    = 1,
        face     = gfx.Face{cell_w = 10, line_height = LH},
        mouse_on = true,
        aux_mode = .Color,
        focus    = .Aux,
    }
    a.color = app.ColorPane {
        rgba    = {1, 0, 0, 1},
        hsva    = {0, 1, 1, 1},
        active  = true,
        style   = {kind = .Hex, has_alpha = has_alpha},
        buf_idx = -1,
    }
    a.mouse.known = true
    a.mouse.x, a.mouse.y = x, y
    return a
}

@(private = "file")
press :: proc(a: ^app.App) {
    a.mouse.down = true
    a.mouse.click = true
    a.mouse.click_count = 1
}

// The rows stack without overlapping, each rail sits inside its own row, and the live format
// line pushes EVERY row down by exactly the line it takes — which is the half the old paint
// path knew about and the old hit path did not.
@(test)
test_color_rows_carry_their_rails :: proc(t: ^testing.T) {
    a := color_app(0, 0, true)
    prev := app.color_preview_rect(app.ctx_of(&a), PANE)
    // The ring, then a cell in and a row down: a 3-row swatch.
    testing.expect_value(t, prev, gfx.Rect{12, 18, 176, 48})

    last_bottom := prev.y + prev.h
    for i in 0 ..< 4 {
        row, track := app.color_row(app.ctx_of(&a), &a.color, PANE, i, LH)
        testing.expect(t, row.y >= last_bottom, "rows must not overlap what is above them")
        testing.expect(t, track.y >= row.y + i32(LH), "the rail must clear its label line")
        testing.expect(t, track.y + track.h <= row.y + row.h, "the rail must stay in its row")
        testing.expect_value(t, track.x, row.x)
        testing.expect_value(t, track.w, row.w)
        last_bottom = row.y + row.h
    }

    // The live format line takes a whole row, and it moves the rails, not just the paint: a
    // row that stayed put would sit under the text the picker draws over it.
    dead := color_app(0, 0, true)
    still, _ := app.color_row(app.ctx_of(&dead), &dead.color, PANE, 0, LH)
    a.color.live = true
    row, _ := app.color_row(app.ctx_of(&a), &a.color, PANE, 0, LH)
    testing.expect_value(t, row.y - still.y, i32(LH))
}

// A press anywhere on a row grabs that row's channel and drops it where the pointer is —
// a 6px rail is a pixel hunt, so the row is the target and the rail is only the scale.
@(test)
test_color_click_grabs_the_row_it_landed_on :: proc(t: ^testing.T) {
    a := color_app(0, 0)
    _, track := app.color_row(app.ctx_of(&a), &a.color, PANE, 0, LH)
    row1, _ := app.color_row(app.ctx_of(&a), &a.color, PANE, 1, LH)

    a.mouse.x, a.mouse.y = track.x + track.w / 2, track.y - 2 // on the label line, not the rail
    press(&a)
    app.color_click(app.ctx_of(&a), &a, PANE, LH)

    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Color_Slider, 0), "a press on the hue row must capture it")
    testing.expect(t, !a.mouse.click, "and must claim the press")
    testing.expect_value(t, a.color.sel, 0)
    testing.expect_value(t, a.color.hsva[0], f32(180)) // half way along the hue rail

    // The drag keeps writing that channel wherever the pointer goes — including over another
    // row, which is what capture is for.
    a.mouse.x, a.mouse.y = track.x + track.w, row1.y + 4
    app.color_drag(app.ctx_of(&a), &a, PANE, LH)
    testing.expect_value(t, a.color.hsva[0], f32(360))
    testing.expect_value(t, a.color.hsva[1], f32(1)) // saturation untouched by a hue drag

    // Past either end the channel pins rather than wrapping.
    a.mouse.x = track.x - 500
    app.color_drag(app.ctx_of(&a), &a, PANE, LH)
    testing.expect_value(t, a.color.hsva[0], f32(0))
}

// What the pane refuses: presses outside it, presses on the swatch (a readout, not a control),
// the alpha row when the colour has no alpha, and the mouse switched off.
@(test)
test_color_hit_refuses_what_is_not_a_rail :: proc(t: ^testing.T) {
    a := color_app(0, 0)
    prev := app.color_preview_rect(app.ctx_of(&a), PANE)
    row2, _ := app.color_row(app.ctx_of(&a), &a.color, PANE, 2, LH)
    row3, _ := app.color_row(app.ctx_of(&a), &a.color, PANE, 3, LH)

    a.mouse.x, a.mouse.y = prev.x + 4, prev.y + 4
    testing.expect_value(t, app.color_hit(app.ctx_of(&a), &a.color, PANE, LH), -1)

    a.mouse.x, a.mouse.y = row2.x + 4, row2.y + 4
    testing.expect_value(t, app.color_hit(app.ctx_of(&a), &a.color, PANE, LH), 2)

    a.mouse.y = row3.y + 4 // no alpha channel: the fourth row does not exist
    testing.expect_value(t, app.color_hit(app.ctx_of(&a), &a.color, PANE, LH), -1)
    with_alpha := color_app(a.mouse.x, a.mouse.y, true)
    testing.expect_value(t, app.color_hit(app.ctx_of(&with_alpha), &with_alpha.color, PANE, LH), 3)

    a.mouse.x, a.mouse.y = row2.x + 4, row2.y + 4
    a.mouse_on = false
    testing.expect_value(t, app.color_hit(app.ctx_of(&a), &a.color, PANE, LH), -1)
}

// A press that is somebody else's leaves the picker alone, and one held over the picker does
// not write it — capture is the kind AND the target here as everywhere else.
@(test)
test_color_drag_only_writes_its_own_capture :: proc(t: ^testing.T) {
    a := color_app(0, 0)
    _, track := app.color_row(app.ctx_of(&a), &a.color, PANE, 0, LH)
    a.mouse.x, a.mouse.y = track.x + track.w / 2, track.y
    a.mouse.down = true
    ui.drag_begin(app.ctx_of(&a), .Editor_Text, 0, 1, txt.Pos{}, 0)

    app.color_drag(app.ctx_of(&a), &a, PANE, LH)
    testing.expect_value(t, a.color.hsva[0], f32(0)) // untouched

    outside := color_app(400, 100)
    press(&outside)
    app.color_click(app.ctx_of(&outside), &outside, PANE, LH)
    testing.expect(t, outside.mouse.click, "a press outside the pane must stay pending")
    testing.expect_value(t, outside.drag.kind, ui.Drag_Kind.None)
}

// The rails are their own legend: each shows the colour you would get by dropping the thumb
// there. Hue runs at full saturation on purpose — at value 0 the honest gradient is a black
// bar, which names nothing.
@(test)
test_color_rails_show_what_they_would_do :: proc(t: ^testing.T) {
    a := color_app(0, 0, true)
    a.color.hsva = {0, 1, 0, 0.5} // black, half transparent: the case that eats a naive rail
    a.theme.bg = {0, 0, 0}

    testing.expect_value(t, app.color_track_at(app.ctx_of(&a), &a.color, 0, 1.0 / 3), [3]f32{0, 1, 0}) // 120° green
    testing.expect_value(t, app.color_track_at(app.ctx_of(&a), &a.color, 2, 1), [3]f32{1, 0, 0}) // full value is the hue
    testing.expect_value(t, app.color_track_at(app.ctx_of(&a), &a.color, 3, 0), a.theme.bg) // alpha 0 is the pane

    // And a translucent colour is composited before it is queued — `fill` takes no alpha.
    testing.expect_value(t, app.color_over({1, 1, 1, 0.25}, {0, 0, 0}), [3]f32{0.25, 0.25, 0.25})
}
