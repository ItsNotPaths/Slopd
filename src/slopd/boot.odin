package main

import "core:strings"
import "../edit"
import "../pty"
import "../syntax"

// Everything a running Slopd needs that is NOT a backend: the config applied, the binds and
// macros loaded, the panes and the grammar registry up. A window and a terminal session start
// from the same state, so this is the one place that state is built.
//
// What stays with each front-end is what only it can answer: its own size, its own backend, and
// how it waits for the next frame.
//
// The config is returned rather than kept on the App because the Config pane edits the FILE and
// re-reads it; App holds the applied values, not the parse.

app_boot :: proc(a: ^App) -> Config {
    app_init(a)

    cfg := load_config()
    a.theme = theme_load(cfg.theme_path)
    a.theme_path = strings.clone(cfg.theme_path) // the raw value, for the settings pane
    a.indent = cfg.indent
    a.line_numbers = cfg.line_numbers
    a.scroll_mode = cfg.scroll_mode
    a.jump_lines = cfg.jump_lines
    a.show_whitespace = cfg.show_whitespace
    a.show_guides = cfg.show_guides
    a.folding = cfg.folding
    a.folder_cd_run = cfg.folder_cd_run
    a.discard_run = cfg.discard_run
    a.git_tool = strings.clone(cfg.git_tool) // owned: the Config pane can rewrite it
    a.exclude = strings.clone(cfg.exclude) // likewise
    a.git_term = cfg.git_term
    a.run_term = cfg.run_term
    a.grep_pane_always = cfg.grep_pane_always
    a.cl_preview_on = cfg.cl_preview
    a.conflict_prompt = cfg.conflict_prompt
    a.conflict_stage = cfg.conflict_stage
    a.mouse_on = cfg.mouse
    a.hover_on = cfg.hover
    a.file_pane = cfg.file_pane
    a.file_icons = cfg.file_icons
    a.default_display = cfg.default_display // already acted on; the pane shows and edits it
    a.filebrowser.view = cfg.file_view
    a.font_px = cfg.font_px // a pixel backend bakes its atlas at it; a grid ignores it
    a.binds, a.bind_errors = load_binds()
    a.macros, a.macro_errors = load_macros(a.binds[:]) // after them: they hold the chords
    binds_pane_init(&a.binds_pane, a.binds[:], a.bind_errors)

    edit.editor_init(&a.editor)
    filetree_init(&a.tree)
    filebrowser_init(&a.filebrowser) // reads the config's [places] block
    a.grammars = syntax.load_grammars() // shared by the config pane and the highlighter
    a.gram_ext = syntax.grammar_ext_index(a.grammars)
    config_pane_init(&a.config_pane, a.grammars)
    highlighter_init(&a.hl)
    return cfg
}

// Reverse of app_boot. Written out rather than deferred piecemeal, because the order is load
// bearing: the grammar registry outlives the two panes that borrow from it, and app_destroy is
// last because it joins the terminal reader threads.
app_shutdown :: proc(a: ^App, cfg: ^Config) {
    highlighter_destroy(&a.hl)
    config_pane_destroy(&a.config_pane)
    delete(a.gram_ext) // borrowed keys/values, freed with the registry below
    syntax.grammars_destroy(a.grammars)
    filebrowser_destroy(&a.filebrowser)
    filetree_destroy(&a.tree)
    edit.editor_destroy(&a.editor)
    config_destroy(cfg)
    app_destroy(a)
}

// What every front-end does before it draws, whichever surface it draws onto. Skipping any of it
// does not just lose a feature: app_next_wake schedules against disk_poll_at, so a loop that
// never polls the disk asks to be woken immediately, forever.
app_poll :: proc(a: ^App, now: f64) {
    for term in a.terminals {
        pty.terminal_drain(term) // each session's buffered PTY output into the parser
    }
    cl_chain_pump(a) // advance a pending && chain once its exit code arrives
    view_poll_disk(a, now) // re-read an externally-changed file
    grep_poll(a) // a finished project search into the pane
    cl_preview_sync(a, now) // after the reload: a changed file invalidates what a preview found
}

// The launch flags every front-end reads the same way.
//
//   --util     launch into Full on the aux pane, so the filetree fills the surface
//   --perflog  append a per-second frame-timing line to perf.log
//   --<path>   a directory becomes the workspace, a file opens with its folder as one
//
// The path case is a CATCH-ALL, so every other flag has to be named above it or it is read as a
// folder to open.
Launch_Args :: struct {
    path:    string, // "" for none
    util:    bool,
    perflog: bool,
}

parse_launch_args :: proc(args: []string) -> (out: Launch_Args) {
    for arg in args {
        switch {
        case arg == "--util":
            out.util = true
        case arg == "--perflog":
            out.perflog = true
        case arg == "--tui", arg == "--gfx": // front-end selectors, not paths
        case strings.has_prefix(arg, "--cell-dump"): // handled by cell_dump_cli
        case len(arg) > 2 && strings.has_prefix(arg, "--"):
            out.path = arg[2:]
        }
    }
    return
}

// Which front-end this run gets. `--tui` and `--gfx` name one; with neither, the config's
// `default_display` decides. A flag wins wherever both appear, and the LAST flag wins, so a
// wrapper script's default can be overridden on the command line.
//
// The config is parsed a second time here: the choice is made before app_boot runs, and before
// anything a front-end owns exists to hold the answer.
display_choose :: proc(args: []string) -> Display {
    cfg := load_config()
    defer config_destroy(&cfg)
    out := cfg.default_display
    for arg in args {
        switch arg {
        case "--tui": out = .Tui
        case "--gfx": out = .Gfx
        }
    }
    return out
}

// After the backend is up, because a launch path may be an image and the decode hands its pixels
// straight to it. Before --util, because opening a file focuses the main pane and --util asked
// for the aux one.
app_launch :: proc(a: ^App, args: Launch_Args) -> (ok: bool) {
    ok = true
    if args.path != "" && !cl_launch_path(a, args.path) {
        ok = false
    }
    if args.util {
        a.view = .Full
        a.focus = .Aux
    }
    return
}
