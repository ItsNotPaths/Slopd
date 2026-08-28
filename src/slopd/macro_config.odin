package main

import "core:os"
import "core:strings"

// The `[macros]` block: `chord: command` per line, `!` in front of the command to run it at
// once. A line that does not survive becomes a Bind_Error rather than vanishing, as a `[binds]`
// line does, and is shown on the config pane's macros row.

CONFIG_SECTION_MACROS :: "[macros]"

// The live list, plus every line refused. Both are owned by the caller. `binds` is the LOADED
// table, not the defaults: a chord the config gave to an action is not free for a macro.
load_macros :: proc(
    binds: []Bind,
    alloc := context.allocator,
) -> (
    macros: [dynamic]Macro,
    errs: []Bind_Error,
) {
    macros = make([dynamic]Macro, 0, 8, alloc)
    bad := make([dynamic]Bind_Error, 0, 4, alloc)

    src, _ := os.read_entire_file_from_path(config_file(), context.temp_allocator)
    rest := string(src)
    inside, n := false, 0
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        s := config_strip_comment(raw)
        if len(s) == 0 {
            continue
        }
        if config_is_section(s) {
            inside = s == CONFIG_SECTION_MACROS
            continue
        }
        if !inside {
            continue
        }
        if m, why, ok := macro_line(s, macros[:], binds); ok {
            m.cmd = strings.clone(m.cmd, alloc) // it borrows `s`, which is the file's buffer
            append(&macros, m)
        } else {
            append(&bad, Bind_Error{n, strings.clone(strings.trim_space(raw), alloc), why})
        }
    }
    return macros, bad[:]
}

// One block line to a Macro. `m.cmd` borrows `s`. Pure, so the suite reaches every fault.
macro_line :: proc(
    s: string,
    claimed: []Macro,
    binds: []Bind,
) -> (
    m: Macro,
    why: Bind_Fault,
    ok: bool,
) {
    colon := strings.index_byte(s, ':')
    if colon <= 0 {
        return {}, .Bad_Chord, false
    }
    chord, chord_ok := chord_parse(s[:colon])
    if !chord_ok {
        return {}, .Bad_Chord, false
    }
    if _, dup := macro_find(claimed, chord); dup {
        return {}, .Already_Bound, false
    }
    return macro_make(chord, strings.trim_space(s[colon + 1:]), binds)
}

// Refuses while any line is in error: the block is rewritten wholesale, so an unread bad line
// would vanish. `:macro` therefore refuses to edit until the file is fixed.
config_macros_write :: proc(macros: []Macro, errs: []Bind_Error) -> bool {
    if len(errs) > 0 {
        return false
    }
    lines := make([dynamic]string, 0, len(macros), context.temp_allocator)
    for m in macros {
        append(&lines, macro_line_text(m, context.temp_allocator))
    }
    return config_block_write(
        CONFIG_SECTION_MACROS,
        "# chord: command. `!` runs it at once, else it is staged",
        lines[:],
    )
}

// The config pane's macros row: the block itself, in the editor. There is no macros PANE — the
// value is a command line, which the editor edits better than a row ever would.
config_open_macros :: proc(a: ^App) {
    config_open_block(a, CONFIG_SECTION_MACROS, a.macro_errors)
}
