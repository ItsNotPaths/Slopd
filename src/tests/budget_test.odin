package tests

import app ".."
import clay "../../bindings/clay"
import "core:fmt"
import "core:testing"

// The element budget, measured rather than reasoned about.
//
// Clay is handed one arena up front, with a hard ceiling on how many elements a frame may
// declare (8192). Overrun is not a slowdown: the error handler fires and the frame is wrong.
//
// Aimed at the densest surface there is, under the conditions that maximise the count: the
// smallest font the program allows in a tall window. It asserts a CEILING rather than an exact
// number, and prints the measured figure so a future reader can see the drift.

@(private = "file")
BUDGET_W :: 1920
@(private = "file")
BUDGET_H :: 2160 // a 4K panel stood on end

// FONT_PX_MIN is 8, and a bitmap-ish 5x8 cell is what that bakes to: the smallest row the
// filetree can be asked to draw.
@(private = "file")
tiny_font :: proc() -> app.Font {
    return app.Font{cell_w = 5, line_height = 8}
}

// A list pane, full of rows, at the smallest font. The editor and the terminal are irrelevant:
// each is three elements whatever the buffer holds, because the text is one Custom.
@(test)
test_element_budget_at_minimum_font :: proc(t: ^testing.T) {
    raw := clay_test_context(BUDGET_W, BUDGET_H)
    defer clay_test_context_free(raw)
    f := tiny_font()
    app.clay_use_font(&f)

    a: app.App
    a.scale = 1
    a.tree.dir = "/tmp/budget"
    _, row_h, rows := app.filetree_geom(app.Rect{0, 0, BUDGET_W, BUDGET_H}, 1, f.line_height)

    // Twice as many entries as fit, so the viewport is genuinely full.
    for i in 0 ..< rows * 2 {
        append(
            &a.tree.entries,
            app.FileEntry{name = "entry", path = "/tmp/budget/entry", display = "entry.odin", is_dir = i % 3 == 0},
        )
    }
    defer delete(a.tree.entries)

    cmds := app.filetree_layout(&a, &f, app.Rect{0, 0, BUDGET_W, BUDGET_H}, BUDGET_W, BUDGET_H)

    fmt.printfln(
        "[budget] filetree at FONT_PX_MIN: row_h=%d rows=%d -> %d render commands (Clay max elements %d)",
        row_h,
        rows,
        cmds.length,
        clay.GetMaxElementCount(),
    )

    // The pane must be the dense case, or the ceiling below proves nothing.
    testing.expect(t, rows > 150, "the fixture did not produce a tall list")

    // Render commands are a proxy for elements — a painting one emits a command, a clip group
    // a pair, a transparent container none — so this is a floor and the right order of
    // magnitude. A quarter of Clay's ceiling is the line.
    testing.expectf(
        t,
        cmds.length < clay.GetMaxElementCount() / 4,
        "%d commands for one pane is close enough to Clay's %d-element ceiling to need a real count",
        cmds.length,
        clay.GetMaxElementCount(),
    )
}
