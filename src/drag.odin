package main

// Drag capture. GLFW delivers a press, a stream of motion and a release, all addressed to the
// WINDOW; the meaning that binds them is ours. The invariant is the whole file: **a press
// captures, and every motion until the release goes to whatever the press resolved to, wherever
// the pointer has since gone.** Clay resolves the noun at the press; this file keeps it.
//
// Two things the machine stores that a bare press/release pair does not imply:
//
//   1. **The TARGET, not just the kind.** A drag serves one buffer / terminal / divider, so a
//      buffer switch mid-drag makes it inert rather than repointing it at somebody else's text.
//   2. **The GRADE, fixed at press time.** Single / double / triple chooses the granularity —
//      character, word, line — for the gesture's whole length. Both reference terminals do the
//      same (alacritty's SelectionType, ghostty's Order): store the type, expand when read.
//
// The release is PARKED, not acted on: WaitEvents drains a motion and the release after it into
// ONE frame, so clearing in the callback would discard that last motion. `ending`, then swept.

// Autoscroll cadence while the pointer drags past a pane edge, and the ceiling on how many
// lines one tick may walk — alacritty's 15ms timer scaled by overshoot (drag_scroll_step). The
// cap exists because the overshoot is unbounded: a drag that teleports to EOF is not a drag.
DRAG_SCROLL_S :: 0.015
DRAG_SCROLL_MAX :: 8

// What a press captured. Listing every kind keeps the switch in drag_autoscrolling total.
Drag_Kind :: enum {
    None,
    Editor_Text, // the editor's text selection
    Field_Text, // a one-line field's (field_ui.odin) — the same gesture, one line deep
    Terminal_Sel, // per-character grid selection
    Split, // the editor/aux divider — the one client with a motion threshold
    Media_Pan, // panning the image surface — the only 2D drag
}

Drag :: struct {
    kind:   Drag_Kind,
    // Presses in the run that started this drag: 1 character, 2 word, 3+ line. Fixed here
    // for the whole gesture — see the header.
    grade:  int,
    // Which buffer / terminal / pane the press resolved to. Compared by the client on every
    // frame (drag_live), so a drag whose subject went away is inert rather than misdirected.
    target: int,
    // The button is up and the last frame is owed. Set by the release callback, cleared by
    // drag_sweep at the end of the frame that consumed it.
    ending: bool,

    // Where the press landed, in framebuffer pixels. The split divider and the media pan
    // drag by pixel delta from here, and it is nothing to do with the editor's anchor.
    origin_x, origin_y: i32,

    // Where the VIEW was when a media pan began, so each frame re-derives the pan from the
    // TOTAL pixel delta. Accumulating instead would make origin_x/y mean two different things
    // in two clients — a threshold from the press, a delta from the last frame.
    origin_pan: [2]f32,

    // The gesture has travelled past its client's motion threshold. LATCHED: a press that has
    // become a drag does not stop being one by coming back near where it started. Only clients
    // that HAVE a threshold read it (drag_moved); the editor and terminal have none.
    moved: bool,

    // Where the press landed in the DOCUMENT, resolved once. `anchor` is the caret BOUNDARY a
    // character-grade drag extends from, `anchor_glyph` the character pointed at, which a
    // word-grade drag expands around. Stored because the view SCROLLS during a drag.
    anchor:       Pos,
    anchor_glyph: int,

    // glfw time the next autoscroll step is due. Zero until the first one, which is in the
    // past — so leaving the pane takes effect on the next frame rather than after a tick.
    scroll_at: f64,

    // Where the autoscroll has walked to, in the client's own units (a buffer line, or an
    // absolute scrollback row), and whether it is in force. STATE, not a per-frame derivation:
    // past an edge the pointer stops naming a line, and re-resolving it every frame OSCILLATES.
    over:    int,
    over_on: bool,
}

// Capture. Called by a pane from inside its `_click`, once it knows what the press MEANT.
// Refused when the button is already up: a press and its release can both land between two
// frames, and that is a click — such a flick keeps only its press position.
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

// Has this gesture travelled far enough to BE a drag? `px` is the client's threshold in
// framebuffer pixels, max-norm. **The answer latches**: un-latched, a divider dragged 40px out
// and back to 1px would refuse the last frame and leave the split where the 40px was.
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

// Whether `kind` over `target` is the drag currently held. The target comparison is what
// makes capture safe across a mid-drag change of subject: switching buffers with the button
// down leaves the drag held but stops it writing.
drag_live :: proc(a: ^App, kind: Drag_Kind, target: int) -> bool {
    return a.drag.kind == kind && a.drag.target == target
}

// The button came up. Park it — see the header for why this is not a clear.
drag_release :: proc(a: ^App) {
    if a.drag.kind != .None {
        a.drag.ending = true
    }
}

// End of frame: bury a drag that has had its last frame — a finished gesture must not
// survive into a frame where the pointer is somewhere else. `mouse_on` going false mid-drag
// buries it too, or the capture outlives the toggle meant to have stopped it.
drag_sweep :: proc(a: ^App) {
    if a.drag.kind == .None {
        return
    }
    if a.drag.ending || !a.mouse_on {
        a.drag = {}
    }
}

// Whether the drag is pulling the view past an edge this instant. Asks `a.lay`, the layout the
// LAST FRAME PAINTED (mouse.odin, trap 2). The scheduler calls this too, which keeps the
// autoscroll wake off a render->state backchannel.
drag_autoscrolling :: proc(a: ^App) -> bool {
    r: Rect
    switch a.drag.kind {
    case .None, .Split, .Media_Pan, .Field_Text:
        // The divider has no view to run off the end of, and for the media pan the answer
        // is NEITHER axis: a pan already moves the surface a pixel per pixel of pointer
        // travel, so walking it would be a second thing moving the same view. A field walks
        // its own window from how far past the edge the pointer is, with no tick to spend.
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

// Spend an autoscroll tick if one is due. Called only once the pointer is established as
// past an edge, so a drag inside its pane leaves `scroll_at` in the past — which is what
// makes the first frame after the pointer leaves act at once rather than a tick later.
drag_tick :: proc(a: ^App, now: f64) -> bool {
    if now < a.drag.scroll_at {
        return false
    }
    a.drag.scroll_at = now + DRAG_SCROLL_S
    return true
}

// Lines per autoscroll tick, from how far past the edge the pointer is. One line at the
// boundary, one more per row height beyond it, capped — alacritty's scaling, without its
// exact constants, which are tied to its own timer and cell size.
drag_scroll_step :: proc(past, row_h: int) -> int {
    if row_h <= 0 {
        return 1
    }
    return clamp(1 + past / row_h, 1, DRAG_SCROLL_MAX)
}

// The wait an autoscrolling drag asks the loop for, or -1. The one pointer path that needs a
// pump: a wheel notch and a click each arrive as an event, while a drag held still past the
// bottom edge produces none and must keep scrolling anyway.
drag_next_wake :: proc(a: ^App, now: f64) -> f64 {
    if !drag_autoscrolling(a) {
        return -1
    }
    return max(0, a.drag.scroll_at - now)
}
