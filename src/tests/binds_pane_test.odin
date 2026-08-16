package tests

import app ".."
import "core:strings"
import "core:testing"
import "vendor:glfw"

@(private = "file") C :: i32(glfw.MOD_CONTROL)
@(private = "file") A :: i32(glfw.MOD_ALT)

// A pane over two binds and one refused line, so every row kind is reachable without touching a
// config file.
@(private = "file")
fixture :: proc(a: ^app.App) {
    binds := []app.Bind{{{glfw.KEY_C, C}, .Clip_Copy}, {{glfw.KEY_Y, C}, .Clip_Copy}}
    errs := []app.Bind_Error{{12, "ctrl+quux: edit.save", .Bad_Chord}}
    app.binds_pane_init(&a.binds_pane, binds, errs)
}

@(private = "file")
row_of :: proc(bp: ^app.BindsPane, want: app.Action) -> int {
    for r in 0 ..< app.binds_pane_rows(bp) {
        if act, ok := app.binds_pane_action(bp, r); ok && act == want {
            return r
        }
    }
    return -1
}

// The row map: two buttons, then the refused lines, then one row per Action but `.None`.
@(test)
test_binds_pane_rows :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane

    testing.expect_value(t, app.binds_pane_rows(bp), 3 + 1 + len(app.Action) - 1)
    _, is_act := app.binds_pane_action(bp, app.ROW_BINDS_OPEN)
    testing.expect(t, !is_act, "a button is not an action row")
    _, is_err := app.binds_pane_err(bp, app.ROW_BINDS_ERRS)
    testing.expect(t, is_err)

    first, ok := app.binds_pane_action(bp, app.ROW_BINDS_ERRS + 1)
    testing.expect(t, ok)
    testing.expect_value(t, first, app.Action(1)) // .None owns no row
    testing.expect(t, row_of(bp, .Clip_Copy) > 0)
}

// Left/Right walk the chords ON a row: with ^C and ^Y both on clip.copy, this is what picks
// which one a delete or a rebind acts on.
@(test)
test_binds_pane_cycles_a_rows_chords :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)

    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 2)
    testing.expect_value(t, bp.chord, 0)
    app.binds_pane_cycle(bp, 1)
    testing.expect_value(t, bp.chord, 1)
    app.binds_pane_cycle(bp, 1)
    testing.expect_value(t, bp.chord, 0) // wraps
    app.binds_pane_cycle(bp, -1)
    testing.expect_value(t, bp.chord, 1)

    // Moving off the row starts the next one at its first chord.
    app.binds_pane_move(bp, 1)
    testing.expect_value(t, bp.chord, 0)
}

// Backspace drops the HIGHLIGHTED chord, not the row.
@(test)
test_binds_pane_delete_takes_the_highlighted_chord :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)
    bp.chord = 1 // ^y

    app.binds_pane_delete(bp)
    at := app.binds_of(bp, .Clip_Copy)
    testing.expect_value(t, len(at), 1)
    testing.expect_value(t, bp.working[at[0]].chord, app.Chord{glfw.KEY_C, C})
    testing.expect(t, bp.dirty)

    app.binds_pane_delete(bp)
    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 0) // an action may hold none
}

// A free chord applies at once; one another action holds in a SHARED context asks first.
@(test)
test_binds_pane_steal_needs_a_confirm :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .File_Mark)

    // Free: taken outright.
    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_J, C})
    testing.expect_value(t, bp.capture, app.Bind_Capture.None)
    testing.expect_value(t, len(app.binds_of(bp, .File_Mark)), 1)

    // Held by clip.copy, and Surface is a context they share: ask.
    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_C, C})
    testing.expect_value(t, bp.capture, app.Bind_Capture.Confirm)
    testing.expect_value(t, bp.steal, app.Action.Clip_Copy)
    testing.expect_value(t, len(app.binds_of(bp, .File_Mark)), 1) // nothing taken yet

    app.binds_pane_confirm(bp)
    testing.expect_value(t, bp.capture, app.Bind_Capture.None)
    testing.expect_value(t, len(app.binds_of(bp, .File_Mark)), 2)
    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 1) // ^c left clip.copy
}

// Contexts that never meet cannot collide, so no confirm: ^y is Redo in Text and Mark in Surface.
@(test)
test_binds_pane_no_confirm_across_contexts :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane

    // file.mark is Surface only and edit.save is Text only, so one chord serves both.
    surface := []app.Bind{{{glfw.KEY_D, C}, .File_Mark}}
    held, taken := app.bind_holder(surface, app.Chord{glfw.KEY_D, C}, .Save)
    testing.expect(t, !taken)
    testing.expect_value(t, held, app.Action.None)

    // clip.copy reaches Text too, so it DOES stand in edit.save's way.
    _, shared := app.bind_holder(bp.working[:], app.Chord{glfw.KEY_C, C}, .Save)
    testing.expect(t, shared, "clip.copy and edit.save share the Text context")

    // ...and rebinding a chord onto the action that already holds it is not a theft either.
    _, self := app.bind_holder(bp.working[:], app.Chord{glfw.KEY_C, C}, .Clip_Copy)
    testing.expect(t, !self)
}

// Rebind replaces the highlighted chord in place; Add appends beside it.
@(test)
test_binds_pane_rebind_vs_add :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)
    bp.chord = 0

    app.binds_pane_capture(bp, false)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_B, A})
    at := app.binds_of(bp, .Clip_Copy)
    testing.expect_value(t, len(at), 2) // still two, one of them changed
    testing.expect_value(t, bp.working[at[0]].chord, app.Chord{glfw.KEY_B, A})

    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_K, A})
    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 3)
}

// An error row is acknowledged with the same key, and its going is what unblocks a save: the
// block is rewritten wholesale, so an unread line would vanish without ever being seen.
@(test)
test_binds_pane_errors_block_the_save :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane

    testing.expect(t, !app.binds_pane_save(&a), "a refused line must block the write")

    bp.sel = app.ROW_BINDS_ERRS
    app.binds_pane_delete(bp)
    testing.expect_value(t, len(bp.errs), 0)
    _, still := app.binds_pane_err(bp, app.ROW_BINDS_ERRS)
    testing.expect(t, !still)
}

// The pane groups by the action name's prefix, which is where its section headers come from.
@(test)
test_action_group :: proc(t: ^testing.T) {
    testing.expect_value(t, app.action_group("file.mark"), "file")
    testing.expect_value(t, app.action_group("none"), "none")
    for act in app.Action {
        testing.expect(t, app.action_group(app.action_name(act)) != "")
    }
}

// The pane's rows flatten with a header per group and a value column of chords.
@(test)
test_binds_rows_flatten :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)

    rows := app.binds_rows(bp, 40, context.temp_allocator)
    buttons, errors, actions, headers := 0, 0, 0, 0
    chords := ""
    for r in rows {
        switch r.kind {
        case .Button:
            buttons += 1
        case .Error:
            errors += 1
        case .Header:
            headers += 1
        case .Action:
            actions += 1
            if r.item == bp.sel {
                chords = r.value
            }
        case .Rule, .Note:
        }
    }
    testing.expect_value(t, buttons, 3)
    testing.expect_value(t, errors, 1)
    testing.expect_value(t, actions, len(app.Action) - 1)
    testing.expect(t, headers > 2, "one header per action group, plus the two blocks above")

    // Both chords are listed, and the highlighted one is called out.
    testing.expect(t, strings.contains(chords, "ctrl+c"))
    testing.expect(t, strings.contains(chords, "ctrl+y"))
    testing.expect(t, strings.contains(chords, "[ctrl+c]"))
}

// The pane must refuse what the LOADER refuses, or Ctrl+S writes a file that will not read back.
@(test)
test_binds_pane_refuses_a_bare_key_in_text :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane

    bp.sel = row_of(bp, .Save) // edit.save is Text
    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_K, 0})
    testing.expect_value(t, bp.capture, app.Bind_Capture.Rejected)
    testing.expect_value(t, bp.fault, app.Bind_Fault.Bare_In_Text)
    testing.expect_value(t, len(app.binds_of(bp, .Save)), 0)

    // The same bare key is fine on a Surface action, where nothing types.
    bp.sel = row_of(bp, .File_Mark)
    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_K, 0})
    testing.expect_value(t, bp.capture, app.Bind_Capture.None)
    testing.expect_value(t, len(app.binds_of(bp, .File_Mark)), 1)
}

// Pressing a chord the action already holds is a no-op, not a second identical row.
@(test)
test_binds_pane_ignores_a_chord_it_already_has :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)

    app.binds_pane_capture(bp, true)
    app.binds_pane_take(bp, app.Chord{glfw.KEY_C, C})
    testing.expect_value(t, bp.capture, app.Bind_Capture.None)
    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 2)
    testing.expect(t, !bp.dirty, "nothing changed, so nothing to save")
}

// The `:rebind` grammar. Parsing is split from doing, so every form is reachable without a pane.
@(test)
test_rebind_parse :: proc(t: ^testing.T) {
    Case :: struct {
        line:   string,
        op:     app.Rebind_Op,
        n:      int,
        action: string,
        chord:  string,
    }
    for c in ([]Case {
            {"nav.down down", .Replace, 0, "nav.down", "down"}, // no selector: the first chord
            {"1 nav.down alt+j", .Replace, 1, "nav.down", "alt+j"},
            {"+ nav.down alt+j", .Add, 0, "nav.down", "alt+j"},
            {"- nav.down", .Clear, 0, "nav.down", ""},
            {"-2 nav.down", .Clear, 2, "nav.down", ""},
            {"  +   nav.down   alt+j  ", .Add, 0, "nav.down", "alt+j"},
        }) {
        op, n, action, chord, ok := app.rebind_parse(c.line)
        testing.expectf(t, ok, "%q did not parse", c.line)
        testing.expect_value(t, op, c.op)
        testing.expect_value(t, n, c.n)
        testing.expect_value(t, action, c.action)
        testing.expect_value(t, chord, c.chord)
    }

    for bad in ([]string{"", "   ", "+", "-", "2"}) {
        _, _, _, _, ok := app.rebind_parse(bad)
        testing.expectf(t, !ok, "%q names no action", bad)
    }
}

// bind_set is the one edit both paths run through, so the pane and the command line cannot
// diverge over what a rebind means.
@(test)
test_bind_set_replaces_adds_and_takes :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane

    // Replace the second of clip.copy's two.
    took, _, ok := app.bind_set(bp, .Clip_Copy, 1, app.Chord{glfw.KEY_J, A}, false)
    testing.expect(t, ok)
    testing.expect_value(t, took, app.Action.None)
    at := app.binds_of(bp, .Clip_Copy)
    testing.expect_value(t, len(at), 2)
    testing.expect_value(t, bp.working[at[1]].chord, app.Chord{glfw.KEY_J, A})

    // A slot that is not there is refused rather than appended by accident.
    _, _, miss := app.bind_set(bp, .Clip_Copy, 7, app.Chord{glfw.KEY_K, A}, false)
    testing.expect(t, !miss)

    // Adding names whoever loses the chord.
    took, _, ok = app.bind_set(bp, .File_Mark, 0, app.Chord{glfw.KEY_C, C}, true)
    testing.expect(t, ok)
    testing.expect_value(t, took, app.Action.Clip_Copy)
    testing.expect_value(t, len(app.binds_of(bp, .Clip_Copy)), 1)

    // And the loader's rule holds here too.
    _, why, bare := app.bind_set(bp, .Save, 0, app.Chord{glfw.KEY_K, 0}, true)
    testing.expect(t, !bare)
    testing.expect_value(t, why, app.Bind_Fault.Bare_In_Text)
}

// Fill mode stages the line the command line would take; the toggle picks which path Enter runs.
@(test)
test_rebind_line_and_mode_toggle :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.binds_pane_destroy(&a.binds_pane)
    bp := &a.binds_pane
    bp.sel = row_of(bp, .Clip_Copy)
    bp.chord = 1

    line := app.rebind_line(bp, .Clip_Copy, false, context.temp_allocator)
    testing.expect_value(t, line, ":rebind 1 clip.copy ")
    add := app.rebind_line(bp, .Clip_Copy, true, context.temp_allocator)
    testing.expect_value(t, add, ":rebind + clip.copy ")

    testing.expect_value(t, bp.mode, app.Bind_Edit.Fill) // the default: read the line first
    bp.sel = app.ROW_BINDS_MODE
    app.binds_pane_activate(&a)
    testing.expect_value(t, bp.mode, app.Bind_Edit.Capture)
    app.binds_pane_activate(&a)
    testing.expect_value(t, bp.mode, app.Bind_Edit.Fill)
}
