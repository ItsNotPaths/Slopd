package main

import "core:fmt"
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

// Config — Slopd's own simple `key: value` file. Points at a theme file and holds
// a few editor settings. Search order: $SLOPD_CONFIG, ~/.config/slopd/slopd.config,
// ./slopd.config. Anything missing keeps the defaults below.
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
    if p := os.get_env("SLOPD_CONFIG", context.temp_allocator); p != "" && os.exists(p) {
        return p
    }
    if home := os.get_env("HOME", context.temp_allocator); home != "" {
        if p, jerr := filepath.join({home, ".config", "slopd", "slopd.config"}, context.temp_allocator);
           jerr == nil && os.exists(p) {
            return p
        }
    }
    if os.exists("slopd.config") {
        return "slopd.config"
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

// --- the editable settings shown in the Config aux pane ---
// config.odin owns config, so the Setting model + writeback live here. The pane
// edits these three keys; per-language grammar paths also live in the config file
// but are intentionally NOT here — they're data for the syntax list, not knobs — so
// the settings list stays small.

Setting :: enum {
    Theme,
    LineNumbers,
    Indent,
}

setting_key :: proc(s: Setting) -> string {
    switch s {
    case .Theme:       return "theme"
    case .LineNumbers: return "line_numbers"
    case .Indent:      return "indent"
    }
    return ""
}

// The current value of a setting, formatted for display / for seeding the editor.
// Temp-allocated for Indent; a borrow of App state otherwise — use it before the
// temp arena is reclaimed.
setting_value :: proc(a: ^App, s: Setting) -> string {
    switch s {
    case .Theme:       return a.theme_path
    case .LineNumbers: return a.line_numbers == .Global ? "global" : "relative"
    case .Indent:      return a.indent.kind == .Tab ? "tab" : fmt.tprintf("spaces%d", a.indent.width)
    }
    return ""
}

// Validates val, applies it to the live App config, and persists it to the config
// file. Returns false (changing nothing) on an invalid value, so a fat-fingered
// edit keeps the old setting.
setting_commit :: proc(a: ^App, s: Setting, val: string) -> bool {
    switch s {
    case .Theme:
        delete(a.theme_path)
        a.theme_path = strings.clone(val)
        // TODO: resolve a relative path against the config dir (load_config does);
        // here load_theme takes it as-is, so a relative value resolves from cwd.
        a.theme = load_theme(val) // "" -> baked-in default
    case .LineNumbers:
        switch val {
        case "global":   a.line_numbers = .Global
        case "relative": a.line_numbers = .Relative
        case:            return false
        }
    case .Indent:
        a.indent = parse_indent(val) or_return // invalid spec -> no change, return false
    }
    config_set(setting_key(s), val)
    return true
}

// Persists `key: value` to the config file via read-modify-write: the matching key
// line is replaced in place and every other line — comments, unknown keys, the
// hidden per-language path lines — is preserved verbatim; a new key is appended.
config_set :: proc(key, val: string) -> bool {
    path := config_write_path()
    line := fmt.tprintf("%s: %s", key, val)

    b := strings.builder_make(context.temp_allocator)
    replaced := false
    if src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil; src != nil {
        rest := string(src)
        for raw in strings.split_lines_iterator(&rest) {
            s := strings.trim_space(raw)
            if !replaced && len(s) > 0 && s[0] != '#' {
                if colon := strings.index_byte(s, ':'); colon > 0 && strings.trim_space(s[:colon]) == key {
                    strings.write_string(&b, line)
                    strings.write_byte(&b, '\n')
                    replaced = true
                    continue
                }
            }
            strings.write_string(&b, raw)
            strings.write_byte(&b, '\n')
        }
    }
    if !replaced {
        strings.write_string(&b, line)
        strings.write_byte(&b, '\n')
    }
    err := os.write_entire_file(path, transmute([]byte)strings.to_string(b))
    return err == nil
}

// Where settings are written: the existing config if one was found, else a local
// slopd.config (so we never need to create ~/.config on first write).
// TODO: honour XDG and create ~/.config/slopd when that's the only sensible target.
@(private = "file")
config_write_path :: proc() -> string {
    if p := find_config(); p != "" {
        return p
    }
    return "slopd.config"
}
