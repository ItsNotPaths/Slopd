package main

import "vendor:glfw"

// Scoped animation for the redraw scheduler. An Anim is a one-shot scalar tween in
// seconds on the glfw.GetTime() clock: state that wants to move (smooth scroll, the
// Zen slide, the overlay fades) embeds one, starts it, and reads anim_value() each frame.
//
// The main loop polls app_next_wake() after every frame to decide how to wait: a
// non-negative result is a timeout (spin at the frame budget while something moves), a
// negative one means block until the next input event (0% idle when nothing is animating).
// An external wake_post (a PTY reader thread) unblocks either wait.

// The wait an animating frame asks for. 0 means "don't sleep, redraw now", which is right
// only where SwapBuffers itself blocks until the next refresh and so paces the animation:
// X11 at SwapInterval(1). On Wayland the swap must NOT be the pacer (see main.odin), so
// window_pacing_init sets a real per-frame budget here and the wait paces instead. Any
// budget floors the wait, so it is set just under a refresh period, never above one.
frame_budget: f64 = 0.0

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
    // Smooth scroll, both axes — one gate, because either tween moving is the same obligation
    // to redraw and the loop has no use for knowing which way the view is travelling.
    if eb := editor_current(&a.editor); anim_active(&eb.scroll_anim, now) || anim_active(&eb.hscroll_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    // The filetree pane's viewport tween, under EITHER presentation — the listing and the
    // browser share `tree.scroll_anim` because they share the viewport. Gated on the aux mode
    // for the overlays' reason: a tween nothing is drawing must not spin the loop, and a target
    // moved without a wake scheduled here leaves the view frozen part-scrolled (rule 9).
    if a.aux_mode == .FileTree && anim_active(&a.tree.scroll_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if a.view == .Zen && anim_active(&a.zen_anim, now) { // aux-pane slide
        wake = sched_min(wake, frame_budget)
    }
    if a.view == .Split && anim_active(&a.split_anim, now) { // the split widen/narrow
        wake = sched_min(wake, frame_budget)
    }
    // The two overlay fades, gated on the SAME predicates their draw sites use
    // (overlay_ui.odin) rather than a copy spelled out here: a copy drifts, and the loop
    // then wakes at vsync to animate a render that is refusing to draw.
    if switcher_shown(a) && anim_active(&a.switcher_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if chord_shown(a) && anim_active(&a.chord_anim, now) {
        wake = sched_min(wake, frame_budget)
    }
    if caret_shown(a) { // a blinking caret must wake at its next on/off edge
        wake = sched_min(wake, blink_next_edge(a, now))
    }
    // The command line's debounced preview: `:grep` runs its search once the typing pauses, and
    // without this wake the pause would have to be broken to see the result.
    if a.cl_preview.pending {
        wake = sched_min(wake, max(0, a.cl_preview.due - now))
    }
    if a.font_save_at > 0 { // wake to flush the debounced font-zoom save when it's due
        wake = sched_min(wake, max(0, a.font_save_at - now))
    }
    if a.focus == .Editor { // wake to re-stat the focused view pane for external edits
        wake = sched_min(wake, max(0, a.disk_poll_at - now))
    }
    // A drag held past a pane edge (drag.odin) — the only pointer path needing a wake: a
    // click or wheel notch ARRIVES as an event, but a drag parked off the pane bottom emits
    // none and must keep scrolling. Not frame_budget: this wake paces DRAG_SCROLL_S, not fps.
    if w := drag_next_wake(a, now); w >= 0 {
        wake = sched_min(wake, w)
    }
    return wake
}

// Folds a candidate deadline into the running soonest, treating -1 as "no deadline".
sched_min :: proc(wake, cand: f64) -> f64 {
    if wake < 0 {
        return cand
    }
    return min(wake, cand)
}

// The redraw gate the loop's wait is really gated on lives in wake/. Its sources are the
// input callbacks (input.odin, mouse.odin), the window callbacks main.odin registers, and
// the worker threads (terminal.odin, system/sysbus.odin). A deadline coming due is the
// other way through the gate, and app_next_wake owns those.

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
    if a.cl_active || filebrowser_path_live(a) {
        return true
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        return config_caret_live(a)
    }
    return panes_visible(a).editor // the editor and its caret are on screen
}

// Component-wise colour lerp, for fading UI in from the background colour.
lerp3 :: proc(from, to: [3]f32, s: f32) -> [3]f32 {
    return from + (to - from) * s
}
