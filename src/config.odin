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
    theme_path:        string, // absolute (owned), or "" for the baked-in default
    indent:            Indent,
    line_numbers:      Line_Numbers,
    font_px:           f32, // logical text size in points (font zoom), persisted across runs
    jump_lines:        int, // how many lines Ctrl+Up/Down jumps in the editor
    show_whitespace:   bool, // ghost the leading-space dots / tab marks
    show_guides:       bool, // draw indent guides + the active-scope rail
    folding:           bool, // allow Ctrl+Enter block folding
    folder_cd_run:     bool, // filetree Alt+Enter: run the `cd` at once vs stage it in the CL
    git_checkout_run:  bool, // git branch Enter: run `git checkout` at once vs stage it
    git_commit_run:    bool, // git commit Enter: run the commit recipe at once vs stage it
    git_merge_run:     bool, // git branch Space / merge finish: run vs stage it
    risky_mode:        bool, // git slot machine: auto-send the lucky-dip commit (no review)
    grep_pane_always:  bool, // CL grep: always open the results pane vs jump straight on a lone hit
}

load_config :: proc() -> Config {
    cfg := Config {
        indent          = {.Spaces, 4}, // matches the project's 4-space convention
        line_numbers    = .Global,
        font_px         = FONT_BASE_PX,
        jump_lines      = 10,
        show_whitespace = true, // the guides default on; the config toggles them off
        show_guides     = true,
        folding         = true,
        folder_cd_run   = false, // stage the cd in the CL by default (reviewable)
        git_checkout_run = false, // stage branch checkout / commit / merge in the CL by default
        git_commit_run  = false,
        git_merge_run   = false,
        risky_mode      = false, // the lucky-dip commit is staged for review by default
        grep_pane_always = true, // always show the results pane (no auto-jump on a lone hit)
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
        case "jump_lines":
            if n, ok := strconv.parse_int(val, 10); ok && n > 0 {
                cfg.jump_lines = n
            }
        case "whitespace":
            if v, ok := parse_on_off(val); ok {cfg.show_whitespace = v}
        case "indent_guides":
            if v, ok := parse_on_off(val); ok {cfg.show_guides = v}
        case "folding":
            if v, ok := parse_on_off(val); ok {cfg.folding = v}
        case "folder_cd":
            if v, ok := parse_stage_run(val); ok {cfg.folder_cd_run = v}
        case "git_checkout":
            if v, ok := parse_stage_run(val); ok {cfg.git_checkout_run = v}
        case "git_commit":
            if v, ok := parse_stage_run(val); ok {cfg.git_commit_run = v}
        case "git_merge":
            if v, ok := parse_stage_run(val); ok {cfg.git_merge_run = v}
        case "risky_mode":
            if v, ok := parse_on_off(val); ok {cfg.risky_mode = v}
        case "grep_pane":
            if v, ok := parse_on_off(val); ok {cfg.grep_pane_always = v}
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
    case .Folding, .IndentGuides, .Whitespace, .RiskyMode, .GrepPane:
        return ON_OFF_OPTS[:]
    case .FolderCd, .GitCheckout, .GitCommit, .GitMerge:
        return STAGE_RUN_OPTS[:]
    }
    return nil
}

INDENT_OPTS := [?]string{"tab", "spaces2", "spaces4", "spaces8"}
LINE_NUMBER_OPTS := [?]string{"global", "relative"}
ON_OFF_OPTS := [?]string{"on", "off"}
STAGE_RUN_OPTS := [?]string{"stage", "run"}

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
    Folding,
    IndentGuides,
    Whitespace,
    FolderCd,
    GitCheckout,
    GitCommit,
    GitMerge,
    RiskyMode,
    GrepPane,
}

setting_key :: proc(s: Setting) -> string {
    switch s {
    case .Theme:        return "theme"
    case .LineNumbers:  return "line_numbers"
    case .Indent:       return "indent"
    case .Folding:      return "folding"
    case .IndentGuides: return "indent_guides"
    case .Whitespace:   return "whitespace"
    case .FolderCd:     return "folder_cd"
    case .GitCheckout:  return "git_checkout"
    case .GitCommit:    return "git_commit"
    case .GitMerge:     return "git_merge"
    case .RiskyMode:    return "risky_mode"
    case .GrepPane:     return "grep_pane"
    }
    return ""
}

// The current value of a setting, formatted for display / for seeding the editor.
// Temp-allocated for Indent; a borrow of App state otherwise — use it before the
// temp arena is reclaimed.
setting_value :: proc(a: ^App, s: Setting) -> string {
    switch s {
    case .Theme:        return a.theme_path
    case .LineNumbers:  return a.line_numbers == .Global ? "global" : "relative"
    case .Indent:       return a.indent.kind == .Tab ? "tab" : fmt.tprintf("spaces%d", a.indent.width)
    case .Folding:      return on_off(a.folding)
    case .IndentGuides: return on_off(a.show_guides)
    case .Whitespace:   return on_off(a.show_whitespace)
    case .FolderCd:     return a.folder_cd_run ? "run" : "stage"
    case .GitCheckout:  return a.git_checkout_run ? "run" : "stage"
    case .GitCommit:    return a.git_commit_run ? "run" : "stage"
    case .GitMerge:     return a.git_merge_run ? "run" : "stage"
    case .RiskyMode:    return on_off(a.risky_mode)
    case .GrepPane:     return on_off(a.grep_pane_always)
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
    case .Folding:
        a.folding = parse_on_off(val) or_return
        if !a.folding {
            editor_clear_folds(&a.editor) // expand everything when folding is turned off
        }
    case .IndentGuides:
        a.show_guides = parse_on_off(val) or_return
    case .Whitespace:
        a.show_whitespace = parse_on_off(val) or_return
    case .FolderCd:
        a.folder_cd_run = parse_stage_run(val) or_return
    case .GitCheckout:
        a.git_checkout_run = parse_stage_run(val) or_return
    case .GitCommit:
        a.git_commit_run = parse_stage_run(val) or_return
    case .GitMerge:
        a.git_merge_run = parse_stage_run(val) or_return
    case .RiskyMode:
        a.risky_mode = parse_on_off(val) or_return
    case .GrepPane:
        a.grep_pane_always = parse_on_off(val) or_return
    }
    config_set(setting_key(s), val)
    return true
}

// Parses the folder-cd action's stage/run value; ok=false on anything else (an invalid
// edit keeps the old value, like the other settings).
parse_stage_run :: proc(s: string) -> (run: bool, ok: bool) {
    switch s {
    case "stage": return false, true
    case "run":   return true, true
    }
    return false, false
}

// Parses the on/off settings' values; ok=false on anything else (an invalid edit
// keeps the old value, like the other settings).
parse_on_off :: proc(s: string) -> (val: bool, ok: bool) {
    switch s {
    case "on", "true", "yes":  return true, true
    case "off", "false", "no": return false, true
    }
    return false, false
}

on_off :: proc(b: bool) -> string {
    return b ? "on" : "off"
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
