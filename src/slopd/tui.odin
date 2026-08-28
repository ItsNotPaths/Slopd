package main

import "core:fmt"
import "../gfx"
import "../tty"
import "../wake"
import "../ui"
import "../clock"

// `slopd --tui`, the terminal front-end. Same binary, same app_boot, same render: what differs is
// the backend under gfx.Draw, the surface the size comes from, and how the loop waits.
//
// No input yet. `q` and ^C quit, and everything else is ignored — the bind table is keyed on GLFW
// key codes and the translation from escape sequences is its own job.

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

    ui.frame_budget = TUI_FRAME_BUDGET
    buf: [256]u8

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
                n := tty.read(&host, buf[:])
                if tui_wants_quit(n, buf[:]) {
                    return
                }
                if n > 0 {
                    break
                }
            } else if timeout >= 0 {
                break // the deadline came due
            }
        }
    }
}

// The whole input layer for now: q, Q, or ^C. Everything else is dropped rather than guessed at,
// because a half-translated escape sequence is worse than no input at all.
@(private = "file")
tui_wants_quit :: proc(n: int, buf: []u8) -> bool {
    for b in buf[:n] {
        if b == 'q' || b == 'Q' || b == 0x03 {
            return true
        }
    }
    return false
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
