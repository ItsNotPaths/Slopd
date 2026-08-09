package main

import "base:runtime"
import "core:fmt"
import clay "../bindings/clay"

// Clay bring-up. Clay is the layout + hit-test engine behind Slopd's chrome: panes,
// list rows, fields, dropdowns, overlays, the status strip and the command line are
// DECLARED as a tree, and Clay hands back a flat command list with resolved bounding
// boxes. Paint reads that list and mouse hit-testing reads the same tree, so the two
// cannot disagree — which is the whole point, since today every draw_* proc computes
// its geometry as locals and throws it away each frame. See docs/clay-refactor.md.
//
// It never owns the editor text body, the terminal cell grid, or the media surface:
// those are per-glyph 2D surfaces (folds, per-glyph syntax colour, multi-cursor,
// selection spans) and stay with the existing painters behind a single Custom command.
//
// This file is C0: allocate the arena and initialise. No pane declares anything yet,
// so behaviour is unchanged; the measure-text hook and the command-list → text.odin
// bridge arrive in C1.

// Clay allocates nothing at run time — it is handed one arena up front and lives
// entirely inside it, so this is the library's whole memory footprint. The size it
// wants is derived from its max element count (8192 by default, ~5.5 MiB); we keep
// upstream's default rather than tuning it down, because the element budget is a
// question the git diff column at FONT_PX_MIN answers, not a guess to make here.
// BSS, so it costs address space and zero pages, not binary size.
//
// clay_arena_fits (below) is the guard: a Clay bump that grows the requirement must
// fail in `odin test`, not at a user's startup.
CLAY_ARENA_BYTES :: 6 * 1024 * 1024

// The arena's BASE must be 64-byte aligned, and getting that right is not automatic.
// Clay puts its Clay_Context at `arena->memory` verbatim and then bump-allocates every
// internal array at 64-byte OFFSETS from it (Clay__Array_Allocate_Arena) — so alignment
// of the whole allocator is inherited from wherever this buffer lands. A plain
// `[N]u8` global has align_of 1: measured on this toolchain it landed at base % 64 == 16,
// which would have handed Clay a misaligned context and every array 16 bytes off its
// intended line. Aligning through the element TYPE is what makes it a guarantee rather
// than a linker accident; CLAY_ARENA_ALIGN is asserted in tests/clay_test.odin.
CLAY_ARENA_ALIGN :: 64

@(private = "file")
Clay_Arena_Chunk :: struct #align (CLAY_ARENA_ALIGN) {
    bytes: [CLAY_ARENA_ALIGN]u8,
}

@(private = "file")
clay_arena_mem: [CLAY_ARENA_BYTES / CLAY_ARENA_ALIGN]Clay_Arena_Chunk

// The arena as raw bytes: one contiguous run, since the chunking above is purely how the
// alignment is expressed. Package-level so tests can check the base address.
clay_arena_bytes :: proc() -> []u8 {
    return (cast([^]u8)&clay_arena_mem)[:CLAY_ARENA_BYTES]
}

// Whether the static arena still satisfies what this build of Clay asks for. GL-free, so
// a headless test can pin it — see tests/clay_test.odin. Legal before Initialize because
// MinMemorySize falls back to Clay's compiled-in limits when no context exists; when one
// DOES exist it dereferences it for its limits instead (clay.h), which is why a context
// must never outlive the memory it was initialised over. Moot here (the arena is static
// BSS) but not moot for tests that build their own — see clay_test_context_free.
clay_arena_fits :: proc() -> bool {
    return int(clay.MinMemorySize()) <= CLAY_ARENA_BYTES
}

// Clay reports problems (element count exceeded, a missing measure-text function, an
// arena too small) through this callback rather than by returning errors from the
// declaration calls, since those run deep inside a layout tree. Route them to stderr:
// they mean a layout bug or a budget we have outgrown, both of which we want loud.
@(private = "file")
clay_error :: proc "c" (e: clay.ErrorData) {
    context = runtime.default_context()
    text := e.errorText.length > 0 ? string(e.errorText.chars[:e.errorText.length]) : "(no detail)"
    fmt.eprintfln("clay error [%v]: %s", e.errorType, text)
}

// Initialise Clay over the static arena at the current framebuffer size. Called once
// from main after the window exists; Clay keeps the context globally (its own
// GetCurrentContext), so nothing needs storing on App. Returns false if the arena is
// too small, which clay_arena_fits makes a test failure long before it is a run.
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
