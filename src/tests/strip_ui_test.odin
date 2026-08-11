package tests

import app ".."
import clay "../../bindings/clay"
import "core:strings"
import "core:testing"

// C8b: the status strip declared in Clay. The strip has no list, no viewport and no click, so
// what is left to test is the whole of it — WHICH of the three things it shows, and WHERE each
// piece lands.
//
// Every expected box below is derived from the arithmetic the hand-drawn painters used, not
// from what Clay printed. The strip is {0, 280, 500, 20} at scale 1 with the synthetic 10x16
// font, so: pad 8, text top 280 + (20 - 16) / 2 = 282, and a cell is 10 wide.
//
//   draw_command_line:   prompt at strip.x + pad; text origin one prompt (2 cells) further;
//                        hint at origin + cw * (len + 1)
//   draw_status:         left at strip.x + pad; right ending at strip.x + strip.w - pad;
//                        root at strip.x + (strip.w - cw * len) / 2   <- centred in the STRIP,
//                        which is why it is a floating slot and not a row cell
//   draw_conflict_prompt: message at the pad, keys immediately after it

@(private = "file")
STRIP :: app.Rect{0, 280, 500, 20}
@(private = "file")
WIN_W :: 500
@(private = "file")
WIN_H :: 300
@(private = "file")
TEXT_Y :: 282
@(private = "file")
PAD :: 8

@(private = "file")
fixture :: proc(a: ^app.App, text: string) {
    app.editor_init(&a.editor)
    a.scale = 1
    a.focus = .Editor
    a.project_root = "/zz/proj" // no $HOME prefix, so home_abbrev leaves it alone
    app.cl_init(&a.cl)
    app.buffer_set_text(app.editor_current(&a.editor), text)
}

@(private = "file")
teardown :: proc(a: ^app.App) {
    app.editor_destroy(&a.editor)
    app.doc_destroy(&a.cl.doc)
}

// Find a Text command by the string it carries. Returns a zero rect when absent, which every
// caller distinguishes from a real box (nothing in the strip is at the origin).
@(private = "file")
text_box :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), want: string) -> app.Rect {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        if c.commandType != .Text {
            continue
        }
        d := c.renderData.text
        if string(d.stringContents.chars[:d.stringContents.length]) == want {
            return app.clay_rect(c.boundingBox)
        }
    }
    return {}
}

@(private = "file")
count_of :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), kind: clay.RenderCommandType) -> int {
    n := 0
    for i in 0 ..< cmds.length {
        if clay.RenderCommandArray_Get(cmds, i).commandType == kind {
            n += 1
        }
    }
    return n
}

// The three-way choice, and the precedence inside it. An open command line beats a pending
// conflict because the conflict's own answer is typed into that line — a `reload ` staged by
// the conflict must not be hidden behind the prompt telling you to type it.
@(test)
test_strip_mode :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Status)

    b := app.editor_current(&a.editor)
    b.conflict = true
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Conflict)

    a.cl_active = true
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Command) // the CL wins
    a.cl_active = false

    // A conflict is the DOCUMENT pane's business: it is not reported while the aux pane holds
    // focus (you are not looking at the file) or while the surface is an image.
    a.focus = .Aux
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Status)
    a.focus = .Editor
    a.main = .Image
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Status)
}

// The modeline: three labels at three anchors, each on the pixel the hand-drawn version put it.
@(test)
test_strip_status_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    // Left: the modified marker, a space, then the name. Unnamed buffers read "untitled".
    left := text_box(&cmds, "  untitled")
    testing.expect_value(t, left, app.Rect{PAD, TEXT_Y, 100, 16})

    // Right: language, caret, line count, scroll — one string, ending at the far pad.
    right := text_box(&cmds, "text   L1:1   2 lines   Top")
    testing.expect_value(t, right.w, i32(270))
    testing.expect_value(t, right.x + right.w, i32(STRIP.w - PAD))
    testing.expect_value(t, right.y, i32(TEXT_Y))

    // Centre: the project root, centred in the STRIP rather than between its neighbours.
    root := text_box(&cmds, "/zz/proj")
    testing.expect_value(t, root, app.Rect{(STRIP.w - 80) / 2, TEXT_Y, 80, 16})

    // The strip paints its own background — there is no panel() down here — and rings itself
    // only when it is holding something that wants an answer, which the idle modeline is not.
    testing.expect_value(t, count_of(&cmds, .Rectangle), 1)
    testing.expect_value(t, count_of(&cmds, .Border), 0)

    // EVERY label is inside a clip group, and that is not decoration. A floating child is
    // hoisted out of its parent and clipped by nothing unless it says `clipTo`, so without it
    // the three anchored labels are emitted AFTER the strip's ScissorEnd — free to paint over
    // the panes above them on a narrow window, with every box in this list still correct.
    // Depth is the only thing that shows it.
    depth := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            testing.expect_value(t, app.clay_rect(c.boundingBox), STRIP)
            depth += 1
        case .ScissorEnd:
            depth -= 1
        case .Text:
            testing.expect(t, depth > 0, "a strip label escaped the strip's clip")
        }
    }
    testing.expect_value(t, depth, 0)
}

// The three labels are ANCHORED, not laid out — each holds its place whatever the other two
// are doing. This is the assertion that rules out the obvious alternative declaration, a
// left-to-right row, and the label it has to be written about is the RIGHT one: a row gives a
// grown left cell its content width when the content is too big for its share (SizingGrow
// means "at least fit", C5c's rule 8), which shoves the readout off the end of the strip where
// the clip eats it. Under anchors it does not move.
//
// The FIRST version of this test asserted the same thing about the root and passed against the
// row design, because a symmetrically padded content box has the same centre as the strip —
// C7c's "right assertion, wrong setup" recurring. The root is pinned here too, but it is the
// right-hand box that carries the claim.
@(test)
test_strip_labels_are_anchored_not_a_row :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    // A file name far wider than its share of the strip: 45 characters, in a 50-cell window.
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/tmp/a-very-long-file-name-that-eats-the-strip.odin") // owned: buffer_destroy frees it
    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    left := text_box(&cmds, "  a-very-long-file-name-that-eats-the-strip.odin")
    right := text_box(&cmds, "odin   L1:1   2 lines   Top")
    root := text_box(&cmds, "/zz/proj")

    testing.expect_value(t, left.x, i32(PAD))
    testing.expect_value(t, right.x + right.w, i32(STRIP.w - PAD)) // still on the far pad
    testing.expect_value(t, root.x, i32((STRIP.w - 80) / 2)) // still on the strip's centre

    // They now OVERLAP, and that is the pre-existing behaviour being preserved rather than a
    // property being claimed: three independent text_draw calls have always been free to run
    // into each other on a narrow window. Stated here so the port is not later "fixed" into
    // the row that loses the readout entirely.
    testing.expect(t, left.x + left.w > right.x, "premise changed: the labels no longer overlap")
}

// The command line: prompt, field, hint, touching, left to right.
@(test)
test_strip_command_line_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    a.cl_active = true
    app.doc_set_text(&a.cl.doc, "reload")

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    testing.expect_value(t, text_box(&cmds, "> "), app.Rect{PAD, TEXT_Y, 20, 16})

    // The field is a Custom — a caret is an over-quad, so it cannot be Clay's to paint — and
    // it is sized to the runes PLUS ONE CELL. That cell is the caret column: typing at the end
    // of the line puts the caret at col == len, one cell past the last glyph, and a box sized
    // to the runes alone would clip it away exactly when it matters.
    custom: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Custom {
            custom = app.clay_rect(c.boundingBox)
        }
    }
    testing.expect_value(t, custom, app.Rect{PAD + 20, STRIP.y, 70, STRIP.h}) // 6 runes + 1

    // The ghost hint starts where that extra cell ends — the same pixel the hand-drawn
    // version put it at, `origin + cw * (len + 1)`.
    testing.expect_value(t, text_box(&cmds, "(y/n)"), app.Rect{PAD + 20 + 70, TEXT_Y, 50, 16})

    // An argument makes the hint go away, so the field grows into the space it had.
    app.doc_set_text(&a.cl.doc, "reload y")
    cmds2 := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds2, "(y/n)"), app.Rect{})
}

// A staged (injected) line the user has not touched rings the strip in the alert colour —
// "review this before Enter". It is the element's own border now, where it used to be four
// fills laid over the top of the strip; the ring clears itself on the first edit, because any
// edit bumps doc.version past the mark and nothing has to hook the edit to notice.
@(test)
test_strip_injected_ring :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)

    app.cl_inject(&a, "reload ")
    testing.expect(t, a.cl.injected, "cl_inject did not stage the line")

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    ring := false
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Border {
            ring = true
            testing.expect_value(t, app.clay_rect(c.boundingBox), STRIP)
            testing.expect_value(t, int(c.renderData.border.width.left), 2)
            testing.expect_value(t, int(c.renderData.border.width.bottom), 2)
        }
    }
    testing.expect(t, ring, "a pristine injected line drew no ring")

    // One keystroke into it and the alert is spent.
    app.doc_insert_rune(&a.cl.doc, 'y')
    cmds2 := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, count_of(&cmds2, .Border), 0)
}

// The conflict prompt: the alert ring plus two labels that touch, so the sentence reads as one
// line in two colours.
@(test)
test_strip_conflict_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/tmp/x.odin") // owned: buffer_destroy frees it
    b.conflict = true

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    msg := text_box(&cmds, "x.odin changed on disk - ")
    testing.expect_value(t, msg, app.Rect{PAD, TEXT_Y, 250, 16}) // 25 runes
    keys := text_box(&cmds, "run: reload y (lose edits) / reload n (keep mine)")
    testing.expect_value(t, keys.x, msg.x + msg.w) // touching, as the arithmetic had them
    testing.expect_value(t, count_of(&cmds, .Border), 1) // always rung: it wants an answer
}

// No editor on screen (Full on the aux surface): the strip names the aux pane and reports
// nothing else, because the root and the right-hand readout are both about a document.
@(test)
test_strip_status_without_an_editor :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    a.view = .Full
    a.focus = .Aux
    a.aux_mode = .Config

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds, "config"), app.Rect{PAD, TEXT_Y, 60, 16})
    testing.expect_value(t, text_box(&cmds, "/zz/proj"), app.Rect{}) // no document, no root
    testing.expect_value(t, count_of(&cmds, .Text), 1)
}

// A degenerate strip declares nothing at all, rather than a zero-sized element the bridge
// would then flush around. Same guard every pane's frame opens with.
@(test)
test_strip_degenerate :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)

    cmds := app.strip_layout(&a, &f, app.Rect{0, 300, 500, 0}, WIN_W, WIN_H)
    testing.expect_value(t, cmds.length, i32(0))
}
