package main

import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Slopd"

GL_MAJOR :: 3
GL_MINOR :: 3

main :: proc() {
    // Grammar CLI (`slopd --health [lang]`, `slopd --grammar <action> <lang>`) runs
    // headless — handle it before opening a window, then exit.
    if grammar_cli(os.args[1:]) {
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

    window := glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
    if window == nil {
        desc, code := glfw.GetError()
        fmt.eprintfln("glfw.CreateWindow failed (%d): %s", code, desc)
        return
    }
    defer glfw.DestroyWindow(window)

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(1)
    gl.load_up_to(GL_MAJOR, GL_MINOR, glfw.gl_set_proc_address)

    app: App
    app_init(&app)
    defer app_destroy(&app)

    // --util: launch into Full (full-window swap) mode on the aux pane, so the filetree fills
    // the window; the editor is still reachable via Alt+E.
    // --perflog: append a per-second frame-timing line to perf.log (off otherwise).
    perflog := false
    for arg in os.args[1:] {
        if arg == "--util" {
            app.view = .Full
            app.focus = .Aux
        }
        if arg == "--perflog" {
            perflog = true
        }
    }

    cfg := load_config()
    defer config_destroy(&cfg)
    app.theme = load_theme(theme_resolve(cfg.theme_path))
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
    app.grep_pane_always = cfg.grep_pane_always
    app.conflict_prompt = cfg.conflict_prompt
    app.mouse_on = cfg.mouse
    app.hover_on = cfg.hover
    app.font_px = cfg.font_px // persisted font zoom; text_init bakes the atlas at it

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
    app.grammars = load_grammars() // shared by the config pane + the highlighter
    defer grammars_destroy(app.grammars)
    config_pane_init(&app.config_pane, app.grammars)
    defer config_pane_destroy(&app.config_pane)
    highlighter_init(&app.hl)
    defer highlighter_destroy(&app.hl)
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

    // Render first, then block until the next event. The UI only redraws when
    // something actually changes, so it idles at 0% CPU.
    for !glfw.WindowShouldClose(window) {
        // Reclaim last frame's scratch — both render and the event callbacks that
        // ran during WaitEvents allocate from the temp arena, and nothing temp
        // escapes into App state, so one free_all per frame keeps it bounded.
        free_all(context.temp_allocator)

        // Drain each session's PTY output (buffered by its reader thread) into the
        // parser before drawing. The reader's PostEmptyEvent is what woke us.
        for term in app.terminals {
            terminal_drain(term)
        }
        cl_chain_pump(&app) // advance a pending && chain once its exit code arrives

        now := glfw.GetTime()
        view_poll_disk(&app, now) // re-read an externally-changed file into the focused view pane
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

        // Adaptive wait: spin at vsync while something animates, otherwise block
        // until the next event (0% idle). An external glfw.PostEmptyEvent — e.g. a
        // future terminal's PTY reader thread — unblocks either wait.
        if wake := app_next_wake(&app, now); wake >= 0 {
            glfw.WaitEventsTimeout(wake)
        } else {
            glfw.WaitEvents()
        }
    }
}
