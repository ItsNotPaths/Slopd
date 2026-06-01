package main

import "core:fmt"
import gl "vendor:OpenGL"
import "vendor:glfw"

WIDTH :: 1200
HEIGHT :: 760
TITLE :: "PitEd"

GL_MAJOR :: 3
GL_MINOR :: 3

main :: proc() {
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

    cfg := load_config()
    defer config_destroy(&cfg)
    app.theme = load_theme(cfg.theme_path)
    app.indent = cfg.indent
    app.line_numbers = cfg.line_numbers

    editor_init(&app.editor)
    defer editor_destroy(&app.editor)
    filetree_init(&app.tree)
    defer filetree_destroy(&app.tree)
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
    glfw.SetWindowUserPointer(window, &app)
    glfw.SetKeyCallback(window, key_callback)
    glfw.SetCharCallback(window, char_callback)

    // Render first, then block until the next event. The UI only redraws when
    // something actually changes, so it idles at 0% CPU.
    for !glfw.WindowShouldClose(window) {
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
