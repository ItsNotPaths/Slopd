package tests

import app ".."
import clay "../../bindings/clay"
import "base:runtime"
import "core:fmt"

// A Clay context for headless tests. Shared by every test that declares a tree —
// clay_render_test.odin (the bridge) and filetree_ui_test.odin (the first pane), with
// C5's panes to follow — because the two traps below are traps for all of them and are
// not worth rediscovering per file.

// Clay reports layout problems through a callback, and the zero ErrorHandler is a NULL
// function pointer it will happily call — so a test that trips an error would crash with
// no diagnosis. Route them somewhere visible.
clay_test_error :: proc "c" (e: clay.ErrorData) {
    context = runtime.default_context()
    text := e.errorText.length > 0 ? string(e.errorText.chars[:e.errorText.length]) : "(no detail)"
    fmt.eprintfln("clay error in test [%v]: %s", e.errorType, text)
}

// A Clay context over test-owned memory, aligned the way clay_ui.odin aligns the real
// arena (Clay bump-allocates at 64-byte offsets from the base, so the base's alignment is
// the whole library's). The app's static arena is deliberately NOT used: `odin test` runs
// every test in one process, and clobbering it would leave a live context behind for
// whatever runs next. Free it with clay_test_context_free, never with plain delete.
clay_test_context :: proc(w, h: f32) -> []u8 {
    need := int(clay.MinMemorySize())
    raw := make([]u8, need + app.CLAY_ARENA_ALIGN)
    base := uintptr(raw_data(raw))
    pad := (app.CLAY_ARENA_ALIGN - int(base % app.CLAY_ARENA_ALIGN)) % app.CLAY_ARENA_ALIGN
    mem := raw[pad:]
    arena := clay.CreateArenaWithCapacityAndMemory(len(mem), raw_data(mem))
    clay.Initialize(arena, {w, h}, {handler = clay_test_error})
    return raw
}

// UNLATCH THE CONTEXT BEFORE FREEING — this is not tidiness. Clay keeps the current
// context in a library global, and Clay_MinMemorySize *dereferences* it to inherit its
// limits (clay.h: `if (currentContext) fakeContext.maxElementCount = currentContext->...`).
// Freeing the arena while the global still points into it turns the next MinMemorySize
// call — test_clay_arena_fits, or the next test setting up its own context — into a read
// of freed memory. It segfaults, in a test that did nothing wrong, in whatever order the
// runner happens to pick. The app never hits this only because its arena is static BSS
// that lives as long as the process.
clay_test_context_free :: proc(raw: []u8) {
    clay.SetCurrentContext(nil)
    delete(raw)
}

// The synthetic font every Clay test measures through: a 10x16 cell, so any fractional
// box in the output is a real finding rather than rounding noise.
clay_test_font :: proc() -> app.Font {
    return app.Font{cell_w = 10, line_height = 16}
}
