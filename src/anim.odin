package main

// Scoped animation for the redraw scheduler. An Anim is a one-shot scalar tween in
// seconds on the glfw.GetTime() clock: state that wants to move (smooth scroll, the
// Zen slide, a bell flash) embeds one, starts it, and reads anim_value() each frame.
//
// The main loop polls app_next_wake() after every frame to decide how to wait: a
// non-negative result is a timeout (spin at vsync while something moves), a negative
// one means block until the next input event (0% idle when nothing is animating).
// This keeps the event-driven loop adaptive — the best of both — and an external
// glfw.PostEmptyEvent (a future PTY reader thread) unblocks either wait.
//
// Mechanism only for now: nothing starts an Anim yet, so app_next_wake always says
// "block" and the editor idles exactly as before. Smooth scroll is the first consumer.

// The wait an animating frame asks for: 0 means "don't sleep, redraw now" so SwapBuffers
// at SwapInterval(1) is the sole pacer and animations run at the full refresh rate (e.g.
// 240fps on a 240Hz panel). A non-zero budget here would floor the wait and cap animation
// fps below vsync — at 1/120 the loop missed every other 240Hz edge, halving smooth-scroll
// to ~120fps. (If a compositor ever leaves SwapBuffers non-blocking, this becomes a busy
// spin while animating — acceptable, since an animating frame wants to redraw regardless.)
VSYNC_PACED :: 0.0

// Animation timings (seconds) — short by design, in keeping with the spartan ethos.
BLINK_HALF :: 0.5 // caret on for this long, then off for this long
ZEN_DUR :: 0.12 // aux-pane slide in/out
SPLIT_DUR :: 0.12 // editor/aux split adjustment (Alt+[ / Alt+]), zen-paced
SWITCHER_DUR :: 0.10 // terminal switcher fade-in

Anim :: struct {
    start:    f64, // glfw.GetTime() when it began
    duration: f64, // seconds; <= 0 means inactive (anim_value returns `to`)
    from, to: f32,
}

anim_start :: proc(an: ^Anim, now: f64, from, to: f32, duration: f64) {
    an^ = Anim{start = now, duration = duration, from = from, to = to}
}

anim_active :: proc(an: ^Anim, now: f64) -> bool {
    return an.duration > 0 && now < an.start + an.duration
}

// Eased value at `now`, clamped to `to` once finished (and for an inactive tween).
anim_value :: proc(an: ^Anim, now: f64) -> f32 {
    if an.duration <= 0 {
        return an.to
    }
    s := clamp(f32((now - an.start) / an.duration), 0, 1)
    s = 1 - (1 - s) * (1 - s) * (1 - s) // ease-out cubic: fast in, settles softly
    return an.from + (an.to - an.from) * s
}

// The wait timeout the main loop should use after the current frame: -1 to block
// until the next event, or seconds to wake by while something is animating. Each
// animated subsystem reports here; the soonest deadline wins.
app_next_wake :: proc(a: ^App, now: f64) -> f64 {
    wake := f64(-1)
    if anim_active(&editor_current(&a.editor).scroll_anim, now) { // smooth scroll
        wake = sched_min(wake, VSYNC_PACED)
    }
    if a.view == .Zen && anim_active(&a.zen_anim, now) { // aux-pane slide
        wake = sched_min(wake, VSYNC_PACED)
    }
    if a.view == .Split && anim_active(&a.split_anim, now) { // the split widen/narrow
        wake = sched_min(wake, VSYNC_PACED)
    }
    if a.alt_held && a.aux_mode == .Terminal && anim_active(&a.switcher_anim, now) { // switcher fade
        wake = sched_min(wake, VSYNC_PACED)
    }
    if a.ctrl_held && a.focus == .Aux && a.aux_mode == .FileTree && anim_active(&a.chord_anim, now) { // chord bar fade
        wake = sched_min(wake, VSYNC_PACED)
    }
    if a.aux_mode == .Procmon && anim_active(&a.procmon.scroll_anim, now) { // list smooth scroll
        wake = sched_min(wake, VSYNC_PACED)
    }
    if caret_shown(a) { // a blinking caret must wake at its next on/off edge
        wake = sched_min(wake, blink_next_edge(a, now))
    }
    if a.font_save_at > 0 { // wake to flush the debounced font-zoom save when it's due
        wake = sched_min(wake, max(0, a.font_save_at - now))
    }
    if a.focus == .Editor { // wake to re-stat the focused view pane for external edits
        wake = sched_min(wake, max(0, a.disk_poll_at - now))
    }
    // Bell flash reports here once libvterm gives us a bell to flash on.
    return wake
}

// Folds a candidate deadline into the running soonest, treating -1 as "no deadline".
sched_min :: proc(wake, cand: f64) -> f64 {
    if wake < 0 {
        return cand
    }
    return min(wake, cand)
}

// Caret blink: on for BLINK_HALF, off for BLINK_HALF, measured from the last input
// (a.blink_base) so the caret is solid the instant you type or move, then blinks.
caret_blink_on :: proc(a: ^App, now: f64) -> bool {
    return int((now - a.blink_base) / BLINK_HALF) % 2 == 0
}

// Seconds until the next blink edge — the wait the scheduler needs to flip the caret.
blink_next_edge :: proc(a: ^App, now: f64) -> f64 {
    k := int((now - a.blink_base) / BLINK_HALF) + 1
    return a.blink_base + f64(k) * BLINK_HALF - now
}

// Whether a caret is on screen this frame (so the loop knows to keep blinking it).
caret_shown :: proc(a: ^App) -> bool {
    if a.cl_active {
        return true
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        cp := &a.config_pane
        // Only the search box carries a caret now (settings are dropdowns); and not
        // while a dropdown is open over it.
        return config_pane_is_search(cp.sel) && cp.open == .None
    }
    if a.focus == .Aux && a.aux_mode == .Procmon {
        return a.procmon.filtering // only the filter bar carries a caret
    }
    return panes_visible(a).editor // the editor and its caret are on screen
}

// Component-wise colour lerp, for fading UI in from the background colour.
lerp3 :: proc(from, to: [3]f32, s: f32) -> [3]f32 {
    return from + (to - from) * s
}
