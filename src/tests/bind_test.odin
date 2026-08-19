package tests

import app ".."
import "core:testing"
import "vendor:glfw"

// The bind table's four rules, which every chord in Slopd now rests on:
//   1. Global is searched from every context, and the context table beside it.
//   2. An EXACT match wins; a Shift-qualified miss retries without Shift, extending.
//   3. A row can cover a RUN of keys, and the action is handed the offset.
//   4. A verb answering false hands the chord to the next row holding it.

@(private = "file") CTRL :: i32(glfw.MOD_CONTROL)
@(private = "file") SHIFT :: i32(glfw.MOD_SHIFT)
@(private = "file") ALT :: i32(glfw.MOD_ALT)

@(private = "file")
act_of :: proc(key, mods: i32, ctx: app.Bind_Ctx) -> app.Action {
    b, ok := app.bind_find(app.BIND_DEFAULTS[:], app.Chord{key, mods}, ctx)
    return ok ? b.act : .None
}

// The four chords that made a per-pane context system look necessary. Each is two unrelated
// verbs, and the Text/Surface split is the whole of what tells them apart.
@(test)
test_text_and_surface_split_the_colliding_chords :: proc(t: ^testing.T) {
    testing.expect_value(t, act_of(glfw.KEY_Y, CTRL, .Text), app.Action.Redo)
    testing.expect_value(t, act_of(glfw.KEY_Y, CTRL, .Surface), app.Action.File_Mark)

    testing.expect_value(t, act_of(glfw.KEY_LEFT, CTRL, .Text), app.Action.Move_Word_Left)
    testing.expect_value(t, act_of(glfw.KEY_LEFT, CTRL, .Surface), app.Action.Browse_Back)

    testing.expect_value(t, act_of(glfw.KEY_BACKSPACE, 0, .Text), app.Action.Delete_Back)
    testing.expect_value(t, act_of(glfw.KEY_BACKSPACE, 0, .Surface), app.Action.Parent)

    // Bare keys can only ever live where nothing types: `f` fits an image, and types a letter.
    testing.expect_value(t, act_of(glfw.KEY_F, 0, .Surface), app.Action.Media_Fit)
    testing.expect_value(t, act_of(glfw.KEY_F, 0, .Text), app.Action.None)
}

// ^a and ^l are the editable's: they take a document and a line. A terminal has no table entry
// for either, so both reach the job — ^l still clears a shell, ^a still leads a tmux prefix.
@(test)
test_select_chords_are_the_editables :: proc(t: ^testing.T) {
    testing.expect_value(t, act_of(glfw.KEY_A, CTRL, .Text), app.Action.Select_All)
    testing.expect_value(t, act_of(glfw.KEY_L, CTRL, .Text), app.Action.Select_Line)
    testing.expect_value(t, act_of(glfw.KEY_A, CTRL, .Terminal), app.Action.None)
    testing.expect_value(t, act_of(glfw.KEY_L, CTRL, .Terminal), app.Action.None)
    // Alt+A is the cursor trail, unmoved: the two never shared a chord.
    testing.expect_value(t, act_of(glfw.KEY_A, ALT, .Text), app.Action.Cursor_Drop)
}

// The arrows, Enter and the clipboard are one bind each, answered by whichever surface has the
// keys. ^C reaches the terminal too, which is what lets it decline and interrupt instead.
@(test)
test_shared_chords_reach_every_context :: proc(t: ^testing.T) {
    for ctx in ([]app.Bind_Ctx{.Text, .Surface}) {
        testing.expect_value(t, act_of(glfw.KEY_DOWN, 0, ctx), app.Action.Nav_Down)
        testing.expect_value(t, act_of(glfw.KEY_ENTER, 0, ctx), app.Action.Activate)
    }
    for ctx in ([]app.Bind_Ctx{.Text, .Surface, .Terminal}) {
        testing.expect_value(t, act_of(glfw.KEY_C, CTRL, ctx), app.Action.Clip_Copy)
        testing.expect_value(t, act_of(glfw.KEY_V, CTRL, ctx), app.Action.Clip_Paste)
    }
}

// Shift is not written in the table: a Shift-qualified miss retries without it, and the action
// runs extending. That is what gives Shift+Down a mark sweep and ^Shift+C a copy for free.
@(test)
test_shift_falls_back_to_the_unshifted_bind :: proc(t: ^testing.T) {
    testing.expect_value(t, act_of(glfw.KEY_DOWN, SHIFT, .Surface), app.Action.Nav_Down)
    testing.expect_value(t, act_of(glfw.KEY_ENTER, SHIFT, .Surface), app.Action.Activate)
    testing.expect_value(t, act_of(glfw.KEY_D, CTRL | SHIFT, .Surface), app.Action.File_Delete)
    testing.expect_value(t, act_of(glfw.KEY_W, CTRL | SHIFT, .Surface), app.Action.File_Copy_Path)
    testing.expect_value(t, act_of(glfw.KEY_C, CTRL | SHIFT, .Terminal), app.Action.Clip_Copy)
}

// ...and an EXACT row always beats that fallback, which is the only reason ^Shift+Z can be a
// different verb from ^Z rather than an undo that extends nothing.
@(test)
test_an_exact_row_beats_the_shift_fallback :: proc(t: ^testing.T) {
    testing.expect_value(t, act_of(glfw.KEY_Z, CTRL, .Text), app.Action.Undo)
    testing.expect_value(t, act_of(glfw.KEY_Z, CTRL | SHIFT, .Text), app.Action.Redo)
}

// Global is searched from every context — including `.Shell`, where nothing else is. That is
// what keeps Escape and the Alt chords working over a full-screen program that owns the rest.
@(test)
test_global_is_reachable_from_every_context :: proc(t: ^testing.T) {
    for ctx in ([]app.Bind_Ctx{.Text, .Surface, .Terminal, .Shell}) {
        testing.expect_value(t, act_of(glfw.KEY_F, ALT, ctx), app.Action.Aux_Filetree)
        testing.expect_value(t, act_of(glfw.KEY_ESCAPE, 0, ctx), app.Action.Escape)
    }
    // `.Shell` finds Global and NOTHING else: a plain key there is the program's.
    testing.expect_value(t, act_of(glfw.KEY_PAGE_UP, 0, .Terminal), app.Action.Term_Sel_Up)
    testing.expect_value(t, act_of(glfw.KEY_PAGE_UP, 0, .Shell), app.Action.None)
    testing.expect_value(t, act_of(glfw.KEY_DOWN, 0, .Shell), app.Action.None)
}

// The two multi-cursor chords act on whatever editable has the keys, so they are Text binds. That
// placement is load-bearing: an open command line swallows the GLOBAL Alt chords (Alt+C would
// clear the line you are typing), and these two have to survive it.
@(test)
test_the_cursor_chords_are_text_binds :: proc(t: ^testing.T) {
    Pair :: struct {
        key: i32,
        act: app.Action,
    }
    for p in ([]Pair{{glfw.KEY_A, .Cursor_Drop}, {glfw.KEY_M, .Move_All}}) {
        b, ok := app.bind_find(app.BIND_DEFAULTS[:], app.Chord{p.key, ALT}, .Text)
        testing.expect(t, ok)
        testing.expect_value(t, b.act, p.act)
        ctxs := app.bind_ctxs(b.act)
        testing.expect(t, app.Bind_Ctx.Global not_in ctxs, "a global row would be swallowed")
    }
}

// One row covers Alt+1..9, and the offset is what names the session.
@(test)
test_a_run_row_covers_its_whole_span :: proc(t: ^testing.T) {
    b, ok := app.bind_find(app.BIND_DEFAULTS[:], app.Chord{glfw.KEY_3, ALT}, .Surface)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.Term_Goto)
    testing.expect_value(t, glfw.KEY_3 - b.chord.key, 2) // session 3 is offset 2

    _, ok = app.bind_find(app.BIND_DEFAULTS[:], app.Chord{glfw.KEY_0, ALT}, .Surface)
    testing.expect(t, !ok, "the run starts at 1; Alt+0 is not a session")

    b, ok = app.bind_find(app.BIND_DEFAULTS[:], app.Chord{glfw.KEY_9, CTRL}, .Surface)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.Browse_Place)
}

// **The table's own invariant.** First match wins, so a chord listed twice in one context would
// make the second row unreachable and no compiler would say so.
@(test)
test_no_chord_is_bound_twice_in_one_context :: proc(t: ^testing.T) {
    for x, i in app.BIND_DEFAULTS {
        for y in app.BIND_DEFAULTS[i + 1:] {
            ok := !app.bind_clash(x, y)
            testing.expectf(t, ok, "%v and %v fight over one chord", x.act, y.act)
        }
    }
}

// Alt+Q is held twice over: term.close, which declines outside its own pane, and then the file
// pane's discard. `skip` is how the dispatcher walks from the one to the other.
@(test)
test_alt_q_is_held_by_both_the_terminal_and_the_file_pane :: proc(t: ^testing.T) {
    q := app.Chord{glfw.KEY_Q, ALT}

    b, ok := app.bind_find(app.BIND_DEFAULTS[:], q, .Surface)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.Term_Close)

    b, ok = app.bind_find(app.BIND_DEFAULTS[:], q, .Surface, 1)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.File_Discard)

    _, ok = app.bind_find(app.BIND_DEFAULTS[:], q, .Surface, 2)
    testing.expect(t, !ok, "two holders, and the walk has to end")

    // The discard is a Surface row, so an editable holding the keys never reaches it.
    testing.expect_value(t, act_of(glfw.KEY_Q, ALT, .Text), app.Action.Term_Close)
    _, ok = app.bind_find(app.BIND_DEFAULTS[:], q, .Text, 1)
    testing.expect(t, !ok)
}

// The walk itself, through the seam a keystroke takes: the terminal verb declines where its pane
// is not up, and the chord reaches the file pane instead of dying there.
@(test)
test_a_declined_chord_reaches_the_next_holder :: proc(t: ^testing.T) {
    a: app.App
    append(&a.binds, ..app.BIND_DEFAULTS[:])
    app.editor_init(&a.editor)
    defer {delete(a.binds);app.editor_destroy(&a.editor)}

    q := app.Chord{glfw.KEY_Q, ALT}
    a.focus = .Aux

    a.aux_mode = .FileTree
    testing.expect(t, app.bind_dispatch(&a, q, glfw.KEY_Q, false), "the file pane takes it")

    a.aux_mode = .Terminal
    testing.expect(t, app.bind_dispatch(&a, q, glfw.KEY_Q, false), "its first holder keeps it")

    // A pane holding neither verb leaves the chord unclaimed, rather than the walk running on.
    a.aux_mode = .Grep
    testing.expect(t, !app.bind_dispatch(&a, q, glfw.KEY_Q, false))
}

// The keys this pass put on the table, and the two contexts they have to keep apart: the page
// keys are the editor's jump, and stay the terminal's copy cursor where a session has the keys.
@(test)
test_the_line_and_page_chords :: proc(t: ^testing.T) {
    testing.expect_value(t, act_of(glfw.KEY_TAB, 0, .Text), app.Action.Indent)
    testing.expect_value(t, act_of(glfw.KEY_TAB, SHIFT, .Text), app.Action.Outdent)
    testing.expect_value(t, act_of(glfw.KEY_SLASH, CTRL, .Text), app.Action.Comment_Toggle)
    testing.expect_value(t, act_of(glfw.KEY_HOME, CTRL, .Text), app.Action.Move_Doc_Start)
    testing.expect_value(t, act_of(glfw.KEY_END, CTRL, .Text), app.Action.Move_Doc_End)

    testing.expect_value(t, act_of(glfw.KEY_PAGE_UP, 0, .Text), app.Action.Jump_Up)
    testing.expect_value(t, act_of(glfw.KEY_PAGE_DOWN, 0, .Text), app.Action.Jump_Down)
    testing.expect_value(t, act_of(glfw.KEY_PAGE_UP, 0, .Terminal), app.Action.Term_Sel_Up)
    testing.expect_value(t, act_of(glfw.KEY_PAGE_DOWN, 0, .Terminal), app.Action.Term_Sel_Down)

    // Shift+Tab is a verb of its own, so it must not fall back to Tab-extending.
    b, ok := app.bind_find(app.BIND_DEFAULTS[:], app.Chord{glfw.KEY_TAB, SHIFT}, .Text)
    testing.expect(t, ok)
    testing.expect_value(t, b.chord.mods, SHIFT)
}
