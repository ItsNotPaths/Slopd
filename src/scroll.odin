package main

// The list panes' viewport policy — the flat-row twin of buffer_scroll_target
// (buffer.odin): a list tracks its SELECTION as the editor tracks its caret, under the one
// `scroll_mode` config. Lists have no folds, so this walks plain rows, not visible ones.
//   FOLLOW (default) — `top` holds still while `sel` is inside the viewport, then moves the
//     minimum. Top is kept within the list, so a shrinking list never strands the view on
//     blank rows.
//   MIDDLE — `sel` pinned to the middle row, so Up/Down move the LIST under it. Clamped at
//     row 0; at the end it keeps centring and runs past the last row, as the editor does.
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

// How many rows of `row_h` a viewport `view_h` tall actually SHOWS when its top sits `off`
// pixels into the first one: ceil((off + view_h) / row_h).
//
// **Not the same number as the viewport policy's.** `list_scroll_apply` counts the WHOLE rows
// that fit, because a selection has to be entirely visible to count as visible. The declaration
// counts the rows the region touches, which is one or two more — and using the policy's number
// there is a gap you can see: a region 270px tall showing 56px rows fits 4, leaving 46px of the
// fifth on screen and undeclared. Every list pane wants this; the two file panes ask for it.
list_visible_rows :: proc(view_h, off, row_h: i32) -> int {
    if row_h <= 0 || view_h <= 0 {
        return 0
    }
    return int((max(0, off) + view_h + row_h - 1) / row_h)
}

// Move a DETACHED list view by `delta` rows and stamp it — the wheel's entry point.
// Deliberately takes no total: the caller is a GLFW callback with no font, pane rect or
// row list, so `list_scroll_apply` clamps next frame, bounding overshoot at one notch.
list_scroll_by :: proc(scroll: ^int, detached: ^f64, delta: int, now: f64) {
    scroll^ += delta
    detached^ = now
}

// Per-frame write: a keystroke postdating the stamp re-attaches; while detached only bounds
// apply, so neither policy runs and the wheel acts alike in both `scroll_mode`s (MIDDLE would
// re-derive top from the selection). Pass `last_input_at` only while this pane HOLDS FOCUS.
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

// The keystroke timestamp an AUX pane should re-attach on — the app's, only while that
// pane holds focus. Zero means "no input has reached me" and never re-attaches.
pane_input_at :: proc(a: ^App) -> f64 {
    return a.focus == .Aux ? a.last_input_at : 0
}

// How long a scroll step takes to settle (seconds). Short by design — spartan.
SCROLL_DUR :: 0.09

// Re-aim `anim` at `to`, then return the floored top row + sub-row pixel offset; `top` may go
// negative when over-scrolled past row 0 (the diff centres edge hunks), so floor. **The re-aim
// sets anim_active**: change `to` without reaching here the same frame and it freezes mid-scroll.
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

// The horizontal twin: re-aim `anim` at column `to`, then return how many PIXELS the text
// column is currently shifted left by. No floor/remainder split — a row grid has to be walked
// row by row, but a monospace column is pure arithmetic, so the whole answer is one offset
// every x in the pane subtracts. The same re-aim rule applies: reach here every frame the
// target moves, or the view freezes part-scrolled.
smooth_hscroll :: proc(anim: ^Anim, to: int, now: f64, cw: f32) -> f32 {
    if f32(to) != anim.to {
        anim_start(anim, now, anim_value(anim, now), f32(to), SCROLL_DUR)
    }
    return anim_value(anim, now) * cw
}
