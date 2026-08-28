package ui

import "../gfx"

// What a pane needs to draw itself and to answer "is the pointer on me": the look, the
// pointer, and the clock. Nothing else.
//
// Passed BY VALUE. The scalars are a read-only snapshot of the frame; the pane state a helper
// must change (a consumed click, a live drag) is reached through the pointers, so a copy is
// never stale where it matters.
//
// The point of it is what it leaves out. A proc taking this cannot reach the application, so
// the pane chrome is shared with any front-end while the actions it fires stay product code.
UI_Ctx :: struct {
    theme:         ^gfx.Theme,
    mouse:         ^Mouse, // a helper may consume a click through it
    drag:          ^Drag,
    blink_base:    ^f64, // the last-input time the blink is measured from; a drag re-bases it
    focus:         Focus,
    scroll_mode:   Scroll_Mode,
    face:          gfx.Face, // sizes come from the line box, never from a DPI scale
    mouse_on:      bool,
    hover_on:      bool,
    last_input_at: f64,
}

// "Does this path have unsaved edits somewhere?"
//
// A file pane marks such a row, but the ring that answers belongs to the product, not to the
// pane. A front-end with no open-file ring leaves `ask` nil and nothing is marked, which is why
// this is a question rather than a flag on the entry.
Path_Dirty :: struct {
    ask:  proc(user: rawptr, path: string) -> bool,
    user: rawptr,
}

path_is_dirty :: proc(d: Path_Dirty, path: string) -> bool {
    return d.ask != nil && d.ask(d.user, path)
}

