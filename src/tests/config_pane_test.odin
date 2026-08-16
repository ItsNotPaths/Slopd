package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_config_pane_nav :: proc(t: ^testing.T) {
    cp: app.ConfigPane
    app.config_pane_init(&cp, nil)
    defer app.config_pane_destroy(&cp)

    // Seed a deterministic lang list so the nav assertions don't depend on the
    // generated `languages` registry being present, then rebuild the filtered view.
    clear(&cp.langs)
    append(&cp.langs, app.LangStatus{name = "a"}, app.LangStatus{name = "b"}, app.LangStatus{name = "c"})
    app.config_pane_filter(&cp)

    // Layout: the install row, the settings, the search row, then one row per (filtered)
    // language.
    rows := app.config_pane_rows(&cp)
    testing.expect_value(t, rows, app.ROW_LANGS + 3)

    // Up at the top clamps to the install row.
    app.config_pane_move(&cp, -5)
    testing.expect_value(t, cp.sel, app.ROW_INSTALL)

    // Each block answers for its own rows and no others: the install row is not a setting,
    // the search row is neither a setting nor a language, and the languages start after it.
    testing.expect(t, app.config_pane_is_install(app.ROW_INSTALL))
    _, install_is_setting := app.config_pane_setting(app.ROW_INSTALL)
    testing.expect(t, !install_is_setting)
    _, is_setting := app.config_pane_setting(app.ROW_SETTINGS)
    testing.expect(t, is_setting)
    testing.expect(t, app.config_pane_is_search(app.ROW_SEARCH))
    _, past := app.config_pane_setting(app.ROW_SEARCH)
    testing.expect(t, !past)
    testing.expect(t, app.config_pane_lang(&cp, app.ROW_SEARCH) == nil)
    testing.expect(t, app.config_pane_lang(&cp, app.ROW_LANGS) != nil)

    // Down past the end clamps to the last row.
    app.config_pane_move(&cp, rows + 10)
    testing.expect_value(t, cp.sel, rows - 1)
}

@(test)
test_config_pane_filter :: proc(t: ^testing.T) {
    cp: app.ConfigPane
    app.config_pane_init(&cp, nil)
    defer app.config_pane_destroy(&cp)

    clear(&cp.langs)
    append(
        &cp.langs,
        app.LangStatus{name = "python"},
        app.LangStatus{name = "javascript"},
        app.LangStatus{name = "typescript"},
        app.LangStatus{name = "c"},
    )

    app.config_pane_filter(&cp)
    testing.expect_value(t, len(cp.filtered), 4) // empty query -> all langs

    app.doc_set_text(&cp.search, "script")
    app.config_pane_filter(&cp)
    testing.expect_value(t, len(cp.filtered), 2) // javascript, typescript

    app.doc_set_text(&cp.search, "PY") // case-insensitive
    app.config_pane_filter(&cp)
    testing.expect_value(t, len(cp.filtered), 1)

    // The first filtered language resolves through the search-row offset.
    l := app.config_pane_lang(&cp, app.ROW_LANGS)
    testing.expect(t, l != nil)
    testing.expect_value(t, l.name, "python")

    app.doc_set_text(&cp.search, "nomatch")
    app.config_pane_filter(&cp)
    testing.expect_value(t, len(cp.filtered), 0)
}

@(test)
test_setting_options :: proc(t: ^testing.T) {
    a: app.App

    indent := app.setting_options(&a, .Indent)
    testing.expect_value(t, len(indent), 4)
    testing.expect_value(t, indent[0], "tab")
    testing.expect_value(t, indent[2], "spaces4")

    ln := app.setting_options(&a, .LineNumbers)
    testing.expect_value(t, len(ln), 2)
    testing.expect_value(t, ln[0], "global")
    testing.expect_value(t, ln[1], "relative")

    // Theme always offers the baked-in default first, ahead of any discovered themes/
    // files. Every other option is a file name from that one directory.
    theme := app.setting_options(&a, .Theme)
    testing.expect(t, len(theme) >= 1)
    testing.expect_value(t, theme[0], "default")
    for name in theme {
        testing.expect(t, !strings.contains(name, "/"))
    }
}

// The on/off reading-aid settings: each offers on/off, reflects the App flag as its
// value, and commits back to the flag (Folding also expands existing folds on off).
@(test)
test_onoff_settings :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    for s in ([]app.Setting{.Folding, .IndentGuides, .Whitespace}) {
        opts := app.setting_options(&a, s)
        testing.expect_value(t, len(opts), 2)
        testing.expect_value(t, opts[0], "on")
        testing.expect_value(t, opts[1], "off")
    }

    a.show_guides = true
    testing.expect_value(t, app.setting_value(&a, .IndentGuides), "on")
    a.show_guides = false
    testing.expect_value(t, app.setting_value(&a, .IndentGuides), "off")

    // Turning folding off expands every open fold (the mechanism setting_commit runs;
    // commit itself persists to a global-env-selected file, so it isn't exercised here
    // — parallel tests share that env var). The on/off parser round-trips.
    on, ok := app.parse_on_off("off")
    testing.expect(t, ok && !on)
    _, bad := app.parse_on_off("maybe")
    testing.expect(t, !bad)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "def f():\n    a = 1\n    b = 2\nx = 3")
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)
    app.editor_clear_folds(&a.editor)
    testing.expect_value(t, len(b.folds), 0) // folds expanded
}

// Opening a setting dropdown pre-selects the current value so the active choice is
// highlighted.
@(test)
test_config_open_setting :: proc(t: ^testing.T) {
    a: app.App
    app.config_pane_init(&a.config_pane, nil)
    defer app.config_pane_destroy(&a.config_pane)

    a.indent = {.Spaces, 4} // -> "spaces4", index 2 in the indent options
    app.config_pane_open_setting(&a, .Indent)
    testing.expect_value(t, a.config_pane.open, app.Open_Kind.Setting)
    testing.expect_value(t, a.config_pane.opt_sel, 2)
}

// The two git rows are deliberately different kinds of row. git_tool is a COMMAND LINE, so
// it is free text with no dropdown at all and no menu guessing at what you meant; git_term
// is a closed choice (a session, or its own window) and stays a dropdown, which needs a
// token for the empty case.
@(test)
test_git_settings :: proc(t: ^testing.T) {
    a: app.App

    // git_tool: text, so no options, and its value is whatever is set — "" when unset.
    testing.expect(t, app.setting_is_text(.GitTool))
    testing.expect(t, app.setting_options(&a, .GitTool) == nil)
    testing.expect_value(t, app.setting_value(&a, .GitTool), "")
    a.git_tool = "sublime_merge -n"
    testing.expect_value(t, app.setting_value(&a, .GitTool), "sublime_merge -n")

    // Opening a dropdown on it is a no-op rather than an empty menu.
    app.config_pane_init(&a.config_pane, nil)
    defer app.config_pane_destroy(&a.config_pane)
    app.config_pane_open_setting(&a, .GitTool)
    testing.expect_value(t, a.config_pane.open, app.Open_Kind.None)

    // git_term: a dropdown, and no other setting is text.
    testing.expect(t, !app.setting_is_text(.GitTerm))
    testing.expect(t, !app.setting_is_text(.Theme))
    testing.expect_value(t, app.setting_value(&a, .GitTerm), "detached")

    // No sessions open: "detached" plus the one slot a launch can reach (git_term_slot's
    // "a number past the end opens the next one, and only one").
    terms := app.setting_options(&a, .GitTerm)
    testing.expect_value(t, len(terms), 2)
    testing.expect_value(t, terms[0], "detached")
    testing.expect_value(t, terms[1], "1")

    // A configured session past that is still offered, so opening the dropdown lands on the
    // value that is actually set rather than silently pointing at "detached".
    a.git_term = 7
    testing.expect_value(t, app.setting_value(&a, .GitTerm), "7")
    terms = app.setting_options(&a, .GitTerm)
    testing.expect_value(t, terms[len(terms) - 1], "7")
    app.config_pane_open_setting(&a, .GitTerm)
    testing.expect_value(t, a.config_pane.opt_sel, len(terms) - 1)

    // run_term names the same sessions MINUS the detached row: every value it can hold is a
    // session, so a "detached" option would be one the setting cannot store.
    a.run_term = 1
    runs := app.setting_options(&a, .RunTerm)
    testing.expect_value(t, len(runs), 1)
    testing.expect_value(t, runs[0], "1")
    testing.expect_value(t, app.setting_value(&a, .RunTerm), "1")
    testing.expect(t, !app.setting_commit(&a, .RunTerm, "detached"), "run_term has no detached case")
    testing.expect(t, !app.setting_commit(&a, .RunTerm, "0"), "t0 is not a session")
    testing.expect_value(t, a.run_term, 1)
}

// The free-text row is an editor while it is highlighted: landing on it seeds the Doc from
// the stored value, and leaving it commits what was typed. Both halves run through
// config_edit_sync, so a click reaches them exactly as the arrows do.
@(test)
test_config_text_setting_edit :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_text_edit_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("git_tool: tig\n")) == nil)
    defer os.remove(path)
    app.config_path_override = path // a commit PERSISTS; keep it off the real config
    defer app.config_path_override = ""

    a: app.App
    a.git_tool = strings.clone("tig") // owned, as main's clone makes it
    defer delete(a.git_tool)
    app.config_pane_init(&a.config_pane, nil)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    row := app.ROW_SETTINGS + int(app.Setting.GitTool)

    // Off the row: no Doc is live, and nothing is committed.
    app.config_edit_sync(&a)
    testing.expect_value(t, cp.edit_row, -1)

    // On it: seeded with the stored value, caret at the end.
    cp.sel = row
    app.config_edit_sync(&a)
    testing.expect_value(t, cp.edit_row, row)
    testing.expect_value(t, app.doc_string(&cp.edit, context.temp_allocator), "tig")

    // A visit that changes nothing must not rewrite the file — the mtime would churn and
    // every "did I edit this?" answer would be yes.
    cp.sel = 0
    testing.expect(t, !app.config_edit_commit(&a))
    app.config_edit_sync(&a)
    testing.expect_value(t, cp.edit_row, -1)
    out, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, string(out), "git_tool: tig\n")

    // Type a full command line — spaces, flags and all — and leave the row.
    cp.sel = row
    app.config_edit_sync(&a)
    app.doc_set_text(&cp.edit, "sublime_merge -n")
    cp.sel = 0
    app.config_edit_sync(&a)
    testing.expect_value(t, a.git_tool, "sublime_merge -n")
    out, _ = os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, string(out), "git_tool: sublime_merge -n\n")

    // And it reads back as itself: the value the pane shows is the value the file holds.
    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.git_tool, "sublime_merge -n")
}

// Free text is the one setting a user can type an unreadable value into: a '#' after a space
// opens a comment, so the file would read back short. setting_commit refuses it and the row
// keeps the tool it had — its stated contract for an invalid value.
@(test)
test_config_text_setting_rejects_comment :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_text_reject_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("git_tool: tig\n")) == nil)
    defer os.remove(path)
    app.config_path_override = path
    defer app.config_path_override = ""

    a: app.App
    a.git_tool = strings.clone("tig")
    defer delete(a.git_tool)
    app.config_pane_init(&a.config_pane, nil)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    cp.sel = app.ROW_SETTINGS + int(app.Setting.GitTool)
    app.config_edit_sync(&a)
    app.doc_set_text(&cp.edit, "sh -c foo # bar")
    testing.expect(t, !app.config_edit_commit(&a))
    testing.expect_value(t, a.git_tool, "tig") // unchanged
    out, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, string(out), "git_tool: tig\n") // and unwritten

    // A '#' glued to a token is part of the value, not a comment, so it commits.
    app.doc_set_text(&cp.edit, "sh -c foo#bar")
    testing.expect(t, app.config_edit_commit(&a))
    testing.expect_value(t, a.git_tool, "sh -c foo#bar")
}

// A caret is live only while a row that edits text owns the keystrokes. The painter and the
// frame scheduler both ask this one proc, because a pane that stops redrawing leaves a caret
// frozen in whatever blink phase it was last painted in.
@(test)
test_config_caret_live :: proc(t: ^testing.T) {
    a: app.App
    app.config_pane_init(&a.config_pane, nil)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    cp.sel = app.ROW_SEARCH

    a.focus = .Aux
    a.aux_mode = .Config
    testing.expect(t, app.config_caret_live(&a))
    testing.expect(t, app.caret_shown(&a))

    cp.open = .Setting // a dropdown is over it
    testing.expect(t, !app.config_caret_live(&a))
    cp.open = .None

    cp.sel = app.ROW_SETTINGS // a settings row: a dropdown, nothing to type into
    testing.expect(t, !app.config_caret_live(&a))

    cp.sel = app.ROW_INSTALL // and neither is Slopd's own row
    testing.expect(t, !app.config_caret_live(&a))

    cp.sel = app.ROW_SETTINGS + int(app.Setting.GitTool) // the free-text setting is an editor too
    testing.expect(t, app.config_caret_live(&a))
    cp.sel = app.ROW_SEARCH

    a.focus = .Editor // the pane is on screen but not taking keys
    testing.expect(t, !app.config_caret_live(&a))
}

// A theme token is a NAME, never a path. Anything with a '/' in it would reach outside
// themes/ beside the binary, so it resolves to "" and the baked-in default stands.
@(test)
test_theme_resolve_refuses_paths :: proc(t: ^testing.T) {
    testing.expect_value(t, app.theme_resolve("/etc/passwd"), "")
    testing.expect_value(t, app.theme_resolve("../../secret.theme"), "")
    testing.expect_value(t, app.theme_resolve("~/.config/unrawk/active.theme"), "")
    testing.expect_value(t, app.theme_resolve("no_such_theme"), "") // a name, but no such file
}

@(test)
test_lang_options :: proc(t: ^testing.T) {
    buf: [len(app.LangOption)]app.LangOption

    absent := app.lang_options(false, buf[:])
    testing.expect_value(t, len(absent), 2)
    testing.expect_value(t, absent[0], app.LangOption.Health)
    testing.expect_value(t, absent[1], app.LangOption.Install)

    present := app.lang_options(true, buf[:])
    testing.expect_value(t, len(present), 3)
    testing.expect_value(t, present[1], app.LangOption.Update)
    testing.expect_value(t, present[2], app.LangOption.Uninstall)
}

@(test)
test_grammar_status_roundtrip :: proc(t: ^testing.T) {
    dir := "/tmp"
    lang := "slopdtestgrammar" // not a real lang; present/uninstall don't gate on the registry
    lib := app.grammar_lib_path(dir, lang, context.temp_allocator)
    testing.expect(t, os.write_entire_file(lib, []u8{0}) == nil)
    defer os.remove(lib)

    testing.expect(t, app.grammar_present(dir, lang))

    ok, _ := app.grammar_uninstall(dir, lang)
    testing.expect(t, ok)
    testing.expect(t, !app.grammar_present(dir, lang))
}

// Writeback preserves comments + unknown/per-lang lines, replaces a present key in
// place, and appends a missing one — and the result reloads to the same values.
@(test)
test_config_writeback :: proc(t: ^testing.T) {
    path := "/tmp/slopd_writeback_test.config"
    seed := "# my config\nline_numbers: global\nlang.odin.path: /opt/grammars/odin.so\n"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)seed) == nil)
    defer os.remove(path)

    app.config_path_override = path
    defer app.config_path_override = ""

    testing.expect(t, app.config_set("line_numbers", "relative")) // replace in place
    testing.expect(t, app.config_set("indent", "spaces2")) // append (was absent)

    out := string(os.read_entire_file_from_path(path, context.temp_allocator) or_else nil)
    testing.expect(t, strings.contains(out, "# my config")) // comment preserved
    testing.expect(t, strings.contains(out, "lang.odin.path: /opt/grammars/odin.so")) // per-lang line preserved
    testing.expect(t, strings.contains(out, "line_numbers: relative"))
    testing.expect(t, !strings.contains(out, "line_numbers: global")) // replaced, not duplicated
    testing.expect(t, strings.contains(out, "indent: spaces2"))

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.line_numbers, app.Line_Numbers.Relative)
    testing.expect_value(t, cfg.indent.kind, app.Indent_Kind.Spaces)
    testing.expect_value(t, cfg.indent.width, 2)
}
