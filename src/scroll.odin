package main

// The list panes' viewport policy — the flat-row twin of buffer_scroll_target
// (buffer.odin), so a list tracks its SELECTION the same way the editor tracks its
// caret and both answer to the one `scroll_mode` config. Lists have no folds, so this
// walks plain rows rather than visible ones; otherwise the two modes match the editor's
// exactly:
//   FOLLOW (default) — `top` holds still while `sel` is inside the viewport, then moves
//     the minimum: up to `sel` when it steps above, down to put it on the bottom row.
//     The top is kept within the list, so a shrinking list (a filter, a new directory)
//     never strands the view on blank rows.
//   MIDDLE — `sel` is pinned to the middle row, so Up/Down move the LIST under a
//     selection that never leaves the middle. Clamped at the first row (there is nothing
//     above row 0 to show); at the end it keeps centring and lets the view run past the
//     last row, exactly as the editor does.
// Pure and GL-free — the caller passes its own stored top and stores the result back.
list_scroll_target :: proc(top, sel, rows, total: int, center: bool) -> int {
    if rows <= 0 || total <= 0 {
        return 0
    }
    s := clamp(sel, 0, total - 1)
    if center {
        return max(0, s - rows / 2)
    }
    // Clamp the incoming top before comparing: the list may have shrunk since it was stored.
    t := clamp(top, 0, max(0, total - rows))
    if s < t {
        return s
    }
    if s >= t + rows {
        return s - rows + 1 // sel onto the bottom row
    }
    return t
}

// Move a DETACHED list view by `delta` rows and stamp it, the wheel's entry point — the
// flat-row twin of buffer_scroll_by (buffer.odin). Deliberately takes no total: the caller
// is a GLFW callback with no font, no pane rect and, for grep and config, no flattened row
// list either, so it cannot know where the end is. list_scroll_apply clamps on the next
// frame instead, which bounds the overshoot at one notch and self-corrects.
list_scroll_by :: proc(scroll: ^int, detached: ^f64, delta: int, now: f64) {
    scroll^ += delta
    detached^ = now
}

// The per-frame write, wrapping list_scroll_target with the detach state a wheel gesture
// leaves behind. Three states, and the middle one is the whole point:
//
//   - a keystroke POSTDATES the stamp -> re-attach, and the policy resumes from the
//     selection. That is what makes the detach safe: every list verb is reached by a key,
//     so not one of them has to know the flag exists.
//   - detached -> bounds only. Any row may be the top, first to last, exactly as the
//     detached editor lets any line be the top. NEITHER policy runs, which is what makes
//     the wheel behave the same in both scroll_modes: MIDDLE re-derives the top from the
//     selection outright, so a view-only scroll would be overwritten on the next frame.
//   - attached -> the policy, unchanged.
//
// `last_input_at` is the caller's to gate: pass the app's keystroke timestamp only while
// this pane HOLDS FOCUS, because a key pressed in the editor cannot have moved an aux
// pane's selection and should not yank its view back (pass 0 otherwise).
list_scroll_apply :: proc(scroll: ^int, detached: ^f64, sel, rows, total: int, center: bool, last_input_at: f64) {
    if detached^ > 0 && last_input_at > detached^ {
        detached^ = 0
    }
    if detached^ > 0 {
        scroll^ = clamp(scroll^, 0, max(0, total - 1))
        return
    }
    scroll^ = list_scroll_target(scroll^, sel, rows, total, center)
}

// The keystroke timestamp an AUX pane should re-attach on, which is the app's only while
// that pane holds focus. Keys are delivered to the focused surface, so a keystroke in the
// editor cannot have moved the filetree's selection — and yanking a side pane's view back
// because you typed somewhere else is exactly the kind of action-at-a-distance the detach
// exists to avoid. Zero means "no input has reached me", which never re-attaches.
pane_input_at :: proc(a: ^App) -> f64 {
    return a.focus == .Aux ? a.last_input_at : 0
}

// How long a scroll step takes to settle (seconds). Short by design — spartan.
SCROLL_DUR :: 0.09

// Smooth-scroll bookkeeping shared by the editor, the diff viewer and the procmon list:
// re-aim `anim` at the integer target `to` when it changes, then return the floored top
// row + the sub-row pixel offset to shift drawing by (the partial top row is clipped by
// the pane scissor). `top` may be negative when over-scrolled past the first row — the
// diff centres edge hunks that way — so floor, not trunc.
//
// The re-aim is the load-bearing half and is why this cannot be a read-only query: it is
// what makes anim_active true, and app_next_wake (anim.odin) schedules the next frame off
// exactly that. A caller that changes `to` and does not reach here in the same frame
// leaves a WaitEvents loop with nothing to wake it, and the view freezes part-scrolled.
smooth_scroll :: proc(anim: ^Anim, to: int, now: f64, row_h: i32) -> (top: int, off: i32) {
    if f32(to) != anim.to {
        anim_start(anim, now, anim_value(anim, now), f32(to), SCROLL_DUR)
    }
    disp := anim_value(anim, now)
    top = int(disp)
    if disp < f32(top) { // int() truncates toward zero; step down for a true floor
        top -= 1
    }
    off = i32((disp - f32(top)) * f32(row_h))
    return
}
