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

    // Layout: settings, the search row, then one row per (filtered) language.
    rows := app.config_pane_rows(&cp)
    testing.expect_value(t, rows, app.SETTING_COUNT + 1 + 3)

    // Up at the top clamps to 0.
    app.config_pane_move(&cp, -5)
    testing.expect_value(t, cp.sel, 0)

    // Row 0 is a setting; SETTING_COUNT is the search row (neither setting nor lang);
    // the first language is right after it.
    _, is_setting := app.config_pane_setting(0)
    testing.expect(t, is_setting)
    testing.expect(t, app.config_pane_is_search(app.SETTING_COUNT))
    _, past := app.config_pane_setting(app.SETTING_COUNT)
    testing.expect(t, !past)
    testing.expect(t, app.config_pane_lang(&cp, app.SETTING_COUNT) == nil)
    testing.expect(t, app.config_pane_lang(&cp, app.SETTING_COUNT + 1) != nil)

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
    l := app.config_pane_lang(&cp, app.SETTING_COUNT + 1)
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

    // Theme always offers the baked-in default and the Thrawk "global" follow option,
    // in that order, ahead of any discovered themes/ files.
    theme := app.setting_options(&a, .Theme)
    testing.expect(t, len(theme) >= 2)
    testing.expect_value(t, theme[0], "default")
    testing.expect_value(t, theme[1], "global")
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

// The "global" theme token resolves to ~/.config/unrawk/active.theme when that file
// exists (the universal Thrawk theme), and to "" (baked-in default) when it doesn't.
@(test)
test_theme_resolve_global :: proc(t: ^testing.T) {
    home := "/tmp/slopd_home_test"
    unrawk := "/tmp/slopd_home_test/.config/unrawk"
    active := "/tmp/slopd_home_test/.config/unrawk/active.theme"
    for d in ([]string{home, "/tmp/slopd_home_test/.config", unrawk}) {
        os.make_directory(d)
    }
    defer {
        os.remove(active)
        os.remove(unrawk)
        os.remove("/tmp/slopd_home_test/.config")
        os.remove(home)
    }

    old := os.get_env("HOME", context.temp_allocator)
    os.set_env("HOME", home)
    defer os.set_env("HOME", old)

    os.remove(active) // ensure absent first
    testing.expect_value(t, app.theme_resolve("global"), "") // missing -> baked-in default

    testing.expect(t, os.write_entire_file(active, transmute([]byte)string("bg: #000000\n")) == nil)
    testing.expect_value(t, app.theme_resolve("global"), active)
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

    os.set_env("SLOPD_CONFIG", path)
    defer os.unset_env("SLOPD_CONFIG")

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
