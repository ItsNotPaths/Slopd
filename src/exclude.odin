package main

import "core:path/filepath"
import "core:strings"

// Exclude — the ONE list of directories the project-wide tools skip, from the config's
// `exclude:` line. "vendor is not my code" is one fact about a project, not a setting per tool,
// so every reader of it asks this file:
//
//   the workspace prompt (Alt+P)   does not walk into them   — wsfind_scan
//   `:grep`, Alt+Enter's lookup    passes them as --exclude-dir — grep_argv
//   `:j <name>` and `[[wiki]]`     does not walk into them   — find_nearest_file
//
// **Entries are directory NAME PATTERNS**, in grep's own `--exclude-dir` syntax (a shell glob
// over the name, never a path), which is what lets one line drive all three: whatever a pattern
// means here is exactly what grep is handed for it, so a search and a jump list cannot disagree
// about what is in the project. A trailing '/' is trimmed, so `vendor/` works as typed.
//
// Not the file LISTING: browsing into a folder is a thing you asked for, one folder at a time.

// The patterns, split from the one config line on commas. Temp-allocated slices of `list`, so
// they live as long as the string does — every caller reads them inside its own frame.
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

// The App's list, split. The seam every caller uses, so nobody re-splits it their own way.
exclude_dirs :: proc(a: ^App, alloc := context.temp_allocator) -> []string {
    return exclude_split(a.exclude, alloc)
}

// Whether a directory called `name` is excluded. A pattern that will not compile matches
// nothing rather than everything: a typo must not empty the jump list.
exclude_hit :: proc(pats: []string, name: string) -> bool {
    for p in pats {
        if ok, err := filepath.match(p, name); ok && err == nil {
            return true
        }
    }
    return false
}
