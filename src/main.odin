package main

import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Slopd"
APP_ID :: "slopd" // Wayland app-id / X11 instance name — what a window rule names us by

GL_MAJOR :: 3
GL_MINOR :: 3

main :: proc() {
    // Headless CLI (`slopd --version`, `--health [lang]`, `--grammar <action> <lang>`,
    // `--install` / `--uninstall` / `--where`, `--desktop [add|remove]`, `--sysbus`) —
    // handled before opening a window, then exit. These run FIRST, before the `--<path>`
    // launch argument below is read, so a flag is never mistaken for a folder to open.
    // `--sysbus` is the parked D-Bus stack's only entry point; the editor itself never
    // touches a bus.
    if about_cli(os.args[1:]) ||
       grammar_cli(os.args[1:]) ||
       install_cli(os.args[1:]) ||
       desktop_cli(os.args[1:]) ||
       sysbus_cli(os.args[1:]) {
        return
    }

    if !glfw.Init() {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.Init failed (%d): %s", code, desc)
        return
    }
    defer glfw.Terminate()

    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true) // required on macOS

    // The window's IDENTITY to the desktop, and the one thing a window manager matches rules on:
    // app-id on Wayland, WM_CLASS on X11. GLFW leaves all three empty unless they are set here,
    // and an empty app-id is INVISIBLE to a rule — `hyprctl clients` shows a blank class, and no
    // window rule, tag or theme can ever name Slopd. APP_ID is the binary's name, which is also
    // what a slopd.desktop would be called, so a launcher can match the window to its entry.
    glfw.WindowHintString(glfw.WAYLAND_APP_ID, APP_ID)
    glfw.WindowHintString(glfw.X11_CLASS_NAME, TITLE)
    glfw.WindowHintString(glfw.X11_INSTANCE_NAME, APP_ID)

    window := glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
    if window == nil {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.CreateWindow failed (%d): %s", code, desc)
        return
    }
    defer glfw.DestroyWindow(window)

    glfw.MakeContextCurrent(window)
    gl.load_up_to(GL_MAJOR, GL_MINOR, glfw.gl_set_proc_address)
    window_pacing_init()

    app: App
    app_init(&app)
    defer app_destroy(&app)

    // --util: launch into Full (full-window swap) mode on the aux pane, so the filetree fills
    // the window; the editor is still reachable via Alt+E.
    // --perflog: append a per-second frame-timing line to perf.log (off otherwise).
    // --<path>: the launch path (`slopd --~/code/thing`, `slopd --/etc/fstab`) — a directory
    // becomes the workspace, a file opens with its folder as the workspace. Read here but
    // APPLIED below, once the panes it loads into exist.
    perflog, util := false, false
    launch: string
    for arg in os.args[1:] {
        switch {
        case arg == "--util":
            util = true
        case arg == "--perflog":
            perflog = true
        case len(arg) > 2 && strings.has_prefix(arg, "--"):
            launch = arg[2:]
        }
    }

    cfg := load_config()
    defer config_destroy(&cfg)
    app.theme = theme_load(cfg.theme_path)
    app.theme_path = strings.clone(cfg.theme_path) // the raw config value, for the settings pane
    app.indent = cfg.indent
    app.line_numbers = cfg.line_numbers
    app.scroll_mode = cfg.scroll_mode
    app.jump_lines = cfg.jump_lines
    app.show_whitespace = cfg.show_whitespace
    app.show_guides = cfg.show_guides
    app.folding = cfg.folding
    app.folder_cd_run = cfg.folder_cd_run
    app.git_tool = strings.clone(cfg.git_tool) // owned: the Config pane can rewrite it
    app.git_term = cfg.git_term
    app.run_term = cfg.run_term
    app.grep_pane_always = cfg.grep_pane_always
    app.cl_preview_on = cfg.cl_preview
    app.conflict_prompt = cfg.conflict_prompt
    app.conflict_stage = cfg.conflict_stage
    app.mouse_on = cfg.mouse
    app.hover_on = cfg.hover
    app.file_pane = cfg.file_pane
    app.file_icons = cfg.file_icons
    app.filebrowser.view = cfg.file_view
    app.font_px = cfg.font_px // persisted font zoom; text_init bakes the atlas at it
    app.binds, app.bind_errors = load_binds()
    binds_pane_init(&app.binds_pane, app.binds[:], app.bind_errors)

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
    filebrowser_init(&app.filebrowser) // reads the config's [places] block; falls back to defaults
    defer filebrowser_destroy(&app.filebrowser)
    app.grammars = load_grammars() // shared by the config pane + the highlighter
    defer grammars_destroy(app.grammars)
    app.gram_ext = grammar_ext_index(app.grammars)
    defer delete(app.gram_ext) // borrowed keys/values; freed above with the registry
    config_pane_init(&app.config_pane, app.grammars)
    defer config_pane_destroy(&app.config_pane)
    highlighter_init(&app.hl)
    defer highlighter_destroy(&app.hl)

    // The launch path, now that the editor and the file panes it moves are up. Ordered before
    // --util because opening a file focuses the main pane, and --util asked for the aux one.
    if launch != "" && !cl_launch_path(&app, launch) {
        fmt.eprintfln("slopd: no such path: %s", launch)
    }
    if util {
        app.view = .Full
        app.focus = .Aux
    }

    if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
        app.scale = sx
    }

    // Glyph renderer. The atlas bakes at physical pixels (font_px logical * DPI scale).
    // Text.ttf BORROWS these bytes for the program's life (it re-bakes from them on a
    // zoom/DPI change), so the free waits for the end and only fires for a font we read.
    ttf, ttf_owned := choose_font()
    defer if ttf_owned {
        delete(ttf)
    }
    text: Text
    if !text_init(&text, ttf, app.font_px, app.scale) {
        fmt.eprintln("text_init failed (font/shader)")
        return
    }

    // Layout engine (clay_ui.odin). Initialised at the real framebuffer size so its
    // first frame is already correctly dimensioned. It allocates nothing beyond its
    // static arena and touches no GL, so it only needs the window for that size.
    fb_w, fb_h := glfw.GetFramebufferSize(window)
    if !clay_init(fb_w, fb_h) {
        return // clay_init reported why
    }
    // Clay measures text through us (monospace: rune count * cell advance). The font is
    // passed by pointer, so a re-baked atlas is picked up without re-registering.
    clay_use_font(&text.font)

    // Frame-timing log (no-op unless --perflog was passed). Needs the GL context for its
    // timer queries, so it's set up after text_init.
    perf: Perf
    perf_init(&perf, perflog)
    defer perf_destroy(&perf)

    // The window owns the App so the "c" key callback can reach it.
    app.window = window
    glfw.SetWindowUserPointer(window, &app)
    glfw.SetKeyCallback(window, key_callback)
    glfw.SetCharCallback(window, char_callback)
    // Pointer input (mouse.odin). Always registered: the `mouse` config gates what the
    // events DO, not whether they arrive, so toggling it takes effect without a restart.
    glfw.SetCursorPosCallback(window, cursor_pos_callback)
    glfw.SetMouseButtonCallback(window, mouse_button_callback)
    glfw.SetScrollCallback(window, scroll_callback)
    // The window's own events. They carry nothing the frame below does not re-read for
    // itself (size, DPI scale, focus), so they exist only to mark the wait gate: without
    // them a resize or a compositor-requested repaint would sit unpainted until the caret's
    // next blink edge.
    glfw.SetWindowRefreshCallback(window, window_event_callback)
    glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
    glfw.SetWindowContentScaleCallback(window, content_scale_callback)
    glfw.SetWindowFocusCallback(window, window_focus_callback)

    // Render first, then wait for the next thing worth drawing — an event or a deadline,
    // never the display server's own chatter (see the gate at the foot of the loop). The UI
    // only redraws when something actually changes, so at rest it costs the caret's blink.
    for !glfw.WindowShouldClose(window) {
        // Reclaim last frame's scratch — both render and the event callbacks that
        // ran during WaitEvents allocate from the temp arena, and nothing temp
        // escapes into App state, so one free_all per frame keeps it bounded.
        free_all(context.temp_allocator)

        // Drain each session's PTY output (buffered by its reader thread) into the
        // parser before drawing. The reader's wake_post is what woke us.
        for term in app.terminals {
            terminal_drain(term)
        }
        cl_chain_pump(&app) // advance a pending && chain once its exit code arrives

        now := glfw.GetTime()
        view_poll_disk(&app, now) // re-read an externally-changed file into the focused view pane
        cl_preview_sync(&app, now) // show what a half-typed builtin line would do (after the reload: a
        // file that just changed underneath invalidates what the preview found in it)
        w, h := glfw.GetFramebufferSize(window)
        // Track DPI, then re-bake the atlas if the DPI scale (monitor move) or the
        // font zoom (Ctrl +/-) changed since last frame. text_apply no-ops otherwise.
        if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
            app.scale = sx
        }
        if text_apply(&text, app.font_px, app.scale) {
            clay_font_changed() // every cached string width is stale at the new cell size
        }

        // Show or hide the cursor to match the pointer's stood-down state (mouse.odin). Here
        // rather than in the callbacks so there is exactly one writer, and no sequence of
        // events — including turning `mouse: off` while it is hidden — can strand it.
        mouse_apply_cursor(&app)

        // Frame timing: cpu = render's vertex assembly, gpu = a timer query around its
        // draws, swap = the SwapBuffers (vsync) block. perf_frame reads back the previous
        // frame's gpu timer and logs a window once a second. All no-ops unless --perflog.
        build_start := glfw.GetTime()
        perf_gpu_begin(&perf)
        render(&app, &text, w, h, now)
        perf_gpu_end(&perf)
        cpu_ms := f32((glfw.GetTime() - build_start) * 1000)

        swap_start := glfw.GetTime()
        glfw.SwapBuffers(window)
        swap_ms := f32((glfw.GetTime() - swap_start) * 1000)
        perf_frame(&perf, glfw.GetTime(), cpu_ms, swap_ms, w, h, text.frame_verts, app.last_input_at)

        // Debounced font-zoom save: once the size has sat unchanged for FONT_SAVE_DELAY
        // (the deadline app_next_wake also wakes us for), write it to config and disarm.
        if app.font_save_at > 0 && now >= app.font_save_at {
            config_set("font_size", fmt.tprintf("%d", int(app.font_px)))
            app.font_save_at = 0
        }

        // Adaptive wait: spin at the frame budget while something animates, otherwise block
        // until the next event (0% idle). An external wake_post — a terminal's PTY reader
        // thread — unblocks either wait.
        //
        // GATED, because a wait returns for reasons that are not news: the display server's
        // own per-frame traffic (a buffer release, a delete_id) wakes GLFW every time we
        // present, and drawing a frame for that presents again, which wakes us again — a
        // loop that pins the editor at the refresh rate with nothing changing on screen.
        // A frame is earned by a marked event (wake_take) or by the scheduled deadline
        // actually coming due; anything else goes back to waiting. The close box is the
        // third way out — it sets no mark, so the loop condition has to see it.
        for !glfw.WindowShouldClose(window) {
            // Tested BEFORE the wait as well as after it: a reader thread can mark while the
            // frame above is still drawing, and its PostEmptyEvent would then be the only
            // thing standing between that mark and a wait with no deadline to end it.
            if wake_take() {
                break
            }
            wake := app_next_wake(&app, glfw.GetTime())
            if wake < 0 {
                glfw.WaitEvents()
                continue
            }
            deadline := glfw.GetTime() + wake
            glfw.WaitEventsTimeout(wake)
            // WAKE_SLACK absorbs the wait returning a hair early (ppoll rounds to the
            // timer's granularity); without it the deadline needs a second, tiny wait.
            if glfw.GetTime() >= deadline - WAKE_SLACK {
                break
            }
        }
    }
}

// How early a timed wait may return and still count as having reached its deadline.
WAKE_SLACK :: 0.001

// Who paces a frame: the swap, or the wait.
//
// X11 leaves it with the swap. SwapInterval(1) blocks in SwapBuffers until the next
// refresh, which is precisely the pacer an animation wants, so frame_budget stays 0 there:
// an animating frame asks for no sleep at all and the swap absorbs it.
//
// Wayland must not let the swap block. A Wayland swap waits on the compositor's frame
// callback, and the compositor stops sending those the instant the window is off-screen —
// another workspace, a blanked monitor, a lid closed to save battery. That wait happens
// inside Mesa's private event queue, which does not dispatch xdg_wm_base.ping, so a hidden
// window stops answering the compositor's pings and gets reported as not responding
// (Hyprland's ANR dialog) while it is in fact perfectly healthy. SwapInterval(0) keeps the
// swap non-blocking and hands pacing to the wait, which always returns to the event loop
// and so always pongs. A hidden window then just draws into a buffer nobody reads.
window_pacing_init :: proc() {
    if glfw.GetPlatform() != glfw.PLATFORM_WAYLAND {
        glfw.SwapInterval(1)
        return
    }
    glfw.SwapInterval(0)
    hz := 60.0 // the fallback if the mode is unreadable; the primary monitor stands in
    if mon := glfw.GetPrimaryMonitor(); mon != nil {
        if mode := glfw.GetVideoMode(mon); mode != nil && mode.refresh_rate > 0 {
            hz = f64(mode.refresh_rate)
        }
    }
    // Just under one refresh period. A whole one leaves the loop drifting in and out of
    // phase with the compositor, which reads as an occasional duplicated frame mid-scroll.
    frame_budget = 0.9 / hz
}

// The window's own events, all of them handled the same way: mark the gate and let the next
// frame re-read the state for itself (main() polls the framebuffer size and content scale
// every frame, and focus lives in App).
@(private = "file")
window_event_callback :: proc "c" (window: glfw.WindowHandle) {
    wake_mark()
}

@(private = "file")
framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    wake_mark()
}

@(private = "file")
content_scale_callback :: proc "c" (window: glfw.WindowHandle, xscale, yscale: f32) {
    wake_mark()
}

@(private = "file")
window_focus_callback :: proc "c" (window: glfw.WindowHandle, focused: i32) {
    wake_mark()
}
