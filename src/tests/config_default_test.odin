package tests

import app ".."
import "core:strings"
import "core:testing"

// The config baked into the binary: the defaults a downloaded binary runs on, and what
// `--install` writes out. There is only one of it, so a value cannot drift.

// It has to be in there: an empty #load is silent, and the binary would build, run, and fall
// back to load_config's struct floor for every setting.
@(test)
test_config_default_source :: proc(t: ^testing.T) {
    src := app.DEFAULT_CONFIG_SRC
    testing.expect(t, len(src) > 1000, "slopd.config did not get #load-ed")
    for key in ([]string{"theme:", "indent:", "scroll_mode:", "mouse:", "file_pane:"}) {
        testing.expect(t, strings.contains(src, key), key)
    }
}

// Layer 2 of load_config is this text, so with no config file the settings are exactly what the
// shipped file says.
@(test)
test_config_default_is_the_default :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_defaults_absent.config"
    config_override(path) // a path that does not exist, so only layer 2 applies
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)

    // Two values that differ from the struct floor, so this cannot pass by accident.
    testing.expect_value(t, cfg.file_pane, app.File_Pane.Browser)
    testing.expect_value(t, cfg.git_tool, "lazygit")
    testing.expect_value(t, cfg.indent.width, 4)
}

// One text for every machine. It used to diverge on Omarchy over a key binding: SUPER+C is bound
// desktop-wide there and the compositor tags whole windows, so the chord reached us as a plain
// ^C. ^C now copies when a terminal has a selection and interrupts when it has none, which is
// right everywhere, so the per-distribution branch went with it.
@(test)
test_config_default_has_no_per_distro_branch :: proc(t: ^testing.T) {
    testing.expect(
        t,
        !strings.contains(app.DEFAULT_CONFIG_SRC, "term_ctrl_c"),
        "the swapped-pair setting is gone; ^C decides on the selection instead",
    )
}

// config_set's rewrite, over text rather than a file: the matching line is replaced, its
// trailing comment kept, and everything else copied through untouched.
@(test)
test_config_rewrite :: proc(t: ^testing.T) {
    src := "# a comment\nmouse: on             # on | off\nhover: on\n"
    out := app.config_rewrite(src, "mouse", "off", context.temp_allocator)
    testing.expect(t, strings.contains(out, "# a comment\n"))
    testing.expect(t, strings.contains(out, "# on | off"), "the setting's own documentation must survive its value")
    testing.expect(t, strings.contains(out, "mouse: off"))
    testing.expect(t, strings.contains(out, "hover: on\n"))

    // A key the file does not carry is appended rather than dropped.
    added := app.config_rewrite(src, "folding", "off", context.temp_allocator)
    testing.expect(t, strings.contains(added, "folding: off"))

    // Nothing to rewrite: the one line, and no leading blank.
    testing.expect_value(t, app.config_rewrite("", "mouse", "off", context.temp_allocator), "mouse: off\n")

    // A [section] header ends the settings, so a key is inserted ABOVE it, where load_config
    // will read it back.
    sectioned := app.config_rewrite("mouse: on\n\n[places]\nHome: /home/me\n", "folding", "off", context.temp_allocator)
    folding := strings.index(sectioned, "folding:")
    places := strings.index(sectioned, "[places]")
    testing.expect(t, folding >= 0 && folding < places, "a new key must land above the block, not after it")
    testing.expect(t, strings.contains(sectioned, "Home: /home/me"), "block data is not settings and must be untouched")
}
