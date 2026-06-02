package main

import "vendor:glfw"

// Application state — the single source of truth. Everything else (layout,
// input, render) reads or mutates this. Kept flat and plain on purpose.

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

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

    // Terminal-session overlay (aux pane, terminal mode only). The session list
    // is hidden until Alt is held, then Up/Down move the selection.
    alt_held:    bool,
    term_count:  int,
    term_active: int,

    // Master command line. A transient input field in the status strip; when
    // active it grabs bare keys (see input routing).
    cl_active: bool,
    cl:        CommandLine,

    tree:        FileTree, // filetree aux mode (initialised in main, needs IO)
    config_pane: ConfigPane, // config / syntax aux mode (initialised in main, needs IO)
    editor:      Editor, // the text buffers (left pane)

    // Multi-cursor drop chord (no mode/toggle): Alt+A held + a direction drops a
    // cursor and steps that way, so holding Alt+A and tapping arrows lays a trail.
    // a_held tracks A the way alt_held tracks Alt. Esc collapses back to one.
    a_held: bool,

    // One-shot "move all cursors" prefix: tap Alt+M, then the next motion moves
    // every cursor (with Ctrl/Shift) instead of just the free caret, and it clears.
    move_all_armed: bool,

    theme:        Theme, // colour palette (loaded from config in main)
    theme_path:   string, // active theme path (owned, resolved by load_config); "" = baked-in default
    indent:       Indent, // Tab-key indentation policy (from config)
    line_numbers: Line_Numbers, // gutter style (from config)
    scale:        f32, // DPI content scale: logical px * scale = physical px

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
    if a.focus == .Aux && a.aux_mode == .Config && a.config_pane.editing {
        return &a.config_pane.edit
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
// to focus, so focus is pinned to the aux pane there.
set_focus :: proc(a: ^App, who: Focus) {
    a.focus = a.view == .Util ? .Aux : who
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

app_init :: proc(a: ^App) {
    a.aux_mode = .FileTree
    a.focus = .Editor
    a.split = 0.5
    a.term_count = 3
    a.term_active = 0
    a.scale = 1
    cl_init(&a.cl)
}

// Frees the App-owned state set up here (the command line + the remembered
// clipboard copy). The editor, filetree, and config are initialised in main and
// torn down by their own defers.
app_destroy :: proc(a: ^App) {
    cl_destroy(a)
    delete(a.theme_path)
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
}
