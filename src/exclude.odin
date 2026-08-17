package main

import "core:path/filepath"
import "core:strings"

// The one list of directories the project-wide tools skip, from the config's `exclude:` line:
//   the workspace prompt (Alt+P)   does not walk into them        — wsfind_scan
//   `:grep`, Alt+Enter's lookup    passed as --exclude-dir        — grep_argv
//   `:j <name>` and `[[wiki]]`     does not walk into them        — find_nearest_file
//
// Entries are directory NAME PATTERNS in grep's own --exclude-dir syntax (a glob over the name,
// never a path), so what a pattern means here is exactly what grep is handed. A trailing '/' is
// trimmed. Not the file listing: browsing into a folder is a thing you asked for.

// Temp-allocated slices of `list`, so they live as long as the string does.
exclude_split :: proc(list: string, alloc := context.temp_allocator) -> []string {
    out := make([dynamic]string, 0, 8, alloc)
    rest := list
    for part in strings.split_iterator(&rest, ",") {
        if p := strings.trim_right(strings.trim_space(part), "/"); p != "" {
            append(&out, p)
        }
    }
    return out[:]
}

// The seam every caller uses, so nobody re-splits it their own way.
exclude_dirs :: proc(a: ^App, alloc := context.temp_allocator) -> []string {
    return exclude_split(a.exclude, alloc)
}

// A pattern that will not compile matches nothing rather than everything: a typo must not
// empty the jump list.
exclude_hit :: proc(pats: []string, name: string) -> bool {
    for p in pats {
        if ok, err := filepath.match(p, name); ok && err == nil {
            return true
        }
    }
    return false
}
