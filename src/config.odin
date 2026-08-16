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
// ROWS only: the editor's column axis has a policy of its own and no Middle mode, for a
// reason spelled out at buffer_hscroll_target.
Scroll_Mode :: enum {
    Follow,
    Middle,
}

// Which presentation the filetree aux pane wears. `Ls` is the dired-style listing Slopd has
// always had; `Browser` is the file-manager one (top bar, places sidebar, list or grid). Both
// drive the SAME FileTree model, so this chooses pixels and pointer targets, never behaviour.
File_Pane :: enum {
    Ls,
    Browser,
}

// Config — Slopd's own simple `key: value` file. Points at a theme file and holds a few
// editor settings. It lives in ONE directory, which install.odin picks (see config_file) —
// beside the binary, or ~/.config/slopd once installed. Anything missing keeps the defaults
// below.
//
// **One `[section]` block exists, and it is not a setting**: `[places]` holds the file browser's
// sidebar shortcuts, `Name: /path` per line. It is deliberately outside the key/value space the
// Config pane edits — a list of directories is added to by pointing at one, not by typing into a
// settings row — so every reader here STOPS at the first section header. See config_places.
Config :: struct {
    theme_path:       string, // absolute (owned), or "" for the baked-in default
    indent:           Indent,
    line_numbers:     Line_Numbers,
    scroll_mode:      Scroll_Mode, // every line view's ROWS: follow the caret/selection, or keep it middled
    font_px:          f32, // logical text size in points (font zoom), persisted across runs
    jump_lines:       int, // how many lines Ctrl+Up/Down jumps in the editor
    show_whitespace:  bool, // ghost the leading-space dots / tab marks
    show_guides:      bool, // draw indent guides + the active-scope rail
    folding:          bool, // allow Ctrl+Enter block folding
    folder_cd_run:    bool, // filetree Alt+Enter: run the `cd` at once vs stage it in the CL
    git_tool:         string, // external git tool Alt+G hands the project root to (owned); "" = none
    git_term:         int, // which terminal session to run it in; 0 = spawn it detached
    run_term:         int, // which terminal session an activated executable runs in
    grep_pane_always: bool, // CL grep: always open the results pane vs jump straight on a lone hit
    cl_preview:       bool, // show a builtin line's effect (`:j` `:f` `:grep`) while it is typed
    conflict_prompt:  bool, // disk changed under unsaved edits: prompt (y/n in the CL) vs silently keep my edits
    conflict_stage:   bool, // a raised conflict stages `:reload ` in the CL vs only marking the modeline
    mouse:            bool, // pointer input (wheel, and the clicks that follow it) on/off
    hover:            bool, // tint the row under the pointer; needs `mouse` to mean anything
    file_pane:        File_Pane, // which presentation the filetree pane wears
    file_view:        Browse_View, // the browser's contents: list or grid (its toggle writes this back)
    file_icons:       bool, // per-type icons in the browser (needs the vendored icon face)
}

// The config file's one section header. Everything below it is data rather than settings, and
// every key/value reader stops when it sees a line like this.
CONFIG_SECTION_PLACES :: "[places]"

// Whether a stripped line opens a `[section]` block. One proc because three readers ask it —
// the loader, the setting writer and the places parser — and a section they disagreed about
// would let a place named `theme` be rewritten as if it were the theme setting.
config_is_section :: proc(s: string) -> bool {
    return len(s) >= 2 && s[0] == '[' && s[len(s) - 1] == ']'
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

// The shipped slopd.config, #load-ed into the binary the way the README, the licence and the
// default theme are. It is THE defaults — not a copy of them — because load_config parses it
// before it parses yours, so a value can never drift between the file this repo ships and the
// behaviour a binary with no config file has. It is also what `--install` writes out, and the
// only place a slopd.config ever comes from.
DEFAULT_CONFIG_SRC := string(#load("../slopd.config"))

// The settings, in three layers, each overriding the last:
//
//   1. the struct below   a floor, for anything the shipped file does not name (and for the
//                         day a key is deleted from it). Never user-visible on its own.
//   2. DEFAULT_CONFIG_SRC the shipped defaults, baked into this binary. A downloaded binary
//                         with no config file gets exactly these.
//   3. your slopd.config  whichever one the mode chose, if it exists.
load_config :: proc() -> Config {
    cfg := Config {
        indent          = {.Spaces, 4}, // matches the project's 4-space convention
        line_numbers    = .Relative,
        scroll_mode     = .Follow, // the view moves only when the caret would leave it
        font_px         = FONT_BASE_PX,
        jump_lines      = 10,
        show_whitespace = true, // the guides default on; the config toggles them off
        show_guides     = true,
        folding         = true,
        folder_cd_run   = false, // stage the cd in the CL by default (reviewable)
        git_term        = 0, // detached by default: a GUI tool wants its own window, not a PTY
        run_term        = 1, // t1, the master CL terminal, unless you point it elsewhere
        grep_pane_always = true, // always show the results pane (no auto-jump on a lone hit)
        cl_preview      = true, // `:j` `:f` `:grep` show what they would do; Esc puts it back
        conflict_prompt = true, // ask before a disk change is reconciled against unsaved edits
        conflict_stage  = true, // and stage the answer in the CL, rather than only marking it
        mouse           = true, // pointer input on; it is purely additive to the keyboard
        hover           = true, // the tint is deliberately faint — see HOVER_MIX (render.odin)
        file_pane       = .Ls,
        file_view       = .List,
        file_icons      = true, // free where the icon face was vendored, and inert where it wasn't
    }
    config_parse(DEFAULT_CONFIG_SRC, &cfg)
    if src, _ := os.read_entire_file_from_path(config_file(), context.temp_allocator); src != nil {
        config_parse(string(src), &cfg)
    }
    return cfg
}

// Read `src` over `cfg`: every key it names is applied, every key it does not is left as it
// was. Run twice per launch (the baked-in defaults, then your file), which is why the two
// OWNED strings free what they replace — a second pass would otherwise leak the first's.
@(private = "file")
config_parse :: proc(src: string, cfg: ^Config) {
    rest := src
    for line in strings.split_lines_iterator(&rest) {
        s := config_strip_comment(line)
        if len(s) == 0 {
            continue
        }
        if config_is_section(s) {
            break // settings end here; what follows is block data (config_places reads it)
        }
        colon := strings.index_byte(s, ':')
        if colon <= 0 {
            continue
        }
        key := strings.trim_space(s[:colon])
        val := strings.trim_space(s[colon + 1:])
        switch key {
        case "theme":
            // Stored as a raw token (a themes/ name, "default", or "omarchy");
            // theme_load turns it into a palette at load time.
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
        case "run_term":
            // A session number and nothing else — unlike git_term there is no detached case,
            // because a program you double-click has output you want to SEE. Junk keeps t1.
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
        }
    }
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

// TEST SEAM, empty in a real run: the config file to use instead of the one beside the
// binary. Only the suite sets it — a settings write PERSISTS, and a test must never land
// on the shipped file. Not reachable from a config value, a flag, or the environment.
// Tests set it through config_override in src/tests/config_harness.odin, never directly:
// it is one string for a multi-threaded runner, so it needs a lock around it.
config_path_override: string

// The config file: slopd.config beside the binary while Slopd is portable, and
// ~/.config/slopd/slopd.config once it is installed (install.odin owns that choice).
// Returned whether or not it exists, since it is also the WRITE target — config_set creates
// it on the first settings change. Temp-allocated.
//
// There is deliberately no search path. One mode picks ONE directory and Slopd reads and
// writes there; no value in the config can point the config, a theme, or a grammar anywhere
// else.
config_file :: proc() -> string {
    if config_path_override != "" {
        return strings.clone(config_path_override, context.temp_allocator)
    }
    return config_asset("slopd.config", context.temp_allocator)
}

// The one way from a theme config token to a live Theme:
//   "omarchy"  -> the desktop palette Omarchy keeps (see theme_omarchy.odin)
//   anything   -> a themes/ file, resolved by theme_resolve
// Both fall back to the baked-in default when the source is not there, so a token that
// stops resolving (an uninstalled Omarchy, a deleted file) shows a palette, never black.
theme_load :: proc(token: string) -> Theme {
    if token == OMARCHY_THEME {
        if t, ok := omarchy_theme(omarchy_colors_file(context.temp_allocator)); ok {
            return t
        }
        return default_theme()
    }
    return load_theme(theme_resolve(token))
}

// Resolves a theme config token (from the Config pane's dropdown) to a file path for load_theme:
//   "" / "default"  -> themes/default.theme in the themes folder (else baked-in)
//   "<name>"        -> themes/<name>.theme there
// A token is a NAME, never a path: a '/' in it would reach outside themes/, so it is refused
// and the baked-in default stands. Result is temp-allocated; "" means the baked-in default.
theme_resolve :: proc(token: string) -> string {
    if strings.contains(token, "/") {
        return "" // not a name — no theme lives outside themes/
    }
    if token == OMARCHY_THEME {
        return "" // reserved: the desktop palette is not a file. theme_load takes it first
    }
    name := token == "" ? "default" : token
    file := fmt.tprintf("%s.theme", name)
    p := filepath.join({data_asset("themes", context.temp_allocator), file}, context.temp_allocator) or_else ""
    return os.exists(p) ? p : ""
}

// The dropdown choices for a setting. Theme is derived (the themes folder, plus
// the "default" baked-in palette); the others are fixed presets. The theme list is
// temp-allocated; the fixed ones are static.
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
        return term_options(a.git_term, true, term_count(a), context.temp_allocator)
    case .RunTerm:
        return term_options(a.run_term, false, term_count(a), context.temp_allocator)
    case .Folding, .IndentGuides, .Whitespace, .GrepPane, .ClPreview, .ConflictStage, .Mouse, .Hover, .FileIcons:
        return ON_OFF_OPTS[:]
    case .FilePane:
        return FILE_PANE_OPTS[:]
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
FILE_PANE_OPTS := [?]string{"ls", "browser"}

// "default" first, then "omarchy" on a desktop that has a theme applied, then every
// themes/<name>.theme in the themes folder, sorted. The two pinned entries are not files,
// so they lead the list rather than sorting into it.
// Names are cloned into `allocator`; the returned slice is too.
@(private = "file")
theme_options :: proc(allocator := context.allocator) -> []string {
    out := make([dynamic]string, 0, 16, allocator)
    append(&out, "default") // the baked-in palette
    pinned := 1
    if omarchy_available() {
        append(&out, OMARCHY_THEME) // offered only when there is a desktop palette to follow
        pinned = 2
    }
    dir := data_asset("themes", context.temp_allocator)
    if f, oerr := os.open(dir); oerr == nil {
        defer os.close(f)
        it := os.read_directory_iterator_create(f)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            if !strings.has_suffix(fi.name, ".theme") {
                continue
            }
            base := strings.trim_suffix(fi.name, ".theme")
            if base == "default" || base == OMARCHY_THEME {
                continue // already offered above, or a reserved token no file can claim
            }
            append(&out, strings.clone(base, allocator))
        }
    }
    slice.sort(out[pinned:]) // keep the pinned tokens first; sort the discovered themes
    return out[:]
}

// git_term's token for "no terminal at all". Unlike git_tool, git_term is a CLOSED choice —
// a session number, or its own window — so it stays a dropdown, and a dropdown needs a row
// to point at for the empty case. load_config maps this straight back to 0.
GIT_TERM_DETACHED :: "detached"

// Every session number a launch can land on: the open ones plus the next (term_slot's rule),
// optionally led by "detached". A configured number beyond that is appended too, because the
// pane pre-selects by MATCHING the current value — a missing `git_term: 7` would silently
// reset it. Shared by the two settings that name a session, which differ only in that one of
// them can also mean "no session at all".
@(private = "file")
term_options :: proc(current: int, detached: bool, count: int, allocator := context.allocator) -> []string {
    top := term_slot(count, TERM_MAX) // the highest slot that names a session
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
    case .RunTerm:      return fmt.tprintf("%d", max(1, a.run_term))
    case .GitTool:      return a.git_tool // free text; "" is unset (Alt+G opens a shell)
    case .GitTerm:      return a.git_term <= 0 ? GIT_TERM_DETACHED : fmt.tprintf("%d", a.git_term)
    case .GrepPane:     return on_off(a.grep_pane_always)
    case .ClPreview:    return on_off(a.cl_preview_on)
    case .DiskConflict:  return a.conflict_prompt ? "prompt" : "keep"
    case .ConflictStage: return on_off(a.conflict_stage)
    case .Mouse:        return on_off(a.mouse_on)
    case .Hover:        return on_off(a.hover_on)
    case .FilePane:     return a.file_pane == .Browser ? "browser" : "ls"
    case .FileIcons:    return on_off(a.file_icons)
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
        a.theme_path = strings.clone(val) // the raw token: a themes/ name, "default", or "omarchy"
        a.theme = theme_load(val) // a file, or the desktop palette; either can fall back
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
    case .RunTerm:
        n := strconv.parse_int(val) or_return
        if n < 1 {
            return false // every value is a session; there is no detached case here
        }
        a.run_term = n
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
    case .ClPreview:
        a.cl_preview_on = parse_on_off(val) or_return
        if !a.cl_preview_on {
            cl_preview_restore(a) // turning it off mid-line puts back whatever is showing
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
    }
    config_set(setting_key(s), val)
    return true
}

// Parses which presentation the filetree pane wears: "ls" is the dired-style listing, "browser"
// the file manager. ok=false on anything else (an invalid edit keeps the old value).
parse_file_pane :: proc(s: string) -> (pane: File_Pane, ok: bool) {
    switch s {
    case "ls":      return .Ls, true
    case "browser": return .Browser, true
    }
    return .Ls, false
}

// Parses the browser's contents view. Written back by the pane's own toggle button rather than
// typed, which is why it is not one of the Config pane's rows — but it is still a config line,
// because a view you chose should survive a restart.
parse_file_view :: proc(s: string) -> (view: Browse_View, ok: bool) {
    switch s {
    case "list": return .List, true
    case "grid": return .Grid, true
    }
    return .List, false
}

// The `[places]` block, in file order: `Name: /path` lines between the header and the next
// section (or the end). Both strings are cloned into `alloc`, and so is the slice — the caller
// owns every one of them (filebrowser_init takes them straight onto the FileBrowser).
//
// An empty result means "no block", not "no places": the browser fills that with its defaults
// rather than showing an empty sidebar, and the block is written the first time one is added.
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

// Rewrite the `[places]` block, keeping every other line of the file verbatim — settings, their
// comments, and any other section. The block is dropped and re-emitted at the END rather than
// edited in place: it is a LIST, so an add is an append and a remove is a hole, and neither is a
// line-for-line replacement the way `config_set` does a setting.
config_places_write :: proc(places: []Place) -> bool {
    if !config_writable() {
        return false // read-only: the binary sits somewhere we may not write (install.odin)
    }
    path := config_file()
    b := strings.builder_make(context.temp_allocator)

    if src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil; src != nil {
        rest := string(src)
        skipping := false
        for raw in strings.split_lines_iterator(&rest) {
            s := config_strip_comment(raw)
            if config_is_section(s) {
                skipping = s == CONFIG_SECTION_PLACES
                if skipping {
                    continue
                }
            }
            if skipping {
                continue // a line of the old block, header included
            }
            strings.write_string(&b, raw)
            strings.write_byte(&b, '\n')
        }
    }
    // Exactly one blank line before the header, whatever the file ended with: the trim is what
    // stops a rewrite-per-add growing a run of blank lines at the end of the file.
    out := strings.trim_right_space(strings.to_string(b))
    b = strings.builder_make(context.temp_allocator)
    strings.write_string(&b, out)
    strings.write_string(&b, "\n\n")
    strings.write_string(&b, CONFIG_SECTION_PLACES)
    strings.write_string(&b, "  # file browser sidebar — add/remove by right-clicking a folder\n")
    for p in places {
        fmt.sbprintf(&b, "%s: %s\n", p.name, p.path)
    }
    ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
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
//
// **A `[section]` header ends the settings.** Nothing below one is a key this may rewrite (a
// place named `theme` is a directory, not the theme), and a key this file does not already carry
// is inserted ABOVE the block rather than appended after it — where load_config, which stops at
// the same line, would never read it back.
config_set :: proc(key, val: string) -> bool {
    if !config_writable() {
        // Either the binary sits somewhere we may not write, or there is no config file to
        // write to and Slopd does not make one — `--install` does. See install.odin.
        return false
    }
    path := config_file()
    src := os.read_entire_file_from_path(path, context.temp_allocator) or_else nil
    out := config_rewrite(string(src), key, val, context.temp_allocator)
    ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)out) == nil
}

// The rewrite itself, over TEXT rather than a file: `src` with `key` set to `val`. Pure, so
// the suite can check the comment column and the section rule without a file, and so the
// Config pane edits by. An empty `src` yields the one line.
config_rewrite :: proc(src, key, val: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(src) + len(key) + len(val) + 8, allocator)
    replaced := false
    rest := src
    for raw in strings.split_lines_iterator(&rest) {
        // A comment-only line leaves body blank, so it can never match a key.
        body, comment := config_split_comment(raw)
        s := strings.trim_space(body)
        if !replaced && config_is_section(s) {
            config_write_line(&b, key, val, "", 0)
            strings.write_byte(&b, '\n') // keep the blank line that sets the block apart
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

// Write the baked-in default config to `path`. **This is the only place a slopd.config is
// created.** Nothing else does: a settings change writes to a file that already exists, or
// reports that it cannot (config_writable). Refuses to overwrite, because the one thing an
// install must never do is roll back settings you have been editing.
config_default_write :: proc(path: string) -> bool {
    if path == "" || os.exists(path) {
        return false
    }
    ensure_parent(path)
    return os.write_entire_file(path, transmute([]byte)DEFAULT_CONFIG_SRC) == nil
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
