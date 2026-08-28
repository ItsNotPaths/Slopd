package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../gfx"
import "../paths"
import "../ui"
import "../txt"
import "../pty"
import "../edit"

Line_Numbers :: enum {
    Global,
    Relative,
}

// Which front-end `slopd` with no front-end flag starts. `--gfx` and `--tui` name one for a
// single run and override this.
Display :: enum {
    Gfx,
    Tui,
}

// Follow moves the view only when the target would leave it; Middle pins the target to the
// middle row. One policy across every line view. ROWS only — the editor's column axis has its
// own, see buffer_hscroll_target.
// `Ls` is the dired-style listing, `Browser` the file-manager one. Both drive the same FileTree
// model, so this chooses pixels and pointer targets, never behaviour.
File_Pane :: enum {
    Ls,
    Browser,
}

// Slopd's own `key: value` file, in one directory src/paths picks (config_file): beside the
// binary, or ~/.config/slopd once installed. Anything missing keeps the defaults below.
//
// One `[section]` block exists and is not a setting: `[places]` holds the browser's sidebar
// shortcuts, `Name: /path` per line. Every reader here stops at the first section header.
Config :: struct {
    default_display:  Display, // which front-end a bare `slopd` opens
    theme_path:       string, // absolute (owned), or "" for the baked-in default
    indent:           txt.Indent,
    line_numbers:     Line_Numbers,
    scroll_mode:      ui.Scroll_Mode, // every line view's ROWS: follow, or keep middled
    font_px:          f32, // logical text size, persisted across runs
    jump_lines:       int, // how many lines Ctrl+Up/Down jumps in the editor
    show_whitespace:  bool, // ghost the leading-space dots / tab marks
    show_guides:      bool, // draw indent guides + the active-scope rail
    folding:          bool, // allow Ctrl+Enter block folding
    folder_cd_run:    bool, // filetree Alt+Enter: run the `cd` at once vs stage it in the CL
    discard_run:      bool, // file pane ^k: discard the edits at once vs stage `:discard`
    git_tool:         string, // external tool Alt+G hands the project root to (owned); "" = none
    git_term:         int, // which terminal session to run it in; 0 = spawn it detached
    run_term:         int, // the session the command line works in (cl_term)
    grep_pane_always: bool, // always open the results pane vs jump straight on a lone hit
    cl_preview:       bool, // show `:j` `:f` `:grep` effects while the line is typed
    conflict_prompt:  bool, // disk changed under unsaved edits: prompt vs silently keep mine
    conflict_stage:   bool, // a conflict stages `:reload ` vs only marking the modeline
    mouse:            bool, // pointer input on/off
    hover:            bool, // tint the row under the pointer; needs `mouse`
    file_pane:        File_Pane,
    file_view:        Browse_View, // list or grid; the pane's toggle writes this back
    file_icons:       bool, // needs the vendored icon face
    exclude:          string, // directories the project-wide tools skip, comma separated (owned)
}

// Everything below it is data, not settings; every key/value reader stops here.
CONFIG_SECTION_PLACES :: "[places]"

// One proc for all three readers: a section they disagreed about would let a place named
// `theme` be rewritten as the theme setting.
config_is_section :: proc(s: string) -> bool {
    return len(s) >= 2 && s[0] == '[' && s[len(s) - 1] == ']'
}

// `body` is untrimmed, so its length is the comment's column. A '#' opens a comment only at line
// start or after a space/tab (the ini rule), keeping one glued to a token inside a value. There
// is no escape after whitespace.
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

// "" for a blank or comment-only line. Every read goes through this: the shipped config
// documents each setting with a trailing comment, which would otherwise reach parse_on_off.
config_strip_comment :: proc(line: string) -> string {
    body, _ := config_split_comment(line)
    return strings.trim_space(body)
}

// The shipped slopd.config, baked in. It IS the defaults — load_config parses it before yours —
// so the file this repo ships and a config-less binary can never drift. Also what `--install`
// writes out, and the only place a slopd.config comes from.
DEFAULT_CONFIG_SRC := string(#load("../../slopd.config"))

// Three layers, each overriding the last:
//   1. the struct below   a floor for anything the shipped file does not name
//   2. DEFAULT_CONFIG_SRC the shipped defaults, baked in
//   3. your slopd.config  if it exists
load_config :: proc() -> Config {
    cfg := Config {
        default_display = .Gfx,
        indent          = {.Spaces, 4},
        line_numbers    = .Relative,
        scroll_mode     = .Follow,
        font_px         = FONT_BASE_PX,
        jump_lines      = 10,
        show_whitespace = true,
        show_guides     = true,
        folding         = true,
        folder_cd_run   = false, // stage the cd, reviewable
        discard_run     = false, // stage the discard: unsaved work is not thrown away unread
        git_term        = 0, // detached: a GUI tool wants its own window, not a PTY
        run_term        = 1, // t1, the command line's own session
        grep_pane_always = true, // no auto-jump on a lone hit
        cl_preview      = true, // Esc puts back whatever the preview showed
        conflict_prompt = true,
        conflict_stage  = true, // stage the answer in the CL
        mouse           = true, // purely additive to the keyboard
        hover           = true, // the tint is faint — see HOVER_MIX (render.odin)
        file_pane       = .Ls,
        file_view       = .List,
        file_icons      = true, // inert where no icon face was vendored
    }
    // `exclude` has no floor: an empty list is a legitimate value a floor could not be told
    // apart from.
    config_parse(DEFAULT_CONFIG_SRC, &cfg)
    if src, _ := os.read_entire_file_from_path(config_file(), context.temp_allocator); src != nil {
        config_parse(string(src), &cfg)
    }
    return cfg
}

// Every key `src` names is applied, the rest left alone. Run twice per launch (baked-in
// defaults, then your file), which is why the owned strings free what they replace.
@(private = "file")
config_parse :: proc(src: string, cfg: ^Config) {
    rest := src
    for line in strings.split_lines_iterator(&rest) {
        s := config_strip_comment(line)
        if len(s) == 0 {
            continue
        }
        if config_is_section(s) {
            break // settings end here; the rest is block data
        }
        colon := strings.index_byte(s, ':')
        if colon <= 0 {
            continue
        }
        key := strings.trim_space(s[:colon])
        val := strings.trim_space(s[colon + 1:])
        switch key {
        case "default_display":
            if d, ok := parse_display(val); ok {
                cfg.default_display = d
            }
        case "theme":
            // A raw token (a themes/ name, "default", or "omarchy"); theme_load resolves it.
            delete(cfg.theme_path)
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
                cfg.font_px = clamp(f32(n), FONT_PX_MIN, FONT_PX_MAX)
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
        case "discard":
            if v, ok := parse_stage_run(val); ok {cfg.discard_run = v}
        case "git_tool":
            delete(cfg.git_tool)
            cfg.git_tool = strings.clone(val)
        case "git_term":
            // Empty or unparseable stays 0 (detached), which is what GIT_TERM_DETACHED writes.
            // git_tool_open clamps a number to the sessions that can exist.
            if v, ok := strconv.parse_int(val); ok {cfg.git_term = max(0, v)}
        case "run_term":
            // A session number only: a program you double-click has output you want to see.
            if v, ok := strconv.parse_int(val); ok && v > 0 {cfg.run_term = v}
        case "grep_pane":
            if v, ok := parse_on_off(val); ok {cfg.grep_pane_always = v}
        case "cl_preview":
            if v, ok := parse_on_off(val); ok {cfg.cl_preview = v}
        case "disk_conflict":
            if v, ok := parse_prompt_keep(val); ok {cfg.conflict_prompt = v}
        case "conflict_stage":
            if v, ok := parse_on_off(val); ok {cfg.conflict_stage = v}
        case "mouse":
            if v, ok := parse_on_off(val); ok {cfg.mouse = v}
        case "hover":
            if v, ok := parse_on_off(val); ok {cfg.hover = v}
        case "file_pane":
            if v, ok := parse_file_pane(val); ok {cfg.file_pane = v}
        case "file_view":
            if v, ok := parse_file_view(val); ok {cfg.file_view = v}
        case "file_icons":
            if v, ok := parse_on_off(val); ok {cfg.file_icons = v}
        case "exclude":
            delete(cfg.exclude)
            cfg.exclude = strings.clone(val)
        }
    }
}

// "tab" | "spaces2" | "spaces4" | "spaces8" ...
@(private = "file")
parse_indent :: proc(s: string) -> (txt.Indent, bool) {
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
    delete(cfg.exclude)
}

// Test seam, empty in a real run: a settings write persists, and a test must never land on the
// shipped file. Not reachable from a config value, a flag or the environment. Tests set it
// through config_override (src/tests/config_harness.odin), which holds the lock it needs.
config_path_override: string

// Beside the binary while portable, ~/.config/slopd/slopd.config once installed (src/paths
// owns that choice). Returned whether or not it exists, since it is also the write target.
// Temp-allocated. No search path: one mode picks one directory.
config_file :: proc() -> string {
    if config_path_override != "" {
        return strings.clone(config_path_override, context.temp_allocator)
    }
    return paths.config_asset("slopd.config", context.temp_allocator)
}

// The one way from a theme token to a live Theme:
//   "omarchy"  -> the desktop palette (theme_omarchy.odin)
//   anything   -> a themes/ file, via theme_resolve
// Both fall back to the baked-in default, so a token that stops resolving shows a palette.
theme_load :: proc(token: string) -> gfx.Theme {
    if token == gfx.OMARCHY_THEME {
        if t, ok := gfx.omarchy_theme(gfx.omarchy_colors_file(context.temp_allocator)); ok {
            return t
        }
        return gfx.default_theme()
    }
    return gfx.load_theme(theme_resolve(token))
}

// A theme token to a file path for load_theme:
//   "" / "default"  -> themes/default.theme, else baked-in
//   "<name>"        -> themes/<name>.theme
// A token is a NAME, never a path: a '/' would reach outside themes/, so it is refused.
// Temp-allocated; "" means the baked-in default.
theme_resolve :: proc(token: string) -> string {
    if strings.contains(token, "/") {
        return "" // no theme lives outside themes/
    }
    if token == gfx.OMARCHY_THEME {
        return "" // reserved: not a file, and theme_load takes it first
    }
    name := token == "" ? "default" : token
    file := fmt.tprintf("%s.theme", name)
    p := filepath.join({paths.data_asset("themes", context.temp_allocator), file}, context.temp_allocator) or_else ""
    return os.exists(p) ? p : ""
}

// Theme is derived from the themes folder; the others are fixed presets. The theme list is
// temp-allocated, the fixed ones static.
setting_options :: proc(a: ^App, s: Setting) -> []string {
    switch s {
    case .DefaultDisplay:
        return DISPLAY_OPTS[:]
    case .LineNumbers:
        return LINE_NUMBER_OPTS[:]
    case .ScrollMode:
        return SCROLL_MODE_OPTS[:]
    case .Indent:
        return INDENT_OPTS[:]
    case .Theme:
        return theme_options(context.temp_allocator)
    case .GitTool, .Exclude:
        return nil // free text — see setting_is_text
    case .GitTerm:
        return term_options(a.git_term, true, term_count(a), context.temp_allocator)
    case .RunTerm:
        return term_options(a.run_term, false, term_count(a), context.temp_allocator)
    case .Folding, .IndentGuides, .Whitespace, .GrepPane, .ClPreview, .ConflictStage, .Mouse, .Hover, .FileIcons:
        return ON_OFF_OPTS[:]
    case .FilePane:
        return FILE_PANE_OPTS[:]
    case .FolderCd, .Discard:
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
FILE_PANE_OPTS := [?]string{"ls", "browser"}
DISPLAY_OPTS := [?]string{"gfx", "tui"}

// "default" first, then "omarchy" where a desktop palette exists, then themes/<name>.theme
// sorted. The pinned entries are not files, so they lead rather than sort in. Names and the
// slice are cloned into `allocator`.
@(private = "file")
theme_options :: proc(allocator := context.allocator) -> []string {
    out := make([dynamic]string, 0, 16, allocator)
    append(&out, "default")
    pinned := 1
    if gfx.omarchy_available() {
        append(&out, gfx.OMARCHY_THEME) // only when a desktop palette exists
        pinned = 2
    }
    dir := paths.data_asset("themes", context.temp_allocator)
    if f, oerr := os.open(dir); oerr == nil {
        defer os.close(f)
        it := os.read_directory_iterator_create(f)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            if !strings.has_suffix(fi.name, ".theme") {
                continue
            }
            base := strings.trim_suffix(fi.name, ".theme")
            if base == "default" || base == gfx.OMARCHY_THEME {
                continue // already offered, or a reserved token
            }
            append(&out, strings.clone(base, allocator))
        }
    }
    slice.sort(out[pinned:]) // pinned first, discovered themes sorted
    return out[:]
}

// git_term's token for "no terminal at all" — a dropdown needs a row for the empty case.
// load_config maps it back to 0.
GIT_TERM_DETACHED :: "detached"

// The open sessions plus the next (term_slot's rule), optionally led by "detached". A
// configured number beyond that is appended too: the pane pre-selects by matching the current
// value, so a missing `git_term: 7` would silently reset it.
@(private = "file")
term_options :: proc(current: int, detached: bool, count: int, allocator := context.allocator) -> []string {
    top := term_slot(count, pty.TERM_MAX) // highest slot naming a session
    out := make([dynamic]string, 0, top + 2, allocator)
    if detached {
        append(&out, GIT_TERM_DETACHED)
    }
    for n in 1 ..= top {
        append(&out, fmt.aprintf("%d", n, allocator = allocator))
    }
    if current > top {
        append(&out, fmt.aprintf("%d", current, allocator = allocator))
    }
    return out[:]
}

// --- the editable settings in the Config aux pane --- These keys and no others; per-language
// grammar paths are data, not knobs, so they stay out. Order is the pane's row order.

Setting :: enum {
    DefaultDisplay,
    Theme,
    LineNumbers,
    ScrollMode,
    Indent,
    Folding,
    IndentGuides,
    Whitespace,
    FolderCd,
    Discard,
    RunTerm,
    GitTool,
    GitTerm,
    GrepPane,
    ClPreview,
    DiskConflict,
    ConflictStage,
    Mouse,
    Hover,
    FilePane,
    FileIcons,
    Exclude,
}

// Free text rather than a choice, so the row is an editor. git_tool is a command line and
// `exclude` a list of patterns; neither has a menu of answers to offer.
setting_is_text :: proc(s: Setting) -> bool {
    return s == .GitTool || s == .Exclude
}

setting_key :: proc(s: Setting) -> string {
    switch s {
    case .DefaultDisplay: return "default_display"
    case .Theme:        return "theme"
    case .LineNumbers:  return "line_numbers"
    case .ScrollMode:   return "scroll_mode"
    case .Indent:       return "indent"
    case .Folding:      return "folding"
    case .IndentGuides: return "indent_guides"
    case .Whitespace:   return "whitespace"
    case .FolderCd:     return "folder_cd"
    case .Discard:      return "discard"
    case .RunTerm:      return "run_term"
    case .GitTool:      return "git_tool"
    case .GitTerm:      return "git_term"
    case .GrepPane:     return "grep_pane"
    case .ClPreview:    return "cl_preview"
    case .DiskConflict:  return "disk_conflict"
    case .ConflictStage: return "conflict_stage"
    case .Mouse:        return "mouse"
    case .Hover:        return "hover"
    case .FilePane:     return "file_pane"
    case .FileIcons:    return "file_icons"
    case .Exclude:      return "exclude"
    }
    return ""
}

// Formatted for display and for seeding the editor. Temp-allocated for Indent, a borrow of App
// state otherwise.
setting_value :: proc(a: ^App, s: Setting) -> string {
    switch s {
    case .DefaultDisplay: return a.default_display == .Tui ? "tui" : "gfx"
    case .Theme:        return a.theme_path
    case .LineNumbers:  return a.line_numbers == .Global ? "global" : "relative"
    case .ScrollMode:   return a.scroll_mode == .Middle ? "middle" : "follow"
    case .Indent:       return a.indent.kind == .Tab ? "tab" : fmt.tprintf("spaces%d", a.indent.width)
    case .Folding:      return on_off(a.folding)
    case .IndentGuides: return on_off(a.show_guides)
    case .Whitespace:   return on_off(a.show_whitespace)
    case .FolderCd:     return a.folder_cd_run ? "run" : "stage"
    case .Discard:      return a.discard_run ? "run" : "stage"
    case .RunTerm:      return fmt.tprintf("%d", max(1, a.run_term))
    case .GitTool:      return a.git_tool // "" is unset (Alt+G opens a shell)
    case .GitTerm:      return a.git_term <= 0 ? GIT_TERM_DETACHED : fmt.tprintf("%d", a.git_term)
    case .GrepPane:     return on_off(a.grep_pane_always)
    case .ClPreview:    return on_off(a.cl_preview_on)
    case .DiskConflict:  return a.conflict_prompt ? "prompt" : "keep"
    case .ConflictStage: return on_off(a.conflict_stage)
    case .Mouse:        return on_off(a.mouse_on)
    case .Hover:        return on_off(a.hover_on)
    case .FilePane:     return a.file_pane == .Browser ? "browser" : "ls"
    case .FileIcons:    return on_off(a.file_icons)
    case .Exclude:      return a.exclude // "" searches everything
    }
    return ""
}

// Validate, apply to the live App, persist. False (changing nothing) on an invalid value.
setting_commit :: proc(a: ^App, s: Setting, val: string) -> bool {
    switch s {
    case .DefaultDisplay:
        // Read at launch, so this run keeps the front-end it started with.
        a.default_display = parse_display(val) or_return
    case .Theme:
        delete(a.theme_path)
        a.theme_path = strings.clone(val) // the raw token
        a.theme = theme_load(val)
    case .LineNumbers:
        switch val {
        case "global":   a.line_numbers = .Global
        case "relative": a.line_numbers = .Relative
        case:            return false
        }
    case .ScrollMode:
        a.scroll_mode = parse_scroll_mode(val) or_return
    case .Indent:
        a.indent = parse_indent(val) or_return
    case .Folding:
        a.folding = parse_on_off(val) or_return
        if !a.folding {
            edit.editor_clear_folds(&a.editor) // expand everything
        }
    case .IndentGuides:
        a.show_guides = parse_on_off(val) or_return
    case .Whitespace:
        a.show_whitespace = parse_on_off(val) or_return
    case .FolderCd:
        a.folder_cd_run = parse_stage_run(val) or_return
    case .Discard:
        a.discard_run = parse_stage_run(val) or_return
    case .RunTerm:
        n := strconv.parse_int(val) or_return
        if n < 1 {
            return false // every value is a session here
        }
        a.run_term = n
    case .GitTool:
        // A value carrying a comment-opening '#' writes whole but reads back truncated, so the
        // pane would show what the file does not hold. Refuse it.
        if _, comment := config_split_comment(val); comment != "" {
            return false
        }
        delete(a.git_tool) // App owns its copy — see app_destroy
        a.git_tool = strings.clone(val)
    case .GitTerm:
        if val == GIT_TERM_DETACHED {
            a.git_term = 0 // its own window, no PTY
        } else {
            n := strconv.parse_int(val) or_return
            if n < 0 {
                return false
            }
            a.git_term = n
        }
    case .GrepPane:
        a.grep_pane_always = parse_on_off(val) or_return
    case .ClPreview:
        a.cl_preview_on = parse_on_off(val) or_return
        if !a.cl_preview_on {
            cl_preview_restore(a) // put back whatever is showing
        }
    case .DiskConflict:
        a.conflict_prompt = parse_prompt_keep(val) or_return
    case .ConflictStage:
        a.conflict_stage = parse_on_off(val) or_return
    case .Mouse:
        a.mouse_on = parse_on_off(val) or_return
    case .Hover:
        a.hover_on = parse_on_off(val) or_return
    case .FilePane:
        a.file_pane = parse_file_pane(val) or_return
    case .FileIcons:
        a.file_icons = parse_on_off(val) or_return
    case .Exclude:
        // git_tool's limit: a '#' would write whole and read back truncated.
        if _, comment := config_split_comment(val); comment != "" {
            return false
        }
        delete(a.exclude) // App owns its copy — see app_destroy
        a.exclude = strings.clone(val)
    }
    config_set(setting_key(s), val)
    return true
}

parse_display :: proc(s: string) -> (d: Display, ok: bool) {
    switch s {
    case "gfx": return .Gfx, true
    case "tui": return .Tui, true
    }
    return .Gfx, false
}

// ok=false on anything else, so an invalid edit keeps the old value.
parse_file_pane :: proc(s: string) -> (pane: File_Pane, ok: bool) {
    switch s {
    case "ls":      return .Ls, true
    case "browser": return .Browser, true
    }
    return .Ls, false
}

// Written back by the pane's toggle rather than typed, so it is not a Config pane row — but
// still a config line, because the view should survive a restart.
parse_file_view :: proc(s: string) -> (view: Browse_View, ok: bool) {
    switch s {
    case "list": return .List, true
    case "grid": return .Grid, true
    }
    return .List, false
}

// `Name: /path` lines between the header and the next section. Strings and slice are cloned
// into `alloc`; the caller owns them all.
//
// An empty result means "no block", not "no places" — the browser fills that with its defaults.
config_places :: proc(alloc := context.allocator) -> []Place {
    out := make([dynamic]Place, 0, 8, alloc)
    src, _ := os.read_entire_file_from_path(config_file(), context.temp_allocator)
    if src == nil {
        return out[:]
    }
    rest := string(src)
    inside := false
    for line in strings.split_lines_iterator(&rest) {
        s := config_strip_comment(line)
        if len(s) == 0 {
            continue
        }
        if config_is_section(s) {
            inside = s == CONFIG_SECTION_PLACES
            continue
        }
        if !inside {
            continue
        }
        colon := strings.index_byte(s, ':')
        if colon <= 0 {
            continue
        }
        name := strings.trim_space(s[:colon])
        path := strings.trim_space(s[colon + 1:])
        if name == "" || path == "" {
            continue
        }
        append(&out, Place{strings.clone(name, alloc), strings.clone(path, alloc)})
    }
    return out[:]
}

// Every other line of the file survives verbatim. The block is dropped and re-emitted at the
// end rather than edited in place: it is a list, so neither an add nor a remove is the
// line-for-line replacement config_set does. `keep_empty` writes the header with nothing under
// it, which is how an emptied [places] stays empty instead of being filled back in.
config_block_write :: proc(
    section, comment: string,
    lines: []string,
    keep_empty := false,
) -> bool {
    if !config_writable() {
        return false // read-only — see src/paths
    }
    path := config_file()
    b := strings.builder_make(context.temp_allocator)
    if src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil; src != nil {
        rest := string(src)
        skipping := false
        for raw in strings.split_lines_iterator(&rest) {
            if s := config_strip_comment(raw); config_is_section(s) {
                skipping = s == section
            }
            if !skipping {
                strings.write_string(&b, raw)
                strings.write_byte(&b, '\n')
            }
        }
    }
    // One blank line before the header whatever the file ended with; the trim stops a
    // rewrite-per-add growing a run of them.
    body := strings.trim_right_space(strings.to_string(b))
    b = strings.builder_make(context.temp_allocator)
    strings.write_string(&b, body)
    strings.write_byte(&b, '\n')
    if len(lines) > 0 || keep_empty {
        fmt.sbprintf(&b, "\n%s  %s\n", section, comment)
        for l in lines {
            strings.write_string(&b, l)
            strings.write_byte(&b, '\n')
        }
    }
    paths.ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

config_places_write :: proc(places: []Place) -> bool {
    lines := make([dynamic]string, 0, len(places), context.temp_allocator)
    for p in places {
        append(&lines, fmt.tprintf("%s: %s", p.name, p.path))
    }
    return config_block_write(
        CONFIG_SECTION_PLACES,
        "# file browser sidebar — add/remove by right-clicking a folder",
        lines[:],
        keep_empty = true,
    )
}

// Open slopd.config at the first line of `section` the loader refused, else at its header, else
// at the end. Shared by the config pane's bindings and macros rows.
config_open_block :: proc(a: ^App, section: string, errs: []Bind_Error, line := 0) {
    path := config_file()
    at := line > 0 ? line : config_block_line(path, section, errs)
    cl_dispatch(a, fmt.tprintf(":j %s %d", cl_quote_arg(path, context.temp_allocator), at), true)
}

@(private = "file")
config_block_line :: proc(path, section: string, errs: []Bind_Error) -> int {
    if len(errs) > 0 {
        return errs[0].line
    }
    src, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    rest, n, last := string(src), 0, 1
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        if config_strip_comment(raw) == section {
            return n
        }
        last = n
    }
    return last
}

// "prompt" asks in the command line before reconciling a disk change against unsaved edits;
// "keep" silently keeps your edits. ok=false on anything else.
parse_prompt_keep :: proc(s: string) -> (prompt: bool, ok: bool) {
    switch s {
    case "prompt": return true, true
    case "keep":   return false, true
    }
    return false, false
}

// "follow" moves the view only when the target would leave it; "middle" keeps it on the middle
// row. ok=false on anything else.
parse_scroll_mode :: proc(s: string) -> (mode: ui.Scroll_Mode, ok: bool) {
    switch s {
    case "follow": return .Follow, true
    case "middle": return .Middle, true
    }
    return .Follow, false
}

// ok=false on anything else.
parse_stage_run :: proc(s: string) -> (run: bool, ok: bool) {
    switch s {
    case "stage": return false, true
    case "run":   return true, true
    }
    return false, false
}

// ok=false on anything else.
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

// Read-modify-write: the matching line is replaced in place, everything else preserved
// verbatim, a new key appended. The replaced line keeps its trailing comment, re-aligned — it
// documents the setting, not its value.
//
// A `[section]` header ends the settings, so a new key is inserted ABOVE the block; appended
// after it, load_config would never read it back.
config_set :: proc(key, val: string) -> bool {
    if !config_writable() {
        // Unwritable location, or no config file — Slopd does not make one, `--install` does.
        return false
    }
    path := config_file()
    src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil
    out := config_rewrite(string(src), key, val, context.temp_allocator)
    paths.ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)out) == nil
}

// Over text rather than a file, so the suite can check the comment column and the section rule
// without one. An empty `src` yields the one line.
config_rewrite :: proc(src, key, val: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(src) + len(key) + len(val) + 8, allocator)
    replaced := false
    rest := src
    for raw in strings.split_lines_iterator(&rest) {
        body, comment := config_split_comment(raw)
        s := strings.trim_space(body)
        if !replaced && config_is_section(s) {
            config_write_line(&b, key, val, "", 0)
            strings.write_byte(&b, '\n') // the blank line that sets the block apart
            replaced = true
        }
        if !replaced {
            if colon := strings.index_byte(s, ':'); colon > 0 && strings.trim_space(s[:colon]) == key {
                config_write_line(&b, key, val, comment, len(body))
                replaced = true
                continue
            }
        }
        strings.write_string(&b, raw)
        strings.write_byte(&b, '\n')
    }
    if !replaced {
        config_write_line(&b, key, val, "", 0)
    }
    return strings.to_string(b)
}

// --- the config file `--install` writes ---

// The only place a slopd.config is created: a settings change writes to a file that already
// exists, or reports that it cannot. Refuses to overwrite, so an install cannot roll back
// settings you have been editing.
config_default_write :: proc(path: string) -> bool {
    if path == "" || os.exists(path) {
        return false
    }
    paths.ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)DEFAULT_CONFIG_SRC) == nil
}

// `comment` is padded out to `col`, where it sat on the replaced line, so the file's comment
// column survives an edit. A longer value pushes it right, keeping one space.
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
