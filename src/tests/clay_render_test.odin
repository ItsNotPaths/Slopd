package tests

import clay "../../bindings/clay"
import "core:testing"
import "../gfx"
import "../ui"

// The renderer bridge. Everything it does that is not a GL call is pure and lives here — colour
// conversion, pixel rounding, clip intersection, text measurement — plus the end-to-end claim: a
// declared tree comes back as a command list whose boxes are on the cell grid.
//
// Not tested here is the last hop (fill / text_draw / flush_pane), which needs a GL context.
// That hop is deliberately one line per command type for exactly this reason.

// Colours cross a 0..255 <-> 0..1 boundary, and the alpha rule is load-bearing: Clay's default
// backgroundColor is fully transparent, so treating it as paintable would fill every unstyled
// container with black.
@(test)
test_clay_color :: proc(t: ^testing.T) {
    col, visible := ui.clay_color(clay.Color{255, 128, 0, 255})
    testing.expect(t, visible, "opaque colour reported invisible")
    testing.expect_value(t, col.r, f32(1))
    testing.expect(t, abs(col.g - 128.0 / 255.0) < 1e-6, "green channel lost precision")
    testing.expect_value(t, col.b, f32(0))

    _, unset := ui.clay_color(clay.Color{})
    testing.expect(t, !unset, "Clay's unset backgroundColor must not paint")

    // A theme slot must come back unchanged.
    back, _ := ui.clay_color(ui.clay_rgb([3]f32{0.25, 0.5, 1}))
    ok := abs(back.r - 0.25) < 1e-6 && abs(back.g - 0.5) < 1e-6 && back.b == 1
    testing.expect(t, ok, "clay_rgb and clay_color are not inverses")
}

// Clay solves in floats and the renderer draws on whole pixels. Rounding the edges rather than
// the origin and size independently is what keeps two rects sharing a boundary agreeing.
@(test)
test_clay_rect_edges :: proc(t: ^testing.T) {
    top := ui.clay_rect(clay.BoundingBox{0, 0.5, 10, 16.4})
    bot := ui.clay_rect(clay.BoundingBox{0, 16.9, 10, 16.4})
    testing.expect_value(t, top.y + top.h, bot.y) // no gap, no overlap
    testing.expect_value(t, top.y, i32(1))
    testing.expect_value(t, top.h, i32(16))

    // Size is derived from the rounded edges, so a rect can round a pixel wider or narrower
    // than its float width: shared edges beat exact sizes.
    r := ui.clay_rect(clay.BoundingBox{0.5, 0, 9, 4})
    testing.expect_value(t, r.x, i32(1))
    testing.expect_value(t, r.w, i32(9))
}

// Nested clip groups become one GL scissor, so nesting is intersection, and a group entirely
// outside its parent comes out empty rather than negative.
@(test)
test_clay_isect :: proc(t: ^testing.T) {
    a := gfx.Rect{10, 10, 100, 100}
    inner := ui.clay_isect(a, gfx.Rect{50, 50, 100, 100})
    testing.expect_value(t, inner, gfx.Rect{50, 50, 60, 60})

    off := ui.clay_isect(a, gfx.Rect{500, 500, 10, 10})
    testing.expect_value(t, off.w, i32(0))
    testing.expect_value(t, off.h, i32(0))
}

// Rune-counted, not byte-counted: a file name with an accent or a box-drawing glyph would
// otherwise measure wide by the bytes UTF-8 spends on it.
@(test)
test_clay_measure :: proc(t: ^testing.T) {
    f := gfx.Face {
        cell_w      = 10,
        line_height = 16,
    }
    w, h := ui.clay_measure_dims(&f, "abc", 0)
    testing.expect_value(t, w, f32(30))
    testing.expect_value(t, h, f32(16)) // no config line height, so the font's

    w2, _ := ui.clay_measure_dims(&f, "ünïcøde", 0) // 7 runes, 11 bytes
    testing.expect_value(t, w2, f32(70))

    _, h2 := ui.clay_measure_dims(&f, "abc", 20) // a row taller than the line box
    testing.expect_value(t, h2, f32(20))

    w3, h3 := ui.clay_measure_dims(nil, "abc", 0) // before a font exists
    testing.expect_value(t, w3, f32(0))
    testing.expect_value(t, h3, f32(0))
}

// The context helpers live in clay_harness.odin, since every test that declares a tree needs
// them and the traps they carry are shared.

// A pane frame, a header row with a label, and a clipped body of three rows where two fit. Every
// number is a whole multiple of the synthetic cell, so any fractional box is a real finding.
@(private = "file")
clay_test_tree :: proc() {
    clay.BeginLayout()
    if clay.UI(clay.ID("t_pane"))(
        {
            layout = {
                sizing          = {clay.SizingFixed(100), clay.SizingFixed(60)},
                layoutDirection = .TopToBottom,
            },
            backgroundColor = {10, 20, 30, 255},
        },
    ) {
        if clay.UI(clay.ID("t_head"))(
            {
                layout = {
                    sizing         = {clay.SizingGrow(), clay.SizingFixed(20)},
                    childAlignment = {y = .Center},
                },
                backgroundColor = {40, 40, 40, 255},
            },
        ) {
            clay.Text("ab", {textColor = {255, 255, 255, 255}, lineHeight = 16, wrapMode = .None})
        }
        if clay.UI(clay.ID("t_body"))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingGrow()},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true},
            },
        ) {
            for i in 0 ..< 3 {
                if clay.UI(clay.ID("t_row", u32(i)))(
                    {
                        layout          = {sizing = {clay.SizingGrow(), clay.SizingFixed(20)}},
                        backgroundColor = {f32(i) * 10, 0, 0, 255},
                    },
                ) {}
            }
        }
    }
}

// declare -> command list -> boxes the bridge can paint, asserted against geometry derived from
// the tree above rather than whatever the library printed.
@(test)
test_clay_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(100, 60)
    defer clay_test_context_free(raw)
    f := gfx.Face {
        cell_w      = 10,
        line_height = 16,
    }
    ui.clay_use_face(&f)

    clay_test_tree()
    cmds := clay.EndLayout(0)

    // One walk, tallying by type and keeping the boxes worth pinning.
    counts: [10]int
    text_box, scissor_box: gfx.Rect
    row_boxes: [3]gfx.Rect
    row_seen: [3]bool
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := ui.clay_rect(c.boundingBox)
        counts[int(c.commandType)] += 1
        #partial switch c.commandType {
        case .Text:
            text_box = r
        case .ScissorStart:
            scissor_box = r
        case .Rectangle:
            for j in 0 ..< 3 {
                if c.id == clay.ID("t_row", u32(j)).id {
                    row_boxes[j] = r
                    row_seen[j] = true
                }
            }
        }
    }

    testing.expectf(t, cmds.length > 0, "EndLayout returned no commands — Clay is not laying out")
    testing.expect_value(t, counts[int(clay.RenderCommandType.Text)], 1)

    // The clip group brackets the body and must balance, or a scissor latches over the rest
    // of the frame.
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorStart)], 1)
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorEnd)], 1)
    testing.expect_value(t, scissor_box, gfx.Rect{0, 20, 100, 40}) // under the header

    // Measured through our hook and centred in the 20-tall header, which is the alignment
    // chrome rows rely on.
    testing.expect_value(t, text_box.w, i32(20))
    testing.expect_value(t, text_box.h, i32(16))
    testing.expect_value(t, text_box.y, i32(2))

    // Rows stack on the grid inside the clip. Row 2 starts past the body's bottom edge, and
    // whether Clay culls it or emits it for the scissor is the library's call.
    testing.expect(t, row_seen[0] && row_seen[1], "visible rows missing from the command list")
    testing.expect_value(t, row_boxes[0], gfx.Rect{0, 20, 100, 20})
    testing.expect_value(t, row_boxes[1], gfx.Rect{0, 40, 100, 20})
}

// Against the PREVIOUS frame's boxes: SetPointerState scans the layout Clay already has, so a
// pointer set before the first declaration hits nothing. It reads as a bug in the click handler
// rather than a frame-ordering rule, so it is pinned here.
@(test)
test_clay_pointer_over_row :: proc(t: ^testing.T) {
    raw := clay_test_context(100, 60)
    defer clay_test_context_free(raw)
    f := gfx.Face {
        cell_w      = 10,
        line_height = 16,
    }
    ui.clay_use_face(&f)

    clay_test_tree() // frame 1: boxes to hit-test against
    _ = clay.EndLayout(0)

    clay.SetPointerState({50, 45}, false) // inside row 1 (y 40..60)
    clay_test_tree() // frame 2
    _ = clay.EndLayout(0)

    testing.expect(t, clay.PointerOver(clay.ID("t_row", 1)), "y=45 did not resolve to row 1")
    testing.expect(t, !clay.PointerOver(clay.ID("t_row", 0)), "y=45 also hit row 0")
    testing.expect(t, clay.PointerOver(clay.ID("t_body")), "the hit skipped the enclosing body")
}
