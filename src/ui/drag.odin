package ui
import "../txt"

// Drag capture. A press captures; every motion until the release goes to what the press
// resolved to, wherever the pointer went since. Clay resolves the target at press time.
// The release is PARKED (`ending`), not cleared: WaitEvents drains the last motion and the
// release into one frame, so clearing in the callback would drop that motion.

// Autoscroll cadence past a pane edge, and the cap on lines per tick. Overshoot is
// unbounded, so the cap stops a drag that teleports to EOF.
DRAG_SCROLL_S :: 0.015
DRAG_SCROLL_MAX :: 8

// Listing every kind keeps the switch in drag_autoscrolling total.
Drag_Kind :: enum {
    None,
    Editor_Text,
    Field_Text, // same gesture as the editor's, one line deep
    Terminal_Sel,
    Split, // the editor/aux divider — the one client with a motion threshold
    Media_Pan, // the only 2D drag
    Color_Slider, // `target` is which channel rail
}

Drag :: struct {
    kind:   Drag_Kind,
    // 1 character, 2 word, 3+ line. Fixed for the whole gesture.
    grade:  int,
    // What the press resolved to. Checked every frame (drag_live), so a drag whose subject
    // went away is inert rather than misdirected.
    target: int,
    // Button is up and the last frame is owed. Cleared by drag_sweep.
    ending: bool,

    // Press position in framebuffer pixels. Split and media pan drag by delta from here.
    origin_x, origin_y: i32,

    // View position when a media pan began, so each frame re-derives the pan from the total
    // delta. Accumulating would make origin_x/y mean two things in two clients.
    origin_pan: [2]f32,

    // Past the client's motion threshold. LATCHED: coming back near the origin does not
    // un-drag. Only clients with a threshold read it.
    moved: bool,

    // Press position in the DOCUMENT, resolved once because the view scrolls during a drag.
    // `anchor` is the caret boundary a character drag extends from, `anchor_glyph` the
    // character a word drag expands around.
    anchor:       txt.Pos,
    anchor_glyph: int,

    // glfw time the next autoscroll step is due. Zero until the first, which is in the past
    // so leaving the pane acts on the next frame rather than after a tick.
    scroll_at: f64,

    // Where autoscroll walked to, in client units, and whether it is in force. State, not a
    // per-frame derivation: past an edge the pointer names no line, and re-resolving
    // oscillates.
    over:    int,
    over_on: bool,
}

// Called by a pane from its `_click`, once it knows what the press meant. Refused when the
// button is already up: press and release between two frames is a click, not a drag.
drag_begin :: proc(u: UI_Ctx, kind: Drag_Kind, target, grade: int, anchor: txt.Pos, glyph: int, pan: [2]f32 = {}) {
    if !u.mouse.down {
        return
    }
    u.drag^ = Drag {
        kind         = kind,
        target       = target,
        grade        = grade,
        anchor       = anchor,
        anchor_glyph = glyph,
        origin_x     = u.mouse.x,
        origin_y     = u.mouse.y,
        origin_pan   = pan,
    }
}

// `px` is the client's threshold in framebuffer pixels, max-norm. Latches — without it a
// divider dragged 40px out and back to 1px would refuse the last frame.
drag_moved :: proc(u: UI_Ctx, px: i32) -> bool {
    if u.drag.moved {
        return true
    }
    if abs(u.mouse.x - u.drag.origin_x) < px && abs(u.mouse.y - u.drag.origin_y) < px {
        return false
    }
    u.drag.moved = true
    return true
}

// The target check is what makes capture safe across a mid-drag subject change: switching
// buffers with the button down leaves the drag held but stops it writing.
drag_live :: proc(u: UI_Ctx, kind: Drag_Kind, target: int) -> bool {
    return u.drag.kind == kind && u.drag.target == target
}

// Park the release — see the header.
drag_release :: proc(u: UI_Ctx) {
    if u.drag.kind != .None {
        u.drag.ending = true
    }
}

// End of frame: bury a drag that has had its last frame. `mouse_on` going false buries it
// too, or the capture outlives the toggle meant to stop it.
drag_sweep :: proc(u: UI_Ctx) {
    if u.drag.kind == .None {
        return
    }
    if u.drag.ending || !u.mouse_on {
        u.drag^ = {}
    }
}


// Called only once the pointer is past an edge, so a drag inside its pane leaves `scroll_at`
// in the past — that is what makes the first frame outside act at once.
drag_tick :: proc(u: UI_Ctx, now: f64) -> bool {
    if now < u.drag.scroll_at {
        return false
    }
    u.drag.scroll_at = now + DRAG_SCROLL_S
    return true
}

// One line at the boundary, one more per row height beyond it, capped.
drag_scroll_step :: proc(past, row_h: int) -> int {
    if row_h <= 0 {
        return 1
    }
    return clamp(1 + past / row_h, 1, DRAG_SCROLL_MAX)
}

