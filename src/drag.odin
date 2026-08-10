package main

// Drag capture — C7c, and the one genuinely NEW state machine in this refactor. Everything
// else the mouse work added was a translation of something that already existed (a click is
// a keyboard verb reached from a pixel, a wheel notch is a scroll); a drag is not, because
// GLFW has no such concept. It delivers a press, a stream of motion, and a release, all
// addressed to the WINDOW, and the meaning that binds them together is ours to keep.
//
// The invariant, and it is the whole file: **a press captures, and every motion until the
// release goes to whatever the press resolved to, wherever the pointer has since gone.** A
// selection begun in the editor keeps extending while the pointer is over the filetree, off
// the bottom of the window, or on another monitor. Without that, a drag would stop the
// instant it left the pane it started in — which is exactly the moment the user is asking
// for more of it.
//
// This is deliberately NOT Clay's job. Clay's OnHover is per-element and frame-scoped: it
// can answer "is the pointer over this box right now", which is the opposite of what capture
// means. Clay resolves the noun at the press (through each pane's `_hit`), and this file
// keeps it.
//
// Two things the machine stores that a bare press/release pair does not imply:
//
//   1. **The TARGET, not just the kind.** A drag serves one buffer / one terminal / one
//      divider. A buffer switch mid-drag must make the drag inert, not repoint it at
//      somebody else's text, so the client asks drag_live with the thing it is drawing.
//   2. **The GRADE, fixed at press time.** Single / double / triple chooses the GRANULARITY
//      of the gesture — character, word, line — and it applies for the whole drag, so a
//      double-click-drag keeps growing by whole words rather than selecting one word and
//      then continuing by characters. Both reference terminals do this by storing the type
//      on the Selection and expanding per-type when the range is READ (alacritty's
//      SelectionType, ghostty's Order); we store it here and expand in the client's frame.
//      A machine that only remembered where the press landed could not express it.
//
// The release is PARKED rather than acted on, which is the one thing here that reads odd
// and is load-bearing. glfw.WaitEvents drains every pending event before the loop renders,
// so a motion immediately followed by a release arrives as ONE batch and is followed by ONE
// frame. Clearing the drag in the release callback would throw that last motion away — the
// final stretch of the gesture, which is the part the user was aiming with. So a release
// sets `ending`, the owning pane gets one more frame to apply the position the pointer
// actually stopped at, and drag_sweep buries it at the end of that frame. It is the same
// shape as Mouse.click, for the same reason: the callback has no noun, only the frame does.

// Autoscroll cadence while the pointer is dragging past a pane edge, and the ceiling on how
// many lines one tick may walk. alacritty uses a 15ms timer with the delta scaled by how far
// past the edge the pointer is, which is what these are — the scaling is drag_scroll_step.
// The cap exists because the overshoot is unbounded (the pointer can be at the bottom of a
// 4K screen while the pane is 200px tall) and a drag that teleports to the end of the file
// is not a drag.
DRAG_SCROLL_S :: 0.015
DRAG_SCROLL_MAX :: 8

// What a press captured. Media pan and the split divider are C8d's and the terminal's
// character selection is C7d's; they are named here rather than added later because the
// machine is built once against ALL of its clients (that is why C7c is a checkpoint of its
// own) and because an enum that lists them makes the switch in drag_autoscrolling total.
Drag_Kind :: enum {
    None,
    Editor_Text, // C7c: the editor's text selection — the only live client today
    Terminal_Sel, // C7d: per-character grid selection
    Split, // C8d: the editor/aux divider
    Media_Pan, // C8d: panning the image surface
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
    // (C8d) drag by pixel delta from here, and it is nothing to do with the editor's anchor.
    origin_x, origin_y: i32,

    // Where the press landed in the DOCUMENT, resolved once and never re-resolved. Both
    // columns, for C7a's reason: `anchor` is the caret BOUNDARY a character-grade drag
    // extends from, `anchor_glyph` is the character actually pointed at, which is what a
    // word-grade drag expands its run around.
    //
    // Storing the position rather than re-deriving it from origin_x/y each frame is the
    // point: the view scrolls DURING a drag (that is what autoscroll is), so a pixel origin
    // would name a different line every time the window moved under it.
    anchor:       Pos,
    anchor_glyph: int,

    // glfw time the next autoscroll step is due. Zero until the first one, which is in the
    // past — so leaving the pane takes effect on the next frame rather than after a tick.
    scroll_at: f64,

    // Where the autoscroll has walked to, in the client's own units — a buffer line for the
    // editor, an absolute scrollback row for the terminal (C7d) — and whether it is in force
    // at all. Seeded from the edge the pointer left over, advanced on each tick, dropped the
    // moment the pointer comes back inside the pane.
    //
    // **This is state and not a per-frame derivation, and the difference is the whole of it.**
    // Past an edge the pointer has stopped naming a line: it is off the pane, and the only
    // thing that changes while it sits there is how long it has been there. Re-resolving it
    // every frame is the obvious implementation and it OSCILLATES — the walked line moves the
    // viewport, the next frame resolves the pointer against a view still tweening toward it,
    // the selection snaps back to the edge row, and the policy re-aims at where the selection
    // now is. The scroll and the selection then fight each other at the frame rate. So while
    // the pointer is outside, the DRAG names the line and the pointer only says "keep going".
    over:    int,
    over_on: bool,
}

// Capture. Called by a pane from inside its `_click`, once it has claimed the press and
// knows what the press MEANT — which is the only place that knowledge exists (a click has no
// noun until a pane draws, C3).
//
// Refused when the button is already up: a press and its release can both land in the gap
// between two frames, and that is a click, not a drag. The cost is that a flick completed
// inside one frame keeps only its press position, which is unavoidable without replaying
// event history and is under 16ms of travel.
drag_begin :: proc(a: ^App, kind: Drag_Kind, target, grade: int, anchor: Pos, glyph: int) {
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
    }
}

// Whether `kind` over `target` is the drag currently held. The target comparison is what
// makes capture safe across a mid-drag change of subject: switching buffers with the button
// down leaves the drag held (it is still the same gesture) but stops it writing, and the
// release then buries it.
drag_live :: proc(a: ^App, kind: Drag_Kind, target: int) -> bool {
    return a.drag.kind == kind && a.drag.target == target
}

// The button came up. Park it — see the header for why this is not a clear.
drag_release :: proc(a: ^App) {
    if a.drag.kind != .None {
        a.drag.ending = true
    }
}

// End of frame: bury a drag that has had its last frame. Beside render's `a.mouse.click =
// false` and for the same reason — a pointer gesture is an event at a place, and one that
// has finished must not survive into a frame where the pointer is somewhere else.
//
// `mouse_on` going false mid-drag also buries it. The alternative is a capture that outlives
// the toggle that was supposed to have switched the pointer off.
drag_sweep :: proc(a: ^App) {
    if a.drag.kind == .None {
        return
    }
    if a.drag.ending || !a.mouse_on {
        a.drag = {}
    }
}

// Whether the drag is pulling the view past an edge this instant: the pointer has left the
// captured pane vertically, so the client walks the selection further on each tick and the
// pane's own viewport policy does the scrolling.
//
// Pure, and it asks `a.lay` — the layout the LAST FRAME PAINTED — for exactly the reason
// wheel_target does (mouse.odin, trap 2): mid-animation a freshly computed layout is already
// somewhere the user cannot see yet. The scheduler calls this too, which is what keeps the
// autoscroll wake off a render→state backchannel: nothing has to publish "I am autoscrolling"
// because the question is answerable from state that already exists.
drag_autoscrolling :: proc(a: ^App) -> bool {
    r: Rect
    switch a.drag.kind {
    case .None, .Split:
        return false // the divider has no view to run off the end of
    case .Editor_Text, .Media_Pan:
        r = a.lay.editor
    case .Terminal_Sel:
        r = a.lay.aux
    }
    if r.h <= 0 {
        return false
    }
    return a.mouse.y < r.y || a.mouse.y >= r.y + r.h
}

// Spend an autoscroll tick if one is due. Called only once the client has established that
// the pointer IS past an edge, so a drag held still inside its pane consumes nothing and
// leaves `scroll_at` in the past — which is what makes the first frame after the pointer
// leaves act at once instead of a tick later.
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

// The wait an autoscrolling drag asks the loop for, or -1 for "nothing here needs a wake".
// Folded into app_next_wake (anim.odin) beside the tweens.
//
// This is the pump the drag needs and no other pointer path does: a wheel notch and a click
// each arrive as an event, so the loop is already awake for them, while a drag held still
// past the bottom edge produces no events at all and must still keep scrolling.
drag_next_wake :: proc(a: ^App, now: f64) -> f64 {
    if !drag_autoscrolling(a) {
        return -1
    }
    return max(0, a.drag.scroll_at - now)
}
