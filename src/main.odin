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

    // --util: launch with no editor, the aux pane filling the window (the mode an
    // xdg-portal file picker would start in). Focus is pinned to the aux pane.
    for arg in os.args[1:] {
        if arg == "--util" {
            app.view = .Util
            app.focus = .Aux
        }
    }

    cfg := load_config()
    defer config_destroy(&cfg)
    app.theme = load_theme(theme_resolve(cfg.theme_path))
    app.theme_path = strings.clone(cfg.theme_path) // the raw config value, for the settings pane
    app.indent = cfg.indent
    app.line_numbers = cfg.line_numbers
    app.jump_lines = cfg.jump_lines
    app.show_whitespace = cfg.show_whitespace
    app.show_guides = cfg.show_guides
    app.folding = cfg.folding
    app.folder_cd_run = cfg.folder_cd_run
    app.git_checkout_run = cfg.git_checkout_run
    app.git_commit_run = cfg.git_commit_run
    app.git_merge_run = cfg.git_merge_run
    app.risky_mode = cfg.risky_mode
    app.font_px = cfg.font_px // persisted font zoom; text_init bakes the atlas at it

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
    app.grammars = load_grammars() // shared by the config pane + the highlighter
    defer grammars_destroy(app.grammars)
    config_pane_init(&app.config_pane, app.grammars)
    defer config_pane_destroy(&app.config_pane)
    git_init(&app.git)
    defer git_destroy(&app.git)
    highlighter_init(&app.hl)
    defer highlighter_destroy(&app.hl)
    if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
        app.scale = sx
    }

    // Glyph renderer. Atlas is baked at physical pixels (font_px logical * DPI
    // scale); font_px is the user's zoom level, defaulting to FONT_BASE_PX.
    text: Text
    if !text_init(&text, choose_font(), app.font_px, app.scale) {
        fmt.eprintln("text_init failed (font/shader)")
        return
    }

    // The window owns the App so the "c" key callback can reach it.
    app.window = window
    glfw.SetWindowUserPointer(window, &app)
    glfw.SetKeyCallback(window, key_callback)
    glfw.SetCharCallback(window, char_callback)

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
        git_scroll_pump(&app, now) // advance a held diff auto-scroll at its (accelerating) tick
        git_spin_pump(&app, now) // pay out the slot-machine gag once its reels settle
        w, h := glfw.GetFramebufferSize(window)
        // Track DPI, then re-bake the atlas if the DPI scale (monitor move) or the
        // font zoom (Ctrl +/-) changed since last frame. text_apply no-ops otherwise.
        if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
            app.scale = sx
        }
        text_apply(&text, app.font_px, app.scale)
        render(&app, &text, w, h, now)
        glfw.SwapBuffers(window)

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
