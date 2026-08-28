package main

import "core:fmt"
import "../clip"
import "../gfx"
import "../tty"
import "../wake"
import "../ui"
import "../clock"

// `slopd --tui`, the terminal front-end. Same binary, same app_boot, same render: what differs is
// the backend under gfx.Draw, the surface the size comes from, and how the loop waits.
//
// Input arrives through tui_input.odin, which decodes the kitty keyboard protocol into the same
// three integers the window's GLFW callback hands handle_key. `:q` ends the session, as it does
// in a window.

// A terminal has no vsync to block on, so an animating frame is paced here instead. Idle frames
// are not paced at all: the loop blocks until something asks for one.
TUI_FRAME_BUDGET :: 1.0 / 60

tui_run :: proc(args: []string) {
    host: tty.Tty
    if !tty.enter(&host) {
        fmt.eprintln("slopd --tui: stdout is not a terminal")
        return
    }
    defer tty.leave(&host)

    cols, rows := tty.size(&host)

    a: App
    cfg := app_boot(&a)
    defer app_shutdown(&a, &cfg)
    a.scale = 1 // a grid has no DPI; every size comes from the Face

    draw: gfx.Draw
    if !gfx.draw_init_cells(&draw, cols, rows) {
        fmt.eprintfln("slopd --tui: bad terminal size %dx%d", cols, rows)
        return
    }
    defer gfx.draw_destroy(&draw)
    a.draw = &draw

    if !ui.clay_init(cols, rows) {
        return // clay_init reported why
    }
    ui.clay_use_face(gfx.face_live(&draw))

    launch := parse_launch_args(args)
    if !app_launch(&a, launch) {
        fmt.eprintfln("slopd: no such path: %s", launch.path)
    }

    a.clipboard = {get = tui_clipboard_get, set = tui_clipboard_set, user = &host}

    ui.frame_budget = TUI_FRAME_BUDGET
    input: Tui_Input
    defer tui_input_destroy(&input)
    buf: [512]u8

    for !a.quit {
        free_all(context.temp_allocator) // nothing temp escapes a frame

        now := clock.now()
        app_poll(&a, now)
        render(&a, &draw, cols, rows, now)
        tty.write_bytes(&host, gfx.frame_bytes(&draw))

        // Then wait for the next thing worth drawing, the same gate the window front-end uses:
        // an event, or a deadline an animation asked for. Waiting is what keeps a terminal
        // editor off the CPU, and a full grid write is far too expensive to do speculatively.
        for {
            if wake.take() { // a pty reader marked it while the frame was drawing
                break
            }
            timeout := app_next_wake(&a, clock.now())
            ready := tty.wait(&host, timeout)
            if tty.resized() {
                cols, rows = tty.size(&host)
                ui.clay_resize(cols, rows)
                break
            }
            if ready {
                if tui_input_pump(&a, &input, &host, buf[:]) {
                    break
                }
            } else if timeout >= 0 {
                break // the deadline came due
            }
        }
    }
}

// The platform's own clipboard tool where there is one, and OSC 52 where there is not. The split
// is not local-versus-remote by accident: over SSH there is no wl-copy to run and no display to
// run it against, and the clipboard worth writing to is on the machine the terminal is on, which
// is exactly the one OSC 52 reaches.
@(private = "file")
tui_clipboard_set :: proc(user: rawptr, s: string) {
    if clip.set(s) {
        return
    }
    tty.clipboard_set((^tty.Tty)(user), s)
}

// "" when there is no tool, and clipboard_get then falls through to our own last copy. OSC 52
// has a read form and it is not used: it lets any program on the terminal read your clipboard,
// which is why terminals disable it. A paste from elsewhere arrives as bracketed paste instead.
@(private = "file")
tui_clipboard_get :: proc(user: rawptr) -> string {
    return clip.get()
}

// `--tui` anywhere in the arguments. Checked before the window is opened, and it is a front-end
// rather than a headless command, so it runs the whole session and main returns after it.
tui_requested :: proc(args: []string) -> bool {
    for arg in args {
        if arg == "--tui" {
            return true
        }
    }
    return false
}
