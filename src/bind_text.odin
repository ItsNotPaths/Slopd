package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "vendor:glfw"

// Chords and actions as TEXT: what a `[binds]` line says, and what the panes print. Parsing and
// printing are inverse, and the suite holds them to it.
//
// Key names are GLFW's, lower case, `KEY_` dropped — except the printable keys, which are the
// character itself (`;`, `[`), because GLFW's codes for those ARE that character's ASCII.

MOD_NAMES :: [3]struct {
    bit:  i32,
    name: string,
} {
    {glfw.MOD_CONTROL, "ctrl"},
    {glfw.MOD_ALT, "alt"},
    {glfw.MOD_SHIFT, "shift"}, // printed in this order, so a rewrite never churns the file
}

// The keys with no printable character of their own. F1..F25 and kp_0..kp_9 are derived.
@(rodata)
KEY_NAMES := [?]struct {
    key:  i32,
    name: string,
} {
    {glfw.KEY_SPACE, "space"},
    {glfw.KEY_ESCAPE, "escape"},
    {glfw.KEY_ENTER, "enter"},
    {glfw.KEY_TAB, "tab"},
    {glfw.KEY_BACKSPACE, "backspace"},
    {glfw.KEY_INSERT, "insert"},
    {glfw.KEY_DELETE, "delete"},
    {glfw.KEY_RIGHT, "right"},
    {glfw.KEY_LEFT, "left"},
    {glfw.KEY_DOWN, "down"},
    {glfw.KEY_UP, "up"},
    {glfw.KEY_PAGE_UP, "page_up"},
    {glfw.KEY_PAGE_DOWN, "page_down"},
    {glfw.KEY_HOME, "home"},
    {glfw.KEY_END, "end"},
    {glfw.KEY_CAPS_LOCK, "caps_lock"},
    {glfw.KEY_SCROLL_LOCK, "scroll_lock"},
    {glfw.KEY_NUM_LOCK, "num_lock"},
    {glfw.KEY_PRINT_SCREEN, "print_screen"},
    {glfw.KEY_PAUSE, "pause"},
    {glfw.KEY_MENU, "menu"},
    {glfw.KEY_KP_DECIMAL, "kp_decimal"},
    {glfw.KEY_KP_DIVIDE, "kp_divide"},
    {glfw.KEY_KP_MULTIPLY, "kp_multiply"},
    {glfw.KEY_KP_SUBTRACT, "kp_subtract"},
    {glfw.KEY_KP_ADD, "kp_add"},
    {glfw.KEY_KP_ENTER, "kp_enter"},
    {glfw.KEY_KP_EQUAL, "kp_equal"},
}

KEY_F_MAX :: 25

// The key's own character, for the keys that have one. GLFW numbers letters by UPPER-case ASCII.
@(private = "file")
key_char :: proc(key: i32) -> (u8, bool) {
    switch key {
    case glfw.KEY_A ..= glfw.KEY_Z:
        return u8(key) + ('a' - 'A'), true
    case glfw.KEY_0 ..= glfw.KEY_9:
        return u8(key), true
    case glfw.KEY_APOSTROPHE, glfw.KEY_COMMA, glfw.KEY_MINUS, glfw.KEY_PERIOD, glfw.KEY_SLASH,
         glfw.KEY_SEMICOLON, glfw.KEY_EQUAL, glfw.KEY_LEFT_BRACKET, glfw.KEY_BACKSLASH,
         glfw.KEY_RIGHT_BRACKET, glfw.KEY_GRAVE_ACCENT:
        return u8(key), true
    }
    return 0, false
}

key_name :: proc(key: i32, alloc := context.allocator) -> string {
    if c, ok := key_char(key); ok {
        return fmt.aprintf("%c", rune(c), allocator = alloc)
    }
    switch key {
    case glfw.KEY_F1 ..= glfw.KEY_F1 + KEY_F_MAX - 1:
        return fmt.aprintf("f%d", key - glfw.KEY_F1 + 1, allocator = alloc)
    case glfw.KEY_KP_0 ..= glfw.KEY_KP_9:
        return fmt.aprintf("kp_%d", key - glfw.KEY_KP_0, allocator = alloc)
    }
    for k in KEY_NAMES {
        if k.key == key {
            return strings.clone(k.name, alloc)
        }
    }
    return ""
}

key_from_name :: proc(s: string) -> (i32, bool) {
    if len(s) == 1 {
        c := s[0]
        if c >= 'a' && c <= 'z' {
            return i32(c) - ('a' - 'A'), true
        }
        if _, ok := key_char(i32(c)); ok {
            return i32(c), true // digits and punctuation are their own code
        }
        return 0, false
    }
    if n, ok := suffix_num(s, "f"); ok && n >= 1 && n <= KEY_F_MAX {
        return glfw.KEY_F1 + i32(n) - 1, true
    }
    if n, ok := suffix_num(s, "kp_"); ok && n <= 9 {
        return glfw.KEY_KP_0 + i32(n), true
    }
    for k in KEY_NAMES {
        if k.name == s {
            return k.key, true
        }
    }
    return 0, false
}

// Whether this chord would stop a letter typing: a printable key with no Ctrl or Alt. Shift
// alone is still bare, since Shift+K is K.
chord_types_text :: proc(c: Chord) -> bool {
    if c.mods & (glfw.MOD_CONTROL | glfw.MOD_ALT) != 0 {
        return false
    }
    if c.key == glfw.KEY_SPACE {
        return true
    }
    _, printable := key_char(c.key)
    return printable
}

// `ctrl+alt+shift+key`, always in that order.
chord_string :: proc(c: Chord, alloc := context.allocator) -> string {
    name := key_name(c.key, context.temp_allocator)
    if name == "" {
        return ""
    }
    b := strings.builder_make(0, 24, alloc)
    for m in MOD_NAMES {
        if c.mods & m.bit != 0 {
            strings.write_string(&b, m.name)
            strings.write_byte(&b, '+')
        }
    }
    strings.write_string(&b, name)
    return strings.to_string(b)
}

chord_parse :: proc(s: string) -> (c: Chord, ok: bool) {
    rest := strings.trim_space(s)
    if rest == "" {
        return {}, false
    }
    // The key is the last field; a '+' KEY does not exist, so splitting on it is unambiguous —
    // which is also what lets each piece be trimmed, so `alt + right` reads as `alt+right`.
    for {
        plus := strings.index_byte(rest, '+')
        if plus < 0 {
            break
        }
        name := strings.trim_space(rest[:plus])
        bit := i32(0)
        for m in MOD_NAMES {
            if m.name == name {
                bit = m.bit
            }
        }
        if bit == 0 || c.mods & bit != 0 {
            return {}, false // not a modifier, or named twice
        }
        c.mods |= bit
        rest = strings.trim_space(rest[plus + 1:])
    }
    c.key = key_from_name(rest) or_return
    return c, true
}

action_name :: proc(act: Action) -> string {
    return ACTIONS[act].name
}

// The section an action belongs to: the part of its name before the dot.
action_group :: proc(name: string) -> string {
    if i := strings.index_byte(name, '.'); i > 0 {
        return name[:i]
    }
    return name
}

action_from_name :: proc(s: string) -> (Action, bool) {
    for info, act in ACTIONS {
        if info.name == s {
            return act, true
        }
    }
    return .None, false
}

// --- why an edit was refused --- The `[binds]` loader and the pane's own edits report the same
// set, so a chord the file rejects is one the pane rejects too.

Bind_Fault :: enum {
    Bad_Chord, // the left side names no key
    Bad_Action, // the right side names no verb
    Bare_In_Text, // a bare key where typing happens: it would eat a letter
    Already_Bound, // an earlier line in the block took the chord
    No_Slot, // `:rebind N` named a chord this action does not have
}

// A line the loader refused. It is NOT a live bind, so it carries its own text: the config pane
// has nothing else to show you.
Bind_Error :: struct {
    line: int, // 1-based, in slopd.config
    text: string, // the raw line (owned)
    why:  Bind_Fault,
}

bind_fault_text :: proc(why: Bind_Fault) -> string {
    switch why {
    case .Bad_Chord:     return "no such key"
    case .Bad_Action:    return "no such action"
    case .Bare_In_Text:  return "a bare key would stop this letter typing"
    case .Already_Bound: return "this chord is already bound above"
    case .No_Slot:       return "this action has no chord there"
    }
    return ""
}

bind_errors_destroy :: proc(errs: []Bind_Error) {
    for e in errs {
        delete(e.text)
    }
    delete(errs)
}

// "f12" -> 12 against prefix "f". False when the prefix is absent or the tail is not a number.
@(private = "file")
suffix_num :: proc(s, prefix: string) -> (int, bool) {
    if !strings.has_prefix(s, prefix) {
        return 0, false
    }
    return strconv.parse_int(s[len(prefix):], 10)
}
