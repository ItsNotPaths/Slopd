package main

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
    anchor:       Pos,
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
drag_begin :: proc(a: ^App, kind: Drag_Kind, target, grade: int, anchor: Pos, glyph: int, pan: [2]f32 = {}) {
    if !a.mouse.down {
        return
    }
    a.drag = Drag {
        kind         = kind,
        target       = target,
        grade        = grade,
        anchor       = anchor,
        anchor_glyph = glyph,
        origin_x     = a.mouse.x,
        origin_y     = a.mouse.y,
        origin_pan   = pan,
    }
}

// `px` is the client's threshold in framebuffer pixels, max-norm. Latches — without it a
// divider dragged 40px out and back to 1px would refuse the last frame.
drag_moved :: proc(a: ^App, px: i32) -> bool {
    if a.drag.moved {
        return true
    }
    if abs(a.mouse.x - a.drag.origin_x) < px && abs(a.mouse.y - a.drag.origin_y) < px {
        return false
    }
    a.drag.moved = true
    return true
}

// The target check is what makes capture safe across a mid-drag subject change: switching
// buffers with the button down leaves the drag held but stops it writing.
drag_live :: proc(a: ^App, kind: Drag_Kind, target: int) -> bool {
    return a.drag.kind == kind && a.drag.target == target
}

// Park the release — see the header.
drag_release :: proc(a: ^App) {
    if a.drag.kind != .None {
        a.drag.ending = true
    }
}

// End of frame: bury a drag that has had its last frame. `mouse_on` going false buries it
// too, or the capture outlives the toggle meant to stop it.
drag_sweep :: proc(a: ^App) {
    if a.drag.kind == .None {
        return
    }
    if a.drag.ending || !a.mouse_on {
        a.drag = {}
    }
}

// Is the drag pulling the view past an edge right now? Asks `a.lay`, the layout the last
// frame painted (mouse.odin, trap 2). The scheduler calls this too, which keeps the
// autoscroll wake off a render->state backchannel.
drag_autoscrolling :: proc(a: ^App) -> bool {
    r: Rect
    switch a.drag.kind {
    case .None, .Split, .Media_Pan, .Field_Text, .Color_Slider:
        // No view to run off: the divider has none, a media pan already moves the surface
        // pixel-for-pixel, a field walks its own window, a colour rail is bounded.
        return false
    case .Editor_Text:
        r = a.lay.editor
    case .Terminal_Sel:
        r = a.lay.aux
    }
    if r.h <= 0 {
        return false
    }
    return a.mouse.y < r.y || a.mouse.y >= r.y + r.h
}

// Called only once the pointer is past an edge, so a drag inside its pane leaves `scroll_at`
// in the past — that is what makes the first frame outside act at once.
drag_tick :: proc(a: ^App, now: f64) -> bool {
    if now < a.drag.scroll_at {
        return false
    }
    a.drag.scroll_at = now + DRAG_SCROLL_S
    return true
}

// One line at the boundary, one more per row height beyond it, capped.
drag_scroll_step :: proc(past, row_h: int) -> int {
    if row_h <= 0 {
        return 1
    }
    return clamp(1 + past / row_h, 1, DRAG_SCROLL_MAX)
}

// The wait an autoscrolling drag asks the loop for, or -1. The one pointer path needing a
// pump: a drag held still past an edge produces no events but must keep scrolling.
drag_next_wake :: proc(a: ^App, now: f64) -> f64 {
    if !drag_autoscrolling(a) {
        return -1
    }
    return max(0, a.drag.scroll_at - now)
}
