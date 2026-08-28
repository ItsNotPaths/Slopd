package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"
import "../edit"

// The editor pane declared in Clay, its body painted through a Custom. What is under test is
// the SEAM: a pixel read back as a Pos must land on the glyph painted there. editor_pos_at is
// the inverse of the painter's arithmetic, and the two must agree through a fold, a scroll
// offset, and a gutter width that grows with the file.
//
// The pane throughout is {100, 50, 300, 200} at scale 1, insetting to {102, 52, 296, 196}: an
// 18px row height and 10 whole rows. The synthetic font is 10px per cell, so a two-digit gutter
// puts column 0 at 142.

@(private = "file")
PANE :: gfx.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: gfx.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 18
@(private = "file")
ROWS :: 10
@(private = "file")
TEXT_X :: AREA.x + 40 // margin + 2 gutter digits + gap, at cw = 10

// Torn down with editor_destroy: the buffer owns its runes, unlike the filetree fixtures.
@(private = "file")
fake_editor :: proc(a: ^app.App, text: string) {
    edit.editor_init(&a.editor)
    a.scale = 1
    a.mouse_on = true
    a.mouse.known = true
    edit.buffer_set_text(edit.editor_current(&a.editor), text)
}

// By hand, so the geometry tests need no anim, font or frame. Mirrors editor_view at cw = 10 /
// lh = 16, `hoff` already subtracted from text_x.
@(private = "file")
mkview :: proc(top: int, off: i32, gutter := 2, hoff: f32 = 0) -> app.Editor_View {
    return app.Editor_View {
        area   = AREA,
        row_h  = ROW_H,
        rows   = ROWS,
        top    = top,
        off    = off,
        gutter = gutter,
        text_x = app.editor_text_x(AREA.x, gutter, 10) - hoff,
        cols   = app.editor_cols(AREA, gutter, 10),
        hoff   = hoff,
        cw     = 10,
        lh     = 16,
    }
}

// Same shape and the same degenerate cases as every other pane's geom.
@(test)
test_editor_geom :: proc(t: ^testing.T) {
    area, row_h, rows := app.editor_geom(PANE, 1, 16)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, ROWS) // 196 / 18, floored

    // A hidden pane is a zero rect and must report no rows.
    _, _, none := app.editor_geom(gfx.Rect{}, 1, 16)
    testing.expect_value(t, none, 0)

    // Too short for a whole row still reports one: the clip keeps it inside, not the count.
    _, _, tiny := app.editor_geom(gfx.Rect{0, 0, 300, 20}, 1, 16)
    testing.expect_value(t, tiny, 1)

    // DPI scale reaches the inset and the row padding both.
    area2, row_h2, _ := app.editor_geom(PANE, 2, 32)
    testing.expect_value(t, area2, gfx.Rect{104, 54, 292, 192})
    testing.expect_value(t, row_h2, i32(36))
}

// The two numbers a click has to share with the painter.
@(test)
test_editor_gutter :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "one\ntwo\nthree")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    // A short file still gets the minimum, so the column does not jitter in a scratch buffer.
    testing.expect_value(t, app.editor_gutter_w(b), 2)
    testing.expect_value(t, app.editor_text_x(AREA.x, 2, 10), f32(TEXT_X))

    // …and grows with the last line number, one cell per digit.
    buf: [dynamic]u8
    defer delete(buf)
    for _ in 0 ..< 120 {
        append(&buf, 'x', '\n')
    }
    edit.buffer_set_text(b, string(buf[:]))
    testing.expect_value(t, app.editor_gutter_w(b), 3) // 121 lines
    testing.expect_value(t, app.editor_text_x(AREA.x, 3, 10), f32(AREA.x + 50))
}

// The seam. A point becomes a Pos through the same row grid and text column the painter draws
// with, fold walk included.
@(test)
test_editor_pos_at :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie\ndelta\necho")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    p, ok := app.editor_pos_at(b, v, TEXT_X + 2, AREA.y + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{0, 0})

    // Row 2, three cells in. The row is (y - area.y) / row_h.
    p, ok = app.editor_pos_at(b, v, TEXT_X + 32, AREA.y + 2 * ROW_H + 5)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{2, 3})

    // The column ROUNDS: the right half of a cell puts the caret after that glyph.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 14, AREA.y + 2) // 1.4 cells
    testing.expect_value(t, p.col, 1)
    p, _ = app.editor_pos_at(b, v, TEXT_X + 16, AREA.y + 2) // 1.6 cells
    testing.expect_value(t, p.col, 2)

    // Past the end of a line clamps to its length, never to the next line's.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p, txt.Pos{0, 5}) // len("alpha")

    // A click in the gutter is column 0 of that line, where Home would put you.
    p, ok = app.editor_pos_at(b, v, AREA.x + 5, AREA.y + ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p, txt.Pos{1, 0})

    // Below the last line is nothing: inventing one would jump the caret to end-of-file.
    _, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 5 * ROW_H + 2)
    testing.expect(t, !ok, "a point below the last line must not resolve")

    // Scrolled, the case that hides an off-by-one: the top row is line 2, not line 0.
    vs := mkview(2, 0)
    p, _ = app.editor_pos_at(b, vs, TEXT_X, AREA.y + 2)
    testing.expect_value(t, p.line, 2)

    // Mid-tween the rows shift up by `off`, so the point moves down by it: 6px of an 18px row
    // leaves the first row its last 12 pixels.
    vo := mkview(0, 6)
    p, _ = app.editor_pos_at(b, vo, TEXT_X, AREA.y + 11)
    testing.expect_value(t, p.line, 0)
    p, _ = app.editor_pos_at(b, vo, TEXT_X, AREA.y + 13)
    testing.expect_value(t, p.line, 1)
}

// With lines 1..2 collapsed under line 0, the second drawn row is line 3. Arithmetic would say
// line 1, which is hidden — the whole reason editor_pos_at walks rather than divides.
@(test)
test_editor_pos_at_folded :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody1\nbody2\nafter\ntail")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    append(&b.folds, edit.Fold{line = 0, end = 2})
    v := mkview(0, 0)

    p, ok := app.editor_pos_at(b, v, TEXT_X, AREA.y + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 0)

    p, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 3) // not 1: lines 1 and 2 are inside the fold

    p, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 2 * ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 4)

    // Only three lines are drawn, so the fourth row is past the end.
    _, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 3 * ROW_H + 2)
    testing.expect(t, !ok)
}

// The whole command list is ONE Custom, no rectangles and no text, because everything visible
// is painted behind the hatch. The box being exactly the content area is what lets
// editor_pos_at size itself from `area` while the painter positions from the resolved box, so
// a declaration that inset the body or put a sibling above it fails here.
//
// Padding on the body itself would not trip this and need not: Clay puts padding inside an
// element's box, moving its children, of which a Custom has none.
@(test)
test_editor_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    area, row_h, rows := app.editor_geom(PANE, 1, f.line_height)
    v := app.editor_view(b, &f, area, row_h, rows, 0)
    cmds := app.editor_layout(&a, &f, PANE, 500, 300, v, 0)

    customs, others, scissors := 0, 0, 0
    box, clip: gfx.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            box = ui.clay_rect(c.boundingBox)
        case .ScissorStart:
            scissors += 1
            if c.id == clay.ID("ed_pane").id {
                clip = ui.clay_rect(c.boundingBox)
            }
        case .ScissorEnd:
            scissors += 1
        case .None:
        case:
            others += 1
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, others, 0) // panel() paints the frame; no fill here
    testing.expect_value(t, box, AREA)

    // The pane's own clip, declared where the box is, and what the Custom's painter is handed.
    testing.expect_value(t, scissors, 2)
    testing.expect_value(t, clip, AREA)
}

// The pane's own rect plus our arithmetic, deliberately not clay.PointerOver.
@(test)
test_editor_hit :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos, txt.Pos{1, 2})
    testing.expect_value(t, hit.glyph, 2)

    // The two columns diverge in a cell's right half: 2.6 cells is boundary 3 but glyph 2.
    a.mouse.x = TEXT_X + 26
    hit = app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.pos.col, 3)
    testing.expect_value(t, hit.glyph, 2)

    // Off the pane: no hit, and no claim on the press.
    a.mouse.x, a.mouse.y = 10, 10
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)

    // Inside the pane, outside the text.
    a.mouse.x, a.mouse.y = TEXT_X + 5, AREA.y + 8 * ROW_H
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)

    // `mouse: off`: the pointer resolves to nothing.
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    a.mouse_on = false
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)
    a.mouse_on = true

    // The media viewer owns the same pane on the Image surface, with no text to point at.
    a.main = .Image
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)
}

// Written for a trap: an editor asking clay.PointerOver got `false` forever, because the aux
// pane declared after it and replaced the tree. Kept with its premise inverted now that the
// window is declared once.
//
// Both panes in render()'s order, into one tree, with the editor resolving BOTH ways: through
// Clay, and through its own rect, which is what editor_hit uses and what makes it testable
// without a tree. The two agreeing is the property.
@(test)
test_editor_hit_survives_the_aux_pane :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "e"})
    defer delete(a.tree.entries)

    area, row_h, rows := app.editor_geom(PANE, 1, f.line_height)
    v := app.editor_view(b, &f, area, row_h, rows, 0)

    // One frame in render()'s order: editor first, aux pane second, one tree.
    frame :: proc(a: ^app.App, f: ^gfx.Font, v: app.Editor_View) {
        app.clay_window_begin(500, 300)
        if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(500, 300)) {
            app.editor_declare(a, f, PANE, v, 0)
                    }
        _ = clay.EndLayout(0)
    }
    frame(&a, &f, v)

    // The next frame's pointer, over the editor; the aux pane no longer takes the tree.
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    clay.SetPointerState({f32(a.mouse.x), f32(a.mouse.y)}, false)
    frame(&a, &f, v)
    testing.expect(
        t,
        clay.PointerOver(clay.ID("ed_body")),
        "invariant 11 is back: the aux pane replaced the editor's tree again",
    )

    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos, txt.Pos{1, 2})
}

// A button that happens to sit at the end of a line, so it resolves as its own kind rather than
// "the caret goes here" — otherwise expanding a block would move the caret.
@(test)
test_editor_hit_fold_marker :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody\nafter")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    append(&b.folds, edit.Fold{line = 0, end = 1})
    v := mkview(0, 0)

    // Just past "header" (6 cells) on the header's row: the marker.
    a.mouse.x, a.mouse.y = TEXT_X + 65, AREA.y + 4
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Fold)
    testing.expect_value(t, hit.pos.line, 0)

    // Well past the marker is ordinary text again, so a click in the empty right half of a
    // folded line does not expand it.
    a.mouse.x = TEXT_X + 200
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.Text)

    // The same x on an unfolded line is text: the marker exists only where a fold does.
    a.mouse.x, a.mouse.y = TEXT_X + 65, AREA.y + ROW_H + 4
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.Text)
}

// Each grade of the click is a grade of one verb, selection, which is why nothing is swallowed
// here the way a dropdown's second press is.
@(test)
test_editor_click_verbs :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    press :: proc(a: ^app.App, count: int, shift := false, alt := false) {
        a.mouse.click = true
        a.mouse.click_count = count
        a.mouse.click_shift = shift
        a.mouse.click_alt = alt
    }
    hit :: proc(line, col: int, glyph := -1) -> app.Editor_Hit {
        return app.Editor_Hit{kind = .Text, pos = txt.Pos{line, col}, glyph = glyph < 0 ? col : glyph}
    }

    press(&a, 1)
    app.editor_click(&a, hit(1, 4), 100)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].head, txt.Pos{1, 4})
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{1, 4})
    testing.expect(t, !a.mouse.click, "a click on text must be claimed")

    press(&a, 1, shift = true)
    app.editor_click(&a, hit(1, 9), 101)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{1, 4})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{1, 9})

    press(&a, 1, alt = true)
    app.editor_click(&a, hit(0, 2), 102)
    testing.expect_value(t, len(b.cursors), 2)
    testing.expect_value(t, b.cursors[b.primary].head, txt.Pos{0, 2})

    // Double click selects "bravo", columns 6..11.
    press(&a, 2)
    app.editor_click(&a, hit(0, 8), 103)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 6})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})

    // …by the GLYPH pointed at, not the caret boundary: pointing at the last letter of "alpha"
    // rounds the caret to column 5, the space, so a selection taken from the caret column would
    // take the gap. Hence the two columns in Editor_Hit.
    press(&a, 2)
    app.editor_click(&a, hit(0, 5, glyph = 4), 104)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 5})

    press(&a, 3)
    app.editor_click(&a, hit(0, 8), 105)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})

    // A press that hit nothing is left for whoever else is drawing.
    press(&a, 1)
    app.editor_click(&a, app.Editor_Hit{}, 105)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})

    // `mouse: off`: the keyboard path is untouched, a press does nothing.
    a.mouse_on = false
    press(&a, 1)
    app.editor_click(&a, hit(1, 0), 106)
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})
}

// Re-attaches THIS buffer's view only. The global keystroke timestamp is left alone: the aux
// panes re-attach off it, so stamping it here would snap a wheel-scrolled filetree back.
@(test)
test_editor_click_reattaches_scroll :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "a\nb\nc\nd\ne\nf\ng\nh")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    // The aux pane holds focus and has a detached view of its own.
    a.focus = .Aux
    a.tree.scroll_detached = 50

    edit.buffer_scroll_by(b, 4, 50) // the wheel cuts the view loose at t=50
    testing.expect(t, b.scroll_detached > 0)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.editor_click(&a, app.Editor_Hit{kind = .Text, pos = txt.Pos{5, 0}}, 60)

    testing.expect_value(t, b.scroll_detached, 0) // this buffer follows its caret again
    testing.expect_value(t, a.last_input_at, 0) // and nothing global moved
    testing.expect_value(t, ui.pane_input_at(app.ctx_of(&a)), 0) // so the aux pane is not yanked back
    app.filetree_scroll_apply(&a.tree, 4, false, ui.pane_input_at(app.ctx_of(&a)))
    testing.expect_value(t, a.tree.scroll_detached, 50) // still where the wheel left it
}

// Expands, and does nothing else: a fold marker is a button, not a place in the text.
@(test)
test_editor_click_fold_expands :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody\nafter")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    append(&b.folds, edit.Fold{line = 0, end = 1})

    txt.doc_reset_cursor(&b.doc, txt.Pos{2, 1})
    a.mouse.click = true
    a.mouse.click_count = 1
    app.editor_click(&a, app.Editor_Hit{kind = .Fold, pos = txt.Pos{0, 6}}, 100)

    testing.expect_value(t, len(b.folds), 0)
    testing.expect_value(t, b.cursors[0].head, txt.Pos{2, 1}) // the caret did not move
    testing.expect(t, !a.mouse.click, "a click on the marker must be claimed")
}

// --- the drag --- The press resolves the noun, so it also makes the CAPTURE. Every text click
// begins one, the plain single included, because a press cannot know whether it is a drag. A
// press with the button already up is a completed click and captures nothing (drag_test.odin).
@(test)
test_editor_click_begins_a_drag :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    a.mouse.down = true

    a.mouse.click, a.mouse.click_count = true, 2
    app.editor_click(&a, app.Editor_Hit{kind = .Text, pos = txt.Pos{0, 5}, glyph = 4}, 100)
    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Editor_Text, 0), "a text press captures")
    testing.expect_value(t, a.drag.grade, 2) // granularity, fixed for the gesture
    testing.expect_value(t, a.drag.anchor, txt.Pos{0, 5}) // the caret boundary
    testing.expect_value(t, a.drag.anchor_glyph, 4) // and the glyph beside it

    // A marker is a button, not something you drag out of.
    a.drag = {}
    append(&b.folds, edit.Fold{line = 0, end = 0})
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.Editor_Hit{kind = .Fold, pos = txt.Pos{0, 11}}, 101)
    testing.expect_value(t, a.drag.kind, ui.Drag_Kind.None)
}

// A hit off the pane is refused, since a press there belongs to somebody else; a drag under
// capture answers wherever the pointer went. The clamp is on the ROW, not the pixel: the pane
// is 196px of 18px rows, so its bottom 16px is a row the painter never fills.
@(test)
test_editor_drag_pos_past_the_edges :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\nindia\njuliet\nkilo\nlima")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    // Above the window: the first visible row, not a refusal or a negative one.
    p, glyph := app.editor_drag_pos(b, v, TEXT_X + 22, AREA.y - 400)
    testing.expect_value(t, p, txt.Pos{0, 2})
    testing.expect_value(t, glyph, 2)

    // Below it: the last DRAWN row, 9, not the part-drawn tenth.
    p, _ = app.editor_drag_pos(b, v, TEXT_X + 5, AREA.y + 4000)
    testing.expect_value(t, p.line, 9)

    // Left of the text column is column 0, as a click in the gutter already is.
    p, glyph = app.editor_drag_pos(b, v, 0, AREA.y + ROW_H + 4)
    testing.expect_value(t, p, txt.Pos{1, 0})
    testing.expect_value(t, glyph, 0)

    // Past the end of a line clamps to its length, per line, as the pointer travels.
    p, _ = app.editor_drag_pos(b, v, TEXT_X + 900, AREA.y + ROW_H + 4)
    testing.expect_value(t, p, txt.Pos{1, 5})

    // A buffer shorter than its pane: below the last line is the end of the text, never
    // "nothing".
    short: app.App
    fake_editor(&short, "one\ntwo\nthree")
    defer edit.editor_destroy(&short.editor)
    sb := edit.editor_current(&short.editor)
    p, _ = app.editor_drag_pos(sb, v, TEXT_X + 900, AREA.y + 4000)
    testing.expect_value(t, p, txt.Pos{2, 5})
}

// Moves the HEAD and leaves the anchor alone, which is what makes it compose with the click
// that began it: a Shift+click's anchor is not the press position.
@(test)
test_editor_drag_extends_by_character :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    a.mouse.x, a.mouse.y = TEXT_X + 20, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 2})

    // Down and right: one cursor, the anchor pinned at the press.
    a.mouse.x, a.mouse.y = TEXT_X + 70, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{1, 7})

    // Back over the press point: the selection reverses rather than collapsing.
    a.mouse.x, a.mouse.y = TEXT_X, AREA.y + 4
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 0})

    // The capture is a buffer's: another buffer current leaves the drag held but inert.
    second: edit.Buffer
    txt.doc_init(&second.doc)
    append(&a.editor.buffers, second)
    a.editor.active = 1
    b2 := edit.editor_current(&a.editor)
    edit.buffer_set_text(b2, "second buffer")
    a.mouse.x, a.mouse.y = TEXT_X + 40, AREA.y + 4
    app.editor_drag(&a, b2, v, 103)
    testing.expect_value(t, b2.cursors[0].head, txt.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 0}) // the original stands
}

// Re-derives BOTH ends every frame, which is the difference from "double click selects a word":
// crossing back over the press point moves the ANCHOR from one end of the pressed word to the
// other, which a fixed anchor cannot express.
@(test)
test_editor_drag_word_and_line_grades :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    // Double press inside "bravo" (6..11), pointing at the 'r'.
    a.mouse.x, a.mouse.y = TEXT_X + 72, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 2
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 6})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})

    // Forward into "delta" on the next line: whole words at both ends.
    a.mouse.x, a.mouse.y = TEXT_X + 100, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 6}) // still the start of "bravo"
    testing.expect_value(t, b.cursors[0].head, txt.Pos{1, 13}) // the end of "delta"

    // Backward past the press: the anchor flips to the END of "bravo".
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + 4
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 11})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 0})

    // Line grade: whole lines at both ends, in the direction of travel.
    a.drag.grade = 3
    a.mouse.x, a.mouse.y = TEXT_X + 30, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 103)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{1, 13})
}

// Past an edge the drag walks the SELECTION and the viewport policy follows. Nothing here
// writes b.scroll, which is why it works in either scroll_mode without knowing there are two.
//
// The second frame is the assertion that matters: a drag past the edge is redrawn many times
// per tick, and re-resolving the pointer each frame snaps the selection back to the edge row in
// between, so the scroll and the selection cancel at the frame rate. Hence Drag.over.
@(test)
test_editor_drag_autoscrolls_past_the_edge :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    a.mouse.x, a.mouse.y = TEXT_X, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)

    // One row-height below the bottom edge: seeded at the last drawn row (9), then two lines
    // on the first tick — one for the edge, one for the row height beyond.
    a.mouse.y = AREA.y + AREA.h + ROW_H
    app.editor_drag(&a, b, v, 100)
    testing.expect_value(t, b.cursors[0].head.line, 11)
    testing.expect_value(t, b.scroll, 0) // the selection moved; the view is the policy's

    // Another frame inside the same tick must hold the line, not snap back to row 9.
    app.editor_drag(&a, b, v, 100)
    testing.expect_value(t, b.cursors[0].head.line, 11)

    // The next interval walks on from where the drag got to, not from the edge.
    app.editor_drag(&a, b, v, 100 + ui.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 13)

    // An absolute line, so the view catching up underneath changes nothing — which is what
    // stops the walk double-counting its own scrolling.
    v2 := mkview(3, 0)
    app.editor_drag(&a, b, v2, 100 + 2 * ui.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 14) // the buffer ran out

    // Back inside the pane, the pointer names its own line again, from the scrolled view.
    a.mouse.y = AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v2, 100 + 3 * ui.DRAG_SCROLL_S)
    testing.expect(t, !a.drag.over_on, "the walk is dropped the moment the pointer is back")
    testing.expect_value(t, b.cursors[0].head.line, 4) // top 3, second row

    // Above the top edge it walks the other way, and the anchor holds throughout.
    a.mouse.y = AREA.y - ROW_H
    app.editor_drag(&a, b, v2, 100 + 4 * ui.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, b.scroll, 0)

    // The wheel may detach the view mid-drag, and a detached view does not chase the caret. So
    // walking past an edge re-attaches it, or the selection extends out of sight.
    edit.buffer_scroll_by(b, 2, 100) // the wheel, mid-gesture
    testing.expect(t, b.scroll_detached > 0)
    a.mouse.y = AREA.y + AREA.h + ROW_H
    app.editor_drag(&a, b, v2, 100 + 5 * ui.DRAG_SCROLL_S)
    testing.expect_value(t, b.scroll_detached, 0)
}

// Why it is doc_set_head rather than a span from the press. Both cases here have a press
// position that is NOT the anchor:
//   Shift+click   the anchor is where the previous click left it, and the press is the far end
//   Alt+click     there is a cursor trail, and a span verb would collapse it on the first pixel
// Both bite the same mutation: doc_select_span(a.drag.anchor, p), indistinguishable on a plain
// click and wrong on either of these.
@(test)
test_editor_drag_composes_with_the_click_that_began_it :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    // A plain click at column 2, then a Shift+click at 8: anchor 2, head 8.
    a.mouse.x, a.mouse.y = TEXT_X + 20, AREA.y + 4
    a.mouse.click, a.mouse.click_count, a.mouse.click_shift = true, 1, false
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    a.mouse.x = TEXT_X + 80
    a.mouse.click, a.mouse.click_shift = true, true
    app.editor_click(&a, app.editor_hit(&a, b, v), 101)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 2})

    // Dragging on keeps THAT anchor, not the press it came from.
    a.mouse.x = TEXT_X + 100
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 10})

    // Alt+click drops a cursor and the drag moves that one.
    a.mouse.x, a.mouse.click, a.mouse.click_shift, a.mouse.click_alt = TEXT_X + 30, true, false, true
    app.editor_click(&a, app.editor_hit(&a, b, v), 103)
    testing.expect_value(t, len(b.cursors), 2)

    a.mouse.x = TEXT_X + 60
    app.editor_drag(&a, b, v, 104)
    testing.expect_value(t, len(b.cursors), 2) // the trail survives the drag
    testing.expect_value(t, b.cursors[b.primary].anchor, txt.Pos{0, 3})
    testing.expect_value(t, b.cursors[b.primary].head, txt.Pos{0, 6})
}

// The one-pixel-two-questions split on the DRAG path. Pinned separately, because a press
// anywhere but the last cell of a word gives the same answer either way.
//
// The right half of the last 'a' of "alpha" rounds the caret BOUNDARY to column 5, the space. A
// word drag anchored there expands the whitespace run; anchored on the GLYPH it expands
// "alpha".
@(test)
test_editor_drag_word_grade_uses_the_glyph :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    a.mouse.x, a.mouse.y = TEXT_X + 46, AREA.y + 4 // 4.6 cells: boundary 5, glyph 4
    a.mouse.click, a.mouse.click_count = true, 2
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.pos.col, 5) // the premise: the two columns disagree
    testing.expect_value(t, hit.glyph, 4)
    app.editor_click(&a, hit, 100)

    // Into "bravo". The anchor is the start of "alpha", not of the space the boundary sits in.
    a.mouse.x = TEXT_X + 75
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, b.cursors[0].anchor, txt.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, txt.Pos{0, 11})
}

// --- the horizontal scroll, through the same seam --- The same claim on the other axis, with
// the text column shifted sideways. It holds for one reason: `hoff` is baked into v.text_x, so
// editor_pos_at's arithmetic is untouched.
@(test)
test_editor_pos_at_through_hscroll :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "0123456789abcdefghijklmnopqrstuvwxyz")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    // At home, x = TEXT_X is column 0 and each cell is 10px further right.
    v := mkview(0, 0)
    p, ok := app.editor_pos_at(b, v, TEXT_X + 35, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 4) // the right half of cell 3 is boundary 4

    // Scrolled 12 columns right, the SAME pixel names a column 12 further on.
    v = mkview(0, 0, 2, 120)
    p, ok = app.editor_pos_at(b, v, TEXT_X + 35, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 16)

    // The text region's left edge is the scrolled-to column itself.
    p, _ = app.editor_pos_at(b, v, TEXT_X, 55)
    testing.expect_value(t, p.col, 12)

    // A part-scrolled view is exact rather than snapped.
    v = mkview(0, 0, 2, 124)
    p, _ = app.editor_pos_at(b, v, TEXT_X + 36, 55)
    testing.expect_value(t, p.col, 16)

    // Still clamped to the line, so scrolling past its end cannot invent a column.
    v = mkview(0, 0, 2, 300)
    p, ok = app.editor_pos_at(b, v, TEXT_X + 200, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 36) // the line's length, not column 55
}

// Counts the columns RIGHT OF THE GUTTER, so it shrinks as the line count grows a digit. The
// policy frames the caret into this number and the painter culls to it.
@(test)
test_editor_cols :: proc(t: ^testing.T) {
    // AREA is 296 wide from x = 102; a 2-digit gutter puts column 0 at 142, leaving 256px.
    testing.expect_value(t, app.editor_cols(AREA, 2, 10), 25)
    testing.expect_value(t, app.editor_cols(AREA, 3, 10), 24) // a thousand lines: one narrower
    testing.expect_value(t, app.editor_cols(AREA, 6, 10), 21)

    // Degenerate geometry pins to zero rather than going negative, and the policy then holds
    // the view at home.
    testing.expect_value(t, app.editor_cols(AREA, 2, 0), 0)
    testing.expect_value(t, app.editor_cols(gfx.Rect{102, 52, 10, 196}, 2, 10), 0)
}

// The widest line the window is DRAWING, not the widest in the file. Over the same walk the
// painter uses, so it skips folded lines: a collapsed block's long line must not hold the view
// open.
@(test)
test_editor_longest_visible :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "ab\n0123456789\nxyz\nlonger line here\n")
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    testing.expect_value(t, app.editor_longest_visible(b, 0, 2), 10) // lines 0-1
    testing.expect_value(t, app.editor_longest_visible(b, 0, 4), 16) // through line 3
    testing.expect_value(t, app.editor_longest_visible(b, 2, 2), 16)
    testing.expect_value(t, app.editor_longest_visible(b, 2, 1), 3) // just "xyz"
    testing.expect_value(t, app.editor_longest_visible(b, 0, 0), 0)
}

// --- the byte/cell seam --- A Pos counts BYTES and the pane draws CELLS, so on a row with
// multi-byte runes the two differ for every glyph past the first. Everything above tests the
// seam where they agree; these test it where they cannot.
//
//   h é(2) l l o ␣ →(3) ␣ w ö(2) r l d     13 cells over 17 bytes
//   cell 0 1   2 3 4 5 6   7 8 9  10 11 12
//   byte 0 1   3 4 5 6 7  10 11 12 14 15 16

@(private = "file")
MB :: "héllo → wörld"

// The pane's whole claim on the row that can break it. Checked at every cell rather than a
// chosen one: an off-by-one that only bites past the second multi-byte rune is what a
// hand-picked column misses.
@(test)
test_editor_pos_at_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    cells := txt.doc_cells(&b.doc, 0, context.temp_allocator)
    n := txt.cells_count(cells)
    testing.expect_value(t, n, 13) // cells
    testing.expect_value(t, txt.doc_line_len(&b.doc, 0), 17) // bytes

    for k in 0 ..= n {
        // Cell k's left edge, where the painter starts glyph k.
        p, ok := app.editor_pos_at(b, v, TEXT_X + i32(10 * k), AREA.y + 2)
        testing.expectf(t, ok, "cell %d did not resolve", k)
        testing.expect_value(t, p.line, 0)
        testing.expect_value(t, p.col, txt.cells_off(cells, k)) // reads back as that byte
        testing.expect_value(t, txt.cells_col(cells, p.col), k) // and paints back at that cell
    }

    // The rounding boundary is mid-CELL, not mid-rune: the arrow is three bytes in one cell,
    // and the cell's right half puts the caret past all three at once.
    p, _ := app.editor_pos_at(b, v, TEXT_X + 64, AREA.y + 2) // 6.4 cells
    testing.expect_value(t, p.col, 7) // the arrow's first byte
    p, _ = app.editor_pos_at(b, v, TEXT_X + 66, AREA.y + 2) // 6.6 cells
    testing.expect_value(t, p.col, 10) // past all three of them

    // Past the end clamps to the line's BYTE length, not its cell count.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p, txt.Pos{0, 17})
}

// The GLYPH the pointer is over, floored — and over multi-byte runes that has to name a whole
// rune, or the word it selects starts mid-character.
@(test)
test_editor_hit_glyph_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    // Cell 8 is the 'w' of "wörld"; its right half diverges the two columns, but here they are
    // 12 bytes apart rather than 1.
    a.mouse.x, a.mouse.y = TEXT_X + 86, AREA.y + 2
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos.col, 12) // the boundary: cell 9, the 'ö'
    testing.expect_value(t, hit.glyph, 11) // the glyph: cell 8, the 'w'

    // And the word that comes out is whole, umlaut included.
    txt.doc_select_word(&b.doc, txt.Pos{0, hit.glyph})
    lo, hi := txt.cursor_range(b.cursors[0])
    testing.expect_value(t, txt.doc_text(&b.doc, lo, hi, context.temp_allocator), "wörld")
}

// A drag resolves through editor_drag_pos, which clamps by row rather than refusing, so it
// converts cell to byte separately from editor_hit.
@(test)
test_editor_drag_pos_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)
    v := mkview(0, 0)

    p, glyph := app.editor_drag_pos(b, v, TEXT_X + 86, AREA.y + 2)
    testing.expect_value(t, p, txt.Pos{0, 12})
    testing.expect_value(t, glyph, 11)

    // Past the right edge: the boundary clamps to the byte length, the glyph to the last rune.
    p, glyph = app.editor_drag_pos(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p.col, 17)
    testing.expect_value(t, glyph, 17)
}

// A `:f` hit is a BYTE span painted on the cell grid, so the bar sits over the match rather
// than short of it by one cell per multi-byte rune before it.
@(test)
test_find_marks_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer edit.editor_destroy(&a.editor)
    defer app.find_destroy(&a.find)
    b := edit.editor_current(&a.editor)

    app.find_set(&a.find, b, "wörld", txt.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 1)
    m := a.find.matches[0]
    testing.expect_value(t, m.col, 11) // bytes in
    testing.expect_value(t, m.n, 6) // w ö(2) r l d

    cells := txt.doc_cells(&b.doc, 0, context.temp_allocator)
    testing.expect_value(t, txt.cells_col(cells, m.col), 8) // …cells out
    testing.expect_value(t, txt.cells_col(cells, m.col + m.n), 13) // a 5-cell bar

    // Smart case still folds across the multi-byte rune.
    app.find_set(&a.find, b, "WÖRLD", txt.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 0) // a capital asks for an exact match
    app.find_set(&a.find, b, "wörld", txt.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 1)
}
