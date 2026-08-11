package main

import "base:runtime"
import "vendor:glfw"
import clay "../bindings/clay"

// Mouse: GLFW pointer events -> mutations on App. The sibling of input.odin, which owns
// the keyboard; everything reachable here has a key binding too, so `mouse: off` costs
// convenience, never capability.
//
// Mouse input is NOUN-FIRST: a key names its verb outright, while a wheel notch carries only
// a position and must resolve to a pane before there is a verb at all. wheel_target is that
// resolution and is PURE, so the routing table is a headless unit test (tests/mouse_test.odin);
// wheel_apply is the only half that writes.
//
// Two coordinate traps, handled at the callback so nothing downstream repeats them:
//   1. GLFW reports WINDOW (logical) coords; Layout, Rect and Clay use FRAMEBUFFER pixels.
//      mouse_to_fb converts once on the way in, deriving the ratio from the two sizes rather
//      than from App.scale — only the former is the conversion by definition.
//   2. Routing resolves against the layout the last frame PAINTED (App.lay); mid-animation a
//      recomputed layout is elsewhere, so a notch would land in a pane not yet on screen.

// Lines moved per wheel notch — the near-universal desktop default. Every routing target
// consumes "lines" natively, so one constant rather than a per-pane table.
WHEEL_LINES :: 3

// What makes two presses a double-click: near enough in time AND in space. The slop is in
// framebuffer pixels and deliberately small — a press that travelled is a drag, not a second
// click — while 0.4s is the common desktop default.
DOUBLE_CLICK_S :: 0.4
DOUBLE_CLICK_PX :: 4

// Pointer state, mirrored from the GLFW callbacks. Positions are framebuffer pixels (see
// the header); `known` guards the window between startup and the first motion event, when
// there is genuinely no position and (0, 0) would be a lie that hits the editor pane.
Mouse :: struct {
    x, y:  i32,
    known: bool,
    down:  bool, // left button held; fed to Clay and the drag machine
    // Undelivered wheel travel. A wheel reports whole notches, a trackpad fractions of one,
    // and rounding each event up to a notch would make a gentle two-finger drag tear through
    // the buffer. Carrying the remainder gets both right without a device check.
    accum: f64,

    // A left press waiting for a noun. A wheel notch resolves to a PANE in the callback, but a
    // click resolves to a ROW or field, and only the pane's own declaration knows what is under
    // the pointer — so the press is parked here and the next frame's draw claims it.
    click:       bool, // a press is pending
    click_count: int, // presses in the current run: 1 single, 2 double, 3+ keeps counting
    click_at:    f64, // glfw time of the press, for the double-click window
    click_x:     i32, // and where it landed, for the slop
    click_y:     i32,

    // The keyboard has taken over: cursor hidden, nothing hovers. `cursor_hidden` is only
    // bookkeeping, to keep mouse_apply_cursor from calling into GLFW every frame.
    stood_down:    bool,
    cursor_hidden: bool,

    // The modifiers held AT THE PRESS, from GLFW's own `mods`: a press is claimed a frame
    // later, so a modifier released in between would read as never held via App.alt_held etc.
    // Ctrl has one client — the terminal forwards it to a mouse-tracking TUI as MOD_CTRL.
    click_shift: bool,
    click_ctrl:  bool,
    click_alt:   bool,
}

// --- standing the pointer down while the keyboard is in use ---
// A keystroke hides the cursor and stops it hovering until any pointer event (a wheel counts)
// wakes it. **Suppresses HOVER, never a click** — hence the gate in hover_shown, not a hit test.

// A key that does something: hide the pointer and stop it answering.
mouse_stand_down :: proc(a: ^App) {
    a.mouse.stood_down = true
}

// A pointer event: the hand is back on the mouse, so bring it back.
mouse_wake :: proc(a: ^App) {
    a.mouse.stood_down = false
}

// Whether hover may PAINT this frame — the config toggle and the stand-down state in one
// place, since every pane needs both. The hovered item is still RESOLVED while stood down:
// it is the same call the click needs, and dropping it would force a re-hit-test on wake.
hover_shown :: proc(a: ^App) -> bool {
    return a.hover_on && !a.mouse.stood_down
}

// Push the cursor's visibility to GLFW once per frame. From the main loop, not the callbacks,
// so there is a single writer and no path can strand a hidden cursor — turning `mouse: off`
// while stood down reveals it next frame, the desired state simply being false again.
mouse_apply_cursor :: proc(a: ^App) {
    want := a.mouse_on && a.mouse.stood_down
    if want == a.mouse.cursor_hidden || a.window == nil {
        return
    }
    a.mouse.cursor_hidden = want
    glfw.SetInputMode(a.window, glfw.CURSOR, want ? glfw.CURSOR_HIDDEN : glfw.CURSOR_NORMAL)
}

// Claim the pending click. Clearing it here is what gives a press exactly ONE noun: the first
// pane to hit-test something owns it, and every later asker sees nothing — so a pane must ask
// only when it actually hit something. An unclaimed press is dropped at the end of the frame.
mouse_take_click :: proc(a: ^App) -> (count: int, ok: bool) {
    if !a.mouse_on || !a.mouse.click {
        return 0, false
    }
    a.mouse.click = false
    return a.mouse.click_count, true
}

// Where a wheel notch lands. The aux modes are split out rather than lumped as "the aux
// pane" because each scrolls a categorically different thing: a view, a selection, or a
// child process's own scrollback.
Wheel_Target :: enum {
    None, // the status strip, the inter-pane gutter, off-window
    Editor, // editor pane, Text surface: the buffer's viewport
    Media, // editor pane, Image surface: the zoom — the one target that is not a scroll
    Terminal,
    List, // filetree / grep / config
}

// Which target a wheel notch at (mx, my) belongs to. Pure — the routing decision table, pinned
// by tests/mouse_test.odin. Hidden panes carry a zero rect, so rect_hit rejects them with no
// visibility check, and the editor/aux rects never overlap, so probe order is free.
wheel_target :: proc(a: ^App, lay: Layout, mx, my: i32) -> Wheel_Target {
    if rect_hit(lay.editor, mx, my) {
        return a.main == .Image ? .Media : .Editor
    }
    if !rect_hit(lay.aux, mx, my) {
        return .None // the status strip, the gutter, or outside the window entirely
    }
    switch a.aux_mode {
    case .Terminal:
        return .Terminal
    case .FileTree, .Grep, .Config:
        return .List
    }
    return .None
}

// Apply `notch` wheel notches to `target`. Positive is DOWN / forward (the callback normalises
// GLFW's inverted sign). **A wheel scrolls the VIEW, never a selection** — and since both
// viewport policies re-derive the top from what they follow, that needs the DETACH.
wheel_apply :: proc(a: ^App, target: Wheel_Target, notch: int) {
    if notch == 0 {
        return
    }
    d := notch * WHEEL_LINES
    switch target {
    case .None:
    case .Media:
        // The one target that does not scroll: over an image a notch ZOOMS, about the
        // pointer. The only branch that ignores `d` — WHEEL_LINES counts rows and a picture
        // has none — so the notch count goes to media_wheel, which compounds it into a factor.
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
            // The child asked for the pointer (mouse reports, the alt screen, or both), so the
            // notches are its scroll. Which of the two only picks the ENCODING, one level down.
            // One predicate for both, or a click and a wheel disagree over `fzf --height`.
            for _ in 0 ..< abs(notch) {
                terminal_scroll_tui(t, notch < 0 ? -1 : 1)
            }
        } else {
            terminal_scroll_by(t, d) // the view, not the copy cursor
        }
    case .List:
        // No total is passed: the callback has no font, no pane rect and — for grep and
        // config — no flattened row list, so it cannot know where the end is.
        // list_scroll_apply clamps next frame, bounding the overshoot at one notch.
        now := glfw.GetTime()
        switch a.aux_mode {
        case .FileTree:
            list_scroll_by(&a.tree.scroll, &a.tree.scroll_detached, d, now)
        case .Grep:
            list_scroll_by(&a.grep.scroll, &a.grep.scroll_detached, d, now)
        case .Config:
            // Including with a dropdown open: its options are spliced into the row list, so
            // scrolling the view carries them along.
            list_scroll_by(&a.config_pane.scroll, &a.config_pane.scroll_detached, d, now)
        case .Terminal:
        // Not a list pane; wheel_target never routes it here.
        }
    }
}

// GLFW cursor position (window coords) -> framebuffer pixels; see trap 1 in the header.
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
    // A motion event that does not actually move the pointer must not wake it: GLFW delivers
    // one when the window moves under a still cursor, and a workspace switch or a tiling
    // reflow would otherwise put the cursor back mid-keystroke.
    x, y := mouse_to_fb(window, xpos, ypos)
    if !a.mouse.known || x != a.mouse.x || y != a.mouse.y {
        mouse_wake(a)
    }
    a.mouse.x, a.mouse.y = x, y
    a.mouse.known = true
}

// The left button: held state (fed to Clay and the drag machine) plus a pending press for a
// pane to claim. The press is NOT routed here, but the click RUN is counted here — a property
// of the input stream. Release is not a verb (a click acts on press), only the end of a capture.
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || button != glfw.MOUSE_BUTTON_LEFT {
        return
    }
    a.mouse.down = action != glfw.RELEASE
    if !a.mouse.down {
        // Reported BEFORE the mouse_on gate: a drag switched off mid-gesture must still be
        // told the button came up, or the capture outlives the toggle. It only PARKS the end —
        // the owning pane is owed one more frame at the position the pointer stopped at.
        drag_release(a)
        return
    }
    if !a.mouse_on {
        return
    }
    mouse_wake(a) // wake BEFORE parking it, so the click acts with the cursor visible
    // A press can be the first pointer event the window ever sees (a cursor already over a
    // freshly opened window reports no motion), so ask GLFW rather than routing against a
    // position we never received.
    if !a.mouse.known {
        x, y := glfw.GetCursorPos(window)
        a.mouse.x, a.mouse.y = mouse_to_fb(window, x, y)
        a.mouse.known = true
    }
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

// Spend one wheel event: wake, accumulate the sub-notch travel, then route and apply whatever
// whole notches that produced. GLFW's yoffset is positive for a scroll UP, so the sign flips
// exactly once — here. The wake is UNCONDITIONAL: fractional events still mean a hand on it.
mouse_wheel :: proc(a: ^App, yoffset: f64) {
    if !a.mouse_on || yoffset == 0 {
        return
    }
    mouse_wake(a)
    // Accumulate, then spend whole notches and keep the remainder (see Mouse.accum).
    // int() truncates toward zero, so the leftover always carries the same sign.
    a.mouse.accum += -yoffset
    notch := int(a.mouse.accum)
    a.mouse.accum -= f64(notch)
    wheel_apply(a, wheel_target(a, a.lay, a.mouse.x, a.mouse.y), notch)
}

// The GLFW half: resolve the pointer's position if we have never had one, then spend the
// event.
scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || !a.mouse_on || yoffset == 0 {
        return
    }
    // A wheel can be the first pointer event the window ever sees (the cursor may already
    // be sitting over a freshly opened window, with no motion to report), so fall back to
    // asking GLFW outright rather than routing against a position we never received.
    if !a.mouse.known {
        x, y := glfw.GetCursorPos(window)
        a.mouse.x, a.mouse.y = mouse_to_fb(window, x, y)
        a.mouse.known = true
    }
    mouse_wheel(a, yoffset)
}

// Hand Clay this frame's pointer, so PointerOver / OnHover resolve during the declarations
// that follow. With the mouse off — or before the first pointer event — it is parked
// off-screen so nothing can hover, rather than making every declaration check the flag.
mouse_feed_clay :: proc(a: ^App) {
    if !a.mouse_on || !a.mouse.known {
        clay.SetPointerState({-1, -1}, false)
        return
    }
    clay.SetPointerState({f32(a.mouse.x), f32(a.mouse.y)}, a.mouse.down)
}
