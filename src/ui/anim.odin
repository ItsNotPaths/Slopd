package ui

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
caret_blink_on :: proc(u: UI_Ctx, now: f64) -> bool {
    return int((now - u.blink_base^) / BLINK_HALF) % 2 == 0
}



// For fading UI in from the background colour.
lerp3 :: proc(from, to: [3]f32, s: f32) -> [3]f32 {
    return from + (to - from) * s
}
