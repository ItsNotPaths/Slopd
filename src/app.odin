package main

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
}

Focus :: enum {
    Editor,
    Aux,
}

App :: struct {
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

    tree:   FileTree, // filetree aux mode (initialised in main, needs IO)
    editor: Editor, // the text buffers (left pane)

    theme:        Theme, // colour palette (loaded from config in main)
    indent:       Indent, // Tab-key indentation policy (from config)
    line_numbers: Line_Numbers, // gutter style (from config)
    scale:        f32, // DPI content scale: logical px * scale = physical px
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
