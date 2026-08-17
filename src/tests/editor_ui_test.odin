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
// Mirrors what editor_view produces for the pane above at cw = 10 / lh = 16 — including its
// one subtlety: `hoff` is already SUBTRACTED from text_x, which is what lets every column
// conversion downstream stay ignorant of the horizontal scroll.
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

    customs, others, scissors := 0, 0, 0
    box, clip: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            box = app.clay_rect(c.boundingBox)
        case .ScissorStart:
            scissors += 1
            if c.id == clay.ID("ed_pane").id {
                clip = app.clay_rect(c.boundingBox)
            }
        case .ScissorEnd:
            scissors += 1
        case .None:
        case:
            others += 1
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, others, 0) // panel() paints the frame; this tree declares no fill
    testing.expect_value(t, box, AREA)

    // The pane's own clip, and the whole of what C8a's single tree cost this pane: the
    // per-pane clay_paint that used to be handed the pane rect is gone, so the clip is
    // declared where the box is. It is also what the Custom's painter is handed as `clip`.
    testing.expect_value(t, scissors, 2)
    testing.expect_value(t, clip, AREA)
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

// Written for the trap C7 fell into — an editor that asked clay.PointerOver got `false`
// forever, because the aux pane declared after it and replaced the tree — and kept, with its
// premise inverted, now that C8a declares the window once.
//
// It declares both panes in render()'s order, into ONE tree, and asserts the editor resolves
// BOTH ways: through Clay, which is the retirement of invariant 11, and through its own rect,
// which is what editor_hit actually uses and what makes it testable without a tree. The two
// answers agreeing is the property; if they ever stop, one of the two is lying about where
// the pane is. (tests/window_ui_test.odin is where the retirement itself is pinned; this is
// the editor's own stake in it.)
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

    // One whole frame, in render()'s order: editor first, aux pane second, one tree.
    frame :: proc(a: ^app.App, f: ^app.Font, v: app.Editor_View) {
        app.clay_window_begin(500, 300)
        if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(500, 300)) {
            app.editor_declare(a, f, PANE, v, 0)
                    }
        _ = clay.EndLayout(0)
    }
    frame(&a, &f, v)

    // The next frame's pointer, over the editor — and the aux pane, declared after it, no
    // longer takes the tree with it.
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

    app.doc_reset_cursor(&b.doc, app.Pos{2, 1})
    a.mouse.click = true
    a.mouse.click_count = 1
    app.editor_click(&a, app.Editor_Hit{kind = .Fold, pos = app.Pos{0, 6}}, 100)

    testing.expect_value(t, len(b.folds), 0)
    testing.expect_value(t, b.cursors[0].head, app.Pos{2, 1}) // the caret did not move
    testing.expect(t, !a.mouse.click, "a click on the marker must be claimed")
}

// --- C7c: the drag ---
//
// The press is where the noun is resolved, so it is also where the CAPTURE is made. Every
// text click begins one, including the plain single one, because the difference between a
// click and a drag is not something the press can know — it is whether the pointer moves
// before the release. A press with the button already up is a completed click and captures
// nothing (drag_test.odin holds that half).
@(test)
test_editor_click_begins_a_drag :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    a.mouse.down = true

    a.mouse.click, a.mouse.click_count = true, 2
    app.editor_click(&a, app.Editor_Hit{kind = .Text, pos = app.Pos{0, 5}, glyph = 4}, 100)
    testing.expect(t, app.drag_live(&a, .Editor_Text, 0), "a text press captures")
    testing.expect_value(t, a.drag.grade, 2) // the GRANULARITY, fixed for the whole gesture
    testing.expect_value(t, a.drag.anchor, app.Pos{0, 5}) // the caret boundary
    testing.expect_value(t, a.drag.anchor_glyph, 4) // and the glyph beside it

    // A fold marker is a BUTTON, and a button is not something you drag out of.
    a.drag = {}
    append(&b.folds, app.Fold{line = 0, end = 0})
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.Editor_Hit{kind = .Fold, pos = app.Pos{0, 11}}, 101)
    testing.expect_value(t, a.drag.kind, app.Drag_Kind.None)
}

// Where a drag POINTS, which is not where a hit lands. A hit off the pane is refused,
// because a press there belongs to somebody else; a drag under capture must answer wherever
// the pointer went, because the gesture is already this pane's.
//
// The clamp is on the ROW, not on the pixel, and that is the assertion with teeth: the pane
// is 196px of 18px rows, so its bottom 16px is a row the painter never fills, and a pixel
// clamp would aim the drag at a line that is not on screen.
@(test)
test_editor_drag_pos_past_the_edges :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\nhotel\nindia\njuliet\nkilo\nlima")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    // Above the window: the first visible row, not a refusal and not a negative row.
    p, glyph := app.editor_drag_pos(b, v, TEXT_X + 22, AREA.y - 400)
    testing.expect_value(t, p, app.Pos{0, 2})
    testing.expect_value(t, glyph, 2)

    // Below it: the last DRAWN row, which is row 9 (ROWS = 10) and not the part-drawn tenth.
    p, _ = app.editor_drag_pos(b, v, TEXT_X + 5, AREA.y + 4000)
    testing.expect_value(t, p.line, 9)

    // Left of the text column — the gutter, or off the window entirely — is column 0, the
    // same rule a click in the gutter already follows.
    p, glyph = app.editor_drag_pos(b, v, 0, AREA.y + ROW_H + 4)
    testing.expect_value(t, p, app.Pos{1, 0})
    testing.expect_value(t, glyph, 0)

    // Past the end of a line clamps to its length, per line, as the pointer travels.
    p, _ = app.editor_drag_pos(b, v, TEXT_X + 900, AREA.y + ROW_H + 4)
    testing.expect_value(t, p, app.Pos{1, 5})

    // A buffer SHORTER than its pane: below the last line is the end of the text, never
    // "nothing" — dragging off the bottom of a three-line file selects to the end of it.
    short: app.App
    fake_editor(&short, "one\ntwo\nthree")
    defer app.editor_destroy(&short.editor)
    sb := app.editor_current(&short.editor)
    p, _ = app.editor_drag_pos(sb, v, TEXT_X + 900, AREA.y + 4000)
    testing.expect_value(t, p, app.Pos{2, 5})
}

// A character drag moves the HEAD and leaves the anchor alone — which is what makes it
// compose with the click that began it: a Shift+click's anchor is not the press position,
// and an Alt+click's cursor is the new one, and neither wants re-anchoring per frame.
@(test)
test_editor_drag_extends_by_character :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    // Press at line 0 column 2.
    a.mouse.x, a.mouse.y = TEXT_X + 20, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 2})

    // Drag down and right: one cursor, the anchor pinned at the press.
    a.mouse.x, a.mouse.y = TEXT_X + 70, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, len(b.cursors), 1)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, app.Pos{1, 7})

    // Back over the press point: the selection reverses rather than collapsing, and the
    // anchor still has not moved.
    a.mouse.x, a.mouse.y = TEXT_X, AREA.y + 4
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 0})

    // The capture is a buffer's, not the editor's: another buffer current means the drag is
    // held but inert, rather than writing into somebody else's text.
    second: app.Buffer
    app.doc_init(&second.doc)
    append(&a.editor.buffers, second)
    a.editor.active = 1
    b2 := app.editor_current(&a.editor)
    app.buffer_set_text(b2, "second buffer")
    a.mouse.x, a.mouse.y = TEXT_X + 40, AREA.y + 4
    app.editor_drag(&a, b2, v, 103)
    testing.expect_value(t, b2.cursors[0].head, app.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 0}) // and the original stands
}

// A word drag re-derives BOTH ends every frame, which is the difference between "double
// click selects a word" and word-grade dragging: crossing back over the press point has to
// move the ANCHOR from one end of the pressed word to the other, and a machine holding a
// fixed anchor cannot express that.
@(test)
test_editor_drag_word_and_line_grades :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    // Double press inside "bravo" (columns 6..11), pointing at the 'r'.
    a.mouse.x, a.mouse.y = TEXT_X + 72, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 2
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 6})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})

    // Drag forward into "delta" on the next line: whole words at both ends.
    a.mouse.x, a.mouse.y = TEXT_X + 100, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 6}) // still the start of "bravo"
    testing.expect_value(t, b.cursors[0].head, app.Pos{1, 13}) // the end of "delta"

    // Drag backward past the press, into "alpha": the anchor flips to the END of "bravo"
    // and the head takes the START of "alpha".
    a.mouse.x, a.mouse.y = TEXT_X + 22, AREA.y + 4
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 11})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 0})

    // Line grade: whole lines at both ends, in the direction of travel.
    a.drag.grade = 3
    a.mouse.x, a.mouse.y = TEXT_X + 30, AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v, 103)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, app.Pos{1, 13})
}

// Autoscroll: past an edge, the drag walks the SELECTION further and the existing viewport
// policy follows it. **Nothing here writes b.scroll.** That is the whole design, and it is
// why the drag scrolls correctly in either scroll_mode without knowing there are two.
//
// The second frame is the assertion that matters, and it is the one that found the bug this
// proc was rebuilt around: a drag past the edge is redrawn many times per tick, and an
// implementation that re-resolves the pointer each frame snaps the selection back to the
// edge row in between — which re-aims the viewport policy at the line it just left, so the
// scroll and the selection cancel each other at the frame rate. Hence Drag.over.
@(test)
test_editor_drag_autoscrolls_past_the_edge :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    a.mouse.x, a.mouse.y = TEXT_X, AREA.y + 4
    a.mouse.click, a.mouse.click_count = true, 1
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)

    // One row-height below the bottom edge: seeded at the last DRAWN row (9), then two lines
    // of walk on the first tick — one for the edge, one for the row height beyond it.
    a.mouse.y = AREA.y + AREA.h + ROW_H
    app.editor_drag(&a, b, v, 100)
    testing.expect_value(t, b.cursors[0].head.line, 11)
    testing.expect_value(t, b.scroll, 0) // the SELECTION moved; the view is the policy's job

    // Another frame inside the same tick — a motion event, a caret blink, anything — must
    // hold the line rather than snapping back to row 9.
    app.editor_drag(&a, b, v, 100)
    testing.expect_value(t, b.cursors[0].head.line, 11)

    // The next interval walks on from where the drag GOT to, not from the edge again.
    app.editor_drag(&a, b, v, 100 + app.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 13)

    // And it is an absolute line, so the view catching up underneath it changes nothing —
    // which is exactly what stops the walk double-counting its own scrolling.
    v2 := mkview(3, 0)
    app.editor_drag(&a, b, v2, 100 + 2 * app.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 14) // the last line: the buffer ran out

    // Back inside the pane and the pointer names its own line again, from the scrolled view.
    a.mouse.y = AREA.y + ROW_H + 4
    app.editor_drag(&a, b, v2, 100 + 3 * app.DRAG_SCROLL_S)
    testing.expect(t, !a.drag.over_on, "the walk is dropped the moment the pointer is back")
    testing.expect_value(t, b.cursors[0].head.line, 4) // top 3, second row

    // Above the top edge it walks the other way, and the anchor still holds throughout.
    a.mouse.y = AREA.y - ROW_H
    app.editor_drag(&a, b, v2, 100 + 4 * app.DRAG_SCROLL_S)
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, b.scroll, 0)

    // The wheel may detach the view mid-drag while the pointer is still inside the pane —
    // scroll with one hand, extend with the other — but a detached view does not chase the
    // caret. So walking past an edge re-attaches it, or the selection would go on extending
    // somewhere nobody can see.
    app.buffer_scroll_by(b, 2, 100) // the wheel, mid-gesture
    testing.expect(t, b.scroll_detached > 0)
    a.mouse.y = AREA.y + AREA.h + ROW_H
    app.editor_drag(&a, b, v2, 100 + 5 * app.DRAG_SCROLL_S)
    testing.expect_value(t, b.scroll_detached, 0)
}

// A character drag composes with the modifier that began it, and that is why it is
// doc_set_head rather than a span from the press. Both cases here are ones where the press
// position is NOT the anchor:
//
//   Shift+click   the anchor is wherever the previous click left it, and the press is the
//                 far end — so anchoring the drag at the press throws the extend away
//   Alt+click     there is a cursor trail, and the drag moves the new roaming cursor; a
//                 span verb would collapse the trail on the first pixel of movement
//
// The mutation both bite: replacing doc_set_head with doc_select_span(a.drag.anchor, p),
// which is indistinguishable on a plain click and wrong on either of these.
@(test)
test_editor_drag_composes_with_the_click_that_began_it :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    // A plain click at column 2, then a Shift+click at column 8: anchor 2, head 8.
    a.mouse.x, a.mouse.y = TEXT_X + 20, AREA.y + 4
    a.mouse.click, a.mouse.click_count, a.mouse.click_shift = true, 1, false
    app.editor_click(&a, app.editor_hit(&a, b, v), 100)
    a.mouse.x = TEXT_X + 80
    a.mouse.click, a.mouse.click_shift = true, true
    app.editor_click(&a, app.editor_hit(&a, b, v), 101)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 2})

    // Dragging on from the Shift+click keeps THAT anchor, not the press it came from.
    a.mouse.x = TEXT_X + 100
    app.editor_drag(&a, b, v, 102)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 2})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 10})

    // Alt+click drops a cursor and the drag moves that one, leaving the trail intact.
    a.mouse.x, a.mouse.click, a.mouse.click_shift, a.mouse.click_alt = TEXT_X + 30, true, false, true
    app.editor_click(&a, app.editor_hit(&a, b, v), 103)
    testing.expect_value(t, len(b.cursors), 2)

    a.mouse.x = TEXT_X + 60
    app.editor_drag(&a, b, v, 104)
    testing.expect_value(t, len(b.cursors), 2) // the trail survives the drag
    testing.expect_value(t, b.cursors[b.primary].anchor, app.Pos{0, 3})
    testing.expect_value(t, b.cursors[b.primary].head, app.Pos{0, 6})
}

// C7a's one-pixel-two-questions split, arriving on the DRAG path — and it had to be pinned
// separately, because a press taken anywhere but the last cell of a word gives the same
// answer either way and hides the bug completely.
//
// Pressing the right half of the last 'a' of "alpha" rounds the caret BOUNDARY to column 5,
// which is the space. A word-grade drag anchored on that boundary expands the whitespace run
// instead of the word, at every word ending in the file; anchored on the GLYPH it expands
// "alpha", which is the word the pointer is on.
@(test)
test_editor_drag_word_grade_uses_the_glyph :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "alpha bravo\ncharlie delta")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)
    a.mouse.down = true

    a.mouse.x, a.mouse.y = TEXT_X + 46, AREA.y + 4 // 4.6 cells: boundary 5, glyph 4
    a.mouse.click, a.mouse.click_count = true, 2
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.pos.col, 5) // the premise: the two columns disagree here
    testing.expect_value(t, hit.glyph, 4)
    app.editor_click(&a, hit, 100)

    // Drag forward into "bravo". The anchor is the start of "alpha", not the start of the
    // space that the rounded boundary sits in.
    a.mouse.x = TEXT_X + 75
    app.editor_drag(&a, b, v, 101)
    testing.expect_value(t, b.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, b.cursors[0].head, app.Pos{0, 11})
}

// --- the horizontal scroll, through the same seam ---
//
// The claim this file exists for, on the other axis: a pixel read back as a Pos must land
// on the glyph painted there, with the text column shifted sideways too. It holds for one
// reason — `hoff` is baked into v.text_x, so editor_pos_at's arithmetic is untouched — and
// that is exactly the kind of invariant that survives by being pinned rather than by being
// true when it was written.
@(test)
test_editor_pos_at_through_hscroll :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "0123456789abcdefghijklmnopqrstuvwxyz")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    // At home, x = TEXT_X is column 0 and each cell is 10px further right.
    v := mkview(0, 0)
    p, ok := app.editor_pos_at(b, v, TEXT_X + 35, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 4) // rounds: the right half of cell 3 is boundary 4

    // Scrolled 12 columns (120px) right, the SAME pixel now names a column 12 further on.
    v = mkview(0, 0, 2, 120)
    p, ok = app.editor_pos_at(b, v, TEXT_X + 35, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 16)

    // The left edge of the text region is the scrolled-to column itself.
    p, _ = app.editor_pos_at(b, v, TEXT_X, 55)
    testing.expect_value(t, p.col, 12)

    // A part-scrolled view (mid-tween, 4px into a cell) is still exact rather than snapped.
    v = mkview(0, 0, 2, 124)
    p, _ = app.editor_pos_at(b, v, TEXT_X + 36, 55)
    testing.expect_value(t, p.col, 16)

    // The column is still clamped to the line, so scrolling past its end cannot invent one.
    v = mkview(0, 0, 2, 300)
    p, ok = app.editor_pos_at(b, v, TEXT_X + 200, 55)
    testing.expect(t, ok)
    testing.expect_value(t, p.col, 36) // the line's length: end-of-line, not column 55
}

// editor_cols counts the columns RIGHT OF THE GUTTER, so it shrinks as the line count grows
// a digit. The policy frames the caret into this number and the painter culls to it, so a
// disagreement here settles the view on a column the painter then declines to draw.
@(test)
test_editor_cols :: proc(t: ^testing.T) {
    // AREA is 296 wide from x = 102; a 2-digit gutter puts column 0 at 142, leaving 256px.
    testing.expect_value(t, app.editor_cols(AREA, 2, 10), 25)
    testing.expect_value(t, app.editor_cols(AREA, 3, 10), 24) // a thousand-line file: one cell narrower
    testing.expect_value(t, app.editor_cols(AREA, 6, 10), 21)

    // Degenerate geometry pins to zero rather than going negative — buffer_hscroll_target
    // then holds the view at home, which is what a pane with no text region should show.
    testing.expect_value(t, app.editor_cols(AREA, 2, 0), 0)
    testing.expect_value(t, app.editor_cols(app.Rect{102, 52, 10, 196}, 2, 10), 0)
}

// The bound the column axis is clamped against: the widest line the window is DRAWING, not
// the widest in the file. Measured over the same walk the painter uses, so it skips folded
// lines — a collapsed block's long line is not on screen and must not hold the view open.
@(test)
test_editor_longest_visible :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, "ab\n0123456789\nxyz\nlonger line here\n")
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)

    testing.expect_value(t, app.editor_longest_visible(b, 0, 2), 10) // lines 0-1
    testing.expect_value(t, app.editor_longest_visible(b, 0, 4), 16) // through line 3
    testing.expect_value(t, app.editor_longest_visible(b, 2, 2), 16)
    testing.expect_value(t, app.editor_longest_visible(b, 2, 1), 3) // just "xyz"
    testing.expect_value(t, app.editor_longest_visible(b, 0, 0), 0)
}

// --- the byte/cell seam ---
//
// A Pos counts BYTES and the pane draws a grid of CELLS, so on a row holding multi-byte runes
// the two are different numbers for every glyph past the first of them. Everything above tests
// the seam where they happen to agree; these test it where they cannot.
//
//   h é(2) l l o ␣ →(3) ␣ w ö(2) r l d     13 cells over 17 bytes
//   cell 0 1   2 3 4 5 6   7 8 9  10 11 12
//   byte 0 1   3 4 5 6 7  10 11 12 14 15 16

@(private = "file")
MB :: "héllo → wörld"

// The pane's whole claim, on the row that can break it: a pixel read back as a Pos, painted
// back at the cell the painter would put it in, lands on the pixel it came from. Checked at
// every cell of the row rather than at a chosen one — an off-by-one that only bites past the
// second multi-byte rune is exactly what a hand-picked column misses.
@(test)
test_editor_pos_at_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    cells := app.doc_cells(&b.doc, 0, context.temp_allocator)
    n := app.cells_count(cells)
    testing.expect_value(t, n, 13) // cells
    testing.expect_value(t, app.doc_line_len(&b.doc, 0), 17) // bytes

    for k in 0 ..= n {
        // The pixel at cell k's left edge — where the painter starts glyph k.
        p, ok := app.editor_pos_at(b, v, TEXT_X + i32(10 * k), AREA.y + 2)
        testing.expectf(t, ok, "cell %d did not resolve", k)
        testing.expect_value(t, p.line, 0)
        testing.expect_value(t, p.col, app.cells_off(cells, k)) // reads back as that glyph's byte
        testing.expect_value(t, app.cells_col(cells, p.col), k) // and paints back at that cell
    }

    // The rounding boundary sits mid-CELL, not mid-rune: the arrow is three bytes in one cell,
    // and it is the cell's right half that puts the caret past it — all three bytes at once.
    p, _ := app.editor_pos_at(b, v, TEXT_X + 64, AREA.y + 2) // 6.4 cells
    testing.expect_value(t, p.col, 7) // the arrow's first byte
    p, _ = app.editor_pos_at(b, v, TEXT_X + 66, AREA.y + 2) // 6.6 cells
    testing.expect_value(t, p.col, 10) // past all three of them

    // Past the end clamps to the line's BYTE length, which is not its cell count.
    p, _ = app.editor_pos_at(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p, app.Pos{0, 17})
}

// The double click's column is the GLYPH the pointer is over, floored — and over multi-byte
// runes that has to name a whole rune, or the word it selects starts mid-character.
@(test)
test_editor_hit_glyph_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    // Cell 8 is the 'w' of "wörld"; its right half diverges the two columns, as it does in
    // test_editor_hit — but here the boundary and the glyph are 12 bytes apart, not 1.
    a.mouse.x, a.mouse.y = TEXT_X + 86, AREA.y + 2
    hit := app.editor_hit(&a, b, v)
    testing.expect_value(t, hit.kind, app.Editor_Hit_Kind.Text)
    testing.expect_value(t, hit.pos.col, 12) // the caret boundary: cell 9, the 'ö'
    testing.expect_value(t, hit.glyph, 11) // the glyph pointed at: cell 8, the 'w'

    // And the word that comes out of it is a whole word, umlaut included.
    app.doc_select_word(&b.doc, app.Pos{0, hit.glyph})
    lo, hi := app.cursor_range(b.cursors[0])
    testing.expect_value(t, app.doc_text(&b.doc, lo, hi, context.temp_allocator), "wörld")
}

// A drag resolves through its own path (editor_drag_pos, which clamps by ROW rather than
// refusing), so it converts cell to byte separately from editor_hit and is pinned separately.
@(test)
test_editor_drag_pos_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    v := mkview(0, 0)

    p, glyph := app.editor_drag_pos(b, v, TEXT_X + 86, AREA.y + 2)
    testing.expect_value(t, p, app.Pos{0, 12})
    testing.expect_value(t, glyph, 11)

    // Past the right edge: the boundary clamps to the byte length, the glyph to the last rune.
    p, glyph = app.editor_drag_pos(b, v, TEXT_X + 900, AREA.y + 2)
    testing.expect_value(t, p.col, 17)
    testing.expect_value(t, glyph, 17)
}

// A `:f` hit is a BYTE span and draw_find_marks paints it on the cell grid, so the bar sits
// over the match rather than short of it by one cell per multi-byte rune before it.
@(test)
test_find_marks_multibyte :: proc(t: ^testing.T) {
    a: app.App
    fake_editor(&a, MB)
    defer app.editor_destroy(&a.editor)
    defer app.find_destroy(&a.find)
    b := app.editor_current(&a.editor)

    app.find_set(&a.find, b, "wörld", app.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 1)
    m := a.find.matches[0]
    testing.expect_value(t, m.col, 11) // bytes in
    testing.expect_value(t, m.n, 6) // w ö(2) r l d

    cells := app.doc_cells(&b.doc, 0, context.temp_allocator)
    testing.expect_value(t, app.cells_col(cells, m.col), 8) // …cells out
    testing.expect_value(t, app.cells_col(cells, m.col + m.n), 13) // a 5-cell bar

    // Smart case still folds across the multi-byte rune rather than falling off it.
    app.find_set(&a.find, b, "WÖRLD", app.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 0) // a capital asks for an exact match
    app.find_set(&a.find, b, "wörld", app.Pos{0, 0})
    testing.expect_value(t, len(a.find.matches), 1)
}
