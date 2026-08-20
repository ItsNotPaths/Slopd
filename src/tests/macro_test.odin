package tests

import app ".."
import "core:os"
import "core:testing"

@(private = "file")
chord :: proc(t: ^testing.T, s: string) -> app.Chord {
    c, ok := app.chord_parse(s)
    testing.expectf(t, ok, "%q is not a chord", s)
    return c
}

// --- the checks a macro passes, wherever it was written ---

@(test)
test_macro_make_reads_the_run_sigil :: proc(t: ^testing.T) {
    m, _, ok := app.macro_make(chord(t, "ctrl+alt+g"), "!git status && :ls", app.BIND_DEFAULTS[:])
    testing.expect(t, ok)
    testing.expect(t, m.run)
    testing.expect_value(t, m.cmd, "git status && :ls")

    m, _, ok = app.macro_make(chord(t, "f5"), "cargo build", app.BIND_DEFAULTS[:])
    testing.expect(t, ok)
    testing.expect(t, !m.run) // no sigil: the line is staged, not run
    testing.expect_value(t, m.cmd, "cargo build")
}

// A macro fires wherever you press it, so a bare printable key would stop that letter typing
// everywhere — not only in the Text context, which is all a bind has to answer for.
@(test)
test_macro_make_refuses_a_bare_key :: proc(t: ^testing.T) {
    _, why, ok := app.macro_make(chord(t, "g"), "git status", app.BIND_DEFAULTS[:])
    testing.expect(t, !ok)
    testing.expect_value(t, why, app.Bind_Fault.Bare_In_Text)

    _, why, ok = app.macro_make(chord(t, "shift+g"), "git status", app.BIND_DEFAULTS[:])
    testing.expect(t, !ok, "Shift+G is still G")
    testing.expect_value(t, why, app.Bind_Fault.Bare_In_Text)
}

// Alt+F is pane.files, and Alt+3 is inside term.goto's RUN of eight — both taken.
@(test)
test_macro_make_refuses_a_chord_an_action_holds :: proc(t: ^testing.T) {
    _, why, ok := app.macro_make(chord(t, "alt+f"), "git status", app.BIND_DEFAULTS[:])
    testing.expect(t, !ok)
    testing.expect_value(t, why, app.Bind_Fault.Chord_Taken)

    act, held := app.macro_taken(app.BIND_DEFAULTS[:], chord(t, "alt+3"))
    testing.expect(t, held, "alt+3 is the third step of term.goto's run")
    testing.expect_value(t, act, app.Action.Term_Goto)

    _, free := app.macro_taken(app.BIND_DEFAULTS[:], chord(t, "ctrl+alt+g"))
    testing.expect(t, !free)
}

@(test)
test_macro_make_refuses_an_empty_command :: proc(t: ^testing.T) {
    _, why, ok := app.macro_make(chord(t, "f5"), "   ", app.BIND_DEFAULTS[:])
    testing.expect(t, !ok)
    testing.expect_value(t, why, app.Bind_Fault.No_Command)

    _, why, ok = app.macro_make(chord(t, "f5"), "!", app.BIND_DEFAULTS[:])
    testing.expect(t, !ok, "a sigil with nothing after it commands nothing")
    testing.expect_value(t, why, app.Bind_Fault.No_Command)
}

// --- lines ---

@(test)
test_macro_line_round_trips :: proc(t: ^testing.T) {
    for src in ([]string{"ctrl+alt+g: !git status && :ls", "f5: cargo build", "alt+f5: :ls"}) {
        m, _, ok := app.macro_line(src, nil, app.BIND_DEFAULTS[:])
        testing.expectf(t, ok, "%q was refused", src)
        testing.expect_value(t, app.macro_line_text(m, context.temp_allocator), src)
    }
}

@(test)
test_macro_line_faults :: proc(t: ^testing.T) {
    _, why, ok := app.macro_line("f5 cargo build", nil, app.BIND_DEFAULTS[:])
    testing.expect(t, !ok, "no colon, so no chord")
    testing.expect_value(t, why, app.Bind_Fault.Bad_Chord)

    _, why, ok = app.macro_line("wharrgarbl: :ls", nil, app.BIND_DEFAULTS[:])
    testing.expect(t, !ok)
    testing.expect_value(t, why, app.Bind_Fault.Bad_Chord)

    claimed := []app.Macro{{chord(t, "f5"), "cargo build", false}}
    _, why, ok = app.macro_line("f5: :ls", claimed, app.BIND_DEFAULTS[:])
    testing.expect(t, !ok, "one chord holds one macro")
    testing.expect_value(t, why, app.Bind_Fault.Already_Bound)
}

// The Shift retry is a BIND's, and means extend; a macro has no second meaning to extend into.
@(test)
test_macro_find_is_exact :: proc(t: ^testing.T) {
    macros := []app.Macro{{chord(t, "ctrl+alt+g"), "git status", true}}
    _, ok := app.macro_find(macros, chord(t, "ctrl+alt+g"))
    testing.expect(t, ok)
    _, shifted := app.macro_find(macros, chord(t, "ctrl+alt+shift+g"))
    testing.expect(t, !shifted)
}

// --- the block ---

// Good lines load in file order, and a refused one is recorded with its line number and its text
// rather than vanishing. `binds` is the live table, so it decides what is already spoken for.
@(test)
test_load_macros_records_bad_lines :: proc(t: ^testing.T) {
    path := "/tmp/slopd_macros.config"
    defer os.remove(path)
    src := `indent: tab

[macros]
f5: !git status && :ls
ctrl+alt+g: cargo build
alt+f: :ls
f5: :ls
ctrl+alt+h:
`
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    config_override(path)
    defer config_override_release()
    macros, errs := app.load_macros(app.BIND_DEFAULTS[:])
    defer app.macros_destroy(&macros)
    defer app.bind_errors_destroy(errs)

    testing.expect_value(t, len(macros), 2)
    testing.expect_value(t, macros[0].chord, chord(t, "f5"))
    testing.expect_value(t, macros[0].cmd, "git status && :ls")
    testing.expect(t, macros[0].run)
    testing.expect_value(t, macros[1].cmd, "cargo build")
    testing.expect(t, !macros[1].run)

    testing.expect_value(t, len(errs), 3)
    testing.expect_value(t, errs[0].line, 6)
    testing.expect_value(t, errs[0].text, "alt+f: :ls")
    testing.expect_value(t, errs[0].why, app.Bind_Fault.Chord_Taken)
    testing.expect_value(t, errs[1].why, app.Bind_Fault.Already_Bound)
    testing.expect_value(t, errs[2].why, app.Bind_Fault.No_Command)
}

// Nothing outside the block is a macro, and a file without one loads none.
@(test)
test_load_macros_stays_in_its_block :: proc(t: ^testing.T) {
    path := "/tmp/slopd_macros_none.config"
    defer os.remove(path)
    src := "f5: cargo build\n\n[binds]\nalt+f: pane.grep\n"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    config_override(path)
    defer config_override_release()
    macros, errs := app.load_macros(app.BIND_DEFAULTS[:])
    defer app.macros_destroy(&macros)
    defer app.bind_errors_destroy(errs)

    testing.expect_value(t, len(macros), 0)
    testing.expect_value(t, len(errs), 0)
}

// The block is written back the way it is read, comment line and all.
@(test)
test_config_macros_write_round_trips :: proc(t: ^testing.T) {
    path := "/tmp/slopd_macros_write.config"
    defer os.remove(path)
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("indent: tab\n")) == nil)
    config_override(path)
    defer config_override_release()

    macros := []app.Macro {
        {chord(t, "f5"), "cargo build", false},
        {chord(t, "ctrl+alt+g"), ":gs", true},
    }
    testing.expect(t, app.config_macros_write(macros, nil))

    back, errs := app.load_macros(app.BIND_DEFAULTS[:])
    defer app.macros_destroy(&back)
    defer app.bind_errors_destroy(errs)
    testing.expect_value(t, len(errs), 0)
    testing.expect_value(t, len(back), 2)
    testing.expect_value(t, back[0].cmd, "cargo build")
    testing.expect_value(t, back[1].cmd, ":gs")
    testing.expect(t, back[1].run)

    // A line still in error blocks it: the block is rewritten wholesale, so it would be lost.
    bad := []app.Bind_Error{{4, "alt+f: :ls", .Chord_Taken}}
    testing.expect(t, !app.config_macros_write(macros, bad))
}

// --- `:macro`'s grammar ---

@(test)
test_macro_parse_splits_the_line :: proc(t: ^testing.T) {
    remove, chord_text, value, ok := app.macro_parse(" alt+1  !git status && :ls ")
    testing.expect(t, ok)
    testing.expect(t, !remove)
    testing.expect_value(t, chord_text, "alt+1")
    testing.expect_value(t, value, "!git status && :ls") // the sigil rides along to macro_make

    remove, chord_text, value, ok = app.macro_parse("- f5")
    testing.expect(t, ok)
    testing.expect(t, remove)
    testing.expect_value(t, chord_text, "f5")
    testing.expect_value(t, value, "")

    _, _, _, ok = app.macro_parse("   ")
    testing.expect(t, !ok, "no chord, no macro")
}
