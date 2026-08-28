package tests

import app ".."
import clay "../../bindings/clay"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "../gfx"
import "../ui"

// A Clay context for headless tests, shared by every test that declares a tree, because the two
// traps below are traps for all of them.

// The zero ErrorHandler is a NULL function pointer Clay will happily call, so a test that trips
// an error would crash with no diagnosis.
clay_test_error :: proc "c" (e: clay.ErrorData) {
    context = runtime.default_context()
    text := e.errorText.length > 0 ? string(e.errorText.chars[:e.errorText.length]) : "(no detail)"
    fmt.eprintfln("clay error in test [%v]: %s", e.errorType, text)
}

// ONE TEST AT A TIME MAY HOLD CLAY. Clay keeps the current context in a library global, and
// `odin test` runs tests on several threads in one process — so two tests that each make an
// arena still share that global, and whichever finishes first frees the arena the other is
// reading. That was a storm of 30-odd segfaults across every pane file, none of them wrong.
//
// So the global is a resource with one holder: clay_test_context takes the lock and
// clay_test_context_free gives it back, which is why every caller pairs them with a defer.
@(private = "file")
clay_global: sync.Mutex

// Over test-owned memory, aligned as clay_ui.odin aligns the real arena: Clay bump-allocates at
// 64-byte offsets from the base. The app's static arena is deliberately not used, since
// clobbering it would leave a live context behind for whatever runs next.
clay_test_context :: proc(w, h: f32) -> []u8 {
    sync.lock(&clay_global)
    need := int(clay.MinMemorySize())
    raw := make([]u8, need + ui.CLAY_ARENA_ALIGN)
    base := uintptr(raw_data(raw))
    pad := (ui.CLAY_ARENA_ALIGN - int(base % ui.CLAY_ARENA_ALIGN)) % ui.CLAY_ARENA_ALIGN
    mem := raw[pad:]
    arena := clay.CreateArenaWithCapacityAndMemory(len(mem), raw_data(mem))
    clay.Initialize(arena, {w, h}, {handler = clay_test_error})
    return raw
}

// Unlatch the context BEFORE freeing, and not for tidiness: Clay_MinMemorySize dereferences the
// current context to inherit its limits, so freeing the arena while the global points into it
// turns the next call into a read of freed memory. The app never hits this only because its
// arena is static BSS.
clay_test_context_free :: proc(raw: []u8) {
    clay.SetCurrentContext(nil)
    delete(raw)
    sync.unlock(&clay_global)
}

// The same lock, for a test that reads the Clay global WITHOUT an arena of its own.
// MinMemorySize is the one such call: legal before Initialize, but it dereferences the current
// context when there is one, so it waits its turn.
//
//     clay_test_lock()
//     defer clay_test_unlock()
clay_test_lock :: proc() {
    sync.lock(&clay_global)
}

clay_test_unlock :: proc() {
    sync.unlock(&clay_global)
}

// A 10x16 cell, so any fractional box in the output is a real finding rather than noise.
clay_test_font :: proc() -> gfx.Font {
    return gfx.Font{cell_w = 10, line_height = 16}
}

// One command per element id, by type: what most declaration assertions want, since a surface is
// a handful of named boxes rather than a long list of rows.
//
// Not every command carries the id of the element that asked for it: Clay derives a clip group's
// ScissorStart id, and a border command's, from the element's own, so those have to be found by
// containment or by box.
box_of :: proc(
    cmds: ^clay.ClayArray(clay.RenderCommand),
    id: clay.ElementId,
    kind: clay.RenderCommandType,
) -> (
    box: gfx.Rect,
    found: bool,
) {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        if c.id == id.id && c.commandType == kind {
            return ui.clay_rect(c.boundingBox), true
        }
    }
    return {}, false
}
