package ui

// buffer_scroll_target's flat-row twin: a list tracks its selection as the editor tracks its
// caret, under the one `scroll_mode` config. No folds, so plain rows.
//   Follow — `top` holds still while `sel` is inside the viewport, then moves the minimum.
//     Kept within the list, so a shrinking one never strands the view on blank rows.
//   Middle — `sel` pinned to the middle row. Clamped at row 0; at the end it keeps centring.
// Pure: the caller passes its stored top and stores the result back.
list_scroll_target :: proc(top, sel, rows, total: int, center: bool) -> int {
    if rows <= 0 || total <= 0 {
        return 0
    }
    s := clamp(sel, 0, total - 1)
    if center {
        return max(0, s - rows / 2)
    }
    // Clamp before comparing: the list may have shrunk since `top` was stored.
    t := clamp(top, 0, max(0, total - rows))
    if s < t {
        return s
    }
    if s >= t + rows {
        return s - rows + 1 // sel onto the bottom row
    }
    return t
}

// ceil((off + view_h) / row_h) — the rows a region TOUCHES. Not the viewport policy's number,
// which counts the WHOLE rows that fit because a selection must be entirely visible. Using the
// policy's here leaves a visible gap: 270px of 56px rows fits 4, with 46px of the fifth on
// screen and undeclared.
list_visible_rows :: proc(view_h, off, row_h: i32) -> int {
    if row_h <= 0 || view_h <= 0 {
        return 0
    }
    return int((max(0, off) + view_h + row_h - 1) / row_h)
}

// The wheel's entry point. No total: the caller is a GLFW callback with no font, pane rect or
// row list, so list_scroll_apply clamps next frame, bounding overshoot at one notch.
list_scroll_by :: proc(scroll: ^int, detached: ^f64, delta: int, now: f64) {
    scroll^ += delta
    detached^ = now
}

// A keystroke postdating the stamp re-attaches; while detached only bounds apply, so neither
// policy runs. Pass `last_input_at` only while this pane holds focus.
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

// The app's, only while the aux pane holds focus. Zero never re-attaches.
pane_input_at :: proc(u: UI_Ctx) -> f64 {
    return u.focus == .Aux ? u.last_input_at : 0
}

// Seconds for a scroll step to settle.
SCROLL_DUR :: 0.09

// Re-aim at `to`, then return the floored top row plus sub-row pixel offset. `top` may go
// negative when over-scrolled past row 0, hence the floor. The re-aim is what sets anim_active:
// change `to` without reaching here the same frame and it freezes mid-scroll.
smooth_scroll :: proc(anim: ^Anim, to: int, now: f64, row_h: i32) -> (top: int, off: i32) {
    if f32(to) != anim.to {
        anim_start(anim, now, anim_value(anim, now), f32(to), SCROLL_DUR)
    }
    disp := anim_value(anim, now)
    top = int(disp)
    if disp < f32(top) { // int() truncates toward zero
        top -= 1
    }
    off = i32((disp - f32(top)) * f32(row_h))
    return
}

// The horizontal twin, returning the pixels the text column is shifted left by. No
// floor/remainder split: a monospace column is pure arithmetic, so one offset covers it. Same
// re-aim rule — reach here every frame the target moves.
smooth_hscroll :: proc(anim: ^Anim, to: int, now: f64, cw: f32) -> f32 {
    if f32(to) != anim.to {
        anim_start(anim, now, anim_value(anim, now), f32(to), SCROLL_DUR)
    }
    return anim_value(anim, now) * cw
}
