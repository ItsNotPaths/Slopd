package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Indentation policy: a tab, or N spaces. For .Tab, width is the display column
// count of a tab; for .Spaces, width is how many spaces a Tab press inserts.
Indent_Kind :: enum {
    Tab,
    Spaces,
}
Indent :: struct {
    kind:  Indent_Kind,
    width: int,
}

// Line number gutter: absolute numbers, or distance from the cursor line.
Line_Numbers :: enum {
    Global,
    Relative,
}

// Config — PitEd's own simple `key: value` file. Points at a theme file and holds
// a few editor settings. Search order: $PITED_CONFIG, ~/.config/pited/pited.config,
// ./pited.config. Anything missing keeps the defaults below.
Config :: struct {
    theme_path:   string, // absolute (owned), or "" for the baked-in default
    indent:       Indent,
    line_numbers: Line_Numbers,
}

load_config :: proc() -> Config {
    cfg := Config {
        indent       = {.Spaces, 4}, // matches the project's 4-space convention
        line_numbers = .Global,
    }
    path := find_config()
    if path == "" {
        return cfg
    }
    src, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    if src == nil {
        return cfg
    }
    dir := filepath.dir(path) // slices into path; used immediately below
    rest := string(src)
    for line in strings.split_lines_iterator(&rest) {
        s := strings.trim_space(line)
        if len(s) == 0 || s[0] == '#' {
            continue
        }
        colon := strings.index_byte(s, ':')
        if colon <= 0 {
            continue
        }
        key := strings.trim_space(s[:colon])
        val := strings.trim_space(s[colon + 1:])
        switch key {
        case "theme":
            cfg.theme_path = resolve_path(dir, val)
        case "indent":
            if ind, ok := parse_indent(val); ok {
                cfg.indent = ind
            }
        case "line_numbers":
            switch val {
            case "global":
                cfg.line_numbers = .Global
            case "relative":
                cfg.line_numbers = .Relative
            }
        }
    }
    return cfg
}

// "tab" | "spaces2" | "spaces4" | "spaces8" ...
@(private = "file")
parse_indent :: proc(s: string) -> (Indent, bool) {
    if s == "tab" {
        return {.Tab, 4}, true
    }
    if strings.has_prefix(s, "spaces") {
        if n, ok := strconv.parse_int(s[len("spaces"):], 10); ok && n > 0 {
            return {.Spaces, n}, true
        }
    }
    return {}, false
}

config_destroy :: proc(cfg: ^Config) {
    delete(cfg.theme_path)
}

@(private = "file")
find_config :: proc() -> string {
    if p := os.get_env("PITED_CONFIG", context.temp_allocator); p != "" && os.exists(p) {
        return p
    }
    if home := os.get_env("HOME", context.temp_allocator); home != "" {
        if p, jerr := filepath.join({home, ".config", "pited", "pited.config"}, context.temp_allocator);
           jerr == nil && os.exists(p) {
            return p
        }
    }
    if os.exists("pited.config") {
        return "pited.config"
    }
    return ""
}

// Resolves a theme path: absolute as-is, otherwise relative to the config's dir.
@(private = "file")
resolve_path :: proc(dir, val: string) -> string {
    if filepath.is_abs(val) {
        return strings.clone(val)
    }
    return filepath.join({dir, val}) or_else strings.clone(val)
}
