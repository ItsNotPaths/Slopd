package tests

import app ".."
import clay "../../bindings/clay"
import "core:fmt"
import "core:testing"

// C9's element-budget check, measured rather than reasoned about.
//
// Clay is handed one arena up front and lives entirely inside it, with a hard ceiling on how
// many elements one frame may declare (8192, upstream's default — clay_ui.odin keeps it).
// Overrun is not a slowdown: the error handler fires and the frame is wrong. Every estimate
// so far has been arithmetic in a comment ("~4 elements per row"), and the case the plan
// named as the one never measured — the git diff column at FONT_PX_MIN — **does not exist any
// more**, because C6 deleted that pane rather than porting it.
//
// So this re-aims the item at the densest surface that DID survive, under the conditions that
// maximise the count: the smallest font the program allows (FONT_PX_MIN = 8) in a tall
// window, which is what turns a pane into hundreds of rows.
//
// It asserts a CEILING rather than an exact number. The point is the order of magnitude and
// the margin — an exact count would fail on any cosmetic change to a row and teach nobody
// anything. The measured figure is printed so a future reader can see the drift.

@(private = "file")
BUDGET_W :: 1920
@(private = "file")
BUDGET_H :: 2160 // a 4K panel stood on end: the tallest pane anyone will realistically have

// A synthetic font at the program's minimum size. FONT_PX_MIN is 8, and a bitmap-ish 5x8
// cell is what that bakes to — the smallest row the filetree can be asked to draw.
@(private = "file")
tiny_font :: proc() -> app.Font {
    return app.Font{cell_w = 5, line_height = 8}
}

// The densest declared surface: a list pane, full of rows, at the smallest font. The editor
// and the terminal are irrelevant here — each is THREE elements whatever the buffer holds,
// because the text is one Custom (C7a, C7b) — which is worth stating, since the intuition
// that a big file means a big tree is exactly backwards in this program.
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

    // Twice as many entries as fit, so the viewport is genuinely full rather than short.
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

    // The pane must actually be the dense case, or the ceiling below proves nothing.
    testing.expect(t, rows > 150, "the fixture did not produce a tall list")

    // Render commands are a proxy for elements — a painting element emits one, a clip group
    // emits a pair, and a transparent container emits none — so this is a floor on elements
    // and the right order of magnitude. A quarter of Clay's ceiling is the line: past that
    // the arena, not the arithmetic, becomes the thing to think about.
    testing.expectf(
        t,
        cmds.length < clay.GetMaxElementCount() / 4,
        "%d commands for one pane is close enough to Clay's %d-element ceiling to need a real count",
        cmds.length,
        clay.GetMaxElementCount(),
    )
}
