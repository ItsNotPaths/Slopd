package ui


// The pointer as the panes see it. The GLFW callbacks that fill this in are the product's
// (src/mouse_app.odin); what is here is what a pane asks. Everything reachable
// here has a key binding too, so `mouse: off` costs convenience, never capability.
//
// Mouse input is NOUN-FIRST: a wheel notch carries only a position and must resolve to a pane
// before there is a verb. wheel_target is that resolution and is pure, so the routing table is
// a headless unit test; wheel_apply / wheel_apply_h are the halves that write. Both axes
// resolve against the one target — a gesture is over one pane whichever way it travels.
//
// Four rules, the whole of the pointer's behaviour:
//   1. A wheel scrolls a VIEW — never a selection, a caret or focus — and it detaches.
//   2. A click acts on press and names ONE thing; an unclaimed press dies with the frame.
//   3. Focus follows the click, and only the click.
//   4. The keyboard outranks the pointer: any key that does something stands it down. A bare
//      modifier is excluded — Alt+click needs the cursor on screen to aim with.
//
// Two coordinate traps, handled at the callback:
//   1. GLFW reports WINDOW coords; Layout, Rect and Clay use FRAMEBUFFER pixels. mouse_to_fb
//      converts once on the way in, from the two sizes rather than the DPI scale.
//   2. Routing resolves against the layout the last frame PAINTED; a recomputed one
//      is elsewhere mid-animation, so a notch would land in a pane not yet on screen.

// The near-universal desktop default. Every target consumes "lines" natively.
WHEEL_LINES :: 3

// Except in the file panes, where a row is a whole entry — or a row of tiles — and three a
// notch throws the listing past what you were looking at.
WHEEL_LINES_FILE :: 1

// Shift + the wheel, a tilt wheel, or a trackpad's second direction. More than WHEEL_LINES
// because a column is about a third as wide as a line is tall.
WHEEL_COLS :: 6

// Near enough in time AND in space. The slop is in framebuffer pixels and small: a press that
// travelled is a drag, not a second click.
DOUBLE_CLICK_S :: 0.4
DOUBLE_CLICK_PX :: 4

// Mirrored from the GLFW callbacks; positions in framebuffer pixels. `known` guards the window
// between startup and the first motion, when (0, 0) would be a lie that hits the editor pane.
Mouse :: struct {
    x, y:  i32,
    known: bool,
    down:  bool, // left button held; fed to Clay and the drag machine
    // Undelivered wheel travel. A trackpad reports fractions of a notch, and rounding each
    // event up would make a gentle two-finger drag tear through the buffer. One per axis, so a
    // diagonal drift cannot leak sideways travel into the page.
    accum:   f64,
    accum_x: f64,

    // A left press waiting for a noun. A wheel resolves to a pane in the callback, but a click
    // resolves to a row or field, which only the pane's own declaration knows — so it is parked
    // here and the next frame's draw claims it.
    click:       bool, // a press is pending
    click_count: int, // presses in the current run; 3+ keeps counting
    click_at:    f64, // for the double-click window
    click_x:     i32, // and where it landed, for the slop
    click_y:     i32,

    // The keyboard has taken over: cursor hidden, nothing hovers. `cursor_hidden` only keeps
    // mouse_apply_cursor from calling into GLFW every frame.
    stood_down:    bool,
    cursor_hidden: bool,

    // Modifiers held AT THE PRESS: a press is claimed a frame later, so one released in between
    // would read as never held by whoever tracks the modifier. Ctrl's one client is the terminal, which
    // forwards it to a mouse-tracking TUI.
    click_shift: bool,
    click_ctrl:  bool,
    click_alt:   bool,

    // A right press waiting for a pane to open a menu on. Keeps its own position: the menu goes
    // where the press landed, and the pointer has a frame to move off before a pane claims it.
    rclick:   bool,
    rclick_x: i32,
    rclick_y: i32,
}

// --- standing the pointer down while the keyboard is in use --- A keystroke hides the cursor
// and stops it hovering until any pointer event wakes it. Suppresses hover, never a click,
// hence the gate in hover_shown rather than a hit test.



// Whether hover may PAINT this frame. The hovered item is still resolved while stood down —
// it is the same call the click needs.
hover_shown :: proc(u: UI_Ctx) -> bool {
    return u.hover_on && !u.mouse.stood_down
}


// Clearing it here gives a press exactly one noun: the first pane to hit-test something owns
// it. So a pane must ask only when it actually hit something.
mouse_take_click :: proc(u: UI_Ctx) -> (count: int, ok: bool) {
    if !u.mouse_on || !u.mouse.click {
        return 0, false
    }
    u.mouse.click = false
    return u.mouse.click_count, true
}

// No count: a right press has one grade, and a menu re-opening on the second press of a run
// would flicker rather than mean anything.
mouse_take_rclick :: proc(u: UI_Ctx) -> bool {
    if !u.mouse_on || !u.mouse.rclick {
        return false
    }
    u.mouse.rclick = false
    return true
}

// The aux modes are split out rather than lumped together: each scrolls a different thing — a
// view, a selection, or a child process's scrollback.
Wheel_Target :: enum {
    None, // the status strip, the gutter, off-window
    Editor,
    Media, // the zoom — the one target that is not a scroll
    Terminal,
    List, // filetree / grep / config
}










