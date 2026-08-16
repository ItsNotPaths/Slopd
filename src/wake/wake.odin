// The redraw gate, shared by the main package and the worker threads in system/.
// A returning wait is NOT "something happened": the display server wakes GLFW with
// traffic of its own — under Wayland a buffer release and a delete_id land for every
// frame we present — and a frame drawn for those chains straight into the next one,
// so the loop spins at the refresh rate with nothing on screen changing. The main
// loop's wait is gated on this flag instead, and only these marks set it.
package wake

import "base:intrinsics"
import "vendor:glfw"

@(private = "file")
flag: bool

// From the main thread — a GLFW callback that changed something worth drawing.
mark :: proc "contextless" () {
    intrinsics.atomic_store(&flag, true)
}

// From a worker thread (a PTY reader, the sysbus): the same mark, plus the PostEmptyEvent
// that breaks the wait it is sleeping in. Ordered mark-then-post so the loop cannot wake
// on the post and miss the mark.
post :: proc "contextless" () {
    mark()
    glfw.PostEmptyEvent()
}

// Take the mark, if there is one. Cleared on the way out so the frame it earns is drawn
// once; anything arriving during that frame re-marks and earns the next one.
take :: proc "contextless" () -> bool {
    return intrinsics.atomic_exchange(&flag, false)
}
