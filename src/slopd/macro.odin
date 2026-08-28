package main

import "core:strings"

// A chord and a command line, sister to the key table: a bind names a verb the app holds, a
// macro names a line you would have typed. `!` in front of the command RUNS it at once; without
// it the line is staged for you to read and send with Enter, as every other staged command is.
//
// The command is an ordinary CL line, so `&&`, the `:builtins` and a `:tN` target all work:
//
//   alt+1: !git status && :ls
//   f5: cargo build
//
// The file half is a `[macros]` block (macro_config.odin) and `:macro` edits one (macro_cmd.odin).

Macro :: struct {
    chord: Chord,
    cmd:   string, // sigil-free: the `!` lives in `run`
    run:   bool,
}

// Ahead of the bind table, which the load-time clash check keeps out of its way. The command
// line owns its chords while it is up: a macro under it would replace the line being typed.
macro_fire :: proc(a: ^App, c: Chord) -> bool {
    if a.cl_active {
        return false
    }
    i, ok := macro_find(a.macros[:], c)
    if !ok {
        return false
    }
    cl_dispatch(a, a.macros[i].cmd, a.macros[i].run)
    return true
}

// Exact only: the Shift retry means EXTEND, which a macro has no second meaning for.
macro_find :: proc(macros: []Macro, c: Chord) -> (int, bool) {
    for m, i in macros {
        if m.chord == c {
            return i, true
        }
    }
    return -1, false
}

// A macro fires wherever you press it, so it shares a context with every bind and bind_clash —
// which wants one in common — cannot answer this. Key runs count: Alt+3 is Term_Goto's.
macro_taken :: proc(binds: []Bind, c: Chord) -> (Action, bool) {
    for b in binds {
        if b.chord.mods != c.mods {
            continue
        }
        if c.key >= b.chord.key && c.key <= b.chord.key + bind_run(b.act) {
            return b.act, true
        }
    }
    return .None, false
}

// The checks a macro must pass whatever wrote it, so a chord the file refuses `:macro` refuses
// too. `value` is the raw right-hand side, `!` and all; `m.cmd` BORROWS it, and a caller keeping
// the macro clones. Duplicates are the caller's: the loader refuses one, `:macro` replaces it.
macro_make :: proc(
    chord: Chord,
    value: string,
    binds: []Bind,
) -> (
    m: Macro,
    why: Bind_Fault,
    ok: bool,
) {
    if chord_types_text(chord) {
        return {}, .Bare_In_Text, false // a macro is global, so this would stop the letter anywhere
    }
    if _, held := macro_taken(binds, chord); held {
        return {}, .Chord_Taken, false
    }
    run := strings.has_prefix(value, "!")
    cmd := strings.trim_space(run ? value[1:] : value)
    if cmd == "" {
        return {}, .No_Command, false
    }
    return Macro{chord, cmd, run}, {}, true
}

// Inverse of macro_line, and the suite holds them to it.
macro_line_text :: proc(m: Macro, alloc := context.allocator) -> string {
    chord := chord_string(m.chord, context.temp_allocator)
    return strings.concatenate({chord, ": ", m.run ? "!" : "", m.cmd}, alloc)
}

macros_destroy :: proc(macros: ^[dynamic]Macro) {
    for m in macros {
        delete(m.cmd)
    }
    delete(macros^)
}
