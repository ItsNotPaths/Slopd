package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "Slopd"

GL_MAJOR :: 3
GL_MINOR :: 3

// The theme file to actually load: the config's value if set, else a themes/default.theme
// shipped beside the binary (asset_dir, same exe-relative rule as grammars/), else ""
// for the baked-in default. Result is temp-allocated.
theme_load_path :: proc(configured: string) -> string {
    if configured != "" {
        return configured
    }
    cand := filepath.join({asset_dir("themes", context.temp_allocator), "default.theme"}, context.temp_allocator) or_else ""
    return os.exists(cand) ? cand : ""
}

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
    app.theme = load_theme(theme_load_path(cfg.theme_path))
    app.theme_path = strings.clone(cfg.theme_path) // the raw config value, for the settings pane
    app.indent = cfg.indent
    app.line_numbers = cfg.line_numbers

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
    config_pane_init(&app.config_pane)
    defer config_pane_destroy(&app.config_pane)
    if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
        app.scale = sx
    }

    // Glyph renderer. Atlas is baked at physical pixels (15 logical * DPI scale).
    text: Text
    if !text_init(&text, choose_font(), 15, app.scale) {
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

        w, h := glfw.GetFramebufferSize(window)
        // Track DPI: re-bake the atlas if the window moved to another monitor.
        if sx, _ := glfw.GetWindowContentScale(window); sx > 0 {
            app.scale = sx
            text_set_scale(&text, sx)
        }
        render(&app, &text, w, h)
        glfw.SwapBuffers(window)
        glfw.WaitEvents()
    }
}
