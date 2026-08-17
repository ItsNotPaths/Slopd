package main

import "base:runtime"
import "core:fmt"
import clay "../bindings/clay"

// Clay bring-up. Clay is the layout and hit-test engine behind the chrome: panes, rows,
// fields, dropdowns, overlays and the strip are declared as a tree, and Clay hands back a flat
// command list with resolved boxes. Paint and hit-testing read the same tree, so the two cannot
// disagree. The measure-text hook and the command-list bridge are clay_render.odin.
//
// Clay never owns the editor text body, the terminal grid or the media surface: those are
// per-glyph 2D surfaces and stay with their own painters behind a single Custom.

// Clay allocates nothing at run time, so this is its whole footprint — sized from upstream's
// max element count (8192, ~5.5 MiB). BSS. clay_arena_fits fails in `odin test`, not at startup.
CLAY_ARENA_BYTES :: 6 * 1024 * 1024

// Clay puts its Clay_Context at `arena->memory` verbatim and bump-allocates at 64-byte offsets
// from it. A plain `[N]u8` global has align_of 1, so the alignment comes through the element
// type.
CLAY_ARENA_ALIGN :: 64

@(private = "file")
Clay_Arena_Chunk :: struct #align (CLAY_ARENA_ALIGN) {
    bytes: [CLAY_ARENA_ALIGN]u8,
}

@(private = "file")
clay_arena_mem: [CLAY_ARENA_BYTES / CLAY_ARENA_ALIGN]Clay_Arena_Chunk

// One contiguous run; the chunking above is only how the alignment is expressed.
clay_arena_bytes :: proc() -> []u8 {
    return (cast([^]u8)&clay_arena_mem)[:CLAY_ARENA_BYTES]
}

// GL-free, so a headless test can pin it. Legal before Initialize: MinMemorySize falls back to
// Clay's compiled-in limits when no context exists.
clay_arena_fits :: proc() -> bool {
    return int(clay.MinMemorySize()) <= CLAY_ARENA_BYTES
}

// Clay reports problems here rather than from the declaration calls, which run deep inside the
// tree. Stderr, because they mean a layout bug or a budget we have outgrown.
@(private = "file")
clay_error :: proc "c" (e: clay.ErrorData) {
    context = runtime.default_context()
    text := e.errorText.length > 0 ? string(e.errorText.chars[:e.errorText.length]) : "(no detail)"
    fmt.eprintfln("clay error [%v]: %s", e.errorType, text)
}

// Once from main, after the window exists. Clay keeps the context globally, so nothing is
// stored on App.
clay_init :: proc(w, h: i32) -> bool {
    if !clay_arena_fits() {
        fmt.eprintfln(
            "clay_init: arena too small (need %d bytes, have %d) — raise CLAY_ARENA_BYTES",
            clay.MinMemorySize(),
            CLAY_ARENA_BYTES,
        )
        return false
    }
    arena := clay.CreateArenaWithCapacityAndMemory(CLAY_ARENA_BYTES, raw_data(clay_arena_bytes()))
    clay.Initialize(arena, {f32(w), f32(h)}, {handler = clay_error})
    return true
}
