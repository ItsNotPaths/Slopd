package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// The two overlays. Within one scissor group quads paint UNDER glyphs, so a bar covering a
// pane's text has to get out of that group. Three fields do it:
//
//   `floating`  makes the overlay its own layout root, emitted after the whole pane subtree,
//               so its backdrop is never an under-quad in the rows' batch.
//   `clipTo`    makes that root emit a ScissorStart/End pair using the ATTACHED PARENT's box,
//               which is what keeps a bar that outgrew a short pane inside it.
//   `Capture`   stops what the overlay covers from answering the pointer — and only reaches
//               the panes that ASK the tree, which the last test here is about.
//
// Headless: a Clay context over test memory, the synthetic 10x16 font, no GL. The chord bar's
// pane is {100, 50, 300, 300} -> {102, 52, 296, 296}, taller than filetree_ui_test's so that
// there are rows above the bar as well as under it.

@(private = "file")
PANE :: app.Rect{100, 50, 300, 300}
@(private = "file")
AREA :: app.Rect{102, 52, 296, 296}
@(private = "file")
FT_ROW_H :: 18 // the filetree's rows, under the bar
@(private = "file")
ROW_H :: 22 // the bar's own: a 16px line plus CHORD_ROW_PAD
@(private = "file")
PAD :: 8
@(private = "file")
// Thirteen chords plus a clipboard-empty "[0 marked]" readout, packed into 28 cells. The
// packing test below feeds a longer readout and gets the same rows.
NROWS :: 6
@(private = "file")
BAR_H :: NROWS * ROW_H // 132
@(private = "file")
BAR_Y :: 216 // 52 + 296 - 132: the bottom of the content area

// {0, 0, 240, 200} insets to {2, 2, 236, 196}, holding 8 switcher rows of 22px.
@(private = "file")
TERM_PANE :: app.Rect{0, 0, 240, 200}
@(private = "file")
TERM_AREA :: app.Rect{2, 2, 236, 196}
@(private = "file")
COLW :: 32 // two 10px cells plus SWITCHER_COL_PAD
@(private = "file")
SW_ROWS :: 8

// Four distinguishable slots: every overlay colour is a lerp out of `bg`, and a zero Theme
// would make all four equal, letting a painter that used the wrong one pass.
@(private = "file")
palette :: proc(a: ^app.App) {
    a.theme.bg = {0, 0, 0}
    a.theme.fg = {1, 1, 1}
    a.theme.muted = {0.5, 0.5, 0.5}
    a.theme.accent = {1, 0, 0}
    a.theme.border_dark = {0, 0, 1}
}

// duration <= 0 makes anim_value return `to`, so this is "Alt has been down long enough".
@(private = "file")
faded_in :: proc(an: ^app.Anim) {
    an^ = app.Anim{to = 1}
}

// A listing, the aux pane focused, Ctrl down.
@(private = "file")
chord_app :: proc(a: ^app.App, n: int) {
    a.scale = 1
    a.aux_mode = .FileTree
    a.focus = .Aux
    a.ctrl_held = true
    a.mouse_on = true
    palette(a)
    faded_in(&a.chord_anim)
    a.tree.dir = "/tmp/ft"
    for _ in 0 ..< n {
        append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "entry"})
    }
}

// The sessions are bare structs: switcher_declare reads `locked` and nothing else, so there is
// no PTY to spawn.
@(private = "file")
switcher_app :: proc(a: ^app.App, n, active: int) {
    a.scale = 1
    a.aux_mode = .Terminal
    a.alt_held = true
    a.term_active = active
    palette(a)
    faded_in(&a.switcher_anim)
    for _ in 0 ..< n {
        append(&a.terminals, new(app.Terminal))
    }
}

@(private = "file")
switcher_app_free :: proc(a: ^app.App) {
    for term in a.terminals {
        free(term)
    }
    delete(a.terminals)
}

// ---------------------------------------------------------------------------------------
// When each overlay is up
// ---------------------------------------------------------------------------------------

// Procs rather than inline conditions because app_next_wake needs the same answer, and its copy
// of the switcher's rule had already drifted — it woke at vsync to fade in a switcher render
// was refusing to draw.
@(test)
test_overlay_shown_predicates :: proc(t: ^testing.T) {
    a: app.App

    // Plain Alt, in the terminal pane. Alt+Ctrl and Alt+Shift are the copy cursor's chords.
    a.aux_mode = .Terminal
    a.alt_held = true
    testing.expect(t, app.switcher_shown(&a), "plain Alt over the terminal must show it")
    a.ctrl_held = true
    testing.expect(t, !app.switcher_shown(&a), "Alt+Ctrl is the copy cursor, not the switcher")
    a.ctrl_held, a.shift_held = false, true
    testing.expect(t, !app.switcher_shown(&a), "Alt+Shift is the copy cursor, not the switcher")
    a.shift_held = false
    a.aux_mode = .FileTree
    testing.expect(t, !app.switcher_shown(&a), "the switcher belongs to the terminal pane")

    // The filetree, Ctrl down, holding the arrows. Focus is part of it: a Ctrl held while the
    // editor has focus is somebody else's modifier.
    b: app.App
    b.aux_mode = .FileTree
    b.ctrl_held = true
    b.focus = .Aux
    testing.expect(t, app.chord_shown(&b), "Ctrl over the focused filetree must show it")
    b.focus = .Editor
    testing.expect(t, !app.chord_shown(&b), "the bar must not follow Ctrl into the editor")
    b.focus = .Aux
    b.ctrl_held = false
    testing.expect(t, !app.chord_shown(&b), "the bar is a Ctrl-held cheat-sheet")
    b.ctrl_held = true
    b.aux_mode = .Grep
    testing.expect(t, !app.chord_shown(&b), "the bar belongs to the filetree pane")

    // …and not over the workspace prompt: every chord it lists is then a Text bind.
    b.aux_mode = .FileTree
    b.wsfind.open = true
    testing.expect(t, !app.chord_shown(&b), "the bar must not advertise chords the prompt has taken")
}

// The bar belongs to the PANE, not one of its faces: `file_pane` changes what the arrows do and
// nothing about `^c`. The rows differ, so what is asserted is the anchoring both share.
@(test)
test_chord_bar_in_both_faces :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 400)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    chord_app(&a, 20)
    defer delete(a.tree.entries)
    a.filebrowser.hover_row, a.filebrowser.hover_place, a.filebrowser.hover_seg = -1, -1, -1

    ls := app.filetree_layout(&a, &f, PANE, 500, 400)
    ls_bar, lok := box_of(&ls, clay.ID("ch_bar"), .Rectangle)
    testing.expect(t, lok, "the listing face declared no chord bar")

    a.file_pane = .Browser
    br := app.filebrowser_layout(&a, &f, PANE, 500, 400)
    br_bar, bok := box_of(&br, clay.ID("ch_bar"), .Rectangle)
    testing.expect(t, bok, "the browser face declared no chord bar")

    for r in ([?]app.Rect{ls_bar, br_bar}) {
        testing.expect_value(t, r.x, AREA.x)
        testing.expect_value(t, r.w, AREA.w)
        testing.expect_value(t, r.y + r.h, AREA.y + AREA.h) // pinned to the pane's bottom
    }
    testing.expect(t, br_bar.h >= ls_bar.h, "the browser lists MORE chords, never fewer")
}

// ---------------------------------------------------------------------------------------
// The chord bar
// ---------------------------------------------------------------------------------------

// The only interesting thing the bar does: thirteen chords of known width plus the state
// readout, left-flowing with a two-cell gap.
//
// The second half is the byte-versus-rune assertion. The hand-drawn packing measured the readout
// in BYTES, and its "·" spends two bytes on one cell, so it thought the item two cells wider
// than it is. Harmless while the same code drew it, and not once Clay lays the row out.
@(test)
test_chord_pack_wraps :: proc(t: ^testing.T) {
    state := "[0 marked · copy 0]" // 19 runes, 20 bytes

    // 28 cells: the 296px pane less its two 8px margins. Widths are 7, 9, 7, 6, 8, 6, 10, 7, 6,
    // 7, 8, 12, 12 with a gap of 2, so the rows break after the third, sixth, ninth and
    // eleventh.
    items, nrows := chord_items(state, 28)
    testing.expect_value(t, nrows, 6)
    testing.expect_value(t, items[0].row, 0)
    testing.expect_value(t, items[0].col, 0)
    testing.expect_value(t, items[2].col, 20) // 7 + 2 + 9 + 2
    testing.expect_value(t, items[3].row, 1) // 28 + 6 would overrun
    testing.expect_value(t, items[3].col, 0)
    testing.expect_value(t, items[6].row, 2)
    testing.expect_value(t, items[9].row, 3) // ^o, leading the fourth row
    testing.expect_value(t, items[12].row, 4) // ^h, beside ^I on the fifth
    testing.expect_value(t, items[12].col, 14)
    testing.expect_value(t, items[13].row, 5) // the readout, last in the flow
    testing.expect_value(t, items[13].key, "") // and the only item with no key

    // 150 cells is exactly the width at which the readout's last rune is the row's last cell.
    // Counted in bytes it does not fit and everything moves to a second row.
    wide, wide_rows := chord_items(state, 150)
    testing.expect_value(t, wide_rows, 1)
    testing.expect_value(t, wide[13].col, 131)
    testing.expect_value(t, wide[13].row, 0)

    // One cell narrower and it does wrap, so the boundary above is a real one.
    _, tight_rows := chord_items(state, 149)
    testing.expect_value(t, tight_rows, 2)
}

// So the test reads as arithmetic rather than allocator plumbing.
@(private = "file")
chord_items :: proc(state: string, maxw: int) -> ([]app.Chord_Item, int) {
    // The `ls` hints: the file ops, without the browser's navigation chords.
    return app.chord_pack(app.CHORD_HINTS[:app.CHORD_OPS], state, maxw, context.temp_allocator)
}

// Anchored to the pane's bottom, full width, one row per packed row, and the chords on the cell
// grid the packing chose.
@(test)
test_chord_bar_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 400)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    chord_app(&a, 20)
    defer delete(a.tree.entries)

    cmds := app.chord_layout(&a, &f, AREA, 500, 400)

    bar, ok := box_of(&cmds, clay.ID("ch_bar"), .Rectangle)
    testing.expect(t, ok, "the bar drew no backdrop")
    testing.expect_value(t, bar, app.Rect{AREA.x, BAR_Y, AREA.w, BAR_H})

    // Pure layout: neither declares a background, so neither emits a command (rule 3).
    _, row_bg := box_of(&cmds, clay.ID("ch_row", 0), .Rectangle)
    _, item_bg := box_of(&cmds, clay.ID("ch_item", 0), .Rectangle)
    testing.expect(t, !row_bg && !item_bg, "a row or an item painted a background of its own")

    // One command per text run, in declaration order, with the readout last.
    runs: [dynamic]app.Rect
    defer delete(runs)
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Text {
            append(&runs, app.clay_rect(c.boundingBox))
        }
    }
    testing.expect_value(t, len(runs), 2 * 13 + 1) // thirteen chords of two runs, plus one

    // "^y" on the margin, "mark" one cell past it, "^u" nine cells in (seven plus the gap),
    // "^c" at 20.
    testing.expect_value(t, runs[0].x, AREA.x + PAD)
    testing.expect_value(t, runs[1].x, AREA.x + PAD + 30)
    testing.expect_value(t, runs[2].x, AREA.x + PAD + 90)
    testing.expect_value(t, runs[4].x, AREA.x + PAD + 200)
    // Centred in a 22px row by the solver, not by (row_h - lh) / 2.
    testing.expect_value(t, runs[0].y, BAR_Y + (ROW_H - 16) / 2)

    // The second packed row starts back on the margin.
    testing.expect_value(t, runs[6].x, AREA.x + PAD)
    testing.expect_value(t, runs[6].y, BAR_Y + ROW_H + (ROW_H - 16) / 2)

    testing.expect_value(t, runs[18].x, AREA.x + PAD)
    testing.expect_value(t, runs[18].y, BAR_Y + 3 * ROW_H + (ROW_H - 16) / 2)
    // The fifth row carries the two widest chords, so the readout gets a row of its own: even
    // "[0 marked]" does not fit beside them at 28 cells.
    testing.expect_value(t, runs[24].x, AREA.x + PAD + 140)
    testing.expect_value(t, runs[24].y, BAR_Y + 4 * ROW_H + (ROW_H - 16) / 2)
    testing.expect_value(t, runs[26].x, AREA.x + PAD)
    testing.expect_value(t, runs[26].y, BAR_Y + 5 * ROW_H + (ROW_H - 16) / 2)
}

// The occlusion probe. clay_paint composites under-quads, images, then glyphs within one
// scissor group, so a backdrop declared as an ordinary child of the pane would paint BEHIND the
// file names it covers even with every bounding box correct.
//
// `floating` avoids it, not `clip`: a floating element is its own layout root and Clay emits
// roots in order, so the whole pane subtree — the ScissorEnd that flushes the rows included —
// is on the list before the bar's first command. That is the assertion.
//
// `clipTo` is the second half, asserted here because it is invisible in the boxes: the bar gets
// a ScissorStart whose rect is the PANE's content area. Without it the bar has no scissor and
// would paint over the pane next door once a short pane made it taller than its space.
//
// A root's clip scissor is not keyed by the element that asked for it — Clay derives the id
// from the root's — so the group has to be found by CONTAINMENT, which is what the
// depth-tracking loop below does.
@(test)
test_chord_bar_paints_over_the_rows :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 400)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    chord_app(&a, 20)
    defer delete(a.tree.entries)

    // The real pane, not chord_layout: what is covered is the filetree's own rows.
    cmds := app.filetree_layout(&a, &f, PANE, 500, 400)

    open_at: [8]int
    open_box: [8]app.Rect
    depth := 0
    pane_close, bar_open, bar_fill, bar_depth, last_row_text := -1, -1, -1, -1, -1
    bar_clip: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            open_at[depth] = int(i)
            open_box[depth] = app.clay_rect(c.boundingBox)
            depth += 1
        case .ScissorEnd:
            depth -= 1
            if depth == 0 && bar_fill < 0 {
                pane_close = int(i) // the filetree pane's group, closing
            }
        case .Rectangle:
            if c.id == clay.ID("ch_bar").id {
                bar_fill, bar_depth = int(i), depth
                if depth > 0 {
                    bar_open, bar_clip = open_at[depth - 1], open_box[depth - 1]
                }
            }
        case .Text:
            if bar_fill < 0 {
                last_row_text = int(i) // a file name, about to be covered
            }
        }
    }

    testing.expect(t, last_row_text >= 0, "the filetree declared no rows to cover")
    testing.expect(t, bar_fill > last_row_text, "the bar's backdrop paints under the rows it covers")
    testing.expect_value(t, bar_depth, 1) // inside exactly one group: its own
    testing.expect(t, pane_close >= 0 && bar_open > pane_close, "the bar opened inside the pane's clip group")
    testing.expect_value(t, bar_clip, AREA) // clipped to the PANE, not the bar's own box
    testing.expect_value(t, depth, 0) // every group balanced
}

// The bar has no verbs; its job is to stop the pane underneath having any. Clay stops walking
// layout roots at the first capturing one the pointer is inside, so every `ft_row` under the
// bar goes quiet — no hit, and therefore no hover and no click. A row ABOVE the bar is
// unaffected, which is what makes this a capture test.
@(test)
test_chord_bar_captures_the_pointer :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 400)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    chord_app(&a, 20)
    defer delete(a.tree.entries)

    _, _, rows := app.filetree_geom(PANE, 1, f.line_height)
    _ = app.filetree_layout(&a, &f, PANE, 500, 400) // frame 1: boxes to hit against

    // The first entry row, well clear of the bar.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + FT_ROW_H + 4)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 400)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, rows), 0)
    testing.expect(t, !clay.PointerOver(clay.ID("ch_bar")), "the bar claimed a pointer above it")

    // A row the bar sits on top of: row 11 starts at 268, the bar at 260.
    clay.SetPointerState({f32(AREA.x + 50), f32(BAR_Y + 12)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 400)
    testing.expect(t, clay.PointerOver(clay.ID("ch_bar")), "the bar did not answer for its own box")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_row", 11)), "a row under the bar still answers")
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, rows), -1)
    // The pane itself stops answering too, which a Passthrough overlay would not do.
    testing.expect(t, !clay.PointerOver(clay.ID("ft_pane")), "the pane answered through the overlay")
}

// ---------------------------------------------------------------------------------------
// The terminal switcher
// ---------------------------------------------------------------------------------------

// There is no stored `.scroll`: the switcher has no viewport of its own, so "keep the active
// session centred" is a derivation, and pinning it pins the whole of the pane's scrolling.
@(test)
test_switcher_geom_and_window :: proc(t: ^testing.T) {
    colw, row_h, rows := app.switcher_geom(TERM_AREA, 1, 16, 10)
    testing.expect_value(t, colw, i32(COLW)) // two cells plus the padding
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, SW_ROWS) // 196 / 22

    // Never wider than the pane it is inside.
    narrow, _, _ := app.switcher_geom(app.Rect{0, 0, 12, 196}, 1, 16, 10)
    testing.expect_value(t, narrow, i32(12))

    // A hidden pane is a zero rect and reports no rows.
    _, _, none := app.switcher_geom(app.Rect{}, 1, 16, 10)
    testing.expect_value(t, none, 0)

    // Centred on the active session, then clamped at both ends.
    first, visible := app.switcher_window(12, 7, SW_ROWS)
    testing.expect_value(t, first, 3)
    testing.expect_value(t, visible, SW_ROWS)

    first, visible = app.switcher_window(12, 0, SW_ROWS) // clamped at the top
    testing.expect_value(t, first, 0)
    testing.expect_value(t, visible, SW_ROWS)

    first, visible = app.switcher_window(12, 11, SW_ROWS) // and at the bottom
    testing.expect_value(t, first, 4)
    testing.expect_value(t, visible, SW_ROWS)

    first, visible = app.switcher_window(3, 1, SW_ROWS) // fewer sessions than rows
    testing.expect_value(t, first, 0)
    testing.expect_value(t, visible, 3)

    // No sessions: nothing to declare, and not a negative count that would index backwards.
    _, empty := app.switcher_window(0, 0, SW_ROWS)
    testing.expect_value(t, empty, 0)
}

// The pane's top-left corner, one row per visible session keyed by SESSION index, the active
// one filled, and the numbers centred by the solver — a one-digit and a two-digit label centre
// at different offsets, which the hand-drawn code spelled out.
@(test)
test_switcher_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    switcher_app(&a, 12, 7)
    defer switcher_app_free(&a)
    a.terminals[9].locked = true

    cmds := app.switcher_layout(&a, &f, TERM_AREA, 500, 300)

    col, ok := box_of(&cmds, clay.ID("sw_col"), .Rectangle)
    testing.expect(t, ok, "the switcher drew no column")
    testing.expect_value(t, col, app.Rect{TERM_AREA.x, TERM_AREA.y, COLW, SW_ROWS * ROW_H})

    // Sessions 3..10 are on screen, so the active row is the fifth down — keyed 7, not 4, which
    // is what makes the id name a session.
    active, act_ok := box_of(&cmds, clay.ID("sw_row", 7), .Rectangle)
    testing.expect(t, act_ok, "the active session drew no fill")
    testing.expect_value(t, active, app.Rect{TERM_AREA.x, TERM_AREA.y + 4 * ROW_H, COLW, ROW_H})

    // Only the active one: the rest are transparent and emit no command.
    _, idle_ok := box_of(&cmds, clay.ID("sw_row", 6), .Rectangle)
    testing.expect(t, !idle_ok, "an inactive session painted a background")

    // "8" is one cell in a 32px column and "10" is two, centring at 11 and 6.
    texts, one_digit, two_digit, locked_col := 0, i32(-1), i32(-1), [3]f32{}
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType != .Text {
            continue
        }
        r := app.clay_rect(c.boundingBox)
        s := string(c.renderData.text.stringContents.chars[:c.renderData.text.stringContents.length])
        switch s {
        case "8":
            one_digit = r.x
        case "10":
            two_digit = r.x
            locked_col, _ = app.clay_color(c.renderData.text.textColor)
        }
        texts += 1
    }
    testing.expect_value(t, texts, SW_ROWS) // virtualised: eight rows, not twelve
    testing.expect_value(t, one_digit, TERM_AREA.x + (COLW - 10) / 2)
    testing.expect_value(t, two_digit, TERM_AREA.x + (COLW - 20) / 2)

    // Session 10 is locked, so its number greys rather than taking the foreground.
    testing.expect_value(t, locked_col, a.theme.muted)
}

// A floating root inside the terminal pane, exactly as the chord bar is: its own scissor group,
// taken from the pane's box, emitted after the grid.
//
// It would have worked without one, which is the trap this test closes. The terminal's body is a
// Custom, whose painter ends with its own flush, so the batch is empty by the time anything
// after it is queued and a switcher in the flow would have painted on top by accident.
@(test)
test_switcher_is_a_group_of_its_own :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    switcher_app(&a, 12, 7)
    defer switcher_app_free(&a)

    cmds := app.switcher_layout(&a, &f, TERM_AREA, 500, 300)

    open_at: [8]int
    open_box: [8]app.Rect
    depth, pane_close, col_open, col_fill, col_depth := 0, -1, -1, -1, -1
    col_clip: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            open_at[depth] = int(i)
            open_box[depth] = app.clay_rect(c.boundingBox)
            depth += 1
        case .ScissorEnd:
            depth -= 1
            if depth == 0 && col_fill < 0 {
                pane_close = int(i)
            }
        case .Rectangle:
            if c.id == clay.ID("sw_col").id {
                col_fill, col_depth = int(i), depth
                if depth > 0 {
                    col_open, col_clip = open_at[depth - 1], open_box[depth - 1]
                }
            }
        }
    }
    testing.expect(t, col_fill >= 0, "the switcher drew no column")
    testing.expect_value(t, col_depth, 1) // its own group, not the pane's
    testing.expect(t, pane_close >= 0 && col_open > pane_close, "the column opened inside the pane's group")
    testing.expect_value(t, col_clip, TERM_AREA) // clipped to the pane
    testing.expect_value(t, depth, 0)
}

// ---------------------------------------------------------------------------------------
// The overlay in a whole window
// ---------------------------------------------------------------------------------------

// What OVERLAY_Z is for. Within its own pane an overlay needs no z — it is declared last, and
// Clay appends floating roots in order — but that misses everything declared AFTER the aux
// pane. window_frame puts the status strip there, and Clay's root sort is stable, so a zero-z
// bar would be painted over by a strip it overlapped. The claim is "on top of the window".
//
// Mirrors window_ui_test's `two_panes`: the app's own declarations with only the call order
// written out, because window_frame itself needs a GL context.
@(test)
test_overlay_outranks_everything_declared_after_it :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 400)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    chord_app(&a, 20)
    defer delete(a.tree.entries)
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    app.buffer_set_text(app.editor_current(&a.editor), "alpha\nbravo")

    ed_pane := app.Rect{0, 0, 90, 380}
    strip := app.Rect{0, 380, 500, 20}
    ed_area, ed_row_h, ed_rows := app.editor_geom(ed_pane, 1, f.line_height)
    v := app.editor_view(app.editor_current(&a.editor), &f, ed_area, ed_row_h, ed_rows, 0)

    app.clay_window_begin(500, 400)
    if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(500, 400)) {
        app.editor_declare(&a, &f, ed_pane, v, 0)
        app.filetree_declare(&a, &f, AREA, a.tree.scroll, 0, 0)
        app.strip_declare(&a, &f, strip, 0)
    }
    cmds := clay.EndLayout(0)

    // Stated as "nothing opens a clip group after the bar has painted", since a root's clip
    // scissor carries a derived id. The strip declares three floating labels, each with a
    // group, so at zIndex 0 the bar would have four groups after it.
    last_open, bar_fill, groups := -1, -1, 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            last_open = int(i)
            groups += 1
        case .Rectangle:
            if c.id == clay.ID("ch_bar").id {
                bar_fill = int(i)
            }
        }
    }
    testing.expect(t, groups >= 4, "the fixture declared too little to order against")
    testing.expect(t, bar_fill >= 0, "the bar did not declare itself")
    testing.expect(t, last_open < bar_fill, "something opened a clip group after the overlay painted")
}
