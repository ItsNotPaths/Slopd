package main

import "base:runtime"
import "vendor:glfw"
import clay "../bindings/clay"
import "wake"

// GLFW pointer events -> mutations on App. The sibling of input.odin; everything reachable
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
//      converts once on the way in, from the two sizes rather than App.scale.
//   2. Routing resolves against the layout the last frame PAINTED (App.lay); a recomputed one
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
    // would read as never held via App.alt_held. Ctrl's one client is the terminal, which
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

mouse_stand_down :: proc(a: ^App) {
    a.mouse.stood_down = true
}

mouse_wake :: proc(a: ^App) {
    a.mouse.stood_down = false
}

// Whether hover may PAINT this frame. The hovered item is still resolved while stood down —
// it is the same call the click needs.
hover_shown :: proc(a: ^App) -> bool {
    return a.hover_on && !a.mouse.stood_down
}

// From the main loop, not the callbacks, so there is one writer and no path can strand a
// hidden cursor.
mouse_apply_cursor :: proc(a: ^App) {
    want := a.mouse_on && a.mouse.stood_down
    if want == a.mouse.cursor_hidden || a.window == nil {
        return
    }
    a.mouse.cursor_hidden = want
    glfw.SetInputMode(a.window, glfw.CURSOR, want ? glfw.CURSOR_HIDDEN : glfw.CURSOR_NORMAL)
}

// Clearing it here gives a press exactly one noun: the first pane to hit-test something owns
// it. So a pane must ask only when it actually hit something.
mouse_take_click :: proc(a: ^App) -> (count: int, ok: bool) {
    if !a.mouse_on || !a.mouse.click {
        return 0, false
    }
    a.mouse.click = false
    return a.mouse.click_count, true
}

// No count: a right press has one grade, and a menu re-opening on the second press of a run
// would flicker rather than mean anything.
mouse_take_rclick :: proc(a: ^App) -> bool {
    if !a.mouse_on || !a.mouse.rclick {
        return false
    }
    a.mouse.rclick = false
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

// The routing decision table, pinned by tests/mouse_test.odin. Hidden panes carry a zero rect,
// so rect_hit rejects them with no visibility check, and the pane rects never overlap.
wheel_target :: proc(a: ^App, lay: Layout, mx, my: i32) -> Wheel_Target {
    if rect_hit(lay.editor, mx, my) {
        return a.main == .Image ? .Media : .Editor
    }
    if !rect_hit(lay.aux, mx, my) {
        return .None
    }
    switch a.aux_mode {
    case .Terminal:
        return .Terminal
    case .FileTree, .Grep, .Config, .Binds:
        return .List
    case .Color:
        return .None
    }
    return .None
}

// Positive is DOWN (the callback normalises GLFW's inverted sign). A wheel scrolls the view,
// never a selection — and since both viewport policies re-derive the top, that needs a detach.
wheel_apply :: proc(a: ^App, target: Wheel_Target, notch: int) {
    if notch == 0 {
        return
    }
    d := notch * WHEEL_LINES
    switch target {
    case .None:
    case .Media:
        // A notch zooms about the pointer. The one branch that ignores `d`: WHEEL_LINES counts
        // rows and a picture has none, so media_wheel compounds the notch count into a factor.
        media_wheel(a, notch)
    case .Editor:
        if len(a.editor.buffers) == 0 {
            return
        }
        buffer_scroll_by(editor_current(&a.editor), d, glfw.GetTime())
    case .Terminal:
        t := term_current(a)
        if t == nil {
            return
        }
        if terminal_wheel_forwards(t, a.shift_held) {
            // The child asked for the pointer, so the notches are its scroll. One predicate
            // for both cases, or a click and a wheel disagree over `fzf --height`.
            for _ in 0 ..< abs(notch) {
                terminal_scroll_tui(t, notch < 0 ? -1 : 1)
            }
        } else {
            terminal_scroll_by(t, d) // the view, not the copy cursor
        }
    case .List:
        // No total: the callback has no font, no pane rect and no flattened row list, so it
        // cannot know where the end is. list_scroll_apply clamps next frame.
        now := glfw.GetTime()
        switch a.aux_mode {
        case .FileTree:
            // While the prompt is up its rows are the list on screen, so they are what moves.
            if wsfind_shown(a) {
                list_scroll_by(&a.wsfind.scroll, &a.wsfind.scroll_detached, d, now)
            } else {
                list_scroll_by(&a.tree.scroll, &a.tree.scroll_detached, notch * WHEEL_LINES_FILE, now)
            }
        case .Grep:
            list_scroll_by(&a.grep.scroll, &a.grep.scroll_detached, d, now)
        case .Config:
            // With a dropdown open its options are spliced into the row list and ride along.
            list_scroll_by(&a.config_pane.scroll, &a.config_pane.scroll_detached, d, now)
        case .Binds:
            list_scroll_by(&a.binds_pane.scroll, &a.binds_pane.scroll_detached, d, now)
        case .Color, .Terminal:
        // wheel_target never routes these here.
        }
    }
}

// Positive is RIGHT. Only the text editor has a column axis: a list row, a terminal line and an
// image are no wider than their pane, so a sideways notch over one is nothing — and not a fall
// back to scrolling the page.
wheel_apply_h :: proc(a: ^App, target: Wheel_Target, notch: int) {
    if notch == 0 || target != .Editor || len(a.editor.buffers) == 0 {
        return
    }
    buffer_hscroll_by(editor_current(&a.editor), notch * WHEEL_COLS, glfw.GetTime())
}

// A press or a wheel can be the first pointer event a window sees, since a cursor already over
// it reports no motion. Ask GLFW rather than route against (0, 0). No-op after any motion.
@(private = "file")
mouse_locate :: proc(a: ^App, window: glfw.WindowHandle) {
    if a.mouse.known {
        return
    }
    x, y := glfw.GetCursorPos(window)
    a.mouse.x, a.mouse.y = mouse_to_fb(window, x, y)
    a.mouse.known = true
}

// Window coords -> framebuffer pixels; see trap 1 in the header.
@(private = "file")
mouse_to_fb :: proc(w: glfw.WindowHandle, x, y: f64) -> (i32, i32) {
    ww, wh := glfw.GetWindowSize(w)
    fw, fh := glfw.GetFramebufferSize(w)
    sx := ww > 0 ? f64(fw) / f64(ww) : 1
    sy := wh > 0 ? f64(fh) / f64(wh) : 1
    return i32(x * sx), i32(y * sy)
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    // GLFW delivers a motion event when the window moves under a still cursor, and a workspace
    // switch would otherwise put the cursor back mid-keystroke.
    x, y := mouse_to_fb(window, xpos, ypos)
    if !a.mouse.known || x != a.mouse.x || y != a.mouse.y {
        mouse_wake(a)
        wake.mark() // a cursor that did not move draws nothing new
    }
    a.mouse.x, a.mouse.y = x, y
    a.mouse.known = true
}

// Held state plus a pending press for a pane to claim. The press is not routed here, but the
// click RUN is counted here, being a property of the input stream. Release is not a verb, only
// the end of a capture.
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    wake.mark()
    // A press and nothing else: no held state, no release verb, no run counting.
    if button == glfw.MOUSE_BUTTON_RIGHT {
        if action != glfw.PRESS || !a.mouse_on {
            return
        }
        mouse_wake(a)
        mouse_locate(a, window)
        a.mouse.rclick = true
        a.mouse.rclick_x, a.mouse.rclick_y = a.mouse.x, a.mouse.y
        return
    }
    if button != glfw.MOUSE_BUTTON_LEFT {
        return
    }
    a.mouse.down = action != glfw.RELEASE
    if !a.mouse.down {
        // Before the mouse_on gate: a drag switched off mid-gesture must still hear the button
        // come up, or the capture outlives the toggle. It only parks the end.
        drag_release(a)
        return
    }
    if !a.mouse_on {
        return
    }
    mouse_wake(a) // before parking, so the click acts with the cursor visible
    mouse_locate(a, window)
    m := &a.mouse
    now := glfw.GetTime()
    near := abs(m.x - m.click_x) <= DOUBLE_CLICK_PX && abs(m.y - m.click_y) <= DOUBLE_CLICK_PX
    m.click_count = near && now - m.click_at < DOUBLE_CLICK_S ? m.click_count + 1 : 1
    m.click_at, m.click_x, m.click_y = now, m.x, m.y
    m.click_shift = mods & glfw.MOD_SHIFT != 0
    m.click_ctrl = mods & glfw.MOD_CONTROL != 0
    m.click_alt = mods & glfw.MOD_ALT != 0
    m.click = true
}

// Wake, accumulate the sub-notch travel per axis, then route and apply whatever whole notches
// that produced. Both axes resolve against the same target. The wake is unconditional: a
// fractional event still means a hand on the device.
mouse_wheel :: proc(a: ^App, yoffset: f64, xoffset: f64 = 0) {
    if !a.mouse_on || (yoffset == 0 && xoffset == 0) {
        return
    }
    mouse_wake(a)
    target := wheel_target(a, a.lay, a.mouse.x, a.mouse.y)

    if yoffset != 0 {
        // GLFW's yoffset is positive for a scroll UP, so the sign flips once, here. int()
        // truncates toward zero, so the leftover carries the same sign.
        a.mouse.accum += -yoffset
        notch := int(a.mouse.accum)
        a.mouse.accum -= f64(notch)
        // Shift is the horizontal modifier, and the only way to reach the column axis on a
        // plain wheel. Editor only: over a terminal the chord already means "scroll my
        // scrollback rather than forward it" (terminal_wheel_forwards).
        if a.shift_held && target == .Editor {
            wheel_apply_h(a, target, notch)
        } else {
            wheel_apply(a, target, notch)
        }
    }

    // A tilt wheel or a trackpad's second direction. Positive is already RIGHT, so unlike y it
    // is not negated. A compositor folding Shift+wheel into this axis arrives with yoffset == 0,
    // so the two paths cannot double-apply one gesture.
    if xoffset != 0 {
        a.mouse.accum_x += xoffset
        notch := int(a.mouse.accum_x)
        a.mouse.accum_x -= f64(notch)
        wheel_apply_h(a, target, notch)
    }
}

// The GLFW half: locate the pointer if we never had a position, then spend the event.
scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || !a.mouse_on || (yoffset == 0 && xoffset == 0) {
        return
    }
    wake.mark()
    mouse_locate(a, window)
    mouse_wheel(a, yoffset, xoffset)
}

// So PointerOver / OnHover resolve during the declarations that follow. With the mouse off, or
// before the first event, it is parked off-screen rather than making every declaration check.
mouse_feed_clay :: proc(a: ^App) {
    if !a.mouse_on || !a.mouse.known {
        clay.SetPointerState({-1, -1}, false)
        return
    }
    clay.SetPointerState({f32(a.mouse.x), f32(a.mouse.y)}, a.mouse.down)
}
