package main

import "core:os"
import "core:strings"
import "vendor:glfw"

// Application state — the single source of truth. Flat and plain on purpose.

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Half-open on the far edges, so two rects sharing a boundary never both claim a pixel. A
// zero-sized rect never hits, so hit-testing needs no hidden-pane check.
rect_hit :: proc(r: Rect, x, y: i32) -> bool {
    return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// font_px is the logical text size, shared by every pane; the atlas bakes at font_px * scale.
// Persisting is debounced so a burst of Ctrl+/- is one config write.
FONT_BASE_PX :: 15
FONT_PX_MIN :: 8
FONT_PX_MAX :: 40
FONT_PX_STEP :: 1
FONT_SAVE_DELAY :: 5.0 // seconds unchanged before it persists

// The aux (right) pane's modes. The command line is not one — it lives in the status strip.
AuxMode :: enum {
    FileTree,
    Terminal,
    Config,
    Grep,
    Binds,
    Color,
}

Focus :: enum {
    Editor,
    Aux,
}

// The left pane holds the document, the aux pane a tool acting on documents — which is why
// media surfaces are peers of the text editor here rather than aux modes.
MainSurface :: enum {
    Text,
    Image,
}

// Split: both on screen. Zen: full-width editor, aux slides in while focused. Full: one surface
// fills the window, chosen by focus. Visibility is recomputed per frame.
View :: enum {
    Split,
    Zen,
    Full,
}

Pane_Vis :: struct {
    editor, aux: bool,
}

App :: struct {
    view:     View, // pane arrangement (Split / Zen / Full)
    aux_mode: AuxMode,
    focus:    Focus,
    split:    f32, // editor width as a fraction of the window (0..1)

    // Held by pointer so growing the array never moves a Terminal out from under its reader
    // thread. Alt shows the switcher; Alt+Ctrl / Alt+Shift are copy-cursor chords, so it hides.
    alt_held:    bool,
    ctrl_held:   bool,
    shift_held:  bool,
    terminals:   [dynamic]^Terminal,
    term_active: int,

    // A transient input field in the status strip; active, it grabs bare keys.
    cl_active: bool,
    cl:        CommandLine,

    // A submitted line parses into an && chain, pumped each frame. cl_wait_seq tags each
    // wrapped injection so its exit report matches back.
    cl_chain:    CLChain,
    cl_wait_seq: u64,

    // Live feedback for a builtin line as it is typed, with Esc putting it all back
    // (cl_preview.odin); cl_preview_on is the config toggle. `find` is the search itself, shared
    // with the `:f` builtin so a submitted and a previewed line search alike.
    cl_preview:    CLPreview,
    cl_preview_on: bool,
    find:          Find,

    // What the `:cd` builtin sets — Slopd's own, not a shell cd. New terminals spawn here and
    // `:tu` syncs the unlocked ones. Owned; defaults to the launch cwd.
    project_root: string,

    tree:        FileTree, // initialised in main, needs IO
    config_pane: ConfigPane, // initialised in main, needs IO
    binds_pane:  BindsPane, // holds its own copy of the key table until you save it

    // How the filetree aux mode presents that listing (config `file_pane`). One model, two
    // declarations; `filebrowser` holds only what the listing has no concept of. Its places come
    // off the config file, so it is initialised in main.
    file_pane:   File_Pane,
    file_icons:  bool, // inert without the vendored icon face
    filebrowser: FileBrowser,

    // Alt+P: the file pane's top bar as a `WORKSPACE/` line — the unsaved ring until you type,
    // a fuzzy match over the project's files once you do. Covers the listing (wsfind.odin).
    wsfind:      WS_Find,

    // The one popup in the program (contextmenu.odin). Owned here rather than by a pane: it
    // outlives the frame that opened it and serves more than one.
    ctxmenu:     ContextMenu,

    // `main` selects the surface. Opening an image flips it to .Image, a text file back.
    main:            MainSurface,
    editor:          Editor,
    media:           Media, // the viewed image (media.odin)
    disk_poll_at:    f64, // glfw time of the next staleness check (view_poll_disk)
    conflict_prompt: bool, // disk change under unsaved edits: prompt vs silently keep
    conflict_stage:  bool, // when it prompts: stage `:reload `, or only mark the modeline
    save_seq:        int, // names the private copy a staged `sudo cp` save reads

    // Alt+Enter link jumping (link.odin): grep holds a multi-result jump-to-definition, a
    // single result jumps straight. color is the picker, editing its literal in place.
    grep:  GrepPane,
    color: ColorPane,

    // config `grep_pane`. Set, a search always opens the results pane; off, a lone hit jumps
    // straight into the editor. Default on.
    grep_pane_always: bool,

    // The project search runs off the main thread (grep_worker.odin). grep_seq tickets each
    // request, so an answer to a query already typed past is dropped.
    grep_worker: Grep_Worker,
    grep_seq:    u64, // the newest request
    grep_seen:   u64, // the newest answer applied; behind grep_seq while a search is out

    grammars: []Grammar, // language registry (owned; loaded in main)
    gram_ext: map[string]string, // ext -> language name over `grammars`; borrows its strings
    hl:       Highlighter,

    // BIND_DEFAULTS with the config's `[binds]` block over it, plus every line that block got
    // wrong. Errors show on the config pane's bindings row and block a write-back.
    binds:       [dynamic]Bind,
    bind_errors: []Bind_Error,

    // The `[macros]` block: a chord and the command line it fires. Its own errors, shown on the
    // config pane's macros row, because they block a `:macro` edit rather than a bind one.
    macros:       [dynamic]Macro,
    macro_errors: []Bind_Error,

    // Alt+A held + a direction drops a cursor and steps that way, laying a trail. Esc
    // collapses back to one.
    a_held: bool,

    // Tap Alt+M and the next motion moves every cursor rather than the free caret, then clears.
    move_all_armed: bool,

    // For the redraw scheduler (anim.odin).
    blink_base:    f64, // the last-input time the caret blink is measured from
    last_input_at: f64, // most recent keystroke; the perf log measures keystroke->present from it
    zen_anim:      Anim, // aux-pane reveal in Zen: 0 hidden .. 1 docked
    switcher_anim: Anim, // terminal switcher fade-in while Alt is held
    chord_anim:    Anim, // filetree chord cheat-sheet fade-in while Ctrl is held
    split_anim:    Anim, // the split ratio, eased when Alt+[ / Alt+] adjust it

    theme:        Theme,
    theme_path:   string, // owned, resolved by load_config; "" = baked-in default
    indent:       Indent,
    line_numbers: Line_Numbers,
    scroll_mode:  Scroll_Mode,
    jump_lines:   int, // lines per Ctrl+Up/Down editor jump

    // Reading aids, all default on and toggled from the Config pane.
    show_whitespace: bool,
    show_guides:     bool,
    folding:         bool,

    // Filetree Alt+Enter on a folder makes a `cd <path>` line: run it at once, or stage it in
    // the CL to review (the default). See cl_dispatch.
    folder_cd_run:   bool,
    discard_run:     bool, // the file panes' discard: run it at once vs stage `:discard`

    // Directories every project-wide tool skips (config `exclude`), comma separated. Owned;
    // split at each use by exclude_dirs (exclude.odin), where a pattern's meaning is written.
    exclude: string,

    // What Alt+G hands the project root to (config `git_tool`). Owned; empty opens a plain
    // shell at the root. git_term picks the hosting session; 0 spawns it detached.
    git_tool: string,
    git_term: int,

    // Which session an activated executable runs in. A session number by term_slot's rule,
    // never detached: a program you double-click has output you want to see.
    run_term: int,

    // `mouse` mirrors the GLFW pointer callbacks, `mouse_on` is the config toggle. `lay` is the
    // layout the LAST FRAME PAINTED: pointer events arrive between frames and must resolve
    // against what is on screen.
    mouse:    Mouse,
    mouse_on: bool,
    // What the left button captured (drag.odin): every motion until the release belongs to
    // what the press resolved to, not to whatever the pointer is over now.
    drag:     Drag,
    // Separate from `mouse_on`: a taste question, and it costs a repaint per motion event.
    hover_on: bool,
    lay:      Layout,

    scale:        f32, // logical px * scale = physical px
    font_px:      f32, // logical text size; base is FONT_BASE_PX
    font_save_at: f64, // glfw time to persist font_px at; 0 = nothing pending

    // clip_joined / clip_pieces remember our last copy, so a multi-cursor paste can distribute
    // one piece per caret while the clipboard still holds what we wrote.
    window:      glfw.WindowHandle,
    clip_joined: string,
    clip_pieces: []string,
}

// The command line when active, else the focused editor buffer. The CL is a one-line buffer,
// so motion, multi-cursor and selection serve both through this.
active_doc :: proc(a: ^App) -> ^Doc {
    if a.cl_active {
        return &a.cl.doc
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        cp := &a.config_pane
        if config_pane_is_search(cp.sel) {
            return &cp.search // the pane's only text input
        }
    }
    return &editor_current(&a.editor).doc
}

// A pure function of the view mode and focus. In Zen the aux pane is present exactly while it
// holds focus, so revealing it is a focus change and nothing else.
panes_visible :: proc(a: ^App) -> Pane_Vis {
    switch a.view {
    case .Split:
        return {editor = true, aux = true}
    case .Zen:
        return {editor = true, aux = a.focus == .Aux}
    case .Full:
        return {editor = a.focus == .Editor, aux = a.focus == .Aux}
    }
    return {true, true}
}

DISK_POLL_INTERVAL :: 1.0

// Re-read the focused document pane's file if it changed on disk. Shared by the on-focus
// refresh and the periodic poll. The empty-ring guard keeps it safe on a bare App.
view_refresh :: proc(a: ^App) {
    if a.focus != .Editor {
        return
    }
    switch a.main {
    case .Text:
        if len(a.editor.buffers) > 0 {
            b := editor_current(&a.editor)
            was := b.conflict
            buffer_reload_if_changed(b, a.conflict_prompt)
            // Stage the answer for the user to finish. Edge-triggered, so it is not
            // re-injected every poll tick. A chain in flight is skipped: that is the sudo save,
            // which changes the file under a still-dirty buffer by design.
            if a.conflict_stage && !was && b.conflict && !a.cl_active && !cl_chain_busy(a) {
                cl_inject(a, ":reload ")
            }
        }
    case .Image:
        media_reload_if_changed(&a.media)
    }
}

// So an external tool's edits flow in rather than being overwritten by a later save. Ticks only
// while the document pane holds focus; app_next_wake schedules the wake so it fires at rest.
view_poll_disk :: proc(a: ^App, now: f64) {
    if a.focus != .Editor || now < a.disk_poll_at {
        return
    }
    a.disk_poll_at = now + DISK_POLL_INTERVAL
    view_refresh(a)
}

// The one place focus changes. In Full it picks the lone surface; in Zen it drives the aux
// pane's slide, so the reveal animation is re-aimed here.
set_focus :: proc(a: ^App, who: Focus) {
    a.focus = who
    if a.view == .Zen {
        now := glfw.GetTime()
        anim_start(&a.zen_anim, now, anim_value(&a.zen_anim, now), a.focus == .Aux ? 1 : 0, ZEN_DUR)
    }
    // Refresh on gaining focus, so an external edit flows in at once rather than waiting for
    // the poll and being overwritten by a later save.
    view_refresh(a)
}

// Showing a pane you asked for and leaving the arrows elsewhere is two answers to one request.
set_aux :: proc(a: ^App, mode: AuxMode) {
    a.aux_mode = mode
    set_focus(a, .Aux)
}

clampf :: proc(v, lo, hi: f32) -> f32 {
    if v < lo {
        return lo
    }
    if v > hi {
        return hi
    }
    return v
}

// `:zen` / `:zm`. Works from any view; from Full it lands in the Split-derived arrangement.
view_toggle_zen :: proc(a: ^App) {
    a.view = a.view == .Zen ? .Split : .Zen
    set_focus(a, .Editor) // so zen collapses to full-width at once
}

// `:full` / `:fm`, keeping the current surface so the toggle never loses your place.
view_toggle_full :: proc(a: ^App) {
    a.view = a.view == .Full ? .Split : .Full
    set_focus(a, a.focus)
}

// `:normal` / `:nm`. The only one of the three that names an arrangement rather than toggling,
// so it is idempotent. Focus is kept, but still set through set_focus, which leaving Zen needs.
view_normal :: proc(a: ^App) {
    a.view = .Split
    set_focus(a, a.focus)
}

// Turn Zen on (never off), then once in Zen flip which side is shown. No-op under Full, where
// swapping is Alt+E/T/G's job.
zen_escape :: proc(a: ^App) {
    if a.view == .Full {
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
    a.split_anim = Anim{to = a.split} // settled at the base ratio
    a.mouse_on = true // config may turn it off (main)
    a.hover_on = true
    a.color.buf_idx = -1
    a.scale = 1
    a.font_px = FONT_BASE_PX
    cwd, err := os.get_working_directory(context.allocator) // owned
    a.project_root = err == nil ? cwd : strings.clone(".")
    cl_init(&a.cl)
    wsfind_init(&a.wsfind) // its file list is scanned when it opens
    grep_worker_start(&a.grep_worker)
    // No sysbus: the D-Bus stack is parked (src/system/sysbus.odin) and the App owns none of it.
}

// dir is +1 / -1, in whole points, clamped to the legible range. One atlas, so one step
// rescales every pane; the main loop re-bakes when font_px changes.
font_zoom :: proc(a: ^App, dir: int) {
    font_set_px(a, a.font_px + f32(dir) * FONT_PX_STEP)
}

font_zoom_reset :: proc(a: ^App) {
    font_set_px(a, FONT_BASE_PX)
}

// Arms the debounced config save; each further change pushes it back, so only the size you
// settle on is written.
@(private = "file")
font_set_px :: proc(a: ^App, px: f32) {
    next := clampf(px, FONT_PX_MIN, FONT_PX_MAX)
    if next == a.font_px {
        return
    }
    a.font_px = next
    a.font_save_at = glfw.GetTime() + FONT_SAVE_DELAY
}

// Text-proportional chrome scales by this to keep pace with the font; DPI-only paddings
// (focus rings, gutters) stay put.
font_zoom_ratio :: proc(a: ^App) -> f32 {
    return a.font_px / FONT_BASE_PX
}

// The editor, filetree and config are initialised in main and torn down by their own defers.
app_destroy :: proc(a: ^App) {
    term_destroy_all(a) // kill child shells and join readers before GLFW shuts down
    grep_worker_stop(&a.grep_worker)
    media_destroy(&a.media)
    cl_chain_clear(a)
    cl_destroy(a)
    cl_preview_destroy(a)
    wsfind_destroy(&a.wsfind)
    find_destroy(&a.find)
    ctxmenu_destroy(a)
    grep_destroy(&a.grep)
    delete(a.project_root)
    delete(a.theme_path)
    delete(a.git_tool)
    delete(a.exclude)
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
    delete(a.binds)
    bind_errors_destroy(a.bind_errors)
    macros_destroy(&a.macros)
    bind_errors_destroy(a.macro_errors)
    binds_pane_destroy(&a.binds_pane)
    if a.color.orig_text != "" {
        delete(a.color.orig_text)
    }
}
