package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// C0's whole acceptance surface: Clay links, its ABI answers, and the static arena we
// size for it is still big enough. Everything here is pure — no window, no GL — which
// is exactly why the arena question belongs in a test rather than at startup.

// Clay bump-allocates its internal arrays at 64-byte offsets from the arena base and
// places its context AT that base, so a misaligned base misaligns the entire library.
// This is not hypothetical: a plain [N]u8 global (align_of 1) was measured landing at
// base % 64 == 16, which is why clay_ui.odin expresses the alignment through the buffer's
// element type instead of trusting where the linker puts it.
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

// Clay is handed one arena up front and never allocates again, so if MinMemorySize
// outgrows CLAY_ARENA_BYTES (a Clay bump, or raising its max element count) the app
// refuses to start. Catch that here instead. MinMemorySize is legal before Initialize
// precisely because it only reads Clay's configured limits.
//
// It reads them off the CURRENT CONTEXT when one exists, though, so this test is a reader
// of the same library global every pane test writes — and takes the same lock for it. See
// clay_harness.odin.
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

// The binding in bindings/clay is a verbatim copy of upstream's, pinned to the same
// commit download-deps.sh builds clay.h from — so a mismatched pair shows up as struct
// layouts disagreeing with the archive. These sizes are the cheap canary for that: they
// are ABI, not API, and a silent divergence here would corrupt every bounding box we
// read back. Every number below was cross-checked against sizeof() in C over the same
// clay.h, not merely copied out of what Odin reported. When bumping CLAY_REV, re-check
// them the same way rather than just pasting in the new values.
@(test)
test_clay_abi_shape :: proc(t: ^testing.T) {
    testing.expect_value(t, size_of(clay.Vector2), 8) // [2]f32
    testing.expect_value(t, size_of(clay.Color), 16) // [4]f32
    testing.expect_value(t, size_of(clay.BoundingBox), 16) // 4 x f32
    testing.expect_value(t, size_of(clay.String), 16) // bool + i32 + ptr, packed into 16
    testing.expect_value(t, size_of(clay.Arena), 24) // uintptr + size_t + ptr
    testing.expect_value(t, size_of(clay.ElementId), 32) // 3 x u32 + String, padded
    // The command struct itself: what the C1 bridge walks per frame, and the one whose
    // layout drifting would silently misplace everything we draw.
    testing.expect_value(t, size_of(clay.RenderCommand), 80)

    // The render-command enum is what C1's bridge switches over; its backing type is
    // u8 off Windows and the variant order is the wire format between Clay and us.
    testing.expect_value(t, size_of(clay.RenderCommandType), 1)
    testing.expect_value(t, int(clay.RenderCommandType.Rectangle), 1)
    testing.expect_value(t, int(clay.RenderCommandType.Border), 2)
    testing.expect_value(t, int(clay.RenderCommandType.Text), 3)
    testing.expect_value(t, int(clay.RenderCommandType.Image), 4)
    testing.expect_value(t, int(clay.RenderCommandType.ScissorStart), 5)
    testing.expect_value(t, int(clay.RenderCommandType.ScissorEnd), 6)
    testing.expect_value(t, int(clay.RenderCommandType.Custom), 9)
}

// The one call C0 cannot make from a test: Initialize writes into the package-level
// static arena, and `odin test` runs every test in one process, so initialising here
// would leave a live Clay context behind for whatever runs next. Instead assert the
// arena constructor is sane on memory we own — same call clay_init makes, no global
// state touched.
@(test)
test_clay_arena_ctor :: proc(t: ^testing.T) {
    mem := make([]u8, 1024)
    defer delete(mem)
    arena := clay.CreateArenaWithCapacityAndMemory(len(mem), raw_data(mem))
    testing.expect_value(t, arena.capacity, uint(len(mem)))
    testing.expect_value(t, rawptr(arena.memory), rawptr(raw_data(mem)))
}
