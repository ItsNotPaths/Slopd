package main

import "base:runtime"
import "vendor:glfw"
import clay "../bindings/clay"
import "wake"
import "gfx"
import "ui"

// The GLFW callbacks and the wheel routing: everything about the pointer that has to know
// which pane it is over, and so belongs to the application rather than to the pane.

mouse_stand_down :: proc(a: ^App) {
    a.mouse.stood_down = true
}

mouse_wake :: proc(a: ^App) {
    a.mouse.stood_down = false
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

// The routing decision table, pinned by tests/mouse_test.odin. Hidden panes carry a zero rect,
// so rect_hit rejects them with no visibility check, and the pane rects never overlap.
wheel_target :: proc(a: ^App, lay: Layout, mx, my: i32) -> ui.Wheel_Target {
    if gfx.rect_hit(lay.editor, mx, my) {
        return a.main == .Image ? .Media : .Editor
    }
    if !gfx.rect_hit(lay.aux, mx, my) {
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
wheel_apply :: proc(a: ^App, target: ui.Wheel_Target, notch: int) {
    if notch == 0 {
        return
    }
    d := notch * ui.WHEEL_LINES
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
                ui.list_scroll_by(&a.wsfind.scroll, &a.wsfind.scroll_detached, d, now)
            } else {
                ui.list_scroll_by(&a.tree.scroll, &a.tree.scroll_detached, notch * ui.WHEEL_LINES_FILE, now)
            }
        case .Grep:
            ui.list_scroll_by(&a.grep.scroll, &a.grep.scroll_detached, d, now)
        case .Config:
            // With a dropdown open its options are spliced into the row list and ride along.
            ui.list_scroll_by(&a.config_pane.scroll, &a.config_pane.scroll_detached, d, now)
        case .Binds:
            ui.list_scroll_by(&a.binds_pane.scroll, &a.binds_pane.scroll_detached, d, now)
        case .Color, .Terminal:
        // wheel_target never routes these here.
        }
    }
}

// Positive is RIGHT. Only the text editor has a column axis: a list row, a terminal line and an
// image are no wider than their pane, so a sideways notch over one is nothing — and not a fall
// back to scrolling the page.
wheel_apply_h :: proc(a: ^App, target: ui.Wheel_Target, notch: int) {
    if notch == 0 || target != .Editor || len(a.editor.buffers) == 0 {
        return
    }
    buffer_hscroll_by(editor_current(&a.editor), notch * ui.WHEEL_COLS, glfw.GetTime())
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
        ui.drag_release(ctx_of(a))
        return
    }
    if !a.mouse_on {
        return
    }
    mouse_wake(a) // before parking, so the click acts with the cursor visible
    mouse_locate(a, window)
    m := &a.mouse
    now := glfw.GetTime()
    near := abs(m.x - m.click_x) <= ui.DOUBLE_CLICK_PX && abs(m.y - m.click_y) <= ui.DOUBLE_CLICK_PX
    m.click_count = near && now - m.click_at < ui.DOUBLE_CLICK_S ? m.click_count + 1 : 1
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


// Window coords -> framebuffer pixels; see trap 1 in the header.
@(private = "file")
mouse_to_fb :: proc(w: glfw.WindowHandle, x, y: f64) -> (i32, i32) {
    ww, wh := glfw.GetWindowSize(w)
    fw, fh := glfw.GetFramebufferSize(w)
    sx := ww > 0 ? f64(fw) / f64(ww) : 1
    sy := wh > 0 ? f64(fh) / f64(wh) : 1
    return i32(x * sx), i32(y * sy)
}
