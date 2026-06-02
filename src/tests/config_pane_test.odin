package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_config_pane_nav :: proc(t: ^testing.T) {
    cp: app.ConfigPane
    app.config_pane_init(&cp)
    defer app.config_pane_destroy(&cp)

    // Seed a deterministic lang list so the nav assertions don't depend on the
    // generated `languages` registry being present.
    clear(&cp.langs)
    append(&cp.langs, app.LangStatus{name = "a"}, app.LangStatus{name = "b"}, app.LangStatus{name = "c"})

    rows := app.config_pane_rows(&cp)
    testing.expect_value(t, rows, app.SETTING_COUNT + 3)

    // Up at the top clamps to 0.
    app.config_pane_move(&cp, -5)
    testing.expect_value(t, cp.sel, 0)

    // The first rows are settings; past them are languages.
    _, is_setting := app.config_pane_setting(0)
    testing.expect(t, is_setting)
    _, past := app.config_pane_setting(app.SETTING_COUNT)
    testing.expect(t, !past)
    testing.expect(t, app.config_pane_lang(&cp, app.SETTING_COUNT) != nil)

    // Down past the end clamps to the last row.
    app.config_pane_move(&cp, rows + 10)
    testing.expect_value(t, cp.sel, rows - 1)
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
test_config_pane_cancel :: proc(t: ^testing.T) {
    cp: app.ConfigPane
    app.config_pane_init(&cp)
    defer app.config_pane_destroy(&cp)

    // Nothing open: Esc isn't consumed (the app may then quit).
    testing.expect(t, !app.config_pane_cancel(&cp))

    // An open dropdown closes first.
    cp.expanded = app.SETTING_COUNT
    testing.expect(t, app.config_pane_cancel(&cp))
    testing.expect_value(t, cp.expanded, -1)

    // An in-progress edit cancels before the dropdown.
    cp.editing = true
    cp.expanded = app.SETTING_COUNT
    testing.expect(t, app.config_pane_cancel(&cp))
    testing.expect(t, !cp.editing)
    testing.expect_value(t, cp.expanded, app.SETTING_COUNT) // untouched: edit took priority
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
