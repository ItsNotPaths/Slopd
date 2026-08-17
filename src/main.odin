package main

import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"
import "perf"
import "system"
import "wake"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Slopd"
APP_ID :: "slopd" // Wayland app-id / X11 instance name

GL_MAJOR :: 3
GL_MINOR :: 3

main :: proc() {
    // The headless CLI, handled before a window opens and before the `--<path>` launch
    // argument below is read, so a flag is never mistaken for a folder to open.
    if about_cli(os.args[1:]) ||
       grammar_cli(os.args[1:]) ||
       install_cli(os.args[1:]) ||
       desktop_cli(os.args[1:]) ||
       system.sysbus_cli(os.args[1:]) {
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

    // The window's identity to the desktop, and what a window manager matches rules on. GLFW
    // leaves all three empty unless set here, and an empty app-id is invisible to a rule.
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

    // --util     launch into Full on the aux pane, so the filetree fills the window
    // --perflog  append a per-second frame-timing line to perf.log
    // --<path>   a directory becomes the workspace, a file opens with its folder as one.
    //            Read here, applied below once the panes it loads into exist.
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
    app.theme_path = strings.clone(cfg.theme_path) // the raw value, for the settings pane
    app.indent = cfg.indent
    app.line_numbers = cfg.line_numbers
    app.scroll_mode = cfg.scroll_mode
    app.jump_lines = cfg.jump_lines
    app.show_whitespace = cfg.show_whitespace
    app.show_guides = cfg.show_guides
    app.folding = cfg.folding
    app.folder_cd_run = cfg.folder_cd_run
    app.git_tool = strings.clone(cfg.git_tool) // owned: the Config pane can rewrite it
    app.exclude = strings.clone(cfg.exclude) // likewise
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
    app.font_px = cfg.font_px // text_init bakes the atlas at it
    app.binds, app.bind_errors = load_binds()
    binds_pane_init(&app.binds_pane, app.binds[:], app.bind_errors)

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
    filebrowser_init(&app.filebrowser) // reads the config's [places] block
    defer filebrowser_destroy(&app.filebrowser)
    app.grammars = load_grammars() // shared by the config pane and the highlighter
    defer grammars_destroy(app.grammars)
    app.gram_ext = grammar_ext_index(app.grammars)
    defer delete(app.gram_ext) // borrowed keys/values, freed with the registry
    config_pane_init(&app.config_pane, app.grammars)
    defer config_pane_destroy(&app.config_pane)
    highlighter_init(&app.hl)
    defer highlighter_destroy(&app.hl)

    // Now that the editor and the file panes it moves are up. Before --util, because opening a
    // file focuses the main pane and --util asked for the aux one.
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

    // The atlas bakes at physical pixels. Text.ttf BORROWS these bytes for the program's life,
    // re-baking from them on a zoom or DPI change.
    ttf, ttf_owned := choose_font()
    defer if ttf_owned {
        delete(ttf)
    }
    text: Text
    if !text_init(&text, ttf, app.font_px, app.scale) {
        fmt.eprintln("text_init failed (font/shader)")
        return
    }

    // At the real framebuffer size, so the first frame is correctly dimensioned. Clay
    // allocates nothing beyond its static arena and touches no GL.
    fb_w, fb_h := glfw.GetFramebufferSize(window)
    if !clay_init(fb_w, fb_h) {
        return // clay_init reported why
    }
    // By pointer, so a re-baked atlas is picked up without re-registering.
    clay_use_font(&text.font)

    // No-op unless --perflog. Needs the GL context for its timer queries.
    plog: perf.Perf
    perf.init(&plog, perflog, data_asset("perf.log", context.temp_allocator))
    defer perf.destroy(&plog)

    // The window owns the App so the "c" key callback can reach it.
    app.window = window
    glfw.SetWindowUserPointer(window, &app)
    glfw.SetKeyCallback(window, key_callback)
    glfw.SetCharCallback(window, char_callback)
    // Always registered: the `mouse` config gates what the events DO, not whether they
    // arrive, so toggling it takes effect without a restart.
    glfw.SetCursorPosCallback(window, cursor_pos_callback)
    glfw.SetMouseButtonCallback(window, mouse_button_callback)
    glfw.SetScrollCallback(window, scroll_callback)
    // These carry nothing the frame below does not re-read for itself, so they exist only to
    // mark the wait gate — without them a resize would sit unpainted until the next blink.
    glfw.SetWindowRefreshCallback(window, window_event_callback)
    glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
    glfw.SetWindowContentScaleCallback(window, content_scale_callback)
    glfw.SetWindowFocusCallback(window, window_focus_callback)

    // Render first, then wait for the next thing worth drawing — an event or a deadline, never
    // the display server's chatter (see the gate at the foot of the loop).
    for !glfw.WindowShouldClose(window) {
        // Nothing temp escapes into App state, so one free_all per frame keeps it bounded.
        free_all(context.temp_allocator)

        // Each session's buffered PTY output into the parser, before drawing.
        for term in app.terminals {
            terminal_drain(term)
        }
        cl_chain_pump(&app) // advance a pending && chain once its exit code arrives

        now := glfw.GetTime()
        view_poll_disk(&app, now) // re-read an externally-changed file
        cl_preview_sync(&app, now) // after the reload: a changed file invalidates what a
        // preview found in it
        w, h := glfw.GetFramebufferSize(window)
        // Re-bake the atlas if the DPI scale or the font zoom changed. text_apply no-ops
        // otherwise.
        if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
            app.scale = sx
        }
        if text_apply(&text, app.font_px, app.scale) {
            clay_font_changed() // every cached width is stale at the new cell size
        }

        // Here rather than in the callbacks, so there is one writer and no sequence of events
        // can strand a hidden cursor.
        mouse_apply_cursor(&app)

        // cpu = vertex assembly, gpu = a timer query around the draws, swap = the vsync block.
        // perf.frame reads back the previous frame's gpu timer. No-ops unless --perflog.
        build_start := glfw.GetTime()
        perf.gpu_begin(&plog)
        render(&app, &text, w, h, now)
        perf.gpu_end(&plog)
        cpu_ms := f32((glfw.GetTime() - build_start) * 1000)

        swap_start := glfw.GetTime()
        glfw.SwapBuffers(window)
        swap_ms := f32((glfw.GetTime() - swap_start) * 1000)
        perf.frame(&plog, glfw.GetTime(), cpu_ms, swap_ms, w, h, text.frame_verts, app.last_input_at)

        // Once the size has sat unchanged for FONT_SAVE_DELAY, write it and disarm.
        if app.font_save_at > 0 && now >= app.font_save_at {
            config_set("font_size", fmt.tprintf("%d", int(app.font_px)))
            app.font_save_at = 0
        }

        // Spin at the frame budget while something animates, else block until the next event.
        // GATED, because a wait returns for reasons that are not news: the display server's
        // per-frame traffic wakes GLFW every time we present, and drawing for that presents
        // again. A frame is earned by a marked event or by the deadline actually coming due;
        // the close box is the third way out, and it sets no mark.
        for !glfw.WindowShouldClose(window) {
            // Before the wait as well as after: a reader thread can mark while the frame above
            // is still drawing, leaving only its PostEmptyEvent to end a deadline-less wait.
            if wake.take() {
                break
            }
            timeout := app_next_wake(&app, glfw.GetTime())
            if timeout < 0 {
                glfw.WaitEvents()
                continue
            }
            deadline := glfw.GetTime() + timeout
            glfw.WaitEventsTimeout(timeout)
            // WAKE_SLACK absorbs the wait returning early (ppoll rounds to the timer's
            // granularity); without it the deadline needs a second, tiny wait.
            if glfw.GetTime() >= deadline - WAKE_SLACK {
                break
            }
        }
    }
}

// How early a timed wait may return and still count as reaching its deadline.
WAKE_SLACK :: 0.001

// Who paces a frame: the swap, or the wait.
//
// X11 leaves it with the swap — SwapInterval(1) blocks until the next refresh, which is the
// pacer an animation wants, so frame_budget stays 0.
//
// Wayland must not let the swap block. A Wayland swap waits on the compositor's frame callback,
// which stops arriving the instant the window is off-screen. That wait sits inside Mesa's
// private event queue, which does not dispatch xdg_wm_base.ping, so a hidden window stops
// answering pings and is reported as not responding. SwapInterval(0) hands pacing to the wait,
// which always returns to the event loop and so always pongs.
window_pacing_init :: proc() {
    if glfw.GetPlatform() != glfw.PLATFORM_WAYLAND {
        glfw.SwapInterval(1)
        return
    }
    glfw.SwapInterval(0)
    hz := 60.0 // the fallback if the mode is unreadable
    if mon := glfw.GetPrimaryMonitor(); mon != nil {
        if mode := glfw.GetVideoMode(mon); mode != nil && mode.refresh_rate > 0 {
            hz = f64(mode.refresh_rate)
        }
    }
    // Just under one refresh period: a whole one drifts in and out of phase with the
    // compositor, which reads as a duplicated frame mid-scroll.
    frame_budget = 0.9 / hz
}

// All handled the same way: mark the gate and let the next frame re-read the state itself.
@(private = "file")
window_event_callback :: proc "c" (window: glfw.WindowHandle) {
    wake.mark()
}

@(private = "file")
framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    wake.mark()
}

@(private = "file")
content_scale_callback :: proc "c" (window: glfw.WindowHandle, xscale, yscale: f32) {
    wake.mark()
}

@(private = "file")
window_focus_callback :: proc "c" (window: glfw.WindowHandle, focused: i32) {
    wake.mark()
}
