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

// How a viewport tracks what it follows: Follow moves the view only when the target would leave
// it; Middle pins the target to the middle row so Up/Down move the content. One policy across
// every line view — the editor its caret (buffer_scroll_target), the lists their selection.
Scroll_Mode :: enum {
    Follow,
    Middle,
}

// Config — Slopd's own simple `key: value` file. Points at a theme file and holds
// a few editor settings. Search order: $SLOPD_CONFIG, ~/.config/slopd/slopd.config,
// ./slopd.config. Anything missing keeps the defaults below.
Config :: struct {
    theme_path:       string, // absolute (owned), or "" for the baked-in default
    indent:           Indent,
    line_numbers:     Line_Numbers,
    scroll_mode:      Scroll_Mode, // every line view: follow the caret/selection, or keep it middled
    font_px:          f32, // logical text size in points (font zoom), persisted across runs
    jump_lines:       int, // how many lines Ctrl+Up/Down jumps in the editor
    show_whitespace:  bool, // ghost the leading-space dots / tab marks
    show_guides:      bool, // draw indent guides + the active-scope rail
    folding:          bool, // allow Ctrl+Enter block folding
    folder_cd_run:    bool, // filetree Alt+Enter: run the `cd` at once vs stage it in the CL
    git_tool:         string, // external git tool Alt+G hands the project root to (owned); "" = none
    git_term:         int, // which terminal session to run it in; 0 = spawn it detached
    grep_pane_always: bool, // CL grep: always open the results pane vs jump straight on a lone hit
    conflict_prompt:  bool, // disk changed under unsaved edits: prompt (y/n in the CL) vs silently keep my edits
    mouse:            bool, // pointer input (wheel, and the clicks that follow it) on/off
    hover:            bool, // tint the row under the pointer; needs `mouse` to mean anything
}

// Splits a config line at its trailing comment; `body` is untrimmed, so its length is the comment's
// column. A '#' opens a comment only at line start or after a space/tab (the ini / git-config rule),
// keeping one glued to a token inside a free-text value. **After whitespace there is no escape.**
config_split_comment :: proc(line: string) -> (body: string, comment: string) {
    for i in 0 ..< len(line) {
        if line[i] != '#' {
            continue
        }
        if i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t' {
            return line[:i], line[i:]
        }
    }
    return line, ""
}

// A config line with its comment removed and trimmed; "" for a blank or comment-only line. Every
// read goes through this: the shipped config documents each setting with a trailing comment, so
// keeping it would hand parse_on_off "on   # on | off" and silently fall back to the default.
config_strip_comment :: proc(line: string) -> string {
    body, _ := config_split_comment(line)
    return strings.trim_space(body)
}

load_config :: proc() -> Config {
    cfg := Config {
        indent          = {.Spaces, 4}, // matches the project's 4-space convention
        line_numbers    = .Global,
        scroll_mode     = .Follow, // the view moves only when the caret would leave it
        font_px         = FONT_BASE_PX,
        jump_lines      = 10,
        show_whitespace = true, // the guides default on; the config toggles them off
        show_guides     = true,
        folding         = true,
        folder_cd_run   = false, // stage the cd in the CL by default (reviewable)
        git_term        = 0, // detached by default: a GUI tool wants its own window, not a PTY
        grep_pane_always = true, // always show the results pane (no auto-jump on a lone hit)
        conflict_prompt = true, // ask before a disk change is reconciled against unsaved edits
        mouse           = true, // pointer input on; it is purely additive to the keyboard
        hover           = true, // the tint is deliberately faint — see HOVER_MIX (render.odin)
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
        s := config_strip_comment(line)
        if len(s) == 0 {
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
        case "scroll_mode":
            if m, ok := parse_scroll_mode(val); ok {
                cfg.scroll_mode = m
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
        case "git_tool":
            delete(cfg.git_tool)
            cfg.git_tool = strings.clone(val)
        case "git_term":
            // Empty (or unparseable) stays 0 — detached, which is also what the pane's
            // GIT_TERM_DETACHED writes. A number names a terminal session; git_tool_open
            // clamps it to the sessions that can exist.
            if v, ok := strconv.parse_int(val); ok {cfg.git_term = max(0, v)}
        case "grep_pane":
            if v, ok := parse_on_off(val); ok {cfg.grep_pane_always = v}
        case "disk_conflict":
            if v, ok := parse_prompt_keep(val); ok {cfg.conflict_prompt = v}
        case "mouse":
            if v, ok := parse_on_off(val); ok {cfg.mouse = v}
        case "hover":
            if v, ok := parse_on_off(val); ok {cfg.hover = v}
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
    delete(cfg.git_tool)
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

// Resolves a theme config token (from the Config pane's dropdown) to a file path for load_theme:
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
    case .ScrollMode:
        return SCROLL_MODE_OPTS[:]
    case .Indent:
        return INDENT_OPTS[:]
    case .Theme:
        return theme_options(context.temp_allocator)
    case .GitTool:
        return nil // free text, not a choice — see setting_is_text
    case .GitTerm:
        return git_term_options(a, context.temp_allocator)
    case .Folding, .IndentGuides, .Whitespace, .GrepPane, .Mouse, .Hover:
        return ON_OFF_OPTS[:]
    case .FolderCd:
        return STAGE_RUN_OPTS[:]
    case .DiskConflict:
        return PROMPT_KEEP_OPTS[:]
    }
    return nil
}

INDENT_OPTS := [?]string{"tab", "spaces2", "spaces4", "spaces8"}
LINE_NUMBER_OPTS := [?]string{"global", "relative"}
SCROLL_MODE_OPTS := [?]string{"follow", "middle"}
ON_OFF_OPTS := [?]string{"on", "off"}
STAGE_RUN_OPTS := [?]string{"stage", "run"}
PROMPT_KEEP_OPTS := [?]string{"prompt", "keep"}

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

// git_term's token for "no terminal at all". Unlike git_tool, git_term is a CLOSED choice —
// a session number, or its own window — so it stays a dropdown, and a dropdown needs a row
// to point at for the empty case. load_config maps this straight back to 0.
GIT_TERM_DETACHED :: "detached"

// "detached", then every session number a launch can land on: the open ones plus the next
// (git_term_slot's rule). A configured number beyond that is appended too, because the pane
// pre-selects by MATCHING the current value — a missing `git_term: 7` would silently reset it.
@(private = "file")
git_term_options :: proc(a: ^App, allocator := context.allocator) -> []string {
    top := git_term_slot(term_count(a), TERM_MAX) // the highest slot that names a session
    out := make([dynamic]string, 0, top + 2, allocator)
    append(&out, GIT_TERM_DETACHED)
    for n in 1 ..= top {
        append(&out, fmt.aprintf("%d", n, allocator = allocator))
    }
    if a.git_term > top {
        append(&out, fmt.aprintf("%d", a.git_term, allocator = allocator))
    }
    return out[:]
}

// --- the editable settings shown in the Config aux pane --- The pane edits these keys and no
// others; per-language grammar paths live in the config file but are deliberately NOT here, being
// data for the syntax list rather than knobs. Order is the pane's row order.

Setting :: enum {
    Theme,
    LineNumbers,
    ScrollMode,
    Indent,
    Folding,
    IndentGuides,
    Whitespace,
    FolderCd,
    GitTool,
    GitTerm,
    GrepPane,
    DiskConflict,
    Mouse,
    Hover,
}

// Whether a setting is FREE TEXT rather than a choice — the row is an editor, not a dropdown.
// Only git_tool: it is a command line, flags and wrapper scripts included, so a menu could only
// guess. Everything else is genuinely closed and stays a dropdown.
setting_is_text :: proc(s: Setting) -> bool {
    return s == .GitTool
}

setting_key :: proc(s: Setting) -> string {
    switch s {
    case .Theme:        return "theme"
    case .LineNumbers:  return "line_numbers"
    case .ScrollMode:   return "scroll_mode"
    case .Indent:       return "indent"
    case .Folding:      return "folding"
    case .IndentGuides: return "indent_guides"
    case .Whitespace:   return "whitespace"
    case .FolderCd:     return "folder_cd"
    case .GitTool:      return "git_tool"
    case .GitTerm:      return "git_term"
    case .GrepPane:     return "grep_pane"
    case .DiskConflict: return "disk_conflict"
    case .Mouse:        return "mouse"
    case .Hover:        return "hover"
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
    case .ScrollMode:   return a.scroll_mode == .Middle ? "middle" : "follow"
    case .Indent:       return a.indent.kind == .Tab ? "tab" : fmt.tprintf("spaces%d", a.indent.width)
    case .Folding:      return on_off(a.folding)
    case .IndentGuides: return on_off(a.show_guides)
    case .Whitespace:   return on_off(a.show_whitespace)
    case .FolderCd:     return a.folder_cd_run ? "run" : "stage"
    case .GitTool:      return a.git_tool // free text; "" is unset (Alt+G opens a shell)
    case .GitTerm:      return a.git_term <= 0 ? GIT_TERM_DETACHED : fmt.tprintf("%d", a.git_term)
    case .GrepPane:     return on_off(a.grep_pane_always)
    case .DiskConflict: return a.conflict_prompt ? "prompt" : "keep"
    case .Mouse:        return on_off(a.mouse_on)
    case .Hover:        return on_off(a.hover_on)
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
    case .ScrollMode:
        a.scroll_mode = parse_scroll_mode(val) or_return
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
    case .GitTool:
        // Free text, so this is the one setting that can be typed UNREADABLE: a value carrying a
        // comment-opening '#' writes whole but reads back truncated, and the pane would show a
        // value the file does not hold. Refuse it; the config file stays the place for exotica.
        if _, comment := config_split_comment(val); comment != "" {
            return false
        }
        delete(a.git_tool) // App owns its copy (main clones the Config's) — see app_destroy
        a.git_tool = strings.clone(val)
    case .GitTerm:
        if val == GIT_TERM_DETACHED {
            a.git_term = 0 // its own window, no PTY — see git_tool.odin
        } else {
            n := strconv.parse_int(val) or_return
            if n < 0 {
                return false
            }
            a.git_term = n
        }
    case .GrepPane:
        a.grep_pane_always = parse_on_off(val) or_return
    case .DiskConflict:
        a.conflict_prompt = parse_prompt_keep(val) or_return
    case .Mouse:
        a.mouse_on = parse_on_off(val) or_return
    case .Hover:
        a.hover_on = parse_on_off(val) or_return
    }
    config_set(setting_key(s), val)
    return true
}

// Parses the disk-conflict setting: "prompt" asks (y/n in the command line) before a disk
// change is reconciled against unsaved edits; "keep" silently keeps your edits (the relaxed
// mode, fewer prompts). ok=false on anything else (an invalid edit keeps the old value).
parse_prompt_keep :: proc(s: string) -> (prompt: bool, ok: bool) {
    switch s {
    case "prompt": return true, true
    case "keep":   return false, true
    }
    return false, false
}

// Parses the scroll mode shared by every line view: "follow" moves the view only when the
// caret / selection would leave it; "middle" keeps it on the pane's middle row, so Up/Down
// always move the content. ok=false on anything else (an invalid edit keeps the old value).
parse_scroll_mode :: proc(s: string) -> (mode: Scroll_Mode, ok: bool) {
    switch s {
    case "follow": return .Follow, true
    case "middle": return .Middle, true
    }
    return .Follow, false
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

// Persists `key: value` by read-modify-write: the matching line is replaced in place, every other
// line — comments, unknown keys — preserved verbatim, a new key appended. The replaced line keeps
// its trailing comment, re-aligned: it documents the setting ("# on | off"), not its value.
config_set :: proc(key, val: string) -> bool {
    path := config_write_path()

    b := strings.builder_make(context.temp_allocator)
    replaced := false
    if src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil; src != nil {
        rest := string(src)
        for raw in strings.split_lines_iterator(&rest) {
            if !replaced {
                // A comment-only line leaves body blank, so it can never match a key.
                body, comment := config_split_comment(raw)
                s := strings.trim_space(body)
                if colon := strings.index_byte(s, ':'); colon > 0 && strings.trim_space(s[:colon]) == key {
                    config_write_line(&b, key, val, comment, len(body))
                    replaced = true
                    continue
                }
            }
            strings.write_string(&b, raw)
            strings.write_byte(&b, '\n')
        }
    }
    if !replaced {
        config_write_line(&b, key, val, "", 0)
    }
    err := os.write_entire_file(path, transmute([]byte)strings.to_string(b))
    return err == nil
}

// Writes one `key: value` line, then `comment` (with its '#') padded out to `col` — where it sat
// on the replaced line — so the file's comment column survives an edit. A longer value pushes the
// comment right, keeping one space. An empty value writes a bare `key:`, like the shipped file.
@(private = "file")
config_write_line :: proc(b: ^strings.Builder, key, val, comment: string, col: int) {
    n := strings.write_string(b, key)
    n += strings.write_byte(b, ':')
    if val != "" {
        n += strings.write_byte(b, ' ')
        n += strings.write_string(b, val)
    }
    if comment != "" {
        for _ in 0 ..< max(col - n, 1) {
            strings.write_byte(b, ' ')
        }
        strings.write_string(b, comment)
    }
    strings.write_byte(b, '\n')
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
