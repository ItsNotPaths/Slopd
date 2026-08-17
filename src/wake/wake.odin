// The redraw gate, shared with the worker threads in system/. A returning wait is not
// "something happened": the display server wakes GLFW with traffic of its own — under Wayland
// a buffer release per presented frame — and drawing for those spins the loop at the refresh
// rate with nothing changing. The wait is gated on this flag instead.
package wake

import "base:intrinsics"
import "vendor:glfw"

@(private = "file")
flag: bool

// From the main thread: a GLFW callback changed something worth drawing.
mark :: proc "contextless" () {
    intrinsics.atomic_store(&flag, true)
}

// From a worker thread: the same mark, plus the PostEmptyEvent that breaks the wait. Ordered
// mark-then-post, so the loop cannot wake on the post and miss the mark.
post :: proc "contextless" () {
    mark()
    glfw.PostEmptyEvent()
}

// Cleared on the way out, so the frame it earns is drawn once; anything arriving during that
// frame re-marks and earns the next.
take :: proc "contextless" () -> bool {
    return intrinsics.atomic_exchange(&flag, false)
}
