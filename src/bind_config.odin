package main

import "core:os"
import "core:strings"

// The `[binds]` block: `chord: action` per line over BIND_DEFAULTS; `none` (or an empty value)
// unbinds. A line that does not survive becomes a Bind_Error rather than vanishing.

CONFIG_SECTION_BINDS :: "[binds]"

// The live table, plus every line refused. Both are owned by the caller.
load_binds :: proc(alloc := context.allocator) -> (binds: [dynamic]Bind, errs: []Bind_Error) {
    binds = make([dynamic]Bind, 0, len(BIND_DEFAULTS) + 8, alloc)
    append(&binds, ..BIND_DEFAULTS[:])
    bad := make([dynamic]Bind_Error, 0, 4, alloc)

    src, _ := os.read_entire_file_from_path(config_file(), context.temp_allocator)
    rest := string(src)
    claimed := make([dynamic]Bind, 0, 8, context.temp_allocator) // what THIS block has taken
    inside, n := false, 0
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        s := config_strip_comment(raw)
        if len(s) == 0 {
            continue
        }
        if config_is_section(s) {
            inside = s == CONFIG_SECTION_BINDS
            continue
        }
        if !inside {
            continue
        }
        if b, why, ok := bind_line(s, claimed[:]); ok {
            bind_replace(&binds, b)
            if b.act != .None {
                append(&claimed, b)
            }
        } else {
            append(&bad, Bind_Error{n, strings.clone(strings.trim_space(raw), alloc), why})
        }
    }
    return binds, bad[:]
}

// One block line to a Bind; `.None` is an unbind. Pure, so the suite reaches every fault.
bind_line :: proc(s: string, claimed: []Bind) -> (b: Bind, why: Bind_Fault, ok: bool) {
    colon := strings.index_byte(s, ':')
    if colon <= 0 {
        return {}, .Bad_Chord, false
    }
    chord, chord_ok := chord_parse(s[:colon])
    if !chord_ok {
        return {}, .Bad_Chord, false
    }
    name := strings.trim_space(s[colon + 1:])
    if name == "" {
        return {chord, .None}, {}, true // an empty value unbinds, as `none` does
    }
    act, found := action_from_name(name)
    if !found {
        return {}, .Bad_Action, false
    }
    b = {chord, act}
    if act == .None {
        return b, {}, true
    }
    if .Text in bind_ctxs(act) && chord_types_text(chord) {
        return {}, .Bare_In_Text, false
    }
    for c in claimed {
        if bind_clash(b, c) {
            return {}, .Already_Bound, false
        }
    }
    return b, {}, true
}

// Drop whatever `b` displaces, then take its place. An unbind is the same move with nothing added
// — and it matches on the CHORD alone, since Action.None carries no context to overlap with.
@(private = "file")
bind_replace :: proc(binds: ^[dynamic]Bind, b: Bind) {
    for i := len(binds) - 1; i >= 0; i -= 1 {
        displaced := b.act == .None ? binds[i].chord == b.chord : bind_clash(binds[i], b)
        if displaced {
            ordered_remove(binds, i)
        }
    }
    if b.act != .None {
        append(binds, b)
    }
}

// --- writing ---

// Only what differs from BIND_DEFAULTS, so a default that changes in a later version still
// reaches you. Refuses while any line is in error.
config_binds_write :: proc(binds: []Bind, errs: []Bind_Error) -> bool {
    if len(errs) > 0 {
        return false
    }
    return config_block_write(
        CONFIG_SECTION_BINDS,
        "# chord: action. `none` unbinds a default",
        bind_diff(binds, context.temp_allocator),
    )
}

// One line per bind added or changed, plus a `none` per default that is gone.
bind_diff :: proc(binds: []Bind, alloc := context.allocator) -> []string {
    out := make([dynamic]string, 0, 8, alloc)
    for b in binds {
        if !bind_has(BIND_DEFAULTS[:], b) {
            append(&out, bind_line_text(b, alloc))
        }
    }
    for d in BIND_DEFAULTS {
        if !bind_has(binds, d) && !bind_shadowed(binds, d) {
            append(&out, bind_line_text({d.chord, .None}, alloc))
        }
    }
    return out[:]
}

bind_line_text :: proc(b: Bind, alloc := context.allocator) -> string {
    chord := chord_string(b.chord, context.temp_allocator)
    return strings.concatenate({chord, ": ", action_name(b.act)}, alloc)
}

@(private = "file")
bind_has :: proc(binds: []Bind, want: Bind) -> bool {
    for b in binds {
        if b == want {
            return true
        }
    }
    return false
}

// Whether something in `binds` already covers `d` — a REBOUND default needs no `none` line on
// top of the line that rebound it.
@(private = "file")
bind_shadowed :: proc(binds: []Bind, d: Bind) -> bool {
    for b in binds {
        if bind_clash(b, d) {
            return true
        }
    }
    return false
}

// --- the config pane's bindings row ---

config_open_binds :: proc(a: ^App, line := 0) {
    config_open_block(a, CONFIG_SECTION_BINDS, a.bind_errors, line)
}
