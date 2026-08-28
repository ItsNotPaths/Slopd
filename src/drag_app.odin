package main
import "gfx"

// The two answers a drag needs from the application: which pane it is running off the edge of,
// and when the autoscroll wants the next frame.

// Is the drag pulling the view past an edge right now? Asks `a.lay`, the layout the last
// frame painted (mouse.odin, trap 2). The scheduler calls this too, which keeps the
// autoscroll wake off a render->state backchannel.
drag_autoscrolling :: proc(a: ^App) -> bool {
    r: gfx.Rect
    switch a.drag.kind {
    case .None, .Split, .Media_Pan, .Field_Text, .Color_Slider:
        // No view to run off: the divider has none, a media pan already moves the surface
        // pixel-for-pixel, a field walks its own window, a colour rail is bounded.
        return false
    case .Editor_Text:
        r = a.lay.editor
    case .Terminal_Sel:
        r = a.lay.aux
    }
    if r.h <= 0 {
        return false
    }
    return a.mouse.y < r.y || a.mouse.y >= r.y + r.h
}

// The wait an autoscrolling drag asks the loop for, or -1. The one pointer path needing a
// pump: a drag held still past an edge produces no events but must keep scrolling.
drag_next_wake :: proc(a: ^App, now: f64) -> f64 {
    if !drag_autoscrolling(a) {
        return -1
    }
    return max(0, a.drag.scroll_at - now)
}
