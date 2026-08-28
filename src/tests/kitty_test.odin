package tests

import "core:testing"
import "../tty"

// The kitty keyboard protocol parser. Pure bytes in, one event out, so every shape the terminal
// can send is asserted here rather than discovered by pressing keys and finding one dead.
//
// The three forms carry a number that means three different things, which is why Key_Form exists:
// 27 after `u` is Escape, 27 before `~` is nothing of the sort.

@(private = "file")
one :: proc(t: ^testing.T, s: string) -> (tty.Key_Event, int) {
    ev, n, res := tty.parse(transmute([]u8)s)
    testing.expectf(t, res == .Event, "%q did not parse to an event (%v)", s, res)
    return ev, n
}

@(test)
test_kitty_plain_codepoint :: proc(t: ^testing.T) {
    ev, n := one(t, "\e[97u")
    testing.expect_value(t, ev.form, tty.Key_Form.Codepoint)
    testing.expect_value(t, ev.code, i32(97))
    testing.expect_value(t, ev.mods, i32(0))
    testing.expect_value(t, ev.kind, tty.Key_Kind.Press)
    testing.expect_value(t, ev.text, 'a') // no modifier that suppresses text: it types itself
    testing.expect_value(t, n, 5)
}

// The field is 1 + the bitfield, so 5 is ctrl and 1 is nothing held.
@(test)
test_kitty_modifiers_are_offset_by_one :: proc(t: ^testing.T) {
    ctrl, _ := one(t, "\e[97;5u")
    testing.expect_value(t, ctrl.mods, i32(tty.MOD_CTRL))
    testing.expect_value(t, ctrl.text, rune(0)) // ^A inserts nothing

    none, _ := one(t, "\e[97;1u")
    testing.expect_value(t, none.mods, i32(0))

    all, _ := one(t, "\e[97;16u") // 1 + shift|alt|ctrl|super
    testing.expect_value(t, all.mods, i32(tty.MOD_SHIFT | tty.MOD_ALT | tty.MOD_CTRL | tty.MOD_SUPER))
}

// The subfield after the modifiers. Releases are what let a held Alt let go.
@(test)
test_kitty_event_types :: proc(t: ^testing.T) {
    press, _ := one(t, "\e[97;1:1u")
    testing.expect_value(t, press.kind, tty.Key_Kind.Press)
    repeat, _ := one(t, "\e[97;1:2u")
    testing.expect_value(t, repeat.kind, tty.Key_Kind.Repeat)
    release, _ := one(t, "\e[97;1:3u")
    testing.expect_value(t, release.kind, tty.Key_Kind.Release)

    // No subfield at all is a press, which is the protocol's default.
    bare, _ := one(t, "\e[97u")
    testing.expect_value(t, bare.kind, tty.Key_Kind.Press)
}

// The third field says what to insert, which is not always the key: Shift+2 is key 50, text '@'.
@(test)
test_kitty_associated_text_wins :: proc(t: ^testing.T) {
    ev, _ := one(t, "\e[50;2;64u")
    testing.expect_value(t, ev.code, i32(50))
    testing.expect_value(t, ev.text, '@')
}

// The protocol reports the UNSHIFTED code, so a shifted key with no text field cannot be typed
// from the code alone: Shift+A is 97, and guessing would insert a lower-case one.
@(test)
test_kitty_shift_without_text_types_nothing :: proc(t: ^testing.T) {
    ev, _ := one(t, "\e[97;2u")
    testing.expect_value(t, ev.code, i32(97))
    testing.expect_value(t, ev.mods, i32(tty.MOD_SHIFT))
    testing.expect_value(t, ev.text, rune(0))

    with_text, _ := one(t, "\e[97;2;65u")
    testing.expect_value(t, with_text.text, 'A')
}

// Arrows, Home and End come as a final letter with no codepoint at all.
@(test)
test_kitty_letter_form :: proc(t: ^testing.T) {
    up, n := one(t, "\e[A")
    testing.expect_value(t, up.form, tty.Key_Form.Letter)
    testing.expect_value(t, up.code, i32('A'))
    testing.expect_value(t, n, 3)

    // With a modifier the first field is a placeholder 1, and the mods are second.
    ctrl_left, _ := one(t, "\e[1;5D")
    testing.expect_value(t, ctrl_left.form, tty.Key_Form.Letter)
    testing.expect_value(t, ctrl_left.code, i32('D'))
    testing.expect_value(t, ctrl_left.mods, i32(tty.MOD_CTRL))
}

// Insert, Delete, PageUp/Down and F3+ are a number before a tilde. 3~ is Delete; 3 after `u`
// would be Ctrl+C, which is the whole reason the form is carried alongside the number.
@(test)
test_kitty_tilde_form_is_not_a_codepoint :: proc(t: ^testing.T) {
    del, n := one(t, "\e[3~")
    testing.expect_value(t, del.form, tty.Key_Form.Tilde)
    testing.expect_value(t, del.code, i32(3))
    testing.expect_value(t, n, 4)

    shift_del, _ := one(t, "\e[3;2~")
    testing.expect_value(t, shift_del.mods, i32(tty.MOD_SHIFT))
}

// A bare modifier press is a real event under flag 8, and it is what drives the switcher overlay.
@(test)
test_kitty_bare_modifier_keys :: proc(t: ^testing.T) {
    alt_down, _ := one(t, "\e[57443;1:1u")
    testing.expect_value(t, alt_down.code, i32(tty.KEY_LEFT_ALT))
    testing.expect_value(t, alt_down.kind, tty.Key_Kind.Press)

    alt_up, _ := one(t, "\e[57443;1:3u")
    testing.expect_value(t, alt_up.kind, tty.Key_Kind.Release)

    // And it types NOTHING. The protocol encodes characterless keys in the private use area, so
    // the text fallback would otherwise insert U+E063 every time Alt is pressed.
    testing.expect_value(t, alt_down.text, rune(0))
    testing.expect_value(t, alt_up.text, rune(0))
}

// Bytes that are not a sequence are text, which is what a terminal ignoring the flags sends and
// what a bracketed paste is made of.
@(test)
test_kitty_plain_bytes_are_text :: proc(t: ^testing.T) {
    ev, n := one(t, "x")
    testing.expect_value(t, ev.text, 'x')
    testing.expect_value(t, n, 1)

    utf8, n2 := one(t, "é")
    testing.expect_value(t, utf8.text, 'é')
    testing.expect_value(t, n2, 2) // consumed BOTH bytes, or the second decodes as garbage
}

// A sequence split across two reads must not be consumed as a broken one.
@(test)
test_kitty_partial_sequences_wait :: proc(t: ^testing.T) {
    for prefix in ([]string{"\e", "\e[", "\e[9", "\e[97", "\e[97;", "\e[97;1"}) {
        _, n, res := tty.parse(transmute([]u8)prefix)
        testing.expectf(t, res == .Incomplete, "%q should be incomplete, got %v", prefix, res)
        testing.expectf(t, n == 0, "%q consumed %d bytes while incomplete", prefix, n)
    }
}

// Sequences we do not speak are stepped over rather than stalling the buffer forever.
@(test)
test_kitty_unknown_sequences_are_skipped :: proc(t: ^testing.T) {
    mouse := "\e[<0;1;1M" // an SGR mouse report
    _, n, res := tty.parse(transmute([]u8)mouse)
    testing.expect_value(t, res, tty.Parse_Result.None)
    testing.expect(t, n > 0, "an unknown sequence must consume bytes or the buffer never drains")
}

// Several events in one read, which is what a key repeat or a fast typist produces.
@(test)
test_kitty_drains_a_full_buffer :: proc(t: ^testing.T) {
    buf := transmute([]u8)string("\e[97u\e[98u\e[1;5D")
    codes: [dynamic]i32
    defer delete(codes)
    for len(buf) > 0 {
        ev, n, res := tty.parse(buf)
        if res == .Incomplete || n == 0 {
            break
        }
        if res == .Event {
            append(&codes, ev.code)
        }
        buf = buf[n:]
    }
    testing.expect_value(t, len(codes), 3)
    testing.expect_value(t, codes[0], i32(97))
    testing.expect_value(t, codes[1], i32(98))
    testing.expect_value(t, codes[2], i32('D'))
}
