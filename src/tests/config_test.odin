package tests

import app "../slopd"
import "core:os"
import "core:strings"
import "core:testing"

// `key: value` with '#' comments. Both directions matter — load_config reads through
// config_strip_comment and the Config pane writes back through config_set — and the two must
// agree on where a comment starts.

// A trailing comment is not part of the value. Every shipped line documents itself with one, so
// keeping it would hand parse_on_off "on   # on | off", or make the comment BE a free-text
// value.
@(test)
test_config_strip_comment :: proc(t: ^testing.T) {
    testing.expect_value(t, app.config_strip_comment("mouse: on             # on | off"), "mouse: on")
    testing.expect_value(t, app.config_strip_comment("git_tool: lazygit  # e.g. lazygit"), "git_tool: lazygit")

    // A key with no value but a comment comes back empty rather than carrying the comment:
    // this is the one that would launch "# e.g. lazygit".
    testing.expect_value(t, app.config_strip_comment("git_tool:             # e.g. lazygit"), "git_tool:")

    // Whole-line comments and blanks collapse to "", which the load loop skips.
    testing.expect_value(t, app.config_strip_comment("# a heading"), "")
    testing.expect_value(t, app.config_strip_comment("   # indented"), "")
    testing.expect_value(t, app.config_strip_comment("\t# tab-indented"), "")
    testing.expect_value(t, app.config_strip_comment("   "), "")

    // No comment: just trimmed.
    testing.expect_value(t, app.config_strip_comment("  theme: themes/default.theme  "), "theme: themes/default.theme")
}

// A '#' glued to a token is part of the value, per the ini rule: git_tool is free text handed to
// a shell, so `foo#bar` is a plausible argument. Only a '#' at line start or after whitespace
// opens a comment.
@(test)
test_config_glued_hash_is_value :: proc(t: ^testing.T) {
    testing.expect_value(t, app.config_strip_comment("git_tool: sh -c foo#bar"), "git_tool: sh -c foo#bar")
    testing.expect_value(t, app.config_strip_comment("theme: my#theme"), "theme: my#theme")

    // …and a glued one does not shield a later, spaced one.
    testing.expect_value(t, app.config_strip_comment("theme: my#theme  # the good one"), "theme: my#theme")

    // The split reports the comment verbatim, with the body's length as its column.
    body, comment := app.config_split_comment("mouse: on   # on | off")
    testing.expect_value(t, body, "mouse: on   ")
    testing.expect_value(t, comment, "# on | off")

    body, comment = app.config_split_comment("mouse: on")
    testing.expect_value(t, body, "mouse: on")
    testing.expect_value(t, comment, "")
}

// Other lines verbatim, and the edited line's own comment re-aligned to its column. That comment
// documents the setting, not its value, so dropping it would strip the config's documentation
// one setting at a time. An unknown key is appended.
@(test)
test_config_set_keeps_comments :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_set_test.config"
    src := `# Slopd config — simple ` + "`key: value`" + `, '#' comments.
theme: themes/default.theme

mouse: on             # on | off
git_tool:             # e.g. lazygit
# mouse: on           <- a commented-out setting is not a match
`
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)

    config_override(path)
    defer config_override_release()

    testing.expect(t, app.config_set("mouse", "off"))
    testing.expect(t, app.config_set("git_tool", "lazygit"))
    testing.expect(t, app.config_set("jump_lines", "20")) // absent, so appended

    out, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    got := string(out)

    // Edited lines keep their comment at its original column.
    testing.expect(t, strings.contains(got, "mouse: off            # on | off\n"))
    testing.expect(t, strings.contains(got, "git_tool: lazygit     # e.g. lazygit\n"))

    // Untouched lines survive verbatim, the commented-out `mouse` line included, and the new
    // key lands at the end.
    testing.expect(t, strings.contains(got, "theme: themes/default.theme\n"))
    testing.expect(t, strings.contains(got, "# mouse: on           <- a commented-out setting is not a match\n"))
    testing.expect(t, strings.has_suffix(got, "jump_lines: 20\n"))

    // The round trip: what was written reads back as what was set.
    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.mouse, false)
    testing.expect_value(t, cfg.git_tool, "lazygit")
    testing.expect_value(t, cfg.jump_lines, 20)
}

// A bare `key:`, like the shipped file, rather than `key: ` with a trailing space.
@(test)
test_config_set_empty_value :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_empty_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("git_tool: lazygit  # e.g. lazygit\n")) == nil)
    defer os.remove(path)

    config_override(path)
    defer config_override_release()

    testing.expect(t, app.config_set("git_tool", ""))

    out, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, string(out), "git_tool:          # e.g. lazygit\n")

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.git_tool, "")
}

// A dropdown cannot offer a blank row, so the pane writes "detached" where the file leaves the
// value empty, and it has to read back as 0. git_tool needs no such token, being a text field.
@(test)
test_config_git_detached_token :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_git_test.config"
    src := "git_tool:\ngit_term: detached\n"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)

    config_override(path)
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.git_tool, "")
    testing.expect_value(t, cfg.git_term, 0)
}

// A session and only a session: no detached case, because a program you double-clicked has
// output you want to see. Junk keeps t1 rather than resolving to 0, which term_slot would read
// as "the session before the first".
@(test)
test_config_run_term :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_run_term_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("run_term: 3\n")) == nil)
    defer os.remove(path)

    config_override(path)
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.run_term, 3)

    // Junk and a zero both keep the default.
    for bad in ([]string{"run_term: detached\n", "run_term: 0\n", "run_term:\n"}) {
        testing.expect(t, os.write_entire_file(path, transmute([]byte)bad) == nil)
        junk := app.load_config()
        defer app.config_destroy(&junk)
        testing.expectf(t, junk.run_term == 1, "%q must keep t1, got t%d", bad, junk.run_term)
    }
}

// --- the [places] block --- The sidebar lives in the config file's one section. Everything
// below a `[section]` header is DATA, and all three readers agree on that: the loader stops
// there, config_set refuses to rewrite past it, and config_places reads only inside it.

// A place named like a setting is the hazard: `theme: /home/me/themes` in the block is a
// directory, and a loader that walked past the header would take it as the theme setting.
@(test)
test_config_places_are_not_settings :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_places_test.config"
    src := `theme: default
mouse: on             # on | off

[places]
Home: /home/me
theme: /home/me/themes
`
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.theme_path, "default") // not the block's /home/me/themes

    places := app.config_places(context.allocator)
    defer {
        for p in places {
            delete(p.name);delete(p.path)
        }
        delete(places)
    }
    testing.expect_value(t, len(places), 2)
    testing.expect_value(t, places[0].name, "Home")
    testing.expect_value(t, places[0].path, "/home/me")
    testing.expect_value(t, places[1].path, "/home/me/themes") // a place, not a theme

    // A settings write must not reach into the block, and a new key lands ABOVE it: appended
    // after, load_config would never read it back.
    testing.expect(t, app.config_set("theme", "gruvbox"))
    testing.expect(t, app.config_set("jump_lines", "20"))
    out, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    got := string(out)
    testing.expect(t, strings.contains(got, "theme: gruvbox\n"))
    testing.expect(t, strings.contains(got, "theme: /home/me/themes\n"), "the block's line was rewritten")
    testing.expect(
        t,
        strings.index(got, "jump_lines: 20") < strings.index(got, "[places]"),
        "a new key was appended below the section, where the loader stops",
    )

    cfg2 := app.load_config()
    defer app.config_destroy(&cfg2)
    testing.expect_value(t, cfg2.jump_lines, 20)
}

// Writing the block replaces it wholesale and leaves every other line alone. A rewrite per add
// must also not grow blank lines at the end of the file, which the trim before the header is
// for.
@(test)
test_config_places_write :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_places_write.config"
    src := `theme: default        # a comment worth keeping

[places]
Old: /old
`
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    places := [?]app.Place{{"Home", "/home/me"}, {"Src", "/home/me/src"}}
    testing.expect(t, app.config_places_write(places[:]))
    testing.expect(t, app.config_places_write(places[:])) // twice: the shape must be stable

    out, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    got := string(out)
    testing.expect(t, strings.contains(got, "theme: default        # a comment worth keeping\n"))
    testing.expect(t, !strings.contains(got, "Old: /old"), "the old block survived the rewrite")
    testing.expect(t, strings.has_suffix(got, "Home: /home/me\nSrc: /home/me/src\n"))
    testing.expect(t, !strings.contains(got, "\n\n\n"), "a rewrite grew a run of blank lines")

    // The round trip: what was written is what comes back, in order.
    back := app.config_places(context.allocator)
    defer {
        for p in back {
            delete(p.name);delete(p.path)
        }
        delete(back)
    }
    testing.expect_value(t, len(back), 2)
    testing.expect_value(t, back[0].name, "Home")
    testing.expect_value(t, back[1].path, "/home/me/src")

    // A file with no block gets one appended rather than nothing happening.
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("theme: default\n")) == nil)
    testing.expect(t, app.config_places_write(places[:]))
    out2, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, strings.contains(string(out2), "[places]"))
}

// An enum, not a toggle, and an unreadable value keeps the default.
@(test)
test_config_file_pane :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_filepane.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("file_pane: browser\nfile_view: grid\n")) == nil)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.file_pane, app.File_Pane.Browser)
    testing.expect_value(t, cfg.file_view, app.Browse_View.Grid)

    _, ok := app.parse_file_pane("dolphin")
    testing.expect(t, !ok, "an unknown presentation must not parse")

    // The default that stands is the SHIPPED one: load_config parses the baked-in
    // slopd.config before yours, so an unreadable value falls back to the line this repo ships
    // rather than the struct floor underneath.
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("file_pane: nonsense\n")) == nil)
    bad := app.load_config()
    defer app.config_destroy(&bad)
    testing.expect_value(t, bad.file_pane, app.File_Pane.Browser)
}

// Ignored, not an error: `term_ctrl_c` was removed when ^C stopped being a mode, and an old file
// carrying the line must still load every other setting.
@(test)
test_config_ignores_a_retired_key :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_retired_key.config"
    src := "term_ctrl_c: copy\nindent: spaces2\n"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.indent.width, 2) // the line after the dead key applies
}

