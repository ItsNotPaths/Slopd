package tests

import app ".."
import "core:strings"
import "core:testing"

// The config baked into the binary: the defaults a downloaded binary runs on, and the file
// `--install` writes out. There is only one of it, which is the point — a value cannot drift
// between what this repo ships and what a binary with no config file does.

// It has to be IN there. An empty #load is silent: the binary would still build, still run,
// and quietly fall back to the struct floor in load_config for every single setting.
@(test)
test_config_default_source :: proc(t: ^testing.T) {
    src := app.DEFAULT_CONFIG_SRC
    testing.expect(t, len(src) > 1000, "slopd.config did not get #load-ed")
    for key in ([]string{"theme:", "indent:", "term_ctrl_c:", "mouse:", "file_pane:"}) {
        testing.expect(t, strings.contains(src, key), key)
    }
}

// Layer 2 of load_config is this text, so every default the pane shows must be a line of it.
// Read with no config file at all, the settings are exactly what the shipped file says.
@(test)
test_config_default_is_the_default :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_defaults_absent.config"
    config_override(path) // a path that does not exist: nothing to read, so only layer 2 applies
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)

    // Two values that differ from the struct floor underneath, so this cannot pass by
    // accident: the floor says .Ls and no git tool, the shipped file says browser and lazygit.
    testing.expect_value(t, cfg.file_pane, app.File_Pane.Browser)
    testing.expect_value(t, cfg.git_tool, "lazygit")
    testing.expect_value(t, cfg.term_ctrl_c, app.Term_Ctrl_C.Stop)
    testing.expect_value(t, cfg.indent.width, 4)
}

// The one per-distribution difference, and it is a KEY BINDING rather than a package
// manager: Omarchy binds SUPER+C desktop-wide, and the compositor tags whole windows — it
// cannot see that one pane of ours is a terminal, so the chord reaches us as a plain ^C.
@(test)
test_config_default_omarchy :: proc(t: ^testing.T) {
    plain := app.config_default_text("debian", context.temp_allocator)
    testing.expect_value(t, plain, app.DEFAULT_CONFIG_SRC) // every other distro gets the file verbatim

    om := app.config_default_text("omarchy", context.temp_allocator)
    testing.expect(t, strings.contains(om, "term_ctrl_c: copy"), "omarchy must get the swapped pair")
    testing.expect(t, !strings.contains(om, "term_ctrl_c: stop"))

    // It is a REWRITE of the one line, not a different file: the comment that documents the
    // setting has to survive, or the config Omarchy users read is the undocumented one.
    testing.expect(t, strings.contains(om, "# stop | copy"))
    testing.expect(t, strings.contains(om, "file_pane: browser"), "no other setting may change")
    testing.expect(t, len(om) >= len(app.DEFAULT_CONFIG_SRC) - 8, "the rest of the file must be intact")
}

// config_set's rewrite, over text rather than a file. The Config pane edits by this rule and
// so does the Omarchy default above, so it is worth pinning on its own: the matching line is
// replaced, its trailing comment kept, and everything else copied through untouched.
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

    // A [section] header ends the settings — a key is inserted ABOVE it, where load_config
    // (which stops at the same line) will actually read it back.
    sectioned := app.config_rewrite("mouse: on\n\n[places]\nHome: /home/me\n", "folding", "off", context.temp_allocator)
    folding := strings.index(sectioned, "folding:")
    places := strings.index(sectioned, "[places]")
    testing.expect(t, folding >= 0 && folding < places, "a new key must land above the block, not after it")
    testing.expect(t, strings.contains(sectioned, "Home: /home/me"), "block data is not settings and must be untouched")
}
