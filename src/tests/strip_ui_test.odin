package tests

import app ".."
import clay "../../bindings/clay"
import "core:strings"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"

// The status strip declared in Clay. It has no list, no viewport and no click, so what is left
// is the whole of it: which of the things it shows, and where each piece lands.
//
// Every expected box is derived from the arithmetic the hand-drawn painters used, not from what
// Clay printed. The strip is {0, 280, 500, 20} at scale 1 with the synthetic 10x16 font: pad 8,
// text top 282, a 10-wide cell.
//
//   command line:  prompt at strip.x + pad, text origin two cells further, hint at
//                  origin + cw * (len + 1)
//   status:        left at strip.x + pad, right ending at strip.x + strip.w - pad, root at
//                  strip.x + (strip.w - cw * len) / 2 — centred in the STRIP, which is why it
//                  is a floating slot and not a row cell

@(private = "file")
STRIP :: gfx.Rect{0, 280, 500, 20}
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
    txt.doc_destroy(&a.cl.doc)
}

// A zero rect when absent, which every caller can tell from a real box.
@(private = "file")
text_box :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), want: string) -> gfx.Rect {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        if c.commandType != .Text {
            continue
        }
        d := c.renderData.text
        if string(d.stringContents.chars[:d.stringContents.length]) == want {
            return ui.clay_rect(c.boundingBox)
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

// The command line while it is open, the modeline otherwise. A pending disk conflict is not a
// third thing: its answer is typed into the command line, so the strip reports it in the
// modeline's marker column.
@(test)
test_strip_mode :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Status)

    b := app.editor_current(&a.editor)
    b.conflict = true
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Status) // no line of its own

    a.cl_active = true
    testing.expect_value(t, app.strip_mode(&a), app.Strip_Mode.Command)
}

// Three labels at three anchors, each on the pixel the hand-drawn version put it.
@(test)
test_strip_status_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    // Left: the modified marker, a space, then the name.
    left := text_box(&cmds, "  untitled")
    testing.expect_value(t, left, gfx.Rect{PAD, TEXT_Y, 100, 16})

    // Right: language, caret, line count, scroll — one string, ending at the far pad.
    right := text_box(&cmds, "text   L1:1   2 lines   Top")
    testing.expect_value(t, right.w, i32(270))
    testing.expect_value(t, right.x + right.w, i32(STRIP.w - PAD))
    testing.expect_value(t, right.y, i32(TEXT_Y))

    // Centre: the project root, centred in the STRIP, not between its neighbours.
    root := text_box(&cmds, "/zz/proj")
    testing.expect_value(t, root, gfx.Rect{(STRIP.w - 80) / 2, TEXT_Y, 80, 16})

    // The strip paints its own background, and rings itself only when holding something that
    // wants an answer.
    testing.expect_value(t, count_of(&cmds, .Rectangle), 1)
    testing.expect_value(t, count_of(&cmds, .Border), 0)

    // Every label is inside a clip group. A floating child is hoisted out of its parent and
    // clipped by nothing unless it says `clipTo`, so without it the three anchored labels are
    // emitted after the strip's ScissorEnd, free to paint over the panes on a narrow window.
    // Depth is the only thing that shows it.
    depth := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            testing.expect_value(t, ui.clay_rect(c.boundingBox), STRIP)
            depth += 1
        case .ScissorEnd:
            depth -= 1
        case .Text:
            testing.expect(t, depth > 0, "a strip label escaped the strip's clip")
        }
    }
    testing.expect_value(t, depth, 0)
}

// Anchored, not laid out: each holds its place whatever the other two do. This rules out the
// obvious alternative, a left-to-right row, and the label it has to be written about is the
// RIGHT one — a row gives a grown left cell its content width when the content outgrows its
// share (rule 8), shoving the readout off the end where the clip eats it.
//
// The first version of this test asserted the same about the root and passed against the row
// design, because a symmetrically padded content box has the same centre as the strip.
@(test)
test_strip_labels_are_anchored_not_a_row :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha\nbravo")
    defer teardown(&a)

    // A file name far wider than its share: 45 characters in a 50-cell window.
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/tmp/a-very-long-file-name-that-eats-the-strip.odin") // owned
    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    left := text_box(&cmds, "  a-very-long-file-name-that-eats-the-strip.odin")
    right := text_box(&cmds, "odin   L1:1   2 lines   Top")
    root := text_box(&cmds, "/zz/proj")

    testing.expect_value(t, left.x, i32(PAD))
    testing.expect_value(t, right.x + right.w, i32(STRIP.w - PAD)) // still on the far pad
    testing.expect_value(t, root.x, i32((STRIP.w - 80) / 2)) // still on the strip's centre

    // They now OVERLAP, which is pre-existing behaviour being preserved rather than a property
    // claimed: three independent draws have always been free to run into each other. Stated so
    // the port is not later "fixed" into the row that loses the readout.
    testing.expect(t, left.x + left.w > right.x, "premise changed: the labels no longer overlap")
}

// Prompt, field, hint, touching, left to right.
@(test)
test_strip_command_line_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    a.cl_active = true
    txt.doc_set_text(&a.cl.doc, ":reload")

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)

    testing.expect_value(t, text_box(&cmds, "> "), gfx.Rect{PAD, TEXT_Y, 20, 16})

    // A Custom, since a caret is an over-quad, sized to the runes PLUS ONE CELL — the caret
    // column, one cell past the last glyph, which a box sized to the runes alone would clip.
    custom: gfx.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Custom {
            custom = ui.clay_rect(c.boundingBox)
        }
    }
    testing.expect_value(t, custom, gfx.Rect{PAD + 20, STRIP.y, 80, STRIP.h}) // 7 runes + 1

    // The ghost hint starts where that extra cell ends.
    testing.expect_value(t, text_box(&cmds, "(y/n)"), gfx.Rect{PAD + 20 + 80, TEXT_Y, 50, 16})

    // An argument makes the hint go away, so the field grows into its space.
    txt.doc_set_text(&a.cl.doc, ":reload y")
    cmds2 := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds2, "(y/n)"), gfx.Rect{})
}

// An untouched injected line rings the strip in the alert colour: "review this before Enter".
// The element's own border now, where it used to be four fills laid over the strip. The ring
// clears itself on the first edit, since any edit bumps doc.version past the mark.
@(test)
test_strip_injected_ring :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)

    app.cl_inject(&a, ":reload ")
    testing.expect(t, a.cl.injected, "cl_inject did not stage the line")

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    ring := false
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Border {
            ring = true
            testing.expect_value(t, ui.clay_rect(c.boundingBox), STRIP)
            testing.expect_value(t, int(c.renderData.border.width.left), 2)
            testing.expect_value(t, int(c.renderData.border.width.bottom), 2)
        }
    }
    testing.expect(t, ring, "a pristine injected line drew no ring")

    txt.doc_insert_rune(&a.cl.doc, 'y')
    cmds2 := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, count_of(&cmds2, .Border), 0)
}

// Reported by the modeline's marker column and nothing else: the `*` becomes a `!`. No extra
// label and no ring — the ring belongs to the staged `:reload ` in the command line.
@(test)
test_strip_conflict_marks_the_modeline :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/tmp/x.odin") // owned
    b.dirty = true

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds, "* x.odin"), gfx.Rect{PAD, TEXT_Y, 80, 16})

    b.conflict = true
    cmds2 := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds2, "! x.odin"), gfx.Rect{PAD, TEXT_Y, 80, 16})
    testing.expect_value(t, text_box(&cmds2, "* x.odin"), gfx.Rect{}) // one marker, not two
    testing.expect_value(t, count_of(&cmds2, .Border), 0) // no ring: nothing wants an answer
}

// No editor on screen: the strip names the aux pane and nothing else, since the root and the
// right-hand readout are both about a document.
@(test)
test_strip_status_without_an_editor :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)
    a.view = .Full
    a.focus = .Aux
    a.aux_mode = .Config

    cmds := app.strip_layout(&a, &f, STRIP, WIN_W, WIN_H)
    testing.expect_value(t, text_box(&cmds, "config"), gfx.Rect{PAD, TEXT_Y, 60, 16})
    testing.expect_value(t, text_box(&cmds, "/zz/proj"), gfx.Rect{}) // no document, no root
    testing.expect_value(t, count_of(&cmds, .Text), 1)
}

// Nothing at all, rather than a zero-sized element the bridge would flush around.
@(test)
test_strip_degenerate :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    fixture(&a, "alpha")
    defer teardown(&a)

    cmds := app.strip_layout(&a, &f, gfx.Rect{0, 300, 500, 0}, WIN_W, WIN_H)
    testing.expect_value(t, cmds.length, i32(0))
}
