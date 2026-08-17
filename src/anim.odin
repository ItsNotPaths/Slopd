package main

import "vendor:glfw"

// An Anim is a one-shot scalar tween on the glfw.GetTime() clock: state that moves embeds
// one, starts it, and reads anim_value() each frame.
//
// The main loop polls app_next_wake() after every frame: a non-negative result is a timeout,
// a negative one blocks until the next input event. An external wake.post unblocks either.

// The wait an animating frame asks for. 0 means redraw now, right only where SwapBuffers
// itself blocks until the next refresh (X11 at SwapInterval(1)). On Wayland the swap must not
// pace, so window_pacing_init sets a real budget here — just under a refresh period.
frame_budget: f64 = 0.0

// Seconds.
BLINK_HALF :: 0.5 // caret on for this long, then off for this long
ZEN_DUR :: 0.12 // aux-pane slide in/out
SPLIT_DUR :: 0.12 // editor/aux split adjustment (Alt+[ / Alt+]), zen-paced
SWITCHER_DUR :: 0.10 // terminal switcher fade-in

Anim :: struct {
    start:    f64, // glfw.GetTime() when it began
    duration: f64, // <= 0 means inactive, and anim_value returns `to`
    from, to: f32,
}

anim_start :: proc(an: ^Anim, now: f64, from, to: f32, duration: f64) {
    an^ = Anim{start = now, duration = duration, from = from, to = to}
}

anim_active :: proc(an: ^Anim, now: f64) -> bool {
    return an.duration > 0 && now < an.start + an.duration
}

// Clamped to `to` once finished, and for an inactive tween.
anim_value :: proc(an: ^Anim, now: f64) -> f32 {
    if an.duration <= 0 {
        return an.to
    }
    s := clamp(f32((now - an.start) / an.duration), 0, 1)
    s = 1 - (1 - s) * (1 - s) * (1 - s) // ease-out cubic
    return an.from + (an.to - an.from) * s
}

// -1 to block until the next event, or seconds to wake by. Each animated subsystem reports
// here; the soonest deadline wins.
app_next_wake :: proc(a: ^App, now: f64) -> f64 {
    wake := f64(-1)
    // Both axes under one gate: either tween moving is the same obligation to redraw.
    if eb := editor_current(&a.editor); anim_active(&eb.scroll_anim, now) || anim_active(&eb.hscroll_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    // Both presentations share `tree.scroll_anim` because they share the viewport. Gated on
    // the aux mode: a tween nothing is drawing must not spin the loop.
    if a.aux_mode == .FileTree && anim_active(&a.tree.scroll_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    // A tween of its own, gated on the same predicate its draw site uses.
    if wsfind_shown(a) && anim_active(&a.wsfind.scroll_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if a.view == .Zen && anim_active(&a.zen_anim, now) { // aux-pane slide
        wake = sched_min(wake, frame_budget)
    }
    if a.view == .Split && anim_active(&a.split_anim, now) { // the split widen/narrow
        wake = sched_min(wake, frame_budget)
    }
    // Gated on the same predicates their draw sites use (overlay_ui.odin): a copy would drift,
    // and the loop would wake at vsync to animate a render refusing to draw.
    if switcher_shown(a) && anim_active(&a.switcher_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if chord_shown(a) && anim_active(&a.chord_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if caret_shown(a) { // wake at the next on/off edge
        wake = sched_min(wake, blink_next_edge(a, now))
    }
    // `:grep` runs its search once typing pauses; without this the pause would have to be
    // broken to see the result.
    if a.cl_preview.pending {
        wake = sched_min(wake, max(0, a.cl_preview.due - now))
    }
    if a.font_save_at > 0 { // flush the debounced font-zoom save
        wake = sched_min(wake, max(0, a.font_save_at - now))
    }
    if a.focus == .Editor { // re-stat the focused view pane for external edits
        wake = sched_min(wake, max(0, a.disk_poll_at - now))
    }
    // The only pointer path needing a wake: a drag parked off the pane bottom emits no events
    // and must keep scrolling. Paces DRAG_SCROLL_S, not fps.
    if w := drag_next_wake(a, now); w >= 0 {
        wake = sched_min(wake, w)
    }
    return wake
}

// -1 means "no deadline".
sched_min :: proc(wake, cand: f64) -> f64 {
    if wake < 0 {
        return cand
    }
    return min(wake, cand)
}

// The redraw gate itself lives in wake/; its sources are the input and window callbacks and
// the worker threads. A deadline coming due is the other way through, and this file owns those.

// Measured from the last input, so the caret is solid the instant you type, then blinks.
caret_blink_on :: proc(a: ^App, now: f64) -> bool {
    return int((now - a.blink_base) / BLINK_HALF) % 2 == 0
}

// The wait the scheduler needs to flip the caret.
blink_next_edge :: proc(a: ^App, now: f64) -> f64 {
    k := int((now - a.blink_base) / BLINK_HALF) + 1
    return a.blink_base + f64(k) * BLINK_HALF - now
}

// So the loop knows to keep blinking.
caret_shown :: proc(a: ^App) -> bool {
    if a.cl_active || filebrowser_path_live(a) || wsfind_live(a) {
        return true
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        return config_caret_live(a)
    }
    return panes_visible(a).editor
}

// For fading UI in from the background colour.
lerp3 :: proc(from, to: [3]f32, s: f32) -> [3]f32 {
    return from + (to - from) * s
}
