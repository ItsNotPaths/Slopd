package tests

import app ".."
import clay "../../bindings/clay"
import "base:runtime"
import "core:fmt"
import "core:testing"

// C1: the renderer bridge. Everything the bridge does that is not a GL call is pure and
// lives here — colour conversion, pixel rounding, clip intersection, text measurement —
// plus the end-to-end claim the bridge rests on: a declared tree comes back as a command
// list whose boxes are on the cell grid, in an order the bridge can paint.
//
// What is NOT tested here is the last hop (fill / text_draw / flush_pane), which needs a
// GL context. That hop is deliberately kept to one line per command type for exactly this
// reason; `--clay-probe` is how it gets looked at.

// Colours cross a 0..255 <-> 0..1 boundary, and the alpha rule is load-bearing: Clay's
// default backgroundColor is fully transparent, so treating it as paintable would fill
// every unstyled container with black.
@(test)
test_clay_color :: proc(t: ^testing.T) {
    col, visible := app.clay_color(clay.Color{255, 128, 0, 255})
    testing.expect(t, visible, "opaque colour reported invisible")
    testing.expect_value(t, col.r, f32(1))
    testing.expect(t, abs(col.g - 128.0 / 255.0) < 1e-6, "green channel lost precision")
    testing.expect_value(t, col.b, f32(0))

    _, unset := app.clay_color(clay.Color{})
    testing.expect(t, !unset, "Clay's unset backgroundColor must not paint")

    // Round trip through the palette direction: a theme slot must come back unchanged.
    back, _ := app.clay_color(app.clay_rgb([3]f32{0.25, 0.5, 1}))
    ok := abs(back.r - 0.25) < 1e-6 && abs(back.g - 0.5) < 1e-6 && back.b == 1
    testing.expect(t, ok, "clay_rgb and clay_color are not inverses")
}

// Clay solves in floats; the renderer draws on whole pixels. Rounding the edges rather
// than the origin and size independently is what keeps two rects that share a boundary
// agreeing about where it is — the seam between a row's background and the next.
@(test)
test_clay_rect_edges :: proc(t: ^testing.T) {
    top := app.clay_rect(clay.BoundingBox{0, 0.5, 10, 16.4})
    bot := app.clay_rect(clay.BoundingBox{0, 16.9, 10, 16.4})
    testing.expect_value(t, top.y + top.h, bot.y) // no gap, no overlap
    testing.expect_value(t, top.y, i32(1))
    testing.expect_value(t, top.h, i32(16))

    // Size is derived from the rounded edges, so a rect can round to one pixel wider or
    // narrower than its float width. That is the point: shared edges beat exact sizes.
    r := app.clay_rect(clay.BoundingBox{0.5, 0, 9, 4})
    testing.expect_value(t, r.x, i32(1))
    testing.expect_value(t, r.w, i32(9))
}

// Nested clip groups become one GL scissor, so nesting is intersection — and a group
// entirely outside its parent must come out empty rather than negative.
@(test)
test_clay_isect :: proc(t: ^testing.T) {
    a := app.Rect{10, 10, 100, 100}
    inner := app.clay_isect(a, app.Rect{50, 50, 100, 100})
    testing.expect_value(t, inner, app.Rect{50, 50, 60, 60})

    off := app.clay_isect(a, app.Rect{500, 500, 10, 10})
    testing.expect_value(t, off.w, i32(0))
    testing.expect_value(t, off.h, i32(0))
}

// Monospace measurement is rune-counted, not byte-counted. A file name with an accent or
// a box-drawing glyph would otherwise measure wide by exactly the bytes UTF-8 spends on
// it — the filetree and grep panes are full of both.
@(test)
test_clay_measure :: proc(t: ^testing.T) {
    f := app.Font {
        cell_w      = 10,
        line_height = 16,
    }
    w, h := app.clay_measure_dims(&f, "abc", 0)
    testing.expect_value(t, w, f32(30))
    testing.expect_value(t, h, f32(16)) // no config line height: the font's

    w2, _ := app.clay_measure_dims(&f, "ünïcøde", 0) // 7 runes, 11 bytes
    testing.expect_value(t, w2, f32(70))

    _, h2 := app.clay_measure_dims(&f, "abc", 20) // a row taller than the line box
    testing.expect_value(t, h2, f32(20))

    w3, h3 := app.clay_measure_dims(nil, "abc", 0) // before a font exists
    testing.expect_value(t, w3, f32(0))
    testing.expect_value(t, h3, f32(0))
}

// Clay reports layout problems through a callback, and the zero ErrorHandler is a NULL
// function pointer it will happily call — so a test that trips an error would crash with
// no diagnosis. Route them somewhere visible.
@(private = "file")
clay_test_error :: proc "c" (e: clay.ErrorData) {
    context = runtime.default_context()
    text := e.errorText.length > 0 ? string(e.errorText.chars[:e.errorText.length]) : "(no detail)"
    fmt.eprintfln("clay error in test [%v]: %s", e.errorType, text)
}

// A Clay context over test-owned memory, aligned the way clay_ui.odin aligns the real
// arena (Clay bump-allocates at 64-byte offsets from the base, so the base's alignment is
// the whole library's). The app's static arena is deliberately NOT used: `odin test` runs
// every test in one process, and clobbering it would leave a live context behind for
// whatever runs next.
@(private = "file")
clay_test_context :: proc(w, h: f32) -> []u8 {
    need := int(clay.MinMemorySize())
    raw := make([]u8, need + app.CLAY_ARENA_ALIGN)
    base := uintptr(raw_data(raw))
    pad := (app.CLAY_ARENA_ALIGN - int(base % app.CLAY_ARENA_ALIGN)) % app.CLAY_ARENA_ALIGN
    mem := raw[pad:]
    arena := clay.CreateArenaWithCapacityAndMemory(len(mem), raw_data(mem))
    clay.Initialize(arena, {w, h}, {handler = clay_test_error})
    return raw
}

// UNLATCH THE CONTEXT BEFORE FREEING — this is not tidiness. Clay keeps the current
// context in a library global, and Clay_MinMemorySize *dereferences* it to inherit its
// limits (clay.h: `if (currentContext) fakeContext.maxElementCount = currentContext->...`).
// Freeing the arena while the global still points into it turns the next MinMemorySize
// call — test_clay_arena_fits, or the next test setting up its own context — into a read
// of freed memory. It segfaults, in a test that did nothing wrong, in whatever order the
// runner happens to pick. The app never hits this only because its arena is static BSS
// that lives as long as the process.
@(private = "file")
clay_test_context_free :: proc(raw: []u8) {
    clay.SetCurrentContext(nil)
    delete(raw)
}

// The tree the command-list tests declare: a pane frame, a header row with a label, and a
// clipped body of three rows where only two fit. Every number is a whole multiple of the
// synthetic cell (10 x 16), so any fractional box in the output is a real finding rather
// than rounding noise.
@(private = "file")
clay_test_tree :: proc() {
    clay.BeginLayout()
    if clay.UI(clay.ID("t_pane"))(
        {
            layout = {
                sizing = {clay.SizingFixed(100), clay.SizingFixed(60)},
                layoutDirection = .TopToBottom,
            },
            backgroundColor = {10, 20, 30, 255},
        },
    ) {
        if clay.UI(clay.ID("t_head"))(
            {
                layout = {
                    sizing = {clay.SizingGrow(), clay.SizingFixed(20)},
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
                    sizing = {clay.SizingGrow(), clay.SizingGrow()},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true},
            },
        ) {
            for i in 0 ..< 3 {
                if clay.UI(clay.ID("t_row", u32(i)))(
                    {
                        layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(20)}},
                        backgroundColor = {f32(i) * 10, 0, 0, 255},
                    },
                ) {}
            }
        }
    }
}

// The end-to-end claim: declare -> command list -> boxes the bridge can paint. Asserted
// against geometry derived from the tree above (pane 100x60 at the origin, a 20-tall
// header, a 40-tall clipped body of 20-tall rows), not against whatever the library
// happened to print.
@(test)
test_clay_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(100, 60)
    defer clay_test_context_free(raw)
    f := app.Font {
        cell_w      = 10,
        line_height = 16,
    }
    app.clay_use_font(&f)

    clay_test_tree()
    cmds := clay.EndLayout(0)

    // Walk once, tallying by type and remembering the boxes worth pinning.
    counts: [10]int
    text_box, scissor_box: app.Rect
    row_boxes: [3]app.Rect
    row_seen: [3]bool
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
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

    // The clip group brackets the body and must balance, or the bridge's flush_pane pairs
    // leave a scissor latched over the rest of the frame.
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorStart)], 1)
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorEnd)], 1)
    testing.expect_value(t, scissor_box, app.Rect{0, 20, 100, 40}) // under the 20-tall header

    // Text: measured through our hook (2 runes x 10px cell, 16px line box) and centred in
    // the 20-tall header, which is the alignment chrome rows will rely on.
    testing.expect_value(t, text_box.w, i32(20))
    testing.expect_value(t, text_box.h, i32(16))
    testing.expect_value(t, text_box.y, i32(2))

    // Rows stack on the grid inside the clip. Row 2 starts at y=60, past the body's
    // bottom edge (60) — whether Clay culls it or emits it for the scissor to cut is the
    // library's call; what must hold is that the two visible rows are exactly placed.
    testing.expect(t, row_seen[0] && row_seen[1], "visible rows missing from the command list")
    testing.expect_value(t, row_boxes[0], app.Rect{0, 20, 100, 20})
    testing.expect_value(t, row_boxes[1], app.Rect{0, 40, 100, 20})
}

// Hit-testing resolves against the PREVIOUS frame's boxes: SetPointerState scans the
// layout Clay already has, so a pointer set before the first declaration hits nothing.
// C2/C3 both depend on this ordering, and it is the kind of thing that reads as a bug in
// the click handler rather than as a frame-ordering rule, so pin it here.
@(test)
test_clay_pointer_over_row :: proc(t: ^testing.T) {
    raw := clay_test_context(100, 60)
    defer clay_test_context_free(raw)
    f := app.Font {
        cell_w      = 10,
        line_height = 16,
    }
    app.clay_use_font(&f)

    clay_test_tree() // frame 1: gives Clay boxes to hit-test against
    _ = clay.EndLayout(0)

    clay.SetPointerState({50, 45}, false) // inside row 1 (y 40..60)
    clay_test_tree() // frame 2
    _ = clay.EndLayout(0)

    testing.expect(t, clay.PointerOver(clay.ID("t_row", 1)), "y=45 did not resolve to row 1")
    testing.expect(t, !clay.PointerOver(clay.ID("t_row", 0)), "y=45 also hit row 0")
    testing.expect(t, clay.PointerOver(clay.ID("t_body")), "the hit skipped the enclosing body")
}
