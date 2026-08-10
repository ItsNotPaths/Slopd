package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// C7: the editor pane declared in Clay, its body painted through a Custom. The claim under
// test is narrower than the list panes' and more important: the painter is UNCHANGED, so
// what could break is the seam — that a pixel read back as a Pos lands on the glyph that
// was painted there. editor_pos_at is the inverse of the painter's row/column arithmetic,
// and the two must agree through a fold, through a scroll offset, and at a gutter width
// that grows with the file.
//
// The pane used throughout is {100, 50, 300, 200} at scale 1, which insets to a content
// area of {102, 52, 296, 196}: an 18px row height (16px line + 2px pad) and 10 whole rows.
// The synthetic font is 10px per cell, so a two-digit gutter puts column 0 at
// area.x + (2 + 2) * 10 = 142.

@(private = "file")
PANE :: app.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: app.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 18
@(private = "file")
ROWS :: 10
@(private = "file")
TEXT_X :: AREA.x + 40 // one-cell margin + 2 gutter digits + one-cell gap, at cw = 10

// An App with one buffer holding `text`. Torn down with editor_destroy, which frees every
// line — the buffer owns its runes, unlike the filetree fixtures' literal strings.
@(private = "file")
fake_editor :: proc(a: ^app.App, text: string) {
    app.editor_init(&a.editor)
    a.scale = 1
    a.mouse_on = true
    a.mouse.known = true
    app.buffer_set_text(app.editor_current(&a.editor), text)
}

// A view built by hand, so the geometry tests do not need an anim, a font or a frame.
// Mirrors what editor_view produces for the pane above at cw = 10 / lh = 16.
@(private = "file")
mkview :: proc(top: int, off: i32, gutter := 2) -> app.Editor_View {
    return app.Editor_View {
        area = AREA,
        row_h = ROW_H,
        rows = ROWS,
        top = top,
        off = off,
        gutter = gutter,
        text_x = app.editor_text_x(AREA.x, gutter, 10),
        cw = 10,
        lh = 16,
    }
}

// Every phase of the frame sizes itself from this one proc. Same shape, and the same
// degenerate cases, as every other pane's geom.
@(test)
test_editor_geom :: proc(t: ^testing.T) {
    area, row_h, rows := app.editor_geom(PANE, 1, 16)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, ROWS) // 196 / 18, floored

    // A hidden pane is a zero rect (compute_layout leaves them so) and must report no rows.
    _, _, none := app.editor_geom(app.Rect{}, 1, 16)
    testing.expect_value(t, none, 0)

    // Too short for a whole row still reports one, as the list panes do: the clip is what
    // keeps an overflowing row inside the pane, not the count.
    _, _, tiny := app.editor_geom(app.Rect{0, 0, 300, 20}, 1, 16)
    testing.expect_value(t, tiny, 1)

    // DPI scale reaches the inset and the row padding both, so the pane stays on the grid.
    area2, row_h2, _ := app.editor_geom(PANE, 2, 32)
    testing.expect_value(t, area2, app.Rect{104, 54, 292, 192})
    testing.expect_value(t, row_h2, i32(36))
}

// The gutter and the text column: the two numbers a click has to share with the painter.
@(test)
test_editor_gutter :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "one\ntwo\nthree")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    // A short file still gets the minimum, so the text column does not jitter left in a
    // scratch buffer.
    testing.expect_value(t, app.editor_gutter_w(b), 2)
    testing.expect_value(t, app.editor_text_x(AREA.x, 2, 10), f32(TEXT_X))

    // ... and grows with the last line number, one cell per digit.
    buf: [dynamic]u8
    defer delete(buf)
    for _ in 0 ..< 120 {
        append(&buf, 'x', '\n')
    }
    app.buffer_set_text(b, string(buf[:]))
    testing.expect_value(t, app.editor_gutter_w(b), 3) // 121 lines
    testing.expect_value(t, app.editor_text_x(AREA.x, 3, 10), f32(AREA.x + 50))
}

// The seam, and the reason this file exists. A point in the pane becomes a Pos through the
// same row grid and text column the painter draws with — including the fold walk, which is
// why a screen row cannot be turned back into a line by arithmetic.
@(test)
test_editor_pos_at :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie\ndelta\necho")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    // Row 0, a few pixels into the first cell: line 0, column 0.
    p, ok := app.editor_pos_at(b, v, TEXT_X + 2, AREA.y + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p, app.Pos{0, 0})

    // Row 2, three cells in: line 2, column 3. The row is (y - area.y) / row_h.
    p, ok = app.editor_pos_at(b, v, TEXT_X + 32, AREA.y + 2 * ROW_H + 5)
    testing.expect(t, ok)
    testing.expect_value(t, p, app.Pos{2, 3})

    // The column ROUNDS: the right half of a cell puts the caret AFTER that glyph, which is
    // what makes selecting up to the end of a word possible without overshooting.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 14, AREA.y + 2) // 1.4 cells
    testing.expect_value(t, p.col, 1)
    p, _ = app.editor_pos_at(b, v, TEXT_X + 16, AREA.y + 2) // 1.6 cells
    testing.expect_value(t, p.col, 2)

    // Past the end of a line clamps to its length, never to the next line's.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p, app.Pos{0, 5}) // len("alpha")

    // A click in the GUTTER is column 0 of that line — the same place Home would put you,
    // and much better than reporting a miss.
    p, ok = app.editor_pos_at(b, v, AREA.x + 5, AREA.y + ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p, app.Pos{1, 0})

    // Below the last line there is nothing: inventing the final line would make a click in
    // empty space jump the caret to the end of the file.
    _, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 5 * ROW_H + 2)
    testing.expect(t, !ok, "a point below the last line must not resolve")

    // SCROLLED, which is the case that hides an off-by-one: the window starts at line 2, so
    // the top row is line 2 and not line 0.
    vs := mkview(2, 0)
    p, _ = app.editor_pos_at(b, vs, TEXT_X, AREA.y + 2)
    testing.expect_value(t, p.line, 2)

    // Mid-tween, the rows are shifted UP by `off`, so the point moves down by it: 6px of an
    // 18px row means the first row's last 12 pixels, then whole rows after.
    vo := mkview(0, 6)
    p, _ = app.editor_pos_at(b, vo, TEXT_X, AREA.y + 11)
    testing.expect_value(t, p.line, 0)
    p, _ = app.editor_pos_at(b, vo, TEXT_X, AREA.y + 13)
    testing.expect_value(t, p.line, 1)
}

// The fold walk: with lines 1..2 collapsed under line 0, the second drawn row is line 3.
// Arithmetic would say line 1, which is hidden — this is the whole reason editor_pos_at
// walks rather than divides.
@(test)
test_editor_pos_at_folded :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody1\nbody2\nafter\ntail")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    append(&b.folds, app.Fold{line = 0, end = 2})
    b.fold_nlines = len(b.lines)
    v := mkview(0, 0)

    p, ok := app.editor_pos_at(b, v, TEXT_X, AREA.y + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 0)

    p, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 3) // NOT 1: lines 1 and 2 are inside the fold

    p, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 2 * ROW_H + 2)
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 4)

    // Only three lines are drawn, so the fourth row is past the end of the document.
    _, ok = app.editor_pos_at(b, v, TEXT_X, AREA.y + 3 * ROW_H + 2)
    testing.expect(t, !ok)
}

// The declaration. The editor's whole command list is ONE Custom — no rectangles, no text —
// because everything visible is painted behind the hatch. The box being exactly the content
// area is what lets editor_pos_at size itself from `area` while the painter positions from
// the resolved box: a declaration that ever inset the body or put a sibling above it fails
// here rather than silently painting the text one place and hit-testing it another.
//
// (Padding on the BODY itself would not trip this and does not need to: Clay puts padding
// inside an element's own box, so it moves the element's children — of which a Custom has
// none — and not the box the painter is handed. Confirmed by mutation, not assumed.)
@(test)
test_editor_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    area, row_h, rows := app.editor_geom(PANE, 1, f.line_height)
    v := app.editor_view(b, &f, area, row_h, rows, 0)
    cmds := app.editor_layout(&a, &f, PANE, 500, 300, v, 0)

    customs, others := 0, 0
    box: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            box = app.clay_rect(c.boundingBox)
        case .None:
        case:
            others += 1
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, others, 0) // panel() paints the frame; this tree declares no fill
    testing.expect_value(t, box, AREA)
}

// A hit is the pane's own rect plus our arithmetic — deliberately NOT clay.PointerOver;
// see test_editor_hit_survives_the_aux_pane for what that costs and why.
@(test)
test_editor_hit :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    // Second row, two cells in.
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos, app.Pos{1, 2})
    testing.expect_value(t, hit.glyph, 2)

    // The two columns diverge in the right half of a cell: 2.6 cells is caret boundary 3
    // (after the glyph) but glyph 2 (the one being pointed at).
    a.mouse.x = TEXT_X + 26
    hit = app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.pos.col, 3)
    testing.expect_value(t, hit.glyph, 2)

    // Off the pane entirely: no hit, and therefore no claim on the press.
    a.mouse.x, a.mouse.y = 10, 10
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)

    // Below the last line is inside the pane but outside the text.
    a.mouse.x, a.mouse.y = TEXT_X + 5, AREA.y + 8 * ROW_H
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)

    // `mouse: off` costs convenience, never capability: the pointer resolves to nothing.
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    a.mouse_on = false
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)
    a.mouse_on = true

    // The media viewer owns the same pane on the Image surface, and has no text to point at.
    a.main = .Image
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.None)
}

// The regression test for the trap C7 fell into. Clay holds exactly ONE tree — BeginLayout
// resets it — and every pane still declares its own, in render()'s order: the editor first,
// the aux pane second. So a frame ends with Clay holding the AUX pane's elements, and an
// editor that asked clay.PointerOver("ed_body") the way the list panes ask about their rows
// would get `false` forever: clicks that never happen, with nothing in a command list to
// show for it. The list panes are not clever here, they are merely LAST.
//
// This declares both panes in the real order and then requires the editor to resolve
// anyway, which is exactly what the pane's own rect buys. It also fails if C8 folds the
// panes into one tree and someone "simplifies" this back to PointerOver without checking
// that the tree really is shared by then.
@(test)
test_editor_hit_survives_the_aux_pane :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "e"})
    defer delete(a.tree.entries)

    area, row_h, rows := app.editor_geom(PANE, 1, f.line_height)
    v := app.editor_view(b, &f, area, row_h, rows, 0)

    // One whole frame, in render()'s order.
    _ = app.editor_layout(&a, &f, PANE, 500, 300, v, 0)
    _ = app.filetree_layout(&a, &f, app.Rect{420, 50, 60, 200}, 500, 300)

    // The next frame's pointer, over the editor. Clay is holding the filetree's tree.
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + ROW_H + 4
    clay.SetPointerState({f32(a.mouse.x), f32(a.mouse.y)}, false)
    testing.expect(
        t,
        !clay.PointerOver(clay.ID("ed_body")),
        "premise changed: the aux pane no longer replaces the editor's tree — re-read this test",
    )

    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos, app.Pos{1, 2})
}

// The fold marker is a BUTTON that happens to sit at the end of a line, so it resolves as
// its own kind rather than as "the caret goes here" — otherwise expanding a block would
// move the caret as a side effect.
@(test)
test_editor_hit_fold_marker :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody\nafter")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    append(&b.folds, app.Fold{line = 0, end = 1})
    b.fold_nlines = len(b.lines)
    v := mkview(0, 0)

    // Just past "header" (6 cells) on the header's row: the marker.
    a.mouse.x, a.mouse.y = TEXT_X + 65, AREA.y + 4
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Fold)
    testing.expect_value(t, hit.pos.line, 0)

    // Well past the marker is ordinary text again (the caret at end of line), so a click in
    // the empty right half of a folded line does not expand it.
    a.mouse.x = TEXT_X + 200
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.Text)

    // The same x on an UNFOLDED line is text: the marker only exists where a fold does.
    a.mouse.x, a.mouse.y = TEXT_X + 65, AREA.y + ROW_H + 4
    testing.expect_value(t, app.editor_hit(&a, b, v).kind, app.Editor_Hit_Kind.Text)
}

// The verbs. Each grade of the click is a different grade of one verb — selection — which
// is why nothing is swallowed here the way a dropdown's second press is (C5b).
@(test)
test_editor_click_verbs :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    press :: proc(a: ^app.App, count: int, shift := false, alt := false) {
        a.mouse.click = true
        a.mouse.click_count = count
        a.mouse.click_shift = shift
        a.mouse.click_alt = alt
    }
    hit :: proc(line, col: int, glyph := -1) -> app.Editor_Hit {
        return app.Editor_Hit{kind = .Text, pos = app.Pos{line, col}, glyph = glyph < 0 ? col : glyph}
    }

    // A plain click places the caret and collapses any selection.
    press(&a, 1)
    app.editor_click(&a, hit(1, 4), 100)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].head, app.Pos{1, 4})
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{1, 4})
    testing.expect(t, !a.mouse.click, "a click on text must be claimed")

    // Shift extends from the anchor rather than moving it.
    press(&a, 1, shift = true)
    app.editor_click(&a, hit(1, 9), 101)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{1, 4})
    testing.expect_value(t, b.cursors[0].head, app.Pos{1, 9})

    // Alt drops a cursor AT the click and makes it the roaming one.
    press(&a, 1, alt = true)
    app.editor_click(&a, hit(0, 2), 102)
    testing.expect_value(t, len(b.cursors), 2)
    testing.expect_value(t, b.cursors[b.primary].head, app.Pos{0, 2})

    // Double click selects the word under it — "bravo", columns 6..11.
    press(&a, 2)
    app.editor_click(&a, hit(0, 8), 103)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 6})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})

    // ... and it selects by the GLYPH pointed at, not by the caret boundary. Pointing at the
    // last letter of "alpha" rounds the caret to column 5 — which is the space — so a word
    // selection taken from the caret column would select the gap instead of the word. One
    // cell of slop, at every word ending; hence the two columns in Editor_Hit.
    press(&a, 2)
    app.editor_click(&a, hit(0, 5, glyph = 4), 104)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 5})

    // Triple click selects the whole line's text.
    press(&a, 3)
    app.editor_click(&a, hit(0, 8), 105)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})

    // A press that hit nothing is left for whoever else is drawing, and the caret stands.
    press(&a, 1)
    app.editor_click(&a, app.Editor_Hit{}, 105)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})

    // `mouse: off`: the keyboard path is untouched, but a press does nothing.
    a.mouse_on = false
    press(&a, 1)
    app.editor_click(&a, hit(1, 0), 106)
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})
}

// A click re-attaches the view the wheel detached — and does it to THIS buffer only. The
// global keystroke timestamp is deliberately left alone: the aux panes re-attach off it
// while they hold focus, and render draws the editor first, so stamping it here would snap
// a wheel-scrolled filetree back to its selection because you clicked somewhere else.
@(test)
test_editor_click_reattaches_scroll :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "a\nb\nc\nd\ne\nf\ng\nh")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    // The aux pane holds focus and has a wheel-detached view of its own.
    a.focus = .Aux
    a.tree.scroll_detached = 50

    app.buffer_scroll_by(b, 4, 50) // the wheel cuts the editor's view loose at t=50
    testing.expect(t, b.scroll_detached > 0)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.editor_click(&a, app.Editor_Hit{kind = .Text, pos = app.Pos{5, 0}}, 60)

    testing.expect_value(t, b.scroll_detached, 0) // this buffer follows its caret again
    testing.expect_value(t, a.last_input_at, 0) // ... and nothing global moved
    testing.expect_value(t, app.pane_input_at(&a), 0) // so the aux pane is not yanked back
    app.filetree_scroll_apply(&a.tree, 4, false, app.pane_input_at(&a))
    testing.expect_value(t, a.tree.scroll_detached, 50) // still where the wheel left it
}

// Clicking the marker EXPANDS, and does nothing else: the caret stays where it was, because
// a fold marker is a button and not a place in the text.
@(test)
test_editor_click_fold_expands :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "header\nbody\nafter")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    append(&b.folds, app.Fold{line = 0, end = 1})
    b.fold_nlines = len(b.lines)

    app.doc_reset_cursor(&b.doc, app.Pos{2, 1})
    a.mouse.click = true
    a.mouse.click_count = 1
    app.editor_click(&a, app.Editor_Hit{kind = .Fold, pos = app.Pos{0, 6}}, 100)

    testing.expect_value(t, len(b.folds), 0)
    testing.expect_value(t, b.cursors[0].head, app.Pos{2, 1}) // the caret did not move
    testing.expect(t, !a.mouse.click, "a click on the marker must be claimed")
}
