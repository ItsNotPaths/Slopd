package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// Clay links, its ABI answers, and the static arena we size for it is still big enough. Pure —
// no window, no GL — which is why the arena question belongs in a test rather than at startup.

// Clay bump-allocates its internal arrays at 64-byte offsets from the arena base and puts its
// context AT that base, so a misaligned base misaligns the library. Not hypothetical: a plain
// [N]u8 global was measured landing at base % 64 == 16.
@(test)
test_clay_arena_aligned :: proc(t: ^testing.T) {
    base := uintptr(raw_data(app.clay_arena_bytes()))
    testing.expectf(
        t,
        base % app.CLAY_ARENA_ALIGN == 0,
        "arena base is %d mod %d, must be 0 — the aligned element type in clay_ui.odin was lost",
        base % app.CLAY_ARENA_ALIGN,
        app.CLAY_ARENA_ALIGN,
    )
    testing.expect_value(t, len(app.clay_arena_bytes()), app.CLAY_ARENA_BYTES)
}

// If MinMemorySize outgrows CLAY_ARENA_BYTES the app refuses to start; catch that here instead.
// The call is legal before Initialize, but it reads the CURRENT CONTEXT when one exists, so this
// is a reader of the same library global every pane test writes, and takes the same lock.
@(test)
test_clay_arena_fits :: proc(t: ^testing.T) {
    clay_test_lock()
    defer clay_test_unlock()

    need := int(clay.MinMemorySize())
    testing.expectf(
        t,
        need > 0,
        "MinMemorySize returned %d — Clay linked but is not answering; check vendor/clay/libclay.a",
        need,
    )
    testing.expectf(
        t,
        app.clay_arena_fits(),
        "Clay wants %d bytes, CLAY_ARENA_BYTES is %d — raise it in clay_ui.odin",
        need,
        app.CLAY_ARENA_BYTES,
    )
}

// The binding is a verbatim copy of upstream's, pinned to the commit download-deps.sh builds
// clay.h from, so a mismatched pair shows up as struct layouts disagreeing with the archive.
// Every number below was cross-checked against sizeof() in C over the same clay.h; when bumping
// CLAY_REV, re-check them the same way rather than pasting in what Odin reports.
@(test)
test_clay_abi_shape :: proc(t: ^testing.T) {
    testing.expect_value(t, size_of(clay.Vector2), 8) // [2]f32
    testing.expect_value(t, size_of(clay.Color), 16) // [4]f32
    testing.expect_value(t, size_of(clay.BoundingBox), 16) // 4 x f32
    testing.expect_value(t, size_of(clay.String), 16) // bool + i32 + ptr, packed
    testing.expect_value(t, size_of(clay.Arena), 24) // uintptr + size_t + ptr
    testing.expect_value(t, size_of(clay.ElementId), 32) // 3 x u32 + String, padded
    // What the bridge walks per frame, and the one whose layout drifting would misplace
    // everything we draw.
    testing.expect_value(t, size_of(clay.RenderCommand), 80)

    // What the bridge switches over: u8 off Windows, and the variant order is the wire format.
    testing.expect_value(t, size_of(clay.RenderCommandType), 1)
    testing.expect_value(t, int(clay.RenderCommandType.Rectangle), 1)
    testing.expect_value(t, int(clay.RenderCommandType.Border), 2)
    testing.expect_value(t, int(clay.RenderCommandType.Text), 3)
    testing.expect_value(t, int(clay.RenderCommandType.Image), 4)
    testing.expect_value(t, int(clay.RenderCommandType.ScissorStart), 5)
    testing.expect_value(t, int(clay.RenderCommandType.ScissorEnd), 6)
    testing.expect_value(t, int(clay.RenderCommandType.Custom), 9)
}

// The one call a test cannot make: Initialize writes into the package-level static arena, and
// `odin test` runs every test in one process, so it would leave a live context behind. Instead
// assert the arena constructor on memory we own.
@(test)
test_clay_arena_ctor :: proc(t: ^testing.T) {
    mem := make([]u8, 1024)
    defer delete(mem)
    arena := clay.CreateArenaWithCapacityAndMemory(len(mem), raw_data(mem))
    testing.expect_value(t, arena.capacity, uint(len(mem)))
    testing.expect_value(t, rawptr(arena.memory), rawptr(raw_data(mem)))
}
