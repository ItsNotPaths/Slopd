package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../edit"
import "../gfx"
import "../ui"

// `slopd --cell-dump[=COLSxROWS]`, the cell backend's smoke test: one frame of the real render
// path into a grid, written to stdout as ANSI. No window, no GL, no input — this exists to
// answer whether Clay laying out at one unit per cell produces a usable screen, which every
// later piece of terminal mode depends on.
//
// Deliberately a REDUCED setup: theme, an editor and a filetree, and nothing that reads the
// user's config. What is being looked at is geometry, not settings.
CELL_DUMP_COLS :: 100
CELL_DUMP_ROWS :: 30

cell_dump_cli :: proc(args: []string) -> bool {
    size, ok := cell_dump_arg(args)
    if !ok {
        return false
    }

    a: App
    app_init(&a)
    defer app_destroy(&a)
    a.theme = theme_load("")
    a.scale = 1

    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)
    filetree_init(&a.tree)
    defer filetree_destroy(&a.tree)

    draw: gfx.Draw
    if !gfx.draw_init_cells(&draw, size.x, size.y) {
        fmt.eprintfln("cell-dump: bad size %dx%d", size.x, size.y)
        return true
    }
    defer gfx.draw_destroy(&draw)
    a.draw = &draw

    if !ui.clay_init(size.x, size.y) {
        return true
    }
    ui.clay_use_face(gfx.face_live(&draw))

    render(&a, &draw, size.x, size.y, 0)
    os.write(os.stdout, gfx.frame_bytes(&draw))
    os.write(os.stdout, transmute([]u8)string("\n"))
    return true
}

// --cell-dump, or --cell-dump=120x40.
@(private = "file")
cell_dump_arg :: proc(args: []string) -> (size: [2]i32, ok: bool) {
    size = {CELL_DUMP_COLS, CELL_DUMP_ROWS}
    for arg in args {
        if arg == "--cell-dump" {
            return size, true
        }
        if !strings.has_prefix(arg, "--cell-dump=") {
            continue
        }
        spec := arg[len("--cell-dump="):]
        x := strings.index_byte(spec, 'x')
        if x <= 0 {
            return size, true
        }
        if w, wok := strconv.parse_int(spec[:x], 10); wok {
            if h, hok := strconv.parse_int(spec[x + 1:], 10); hok {
                size = {i32(w), i32(h)}
            }
        }
        return size, true
    }
    return size, false
}
