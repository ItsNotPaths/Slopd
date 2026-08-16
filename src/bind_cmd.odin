package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// `:rebind [+|-|N|-N] <action> [chord]` — the typed half of the binds pane, and the line that
// pane stages for you. It edits the pane's working copy; Ctrl+S there writes it.
//
//   :rebind nav.down down          replace nav.down's first chord
//   :rebind 1 nav.down alt+j       replace its second
//   :rebind + nav.down alt+j       add one beside the others
//   :rebind - nav.down             drop the first    (-1 drops the second)
//
// A chord another action holds in a context they share is TAKEN, and the echo says from whom.
// The staged line is the confirm: you read it before you press Enter, as with every other
// command Slopd puts in front of you.

Rebind_Op :: enum {
    Replace,
    Add,
    Clear,
}

// The selector, the action and the chord text. Splitting is separate from doing so the suite can
// reach the grammar without a pane.
rebind_parse :: proc(args: string) -> (op: Rebind_Op, n: int, action, chord: string, ok: bool) {
    rest := strings.trim_space(args)
    f := first_field(rest)
    if f == "" {
        return {}, 0, "", "", false
    }
    switch {
    case f == "+":
        op = .Add
    case f == "-":
        op = .Clear
    case len(f) > 1 && f[0] == '-':
        op, n = .Clear, strconv.parse_int(f[1:], 10) or_return
    case f[0] >= '0' && f[0] <= '9':
        n = strconv.parse_int(f, 10) or_return
    case:
        // No selector: the whole line is `<action> [chord]`, and a replace of the first.
        action = f
        return .Replace, 0, action, strings.trim_space(rest[len(f):]), true
    }
    rest = strings.trim_space(rest[len(f):])
    action = first_field(rest)
    if action == "" {
        return {}, 0, "", "", false
    }
    return op, n, action, strings.trim_space(rest[len(action):]), true
}

cl_rebind :: proc(a: ^App, args: string) {
    op, n, name, chord_text, ok := rebind_parse(args)
    if !ok {
        cl_echo_t1(a, "rebind: :rebind [+|-|N] <action> [chord]")
        return
    }
    act, known := action_from_name(name)
    if !known || act == .None {
        cl_echo_t1(a, fmt.tprintf("rebind: %s is not an action (see the binds pane)", name))
        return
    }
    bp := &a.binds_pane

    if op == .Clear {
        if !bind_clear(bp, act, n) {
            cl_echo_t1(a, fmt.tprintf("rebind: %s has no chord %d", name, n))
            return
        }
        cl_echo_t1(a, fmt.tprintf("rebind: %s lost chord %d (unsaved: ^s in :binds)", name, n))
        return
    }

    c, parsed := chord_parse(chord_text)
    if !parsed {
        cl_echo_t1(a, fmt.tprintf("rebind: %q is not a chord (ctrl/alt/shift + a key)", chord_text))
        return
    }
    took, why, applied := bind_set(bp, act, n, c, op == .Add)
    if !applied {
        cl_echo_t1(a, fmt.tprintf("rebind: %s — %s", chord_text, bind_fault_text(why)))
        return
    }
    if took != .None {
        from := action_name(took)
        cl_echo_t1(a, fmt.tprintf("rebind: %s took %s from %s (unsaved)", name, chord_text, from))
        return
    }
    cl_echo_t1(a, fmt.tprintf("rebind: %s on %s (unsaved: ^s in :binds)", chord_text, name))
}
