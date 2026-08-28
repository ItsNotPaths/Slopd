package main

import "core:fmt"
import "core:strings"
import "vendor:glfw"
import "../tty"
import "../wake"

// Kitty key events into the same three integers the GLFW callback hands handle_key. The bind
// table, the chord logic and every action stay exactly as they are; this is the terminal's half
// of the same shim key_callback is for a window.
//
// GLFW's key codes for printable keys ARE their ASCII values (KEY_A is 65, KEY_MINUS is 45), and
// kitty reports codepoints, so most of the mapping is arithmetic. Only the keys with no character
// need a table.

// Partial sequences survive between reads: a chord split across two arrivals must not be consumed
// as a broken one.
Tui_Input :: struct {
    pending: [dynamic]u8,
    paste:   [dynamic]u8, // content between the bracketed-paste markers
    pasting: bool,
}

tui_input_destroy :: proc(in_: ^Tui_Input) {
    delete(in_.pending)
    delete(in_.paste)
}

// Everything that has arrived, dispatched in order. True when anything was read, which is the
// frame loop's cue that the screen may have changed.
tui_input_pump :: proc(a: ^App, in_: ^Tui_Input, host: ^tty.Tty, buf: []u8) -> bool {
    n := tty.read(host, buf)
    if n == 0 {
        return false
    }
    append(&in_.pending, ..buf[:n])

    used := 0
    for used < len(in_.pending) {
        // Inside a paste the bytes are CONTENT, not keystrokes, and are taken verbatim: pasted
        // text can hold anything, escape sequences included, and parsing it would run whatever
        // it happened to spell.
        if in_.pasting {
            used += tui_take_paste(a, in_, in_.pending[used:])
            if in_.pasting {
                break // the end marker has not arrived
            }
            continue
        }
        ev, size, res := tty.parse(in_.pending[used:])
        if res == .Incomplete || size == 0 {
            break // wait for the rest of it
        }
        used += size
        #partial switch res {
        case .Event:
            tui_dispatch(a, ev)
        case .Paste_Begin:
            in_.pasting = true
            clear(&in_.paste)
        }
    }
    remove_range(&in_.pending, 0, used)
    return true
}

// Bytes up to the end marker, or all of them when it has not arrived. Returns how many were
// taken. What is held back is only ever a partial end marker.
@(private = "file")
tui_take_paste :: proc(a: ^App, in_: ^Tui_Input, rest: []u8) -> int {
    if at := strings.index(string(rest), tty.PASTE_END); at >= 0 {
        append(&in_.paste, ..rest[:at])
        in_.pasting = false
        tui_paste(a, string(in_.paste[:]))
        clear(&in_.paste)
        return at + len(tty.PASTE_END)
    }
    keep := max(0, len(rest) - (len(tty.PASTE_END) - 1))
    append(&in_.paste, ..rest[:keep])
    return keep
}

// Where a paste goes is the surface's business, so it goes through the same clip_put a bound
// paste does. The content stands in for the clipboard read rather than replacing the clipboard:
// pasting is not copying, and it must not overwrite what you last cut.
@(private = "file")
tui_paste :: proc(a: ^App, text: string) {
    if text == "" {
        return
    }
    a.paste_in = text
    defer a.paste_in = ""
    clip_put(a)
}

// The key first and the text second, which is the order GLFW fires its two callbacks in: a bind
// gets first refusal, then whatever the keystroke types goes into the focused editable.
@(private = "file")
tui_dispatch :: proc(a: ^App, ev: tty.Key_Event) {
    // -define:TUI_TRACE=true. Kept because the input here is bytes nobody can see: the bug that
    // made a bare Alt press type U+E063 into the buffer was invisible until this printed it.
    when #config(TUI_TRACE, false) {
        fmt.eprintfln(
            "[in] form=%v code=%d mods=%d kind=%v text=%q -> key=%d",
            ev.form, ev.code, ev.mods, ev.kind, ev.text, tui_key(ev),
        )
    }
    wake.mark() // a keystroke earns a frame, even one nothing is bound to

    if key := tui_key(ev); key != 0 {
        handle_key(a, key, tui_action(ev.kind), tui_mods(ev.mods))
    }
    if ev.text != 0 && ev.kind != .Release {
        handle_char(a, ev.text)
    }
}

@(private = "file")
tui_action :: proc(k: tty.Key_Kind) -> i32 {
    switch k {
    case .Press:
        return glfw.PRESS
    case .Repeat:
        return glfw.REPEAT
    case .Release:
        return glfw.RELEASE
    }
    return glfw.PRESS
}

@(private = "file")
tui_mods :: proc(m: i32) -> (out: i32) {
    if m & tty.MOD_SHIFT != 0 {
        out |= glfw.MOD_SHIFT
    }
    if m & tty.MOD_ALT != 0 {
        out |= glfw.MOD_ALT
    }
    if m & tty.MOD_CTRL != 0 {
        out |= glfw.MOD_CONTROL
    }
    if m & tty.MOD_SUPER != 0 {
        out |= glfw.MOD_SUPER
    }
    return
}

// 0 for a key with no GLFW equivalent, which is dropped rather than guessed at: a wrong code
// would fire whatever bind happens to sit on it.
@(private = "file")
tui_key :: proc(ev: tty.Key_Event) -> i32 {
    switch ev.form {
    case .Letter:
        switch ev.code {
        case 'A':
            return glfw.KEY_UP
        case 'B':
            return glfw.KEY_DOWN
        case 'C':
            return glfw.KEY_RIGHT
        case 'D':
            return glfw.KEY_LEFT
        case 'H':
            return glfw.KEY_HOME
        case 'F':
            return glfw.KEY_END
        case 'P':
            return glfw.KEY_F1
        case 'Q':
            return glfw.KEY_F2
        case 'S':
            return glfw.KEY_F4
        }
    case .Tilde:
        switch ev.code {
        case 2:
            return glfw.KEY_INSERT
        case 3:
            return glfw.KEY_DELETE
        case 5:
            return glfw.KEY_PAGE_UP
        case 6:
            return glfw.KEY_PAGE_DOWN
        case 13:
            return glfw.KEY_F3
        case 15:
            return glfw.KEY_F5
        case 17:
            return glfw.KEY_F6
        case 18:
            return glfw.KEY_F7
        case 19:
            return glfw.KEY_F8
        case 20:
            return glfw.KEY_F9
        case 21:
            return glfw.KEY_F10
        case 23:
            return glfw.KEY_F11
        case 24:
            return glfw.KEY_F12
        }
    case .Codepoint:
        switch ev.code {
        case 27:
            return glfw.KEY_ESCAPE
        case 13:
            return glfw.KEY_ENTER
        case 9:
            return glfw.KEY_TAB
        case 127:
            return glfw.KEY_BACKSPACE
        case tty.KEY_LEFT_SHIFT:
            return glfw.KEY_LEFT_SHIFT
        case tty.KEY_LEFT_CTRL:
            return glfw.KEY_LEFT_CONTROL
        case tty.KEY_LEFT_ALT:
            return glfw.KEY_LEFT_ALT
        case tty.KEY_LEFT_SUPER:
            return glfw.KEY_LEFT_SUPER
        case tty.KEY_RIGHT_SHIFT:
            return glfw.KEY_RIGHT_SHIFT
        case tty.KEY_RIGHT_CTRL:
            return glfw.KEY_RIGHT_CONTROL
        case tty.KEY_RIGHT_ALT:
            return glfw.KEY_RIGHT_ALT
        case tty.KEY_RIGHT_SUPER:
            return glfw.KEY_RIGHT_SUPER
        }
        // Letters report lower case; GLFW names them upper. Everything else printable already
        // shares its ASCII value with the GLFW constant.
        if ev.code >= 'a' && ev.code <= 'z' {
            return ev.code - 'a' + glfw.KEY_A
        }
        if ev.code >= 32 && ev.code <= 96 {
            return ev.code
        }
    }
    return 0
}
