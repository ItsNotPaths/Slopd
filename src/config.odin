package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
    font_px:      f32, // logical text size in points (font zoom), persisted across runs
}

load_config :: proc() -> Config {
    cfg := Config {
        indent       = {.Spaces, 4}, // matches the project's 4-space convention
        line_numbers = .Global,
        font_px      = FONT_BASE_PX,
    }
    path := find_config()
    if path == "" {
        return cfg
    }
    src, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    if src == nil {
        return cfg
    }
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
            // Stored as a raw token (a themes/ name, "global", or "default"); it's
            // resolved to a file path at load time by theme_resolve.
            cfg.theme_path = strings.clone(val)
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
        case "font_size":
            if n, ok := strconv.parse_int(val, 10); ok {
                cfg.font_px = clampf(f32(n), FONT_PX_MIN, FONT_PX_MAX)
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

// Resolves a theme config token to a file path for load_theme ("" => baked-in
// default). Tokens come from the Config pane's theme dropdown:
//   "" / "default"        -> themes/default.theme beside the binary (else baked-in)
//   "global"              -> ~/.config/unrawk/active.theme, the universal Thrawk theme
//                            (github.com/ItsNotPaths/Thrawk); falls back to default
//   "<name>"              -> themes/<name>.theme beside the binary
//   a value containing '/' -> taken literally (back-compat with hand-edited configs)
// Result is temp-allocated; load_theme falls back to the baked-in default for "".
theme_resolve :: proc(token: string) -> string {
    if strings.contains(token, "/") {
        return strings.clone(token, context.temp_allocator) // literal path, as-is
    }
    if token == "global" {
        home := os.get_env("HOME", context.temp_allocator)
        if home == "" {
            return ""
        }
        p := filepath.join({home, ".config", "unrawk", "active.theme"}, context.temp_allocator) or_else ""
        return os.exists(p) ? p : ""
    }
    name := token == "" ? "default" : token
    file := fmt.tprintf("%s.theme", name)
    p := filepath.join({asset_path("themes", context.temp_allocator), file}, context.temp_allocator) or_else ""
    return os.exists(p) ? p : ""
}

// The dropdown choices for a setting. Theme is derived (themes/ beside the binary,
// plus the "default" baked-in and "global" Thrawk-follow options); the others are
// fixed presets. The theme list is temp-allocated; the fixed ones are static.
setting_options :: proc(a: ^App, s: Setting) -> []string {
    switch s {
    case .LineNumbers:
        return LINE_NUMBER_OPTS[:]
    case .Indent:
        return INDENT_OPTS[:]
    case .Theme:
        return theme_options(context.temp_allocator)
    }
    return nil
}

INDENT_OPTS := [?]string{"tab", "spaces2", "spaces4", "spaces8"}
LINE_NUMBER_OPTS := [?]string{"global", "relative"}

// "default" + "global" first, then every themes/<name>.theme beside the binary,
// sorted. Names are cloned into `allocator`; the returned slice is too.
@(private = "file")
theme_options :: proc(allocator := context.allocator) -> []string {
    out := make([dynamic]string, 0, 16, allocator)
    append(&out, "default", "global") // baked-in default + the Thrawk universal theme
    dir := asset_path("themes", context.temp_allocator)
    if f, oerr := os.open(dir); oerr == nil {
        defer os.close(f)
        it := os.read_directory_iterator_create(f)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            if !strings.has_suffix(fi.name, ".theme") {
                continue
            }
            base := strings.trim_suffix(fi.name, ".theme")
            if base == "default" {
                continue // already offered as the first option
            }
            append(&out, strings.clone(base, allocator))
        }
    }
    slice.sort(out[2:]) // keep default/global pinned; sort the discovered themes
    return out[:]
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
        a.theme_path = strings.clone(val) // store the raw token (name / "global" / "default")
        a.theme = load_theme(theme_resolve(val)) // resolve to a path; "" -> baked-in default
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
