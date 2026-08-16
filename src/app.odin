package main

import "core:os"
import "core:strings"
import "vendor:glfw"

// Application state — the single source of truth. Everything else (layout,
// input, render) reads or mutates this. Kept flat and plain on purpose.

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Whether a point falls inside a rect — half-open on the far edges, so two rects sharing a
// boundary can never both claim the same pixel. A zero-sized rect never hits, which is what
// lets hit-testing skip a hidden-pane check: compute_layout leaves those zeroed.
rect_hit :: proc(r: Rect, x, y: i32) -> bool {
    return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// Font zoom. font_px is the logical text size in points, shared by every pane; the atlas
// bakes at font_px * DPI scale. Ctrl +/- steps it, Ctrl+0 resets. Persisting is debounced by
// FONT_SAVE_DELAY, so a burst of Ctrl+/- is one config write, not a dozen.
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
    Config,
    Grep,
}

Focus :: enum {
    Editor,
    Aux,
}

// What the MAIN (left / "document") pane shows. The left pane holds the document you opened,
// the aux pane a TOOL acting on documents — which is why media surfaces are peers of the text
// editor here rather than aux modes. Audio/Video are future variants.
MainSurface :: enum {
    Text,
    Image,
}

// How the two panes are arranged — the single stored bit the layout derives from. Split: both
// on screen. Zen: full-width editor, aux slides in only while focused. Full: one surface fills
// the window, chosen by focus. Visibility is recomputed per frame, so no hidden state to sync.
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

    // Terminal sessions (aux pane), held by POINTER so the array growing never moves a
    // Terminal out from under its reader thread (terminal.odin). Alt shows the switcher and
    // Up/Down move term_active; Alt+Ctrl / Alt+Shift are copy-cursor chords, so it hides then.
    alt_held:    bool,
    ctrl_held:   bool,
    shift_held:  bool,
    terminals:   [dynamic]^Terminal,
    term_active: int,

    // Master command line. A transient input field in the status strip; when
    // active it grabs bare keys (see input routing).
    cl_active: bool,
    cl:        CommandLine,

    // A submitted line parses into an && chain (builtins + shell steps), pumped each frame:
    // a builtin waiting on a shell step blocks on its exit code (the OSC sentinel).
    // cl_wait_seq tags each wrapped injection so its exit report can be matched back.
    cl_chain:    CLChain,
    cl_wait_seq: u64,

    // Live feedback for a builtin line as it is typed — `:j` moves the view to the target line,
    // `:f` marks every hit — with Esc putting the view back untouched. See cl_preview.odin;
    // cl_preview_on is the config toggle. `find` is the search itself, shared with the `:f`
    // builtin so a submitted line and a previewed one search the same way (find.odin).
    cl_preview:    CLPreview,
    cl_preview_on: bool,
    find:          Find,

    // The project root: the directory the `cd` builtin sets (captured by Slopd, NOT a shell
    // cd). New terminals spawn here, `tu` syncs every unlocked terminal to it, root-scoped
    // tools read it, and the idle status strip shows it. Owned; defaults to the launch cwd.
    project_root: string,

    tree:        FileTree, // filetree aux mode (initialised in main, needs IO)
    config_pane: ConfigPane, // config / syntax aux mode (initialised in main, needs IO)

    // How the filetree aux mode PRESENTS that listing (config `file_pane`): the dired-style
    // rows, or the file browser — top bar, places sidebar, list or grid. One model, two
    // declarations; `filebrowser` holds only what the listing has no concept of (history,
    // shortcuts, which view). Initialised in main: the places come off the config file.
    file_pane:   File_Pane,
    file_icons:  bool, // per-type icons in the browser; inert without the vendored icon face
    filebrowser: FileBrowser,

    // The one popup in the program (contextmenu.odin): a right-press opens a list of buttons for
    // the chords, at the pointer, above everything. Owned here rather than by a pane because it
    // outlives the frame that opened it and is meant to serve more than one of them.
    ctxmenu:     ContextMenu,

    // The main (document) pane. `main` selects the surface; `editor` holds the text
    // buffers, `media` the one image currently viewed (Image surface). Opening an image
    // file flips main to .Image; opening a text file flips it back (see open_file).
    main:            MainSurface,
    editor:          Editor, // the text buffers (main pane, Text surface)
    media:           Media, // the viewed image (main pane, Image surface); see media.odin
    disk_poll_at:    f64, // glfw time of the next view-pane staleness check (see view_poll_disk)
    conflict_prompt: bool, // disk change under unsaved edits: prompt (y/n in the CL) vs silently keep (config)
    conflict_stage:  bool, // and when it prompts: stage `:reload ` in the CL, or only mark the modeline (config)
    save_seq:        int, // names the private copy a staged `sudo cp` save reads (see save_stage_sudo)

    // Alt+Enter link jumping (link.odin). grep holds a multi-result jump-to-definition,
    // rendered by the Grep aux mode (grep_ui.odin); a single result jumps straight in the
    // editor. color holds the colour the caret was on — a state-only seam, not drawn yet.
    grep:  GrepPane,
    color: ColorPane,

    // CL `grep` behaviour (config: grep_pane). When set, a search ALWAYS opens the results
    // pane — even a lone hit lists in it rather than jumping straight into the editor. Off
    // restores the shortcut: a single hit jumps, 2+ open the pane. Default on.
    grep_pane_always: bool,

    grammars: []Grammar, // language registry (owned; loaded in main), shared by the
    // config pane (lang list) and the highlighter (ext -> grammar)
    gram_ext: map[string]string, // ext -> language name over `grammars`; borrows its strings
    hl:       Highlighter, // tree-sitter syntax highlighting (loaded grammars, cached)

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
    last_input_at: f64, // glfw time of the most recent keystroke; the perf log measures keystroke->present from it
    zen_anim:      Anim, // aux-pane reveal in Zen: 0 hidden .. 1 docked
    switcher_anim: Anim, // terminal switcher fade-in while Alt is held
    chord_anim:    Anim, // filetree chord cheat-sheet fade-in while Ctrl is held
    split_anim:    Anim, // the editor/aux split ratio, eased when Alt+[ / Alt+] adjust it

    theme:        Theme, // colour palette (loaded from config in main)
    theme_path:   string, // active theme path (owned, resolved by load_config); "" = baked-in default
    indent:       Indent, // Tab-key indentation policy (from config)
    line_numbers: Line_Numbers, // gutter style (from config)
    scroll_mode:  Scroll_Mode, // viewport policy: follow the caret / keep it middled (config)
    jump_lines:   int, // lines per Ctrl+Up/Down editor jump (from config)

    // Editor reading-aids, toggled from the Config pane (all default on): ghosted leading-space
    // dots / tab marks, indent guides + the active-scope rail, and Ctrl+Enter block folding.
    show_whitespace: bool,
    show_guides:     bool,
    folding:         bool,

    // Filetree Alt+Enter on a folder produces a `cd <path>` command line. When
    // folder_cd_run is set it executes at once; otherwise it's staged in the CL for
    // the user to review and run with Enter (the reviewable default). See cl_dispatch.
    folder_cd_run:   bool,

    // The external git tool Alt+G hands the project root to (config `git_tool`). Owned; empty
    // means none configured, and Alt+G opens a plain shell at the root instead. git_term picks
    // the hosting terminal session; 0 spawns it detached, for a GUI tool. See git_tool.odin.
    git_tool: string,
    git_term: int,

    // Which terminal session an ACTIVATED executable runs in (Enter / double click on a binary
    // or a script). A session number by term_slot's rule — never detached, since a program you
    // double-click has output you want to see. See open_or_run.
    run_term: int,

    // Which chord a focused terminal reads as COPY, and which one the shell gets (config
    // `term_ctrl_c`). The two always swap, so exactly one of them reaches the job. See
    // Term_Ctrl_C (config.odin) and term_clip_chord (input.odin).
    term_ctrl_c: Term_Ctrl_C,

    // Mouse (mouse.odin). `mouse` mirrors the GLFW pointer callbacks; `mouse_on` is the config
    // toggle. `lay` is the layout the LAST FRAME PAINTED, cached by render: pointer events
    // arrive between frames and must resolve against what is on screen. Zero rects until then.
    mouse:    Mouse,
    mouse_on: bool,
    // What the left button captured when it went down (drag.odin). Held between the
    // press and the release, so every motion in between belongs to whatever the press
    // resolved to rather than to whatever the pointer is over now.
    drag:     Drag,
    // Whether a pane tints the row under the pointer. Separate from `mouse_on` because it is
    // a taste question rather than a capability one — hover costs a repaint per motion event.
    hover_on: bool,
    lay:      Layout,

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
    case .Full:
        return {editor = a.focus == .Editor, aux = a.focus == .Aux}
    }
    return {true, true}
}

// Seconds between view-pane staleness checks while the pane is focused.
DISK_POLL_INTERVAL :: 1.0

// Re-read the focused document pane's file if it changed on disk (text reloads, an image
// re-decodes); no-op on a clean stat or an unfocused pane. Shared by the on-focus refresh and
// the periodic poll. The empty-ring guard keeps it safe on a bare App (tests skip editor_init).
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
            // On a freshly-raised conflict, stage the answer for the user to finish (y/n,
            // Enter): `:reload y` takes the disk version, `:reload n` keeps + caches, and a
            // `:w` typed over the staged line makes MY version the disk. EDGE-triggered, so it
            // isn't re-injected every poll tick; skipped if the CL is busy, and turned off
            // entirely by `conflict_stage: off` — the modeline's `!` marker still reports it.
            // A chain in flight is skipped too, and that is the sudo save: `sudo cp ... &&
            // :saved` changes the file under a still-dirty buffer BY DESIGN, and a `:reload `
            // injected into the second between the copy and the `:saved` would ask about a
            // conflict that is already being settled.
            if a.conflict_stage && !was && b.conflict && !a.cl_active && !cl_chain_busy(a) {
                cl_inject(a, ":reload ")
            }
        }
    case .Image:
        media_reload_if_changed(&a.media)
    }
}

// Periodically refresh the focused view pane so an external tool's edits flow in instead of
// being overwritten by a later save. Only ticks while the document pane holds focus (no stat
// traffic elsewhere); app_next_wake schedules the wake so the poll fires even at rest.
view_poll_disk :: proc(a: ^App, now: f64) {
    if a.focus != .Editor || now < a.disk_poll_at {
        return
    }
    a.disk_poll_at = now + DISK_POLL_INTERVAL
    view_refresh(a)
}

// The one place focus changes — honours each view's invariants. In Full, focus picks the lone
// full-window surface; in Zen it drives the aux pane's slide (revealed while it holds focus),
// so the reveal animation is re-aimed here.
set_focus :: proc(a: ^App, who: Focus) {
    a.focus = who
    if a.view == .Zen {
        now := glfw.GetTime()
        anim_start(&a.zen_anim, now, anim_value(&a.zen_anim, now), a.focus == .Aux ? 1 : 0, ZEN_DUR)
    }
    // The view pane refreshes the instant it gains focus, so an external edit (an agent
    // or another editor rewriting the open file) flows in at once rather than waiting for
    // the poll — and can't be silently overwritten by a later save.
    view_refresh(a)
}

// Toggle zen on/off (the `zen` / `zm` command line builtin). Works from any view —
// from Full it lands back in the Split-derived Zen arrangement.
view_toggle_zen :: proc(a: ^App) {
    a.view = a.view == .Zen ? .Split : .Zen
    set_focus(a, .Editor) // land in the editor so zen collapses to full-width at once
}

// Toggle full-window swap mode on/off (the `full` / `fm` command line builtin),
// keeping whichever surface is current so the toggle never loses your place.
view_toggle_full :: proc(a: ^App) {
    a.view = a.view == .Full ? .Split : .Full
    set_focus(a, a.focus)
}

// Back to the normal arrangement — both panes on screen, split by `a.split` (`normal` / `nm`).
// **The only one of the three that names an arrangement instead of toggling one**, so it is
// idempotent. Focus is KEPT, but still set through set_focus, since leaving Zen re-aims it.
view_normal :: proc(a: ^App) {
    a.view = .Split
    set_focus(a, a.focus)
}

// Escape's view action: turn Zen ON (never off), then once in Zen flip which side is shown —
// focusing the editor hides the aux pane, focusing aux slides it back in on the last mode.
// No-op under Full, where surface swapping is driven by Alt+E/T/G (and the CL), not Esc.
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
    a.split_anim = Anim{to = a.split} // settled at the base ratio; Alt+[ / Alt+] ease it
    a.mouse_on = true // config may turn it off (main); on by default
    a.hover_on = true // likewise
    a.scale = 1
    a.font_px = FONT_BASE_PX
    cwd, err := os.get_working_directory(context.allocator) // owned; the launch cwd
    a.project_root = err == nil ? cwd : strings.clone(".")
    cl_init(&a.cl)
    // No sysbus here: the D-Bus stack is parked (see the banner in src/sysbus.odin) and the
    // App owns none of it. `slopd --sysbus` is its only entry point.
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
    media_destroy(&a.media) // free the viewed image's texture + path
    cl_chain_clear(a) // frees any pending chain (incl. its backing array)
    cl_destroy(a)
    cl_preview_destroy(a) // the cursor set a live preview was holding for the restore
    find_destroy(&a.find)
    ctxmenu_destroy(a) // the popup's item list + the path it was opened on
    grep_destroy(&a.grep) // frees any stashed jump-to-definition results
    delete(a.project_root)
    delete(a.theme_path)
    delete(a.git_tool)
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
}
