package tests

import app "../slopd"
import "core:os"
import "core:strings"
import "core:testing"
import "vendor:glfw"
@(private = "file") CTL :: i32(glfw.MOD_CONTROL)
@(private = "file") SFT :: i32(glfw.MOD_SHIFT)
@(private = "file") ALT2 :: i32(glfw.MOD_ALT)

// --- names ---

// Print and parse are inverse over every key the table can name. The printable keys carry no
// entry of their own — GLFW's codes for them ARE the character's ASCII — so this is the check
// that the derivation and the table agree on who owns what.
@(test)
test_key_names_round_trip :: proc(t: ^testing.T) {
    seen := make(map[string]i32, 128, context.temp_allocator)
    check :: proc(t: ^testing.T, seen: ^map[string]i32, key: i32) {
        name := app.key_name(key, context.temp_allocator)
        testing.expectf(t, name != "", "key %d has no name", key)
        back, ok := app.key_from_name(name)
        testing.expectf(t, ok && back == key, "%q did not come back as key %d", name, key)
        if prev, dup := seen[name]; dup {
            testing.expectf(t, false, "%q names both key %d and key %d", name, prev, key)
        }
        seen[name] = key
    }
    for k in glfw.KEY_A ..= glfw.KEY_Z {check(t, &seen, i32(k))}
    for k in glfw.KEY_0 ..= glfw.KEY_9 {check(t, &seen, i32(k))}
    for k in glfw.KEY_KP_0 ..= glfw.KEY_KP_9 {check(t, &seen, i32(k))}
    for n in 0 ..< app.KEY_F_MAX {check(t, &seen, glfw.KEY_F1 + i32(n))}
    for e in app.KEY_NAMES {check(t, &seen, e.key)}
    for k in ([]i32 {
            glfw.KEY_APOSTROPHE,
            glfw.KEY_COMMA,
            glfw.KEY_MINUS,
            glfw.KEY_PERIOD,
            glfw.KEY_SLASH,
            glfw.KEY_SEMICOLON,
            glfw.KEY_EQUAL,
            glfw.KEY_LEFT_BRACKET,
            glfw.KEY_BACKSLASH,
            glfw.KEY_RIGHT_BRACKET,
            glfw.KEY_GRAVE_ACCENT,
        }) {check(t, &seen, i32(k))}

    testing.expect_value(t, app.key_name(glfw.KEY_SEMICOLON, context.temp_allocator), ";")
    testing.expect_value(t, app.key_name(glfw.KEY_LEFT_BRACKET, context.temp_allocator), "[")
    testing.expect_value(t, app.key_name(glfw.KEY_F12, context.temp_allocator), "f12")
    _, bad := app.key_from_name("wharrgarbl")
    testing.expect(t, !bad)
}

// Modifiers print in one order whatever order they arrive in, so a rewrite never churns the file.
@(test)
test_chord_round_trip :: proc(t: ^testing.T) {
    c, ok := app.chord_parse("shift+ctrl+alt+z")
    testing.expect(t, ok)
    testing.expect_value(t, c, app.Chord{glfw.KEY_Z, CTL | ALT2 | SFT})
    testing.expect_value(t, app.chord_string(c, context.temp_allocator), "ctrl+alt+shift+z")

    for s in ([]string{"alt+;", "ctrl+[", "ctrl+kp_add", "f1", "-", "escape", "ctrl+alt+up"}) {
        p, pok := app.chord_parse(s)
        testing.expectf(t, pok, "%q did not parse", s)
        testing.expect_value(t, app.chord_string(p, context.temp_allocator), s)
    }

    // Spaces around the + are read, and printed back out of them: tolerant in, canonical out.
    for s in ([]string{"alt + right", "ctrl +alt+ shift + z", "  alt+;  "}) {
        p, pok := app.chord_parse(s)
        testing.expectf(t, pok, "%q did not parse", s)
        tight, _ := app.chord_parse(strings.trim_space(strings.concatenate(
            strings.split(s, " ", context.temp_allocator),
            context.temp_allocator,
        )))
        testing.expect_value(t, p, tight)
    }

    for s in ([]string{"", "ctrl+", "meta+a", "ctrl+ctrl+a", "ctrl+nope", "+", "alt + + right"}) {
        _, pok := app.chord_parse(s)
        testing.expectf(t, !pok, "%q should not parse", s)
    }
}

// Every action is named, uniquely, and every name comes back.
@(test)
test_action_names_are_unique :: proc(t: ^testing.T) {
    seen := make(map[string]bool, 128, context.temp_allocator)
    for act in app.Action {
        name := app.action_name(act)
        testing.expectf(t, name != "", "%v has no name", act)
        testing.expectf(t, !seen[name], "%q names two actions", name)
        seen[name] = true
        back, ok := app.action_from_name(name)
        testing.expect(t, ok)
        testing.expect_value(t, back, act)
    }
    // Pinned, so renaming an enum member fails here rather than in somebody's config file.
    testing.expect_value(t, app.action_name(.File_Mark), "file.mark")
    testing.expect_value(t, app.action_name(.Save), "edit.save")
    testing.expect_value(t, app.action_name(.None), "none")
}

// --- the block ---

@(private = "file")
claimed_none: []app.Bind

@(test)
test_bind_line_faults :: proc(t: ^testing.T) {
    b, _, ok := app.bind_line("ctrl+j: edit.save", claimed_none)
    testing.expect(t, ok)
    testing.expect_value(t, b, app.Bind{{glfw.KEY_J, CTL}, .Save})

    // An empty value and `none` both unbind.
    for s in ([]string{"ctrl+j:", "ctrl+j: none"}) {
        u, _, uok := app.bind_line(s, claimed_none)
        testing.expect(t, uok)
        testing.expect_value(t, u.act, app.Action.None)
    }

    Case :: struct {
        line: string,
        why:  app.Bind_Fault,
    }
    for c in ([]Case {
            {"ctrl+quux: edit.save", .Bad_Chord},
            {"no colon here", .Bad_Chord},
            {"ctrl+j: edit.explode", .Bad_Action},
            {"k: edit.save", .Bare_In_Text}, // a bare letter would stop `k` typing
            {"shift+k: edit.save", .Bare_In_Text}, // Shift alone is still bare
        }) {
        _, why, cok := app.bind_line(c.line, claimed_none)
        testing.expectf(t, !cok, "%q should be refused", c.line)
        testing.expect_value(t, why, c.why)
        testing.expect(t, app.bind_fault_text(why) != "")
    }

    // A bare key is fine where nothing types, and where the key types nothing.
    for s in ([]string{"k: file.mark", "f5: edit.save"}) {
        _, _, bok := app.bind_line(s, claimed_none)
        testing.expectf(t, bok, "%q should be allowed", s)
    }

    // A chord the block already took is refused rather than silently losing to the first.
    _, why, dok := app.bind_line("ctrl+j: file.delete", []app.Bind{{{glfw.KEY_J, CTL}, .File_Mark}})
    testing.expect(t, !dok)
    testing.expect_value(t, why, app.Bind_Fault.Already_Bound)

    // ...but only where the contexts MEET. ^j in Text and ^j in Surface are two chords, which is
    // the same rule that lets ^y be Redo in the editor and Mark in the file pane.
    _, _, sok := app.bind_line("ctrl+j: file.mark", []app.Bind{{{glfw.KEY_J, CTL}, .Save}})
    testing.expect(t, sok, "edit.save is Text and file.mark is Surface; they cannot collide")
}

@(private = "file")
with_config :: proc(t: ^testing.T, path, src: string) -> ([dynamic]app.Bind, []app.Bind_Error) {
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    config_override(path)
    return app.load_binds()
}

@(test)
test_load_binds_layers_over_the_defaults :: proc(t: ^testing.T) {
    path := "/tmp/slopd_binds_layer.config"
    defer os.remove(path)
    binds, errs := with_config(
        t,
        path,
        "[binds]\nalt+f: pane.grep\nctrl+y: none\nctrl+j: file.mark\n",
    )
    defer config_override_release()
    defer delete(binds)
    defer app.bind_errors_destroy(errs)

    testing.expect_value(t, len(errs), 0)
    act :: proc(binds: []app.Bind, key, mods: i32, ctx: app.Bind_Ctx) -> app.Action {
        b, ok := app.bind_find(binds, app.Chord{key, mods}, ctx)
        return ok ? b.act : .None
    }
    testing.expect_value(t, act(binds[:], glfw.KEY_F, ALT2, .Surface), app.Action.Aux_Grep)
    testing.expect_value(t, act(binds[:], glfw.KEY_Y, CTL, .Surface), app.Action.None) // unbound
    testing.expect_value(t, act(binds[:], glfw.KEY_Y, CTL, .Text), app.Action.None)
    testing.expect_value(t, act(binds[:], glfw.KEY_J, CTL, .Surface), app.Action.File_Mark)
    // Untouched defaults survive.
    testing.expect_value(t, act(binds[:], glfw.KEY_S, CTL, .Text), app.Action.Save)
}

// A bad line is recorded with its file line number and its text — the pane has nothing else to
// show — and it does not stop the lines around it applying.
@(test)
test_load_binds_records_bad_lines :: proc(t: ^testing.T) {
    path := "/tmp/slopd_binds_bad.config"
    defer os.remove(path)
    src := "indent: tab\n\n[binds]\nctrl+j: edit.nope\nalt+f: pane.grep\n"
    binds, errs := with_config(t, path, src)
    defer config_override_release()
    defer delete(binds)
    defer app.bind_errors_destroy(errs)

    testing.expect_value(t, len(errs), 1)
    testing.expect_value(t, errs[0].line, 4)
    testing.expect_value(t, errs[0].text, "ctrl+j: edit.nope")
    testing.expect_value(t, errs[0].why, app.Bind_Fault.Bad_Action)

    b, ok := app.bind_find(binds[:], app.Chord{glfw.KEY_F, ALT2}, .Surface)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.Aux_Grep) // the line after it still applied
}

// --- writing ---

// The block holds the DIFFERENCE, not all 80-odd binds: a rebind, and a `none` for a default
// that is gone. A default left alone writes nothing.
@(test)
test_bind_diff_is_only_the_difference :: proc(t: ^testing.T) {
    binds := make([dynamic]app.Bind, 0, 96, context.temp_allocator)
    append(&binds, ..app.BIND_DEFAULTS[:])
    testing.expect_value(t, len(app.bind_diff(binds[:], context.temp_allocator)), 0)

    append(&binds, app.Bind{{glfw.KEY_J, CTL}, .File_Mark})
    lines := app.bind_diff(binds[:], context.temp_allocator)
    testing.expect_value(t, len(lines), 1)
    testing.expect_value(t, lines[0], "ctrl+j: file.mark")

    // Removing a default emits its `none`.
    for b, i in binds {
        if b.act == .Save {
            ordered_remove(&binds, i)
            break
        }
    }
    lines = app.bind_diff(binds[:], context.temp_allocator)
    testing.expect_value(t, len(lines), 2)
    testing.expect(t, strings.contains(lines[1], "ctrl+s: none"))
}

// Round trip: write the block, read it back, get the same table. And the write is REFUSED while
// any line is in error, which is the promise the binds pane rests on.
@(test)
test_binds_write_round_trip :: proc(t: ^testing.T) {
    path := "/tmp/slopd_binds_write.config"
    defer os.remove(path)
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("indent: tab\n")) == nil)
    config_override(path)
    defer config_override_release()

    binds := make([dynamic]app.Bind, 0, 96, context.temp_allocator)
    append(&binds, ..app.BIND_DEFAULTS[:])
    append(&binds, app.Bind{{glfw.KEY_J, CTL}, .File_Mark})

    broken := []app.Bind_Error{{1, "x", .Bad_Chord}}
    testing.expect(t, !app.config_binds_write(binds[:], broken))
    testing.expect(t, app.config_binds_write(binds[:], nil))

    back, errs := app.load_binds()
    defer delete(back)
    defer app.bind_errors_destroy(errs)
    testing.expect_value(t, len(errs), 0)
    b, ok := app.bind_find(back[:], app.Chord{glfw.KEY_J, CTL}, .Surface)
    testing.expect(t, ok)
    testing.expect_value(t, b.act, app.Action.File_Mark)

    // The settings above the block are untouched.
    src, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, strings.contains(string(src), "indent: tab"))
}
