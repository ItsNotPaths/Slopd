package main

import "core:fmt"
import "core:strings"

// `:macro <chord> [!]<command>` sets the macro on a chord, `:macro - <chord>` drops it:
//
//   :macro alt+1 !git status && :ls    press Alt+1 and it runs
//   :macro f5 cargo build              press F5 and it is staged, Enter runs it
//   :macro - f5                        gone
//
// The chord is ONE field: `alt+1`, not `alt + 1`. Unlike `:rebind` there is no working copy and
// no `^s` — a chord holds one macro, so the edit is whole and lands in the file at once.

// The line split into its three parts. Separate from doing so the suite can reach the grammar
// without an App. `value` keeps its `!`, which macro_make reads.
macro_parse :: proc(args: string) -> (remove: bool, chord_text, value: string, ok: bool) {
    rest := strings.trim_space(args)
    if first_field(rest) == "-" {
        remove = true
        rest = strings.trim_space(rest[1:])
    }
    chord_text = first_field(rest)
    if chord_text == "" {
        return remove, "", "", false
    }
    return remove, chord_text, strings.trim_space(rest[len(chord_text):]), true
}

cl_macro :: proc(a: ^App, args: string) {
    remove, chord_text, value, ok := macro_parse(args)
    c, parsed := chord_parse(chord_text)
    if !ok || !parsed {
        cl_echo(a, "macro: :macro [-] <chord> [!]<command>")
        return
    }
    // The file is rewritten wholesale, so a line it already got wrong has to go first.
    if len(a.macro_errors) > 0 {
        cl_echo(a, "macro: fix the bad line in [macros] first — `:macros` opens it")
        return
    }

    i, held := macro_find(a.macros[:], c)
    if remove {
        if !held {
            cl_echo(a, fmt.tprintf("macro: nothing on %s", chord_text))
            return
        }
        delete(a.macros[i].cmd)
        ordered_remove(&a.macros, i)
        macro_write(a, fmt.tprintf("macro: %s dropped", chord_text))
        return
    }

    m, why, made := macro_make(c, value, a.binds[:])
    if !made {
        cl_echo(a, fmt.tprintf("macro: %s — %s", chord_text, bind_fault_text(why)))
        return
    }
    m.cmd = strings.clone(m.cmd) // it borrows the chain step, which the pump frees
    if held {
        delete(a.macros[i].cmd)
        a.macros[i] = m // in place, so the block keeps its order
    } else {
        append(&a.macros, m)
    }
    macro_write(a, fmt.tprintf("macro: %s %s %s", chord_text, m.run ? "runs" : "stages", m.cmd))
}

@(private = "file")
macro_write :: proc(a: ^App, msg: string) {
    if config_macros_write(a.macros[:], a.macro_errors) {
        cl_echo(a, msg)
        return
    }
    cl_echo(a, "macro: slopd.config could not be written (`:cf` says why)")
}
