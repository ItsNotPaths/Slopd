package clock

import "core:time"

// Monotonic seconds since the first time anything asked. Every tween, caret blink, scroll ease
// and wake deadline in the program is measured on this one number.
//
// Monotonic and not the wall clock, because an NTP step or a daylight-saving jump would move
// every animation mid-flight and could hand a deadline a time in the past. Nothing here needs to
// know what time it is, only how much later this is than that.
//
// It was glfw.GetTime(), which is the same number from a library the terminal front-end never
// initialises.

@(private)
start: time.Tick

// Lazily based on the first call, so no front-end has to remember to start the clock. The branch
// costs nothing against the work a frame does either side of it.
now :: proc "contextless" () -> f64 {
    if start._nsec == 0 {
        start = time.tick_now()
    }
    return time.duration_seconds(time.tick_since(start))
}
