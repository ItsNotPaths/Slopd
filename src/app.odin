package main

import "core:os"
import "core:strings"
import "vendor:glfw"

// Application state — the single source of truth. Everything else (layout,
// input, render) reads or mutates this. Kept flat and plain on purpose.

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Whether a point falls inside a rect — half-open on the far edges, so two rects sharing
// a boundary (the panes either side of the gutter, the halves either side of the
// rule) can never both claim the same pixel. A zero-sized rect never hits, which is what
// lets hit-testing skip a hidden-pane check: compute_layout leaves those zeroed.
rect_hit :: proc(r: Rect, x, y: i32) -> bool {
    return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
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
    Config,
    Grep,
}

Focus :: enum {
    Editor,
    Aux,
}

// What the MAIN (left / "document") pane shows. The left pane holds the document you
// opened — text by default, or a media viewer for an image — while the aux pane (right)
// holds a TOOL acting on documents (filetree/terminal/…). That document-vs-tool line
// is why media surfaces are peers of the text editor here, not aux modes. Text/Image are
// the v1 set; Audio/Video are future variants (each adds a draw_* / *_key branch + decode).
MainSurface :: enum {
    Text,
    Image,
}

// How the two panes are arranged — the single stored bit the layout derives from.
// Split (default): both panes always on screen. Zen: the editor gets the full
// width and the aux pane slides in only while it is focused (any goto / Alt+Right
// reveals it; focusing the editor retracts it). Full: one surface — the editor or
// the aux pane — fills the whole window, chosen by focus; Alt+E / Alt+T / Alt+G /
// … (or the `full`/`fm` builtin) swap which surface is up. `--util` launches into
// Full on the filetree. Visibility is recomputed every frame from this + focus, so
// there is no separate hidden/popped state to keep in sync.
//
// The command line reaches all three: `zen`/`zm` and `full`/`fm` TOGGLE their own mode,
// while `normal`/`nm` names Split outright — the way back that does not depend on
// remembering which mode you are in (see view_normal).
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
    // every unlocked terminal to it, root-scoped tools read it, and the idle status
    // strip shows it. Owned; defaults to the launch cwd.
    project_root: string,

    tree:        FileTree, // filetree aux mode (initialised in main, needs IO)
    config_pane: ConfigPane, // config / syntax aux mode (initialised in main, needs IO)
    procmon:     ProcmonPane, // procmon aux mode (btop-lite; sampler thread, initialised in main)

    // The main (document) pane. `main` selects the surface; `editor` holds the text
    // buffers, `media` the one image currently viewed (Image surface). Opening an image
    // file flips main to .Image; opening a text file flips it back (see open_file).
    main:            MainSurface,
    editor:          Editor, // the text buffers (main pane, Text surface)
    media:           Media, // the viewed image (main pane, Image surface); see media.odin
    disk_poll_at:    f64, // glfw time of the next view-pane staleness check (see view_poll_disk)
    conflict_prompt: bool, // disk change under unsaved edits: prompt (y/n in the CL) vs silently keep (config)

    // Alt+Enter link jumping (link.odin). grep holds a multi-result jump-to-definition for
    // a future results pane to render (single results jump straight in the editor); color
    // holds the colour the caret was on for the stubbed colour editor. Both are state-only
    // seams — neither pane is wired/drawn yet.
    grep:  GrepPane,
    color: ColorPane,

    // CL `grep` behaviour (config: grep_pane). When set, a search ALWAYS opens the results
    // pane — even a lone hit lists in it rather than jumping straight into the editor. Off
    // restores the shortcut: a single hit jumps, 2+ open the pane. Default on.
    grep_pane_always: bool,

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

    // The external git tool Alt+G hands the project root to (`git_tool` in the config
    // file). Owned; empty means "no tool configured", and Alt+G opens a plain shell at
    // the root instead — you already have a git workflow, this just gets out of its way.
    // git_term picks which terminal session hosts it; 0 spawns it detached, for a GUI
    // tool that wants its own window. See git_tool.odin.
    git_tool: string,
    git_term: int,

    // Procmon `k`: when on (default) a kill arms a one-key confirm row first; off kills
    // (SIGKILL) immediately.
    kill_confirm: bool,

    // Mouse (mouse.odin). `mouse` mirrors the GLFW pointer callbacks; `mouse_on` is the
    // config toggle. `lay` is the layout the LAST FRAME PAINTED — cached by render because
    // pointer events arrive between frames and must resolve against what is on screen, not
    // against a layout recomputed mid-animation. Zero until the first frame, and a zero
    // Layout is all zero rects, so hit-testing before then simply finds nothing.
    mouse:    Mouse,
    mouse_on: bool,
    // What the left button captured when it went down (drag.odin, C7c). Held between the
    // press and the release, so every motion in between belongs to whatever the press
    // resolved to rather than to whatever the pointer is over now.
    drag:     Drag,
    // Whether a pane tints the row under the pointer. Separate from `mouse_on` because it
    // is a taste question, not a capability one: hover costs a repaint per motion event and
    // the editor is keyboard-first, so it is worth being able to keep the pointer working
    // while the chrome stays still. Every list pane reads this one flag (see config_ui).
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

// Re-read the focused document pane's file if it changed on disk: the active text buffer
// reloads (buffer_reload_if_changed), an image re-decodes (media_reload_if_changed). Both
// no-op when nothing changed (a clean stat) or the pane isn't focused. Shared by the
// on-focus refresh (set_focus) and the periodic poll. The empty-ring guard keeps it safe
// on a bare App (the view-arrangement tests never call editor_init).
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
            // On a freshly-raised conflict, stage the answer command in the command line
            // for the user to finish (type y/n, Enter): `reload y` takes the disk version,
            // `reload n` keeps + caches. Edge-triggered (only on the false->true transition)
            // so it isn't re-injected every poll tick; skipped if the CL is already busy.
            if !was && b.conflict && !a.cl_active {
                cl_inject(a, "reload ")
            }
        }
    case .Image:
        media_reload_if_changed(&a.media)
    }
}

// Periodically refresh the focused view pane so edits made by an external tool (an agent,
// another editor) flow in instead of being overwritten by a later save. Only ticks while
// the document pane holds focus (no stat traffic off in a terminal or a tool pane);
// switching INTO the pane refreshes it immediately via set_focus, this catches changes
// that land while you sit in it. Called once per frame; app_next_wake schedules the wake
// so the poll fires even at rest.
view_poll_disk :: proc(a: ^App, now: f64) {
    if a.focus != .Editor || now < a.disk_poll_at {
        return
    }
    a.disk_poll_at = now + DISK_POLL_INTERVAL
    view_refresh(a)
}

// The one place focus changes — honours each view's invariants. In Full, focus picks
// the lone full-window surface (editor or aux), so revealing the editor is a normal
// focus change. In Zen, focus drives the aux pane's slide (revealed while it holds
// focus), so re-aim the reveal animation here.
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
    // Procmon only samples /proc while its pane is on screen, so the loop returns to
    // 0% idle otherwise. In Split both panes are always visible (so it keeps updating
    // even when the editor holds focus); in Zen it shows only while focused.
    a.procmon.wanted = a.aux_mode == .Procmon && panes_visible(a).aux
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

// Back to the normal arrangement — both panes on screen, split by `a.split` (the `normal` /
// `nm` command line builtin).
//
// **The only one of the three that names an arrangement instead of toggling one**, which is
// why it is worth having at all. `zen` and `full` each flip their own bit, so getting back to
// Split means remembering which mode you are actually in: `zen` from Full lands in Zen, not
// Split, and `full` from Zen lands in Full. `nm` is the one that always means what it says,
// from any view, and it is idempotent.
//
// Focus is KEPT rather than forced to the editor, unlike view_toggle_zen's exit: in Split both
// panes are on screen whichever one holds the arrows, so there is nothing an arrangement
// change has to resolve. set_focus is still the way it lands, because leaving Zen has to
// re-aim that view's reveal and re-ask whether procmon is on screen — both of which Split
// answers differently and neither of which is this proc's business to know.
view_normal :: proc(a: ^App) {
    a.view = .Split
    set_focus(a, a.focus)
}

// Escape's view action: turn Zen ON (never off), then once in Zen flip which side is
// shown. Focusing the editor hides the aux pane (full-width editor); focusing the aux
// pane slides it back in on whatever mode was last there (a.aux_mode persists). No-op
// under Full, where surface swapping is driven by Alt+E/T/G (and the CL), not Esc.
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
    grep_destroy(&a.grep) // frees any stashed jump-to-definition results
    delete(a.project_root)
    delete(a.theme_path)
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
}
