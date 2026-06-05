package main

import "core:os"
import "core:strings"
import "vendor:glfw"

// Application state — the single source of truth. Everything else (layout,
// input, render) reads or mutates this. Kept flat and plain on purpose.

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Font zoom. font_px is the logical text size in points, shared by every pane; the
// atlas bakes at font_px * DPI scale. Ctrl +/- steps it, Ctrl+0 resets to the base.
// The chosen size is persisted to config, but debounced: we wait FONT_SAVE_DELAY of
// no further change before writing, so a burst of Ctrl+/- is one save, not a dozen.
FONT_BASE_PX :: 15
FONT_PX_MIN :: 8
FONT_PX_MAX :: 40
FONT_PX_STEP :: 1
FONT_SAVE_DELAY :: 5.0 // seconds the size must sit unchanged before it persists

// There are always two panes: the editor (left) and the aux pane (right). The
// aux pane shows one of these modes. (The master command line is not a mode —
// it lives in the bottom status strip + t1.)
AuxMode :: enum {
    FileTree,
    Terminal,
    Procmon,
    Git,
    Config,
}

Focus :: enum {
    Editor,
    Aux,
}

// How the two panes are arranged — the single stored bit the layout derives from.
// Split (default): both panes always on screen. Zen: the editor gets the full
// width and the aux pane slides in only while it is focused (any goto / Alt+Right
// reveals it; focusing the editor retracts it). Util: no editor at all, the aux
// pane fills the window — launched with --util for an xdg-portal file picker etc.
// Visibility is recomputed every frame from this + focus, so there is no separate
// hidden/popped state to keep in sync.
View :: enum {
    Split,
    Zen,
    Util,
}

Pane_Vis :: struct {
    editor, aux: bool,
}

App :: struct {
    view:     View, // pane arrangement (Split / Zen / Util)
    aux_mode: AuxMode,
    focus:    Focus,
    split:    f32, // editor width as a fraction of the window (0..1)

    // Terminal sessions (aux pane, terminal mode). Heap-allocated and held by
    // pointer so the array growing never moves a Terminal out from under its reader
    // thread (see terminal.odin). t1 is spawned lazily on first use. The switcher
    // overlay is hidden until Alt is held, then Up/Down move term_active. Ctrl/Shift
    // held are tracked too: Alt+Ctrl / Alt+Shift are the terminal copy-cursor chords,
    // and the switcher hides while either is down (it is only for plain-Alt switching).
    alt_held:    bool,
    ctrl_held:   bool,
    shift_held:  bool,
    terminals:   [dynamic]^Terminal,
    term_active: int,

    // Master command line. A transient input field in the status strip; when
    // active it grabs bare keys (see input routing).
    cl_active: bool,
    cl:        CommandLine,

    // A submitted line parses into an && chain (builtins + shell steps). The runner
    // injects shell steps and, when a builtin waits on one, blocks on its exit code
    // (the OSC sentinel) before continuing — pumped each frame. cl_wait_seq tags each
    // wrapped injection so its exit report can be matched back.
    cl_chain:    CLChain,
    cl_wait_seq: u64,

    // The project root: the directory the `cd` command-line builtin sets (NOT a shell
    // cd — it's captured by Slopd). New terminals spawn here, the `tu` builtin syncs
    // every unlocked terminal to it, the git pane (and other root-scoped tools) read
    // it, and the idle status strip shows it. Owned; defaults to the launch cwd.
    project_root: string,

    tree:        FileTree, // filetree aux mode (initialised in main, needs IO)
    config_pane: ConfigPane, // config / syntax aux mode (initialised in main, needs IO)
    git:         GitPane, // git aux mode (Sublime-Merge-lite; initialised in main)
    editor:      Editor, // the text buffers (left pane)

    grammars: []Grammar, // language registry (owned; loaded in main), shared by the
    // config pane (lang list) and the highlighter (ext -> grammar)
    hl: Highlighter, // tree-sitter syntax highlighting (loaded grammars, cached)

    // Multi-cursor drop chord (no mode/toggle): Alt+A held + a direction drops a
    // cursor and steps that way, so holding Alt+A and tapping arrows lays a trail.
    // a_held tracks A the way alt_held tracks Alt. Esc collapses back to one.
    a_held: bool,

    // One-shot "move all cursors" prefix: tap Alt+M, then the next motion moves
    // every cursor (with Ctrl/Shift) instead of just the free caret, and it clears.
    move_all_armed: bool,

    // Animation state for the redraw scheduler (see anim.odin). blink_base is the
    // last-input time the caret blink is measured from; the two Anims tween the Zen
    // aux-pane reveal and the terminal switcher fade.
    blink_base:    f64,
    zen_anim:      Anim, // aux-pane reveal in Zen: 0 hidden .. 1 docked
    switcher_anim: Anim, // terminal switcher fade-in while Alt is held
    split_anim:    Anim, // editor/aux split widen while git is the aux mode (carries the editor fraction)

    theme:        Theme, // colour palette (loaded from config in main)
    theme_path:   string, // active theme path (owned, resolved by load_config); "" = baked-in default
    indent:       Indent, // Tab-key indentation policy (from config)
    line_numbers: Line_Numbers, // gutter style (from config)
    jump_lines:   int, // lines per Ctrl+Up/Down editor jump (from config)

    // Editor reading-aids, toggled from the Config pane (all default on). show_whitespace:
    // the ghosted leading-space dots / tab marks. show_guides: indent guides + the active-
    // scope rail. folding: whether Ctrl+Enter collapses blocks.
    show_whitespace: bool,
    show_guides:     bool,
    folding:         bool,

    // Filetree Alt+Enter on a folder produces a `cd <path>` command line. When
    // folder_cd_run is set it executes at once; otherwise it's staged in the CL for
    // the user to review and run with Enter (the reviewable default). See cl_dispatch.
    folder_cd_run:   bool,

    // Git pane CL injections, same stage-vs-run policy as folder_cd: Enter on a branch
    // produces `git checkout <branch>`; Enter in the commit box produces the staged-commit
    // recipe. When the matching flag is set the command fires at once, else it's staged in
    // the CL for review.
    git_checkout_run: bool,
    git_commit_run:   bool,
    git_merge_run:    bool,

    // The git pane's slot-machine gag (Ctrl+Shift+Alt+S): when risky_mode is on the
    // lucky-dip commit auto-sends (run, no review); otherwise it's staged in the CL.
    risky_mode: bool,
    scale:        f32, // DPI content scale: logical px * scale = physical px
    font_px:      f32, // logical text size in points (font zoom); base is FONT_BASE_PX
    font_save_at: f64, // glfw time to persist font_px at (debounce); 0 = nothing pending

    // Clipboard. window is the GLFW handle for the system clipboard; clip_joined /
    // clip_pieces remember our last copy so a multi-cursor paste can distribute
    // one piece per caret when the clipboard still holds exactly what we wrote.
    window:      glfw.WindowHandle,
    clip_joined: string,
    clip_pieces: []string,
}

// The Doc currently receiving edits: the command line when it's active, otherwise
// the focused editor buffer. The CL is just a one-line buffer, so motion, multi-
// cursor, and selection code serves both through this.
active_doc :: proc(a: ^App) -> ^Doc {
    if a.cl_active {
        return &a.cl.doc
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        cp := &a.config_pane
        if config_pane_is_search(cp.sel) {
            return &cp.search // the search box is the pane's only text input
        }
    }
    return &editor_current(&a.editor).doc
}

// Which panes are on screen — a pure function of the view mode and focus. In Zen
// the aux pane is present exactly while it holds focus, so revealing it is just a
// focus change and retracting it is focusing the editor; no extra state.
panes_visible :: proc(a: ^App) -> Pane_Vis {
    switch a.view {
    case .Split:
        return {editor = true, aux = true}
    case .Zen:
        return {editor = true, aux = a.focus == .Aux}
    case .Util:
        return {editor = false, aux = true}
    }
    return {true, true}
}

// The one place focus changes — honours each view's invariants. Util has no editor
// to focus, so focus is pinned to the aux pane there. In Zen, focus drives the aux
// pane's slide (revealed while it holds focus), so re-aim the reveal animation here.
set_focus :: proc(a: ^App, who: Focus) {
    a.focus = a.view == .Util ? .Aux : who
    if a.view == .Zen {
        now := glfw.GetTime()
        anim_start(&a.zen_anim, now, anim_value(&a.zen_anim, now), a.focus == .Aux ? 1 : 0, ZEN_DUR)
    }
    // The git pane reloads whenever it gains focus, so its optics never go stale behind
    // edits made elsewhere (a save in the editor, a commit in a terminal). git status /
    // log are fast and this only fires on a real focus change. Covers both the goto
    // (set_aux -> here) and Alt+Right into an already-git aux pane.
    if a.focus == .Aux && a.aux_mode == .Git {
        git_refresh(a)
    }
}

// Toggle zen on/off (the `zen` / `zm` command line builtin). No-op under Util,
// which is a launch mode, not a runtime toggle.
view_toggle_zen :: proc(a: ^App) {
    if a.view == .Util {
        return
    }
    a.view = a.view == .Zen ? .Split : .Zen
    set_focus(a, .Editor) // land in the editor so zen collapses to full-width at once
}

// Escape's view action: turn Zen ON (never off), then once in Zen flip which side is
// shown. Focusing the editor hides the aux pane (full-width editor); focusing the aux
// pane slides it back in on whatever mode was last there (a.aux_mode persists). No-op
// under Util, which is a launch mode rather than a runtime view.
zen_escape :: proc(a: ^App) {
    if a.view == .Util {
        return
    }
    if a.view != .Zen {
        a.view = .Zen
        set_focus(a, a.focus) // enter Zen keeping focus; animates the aux pane to match
        return
    }
    set_focus(a, a.focus == .Aux ? .Editor : .Aux)
}

app_init :: proc(a: ^App) {
    a.aux_mode = .FileTree
    a.focus = .Editor
    a.split = 0.5
    a.term_active = 0 // sessions are spawned lazily (term_ensure)
    a.split_anim = Anim{to = a.split} // settled at the base ratio; git mode widens it
    a.scale = 1
    a.font_px = FONT_BASE_PX
    cwd, err := os.get_working_directory(context.allocator) // owned; the launch cwd
    a.project_root = err == nil ? cwd : strings.clone(".")
    cl_init(&a.cl)
}

// Font zoom: grow/shrink the logical text size in whole points (dir is +1 / -1),
// clamped to the legible range. Every pane reads the same atlas, so one step here
// rescales all of them; the main loop re-bakes when font_px changes.
font_zoom :: proc(a: ^App, dir: int) {
    font_set_px(a, a.font_px + f32(dir) * FONT_PX_STEP)
}

font_zoom_reset :: proc(a: ^App) {
    font_set_px(a, FONT_BASE_PX)
}

// Applies a new logical size (clamped) and, when it actually changed, arms the
// debounced config save FONT_SAVE_DELAY out — each further change pushes it back, so
// only the size you settle on is written.
@(private = "file")
font_set_px :: proc(a: ^App, px: f32) {
    next := clampf(px, FONT_PX_MIN, FONT_PX_MAX)
    if next == a.font_px {
        return
    }
    a.font_px = next
    a.font_save_at = glfw.GetTime() + FONT_SAVE_DELAY
}

// Text size relative to the default. Text-proportional chrome (the command-line
// strip) scales by this so it keeps pace with the font, while DPI-only paddings
// (focus rings, gutters) stay put.
font_zoom_ratio :: proc(a: ^App) -> f32 {
    return a.font_px / FONT_BASE_PX
}

// Frees the App-owned state set up here (the command line + the remembered
// clipboard copy). The editor, filetree, and config are initialised in main and
// torn down by their own defers.
app_destroy :: proc(a: ^App) {
    term_destroy_all(a) // kill child shells + join reader threads before GLFW shuts down
    cl_chain_clear(a) // frees any pending chain (incl. its backing array)
    cl_destroy(a)
    delete(a.project_root)
    delete(a.theme_path)
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
}
