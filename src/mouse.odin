package main

import "base:runtime"
import "vendor:glfw"
import clay "../bindings/clay"

// Mouse: GLFW pointer events -> mutations on App. The sibling of input.odin, which owns
// the keyboard; the manifesto there still holds, so everything reachable here has a key
// binding too and `mouse: off` costs convenience, never capability.
//
// Mouse input is NOUN-FIRST, and that is the whole reason this file exists separately: a
// key event names its verb outright, while a wheel notch carries only a position, which
// must resolve to a pane before there is a verb at all. wheel_target is that resolution
// and is PURE — App state plus the frame's Layout in, a target out, no mutation — so the
// routing table is a headless unit test (tests/mouse_test.odin) rather than something you
// confirm by waggling a mouse. wheel_apply is the only half that writes.
//
// Two coordinate traps, both handled at the callback so nothing downstream repeats them:
//
//   1. GLFW reports the cursor in WINDOW (logical) coordinates, while Layout, Rect and
//      Clay all work in FRAMEBUFFER pixels. On a HiDPI screen those differ by the
//      framebuffer/window ratio, so mouse_to_fb converts once, on the way in. It derives
//      the ratio from the two sizes rather than reusing App.scale (the content scale):
//      the two agree on every setup we have, but only the former is the conversion by
//      definition.
//
//   2. Routing resolves against the layout the last frame PAINTED (App.lay), not a freshly
//      computed one. Mid-animation — the Zen slide, the git split widen — a recomputed
//      layout is already somewhere else, so a notch would land in a pane the user cannot
//      see yet. This is the same "hit-test against the previous frame" rule Clay's own
//      SetPointerState follows (see docs/clay-refactor.md, C1).

// Lines moved per wheel notch. Three is the near-universal desktop default, and each of
// the routing targets happens to consume "lines" natively — buffer rows, diff rows, list
// selection steps — so there is one constant rather than a per-pane table.
WHEEL_LINES :: 3

// What makes two presses a double-click: near enough in time AND in space. The slop is in
// framebuffer pixels and deliberately small — a press that travelled is a drag gesture
// (C7), not a second click — while 0.4s is the common desktop default, comfortably above a
// deliberate double-tap and below the pause that means "two separate clicks".
DOUBLE_CLICK_S :: 0.4
DOUBLE_CLICK_PX :: 4

// Pointer state, mirrored from the GLFW callbacks. Positions are framebuffer pixels (see
// the header); `known` guards the window between startup and the first motion event, when
// there is genuinely no position and (0, 0) would be a lie that hits the editor pane.
Mouse :: struct {
    x, y:  i32,
    known: bool,
    down:  bool, // left button held; fed to Clay and, from C7, the drag machine
    // Undelivered wheel travel. A mouse wheel reports whole notches, but a trackpad (and
    // libinput's high-resolution axis) reports fractions of one, and rounding each event
    // up to a notch would make a gentle two-finger drag tear through the buffer. Carrying
    // the remainder makes both correct without a device check: exact for ±1 events, and a
    // fraction of a line per event otherwise.
    accum: f64,

    // A left press waiting for a noun. A wheel notch resolves to a PANE, which the callback
    // can do on its own (wheel_target); a click resolves to a ROW, a field, a checkbox —
    // and only the pane's own Clay declaration knows which element sits under the pointer.
    // So the press is parked here and the next frame's draw claims it, hit-testing against
    // the layout Clay is already holding. Nothing else in this file interprets it.
    click:       bool, // a press is pending
    click_count: int, // presses in the current run: 1 single, 2 double, 3+ keeps counting
    click_at:    f64, // glfw time of the press, for the double-click window
    click_x:     i32, // and where it landed, for the slop
    click_y:     i32,
}

// Claim the pending click. Clearing it here is what makes a press have exactly ONE noun:
// the first pane to hit-test something under the pointer owns it, and every later asker in
// the same frame sees nothing. A pane must therefore ask only when it actually hit
// something of its own — an unclaimed press is dropped at the end of the frame (render),
// not carried into the next one, where the pointer may be somewhere else entirely.
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
    None, // the status strip, the inter-pane gutter, the git column rule, off-window
    Editor, // editor pane, Text surface: the buffer's viewport
    Media, // editor pane, Image surface: pan/zoom is C8, so nothing yet
    Terminal,
    Git_Sidebar, // git pane, left column — a list, so the wheel moves its selection
    Git_Diff, // git pane, right column — the diff's own scroll
    List, // filetree / grep / config / procmon
}

// Which target a wheel notch at (mx, my) belongs to. Pure: no mutation, no GL, no window
// — the routing decision table, and the thing tests/mouse_test.odin pins.
//
// Hidden panes carry a zero rect out of compute_layout, so rect_hit rejects them without
// a separate visibility check, and the editor/aux rects never overlap (in Zen the editor
// shrinks to the strip the sliding aux pane leaves uncovered), so probe order is free.
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
    case .Git:
        // The git pane is the one aux mode with sub-columns whose split matters here.
        // git_columns is the same proc draw_git lays out with, so this cannot drift from
        // what was painted — the divergence C6 deletes git_diff_rows over.
        side, _, diff := git_columns(lay.aux, a.scale)
        if rect_hit(side, mx, my) {
            return .Git_Sidebar
        }
        if rect_hit(diff, mx, my) {
            return .Git_Diff
        }
        return .None // the hairline rule between the columns
    case .FileTree, .Grep, .Config, .Procmon:
        return .List
    }
    return .None
}

// Apply `notch` wheel notches to `target`. Positive is DOWN / forward (the callback
// normalises GLFW's inverted sign), and the magnitude is notches, not lines — the
// per-target conversion happens here because a list steps by selection and a buffer by
// rows, and a trackpad can deliver several at once.
//
// The MIDDLE scroll_mode question is the substance of this proc. Both viewport policies
// derive their top from the thing they follow and ignore whatever top they were handed —
// MIDDLE outright, FOLLOW once the caret would leave the pane — so "move the view, leave
// the selection" is not expressible while a policy is running. Two answers, by pane kind:
//
//   - The LIST panes are conceptually a cursor in a list, so the wheel moves the SELECTION
//     and the viewport follows it under either policy. Nothing is detached, nothing to
//     re-attach, and the pane behaves identically in both modes.
//   - The EDITOR detaches instead (buffer_scroll_apply): its policy stops running until the
//     next keystroke, so the view is genuinely free and the caret is not dragged around by
//     a scroll gesture. A selection-moving wheel would be wrong here — the caret is an
//     insertion point, not a cursor in a list.
//
// The terminal and the git diff need neither: they already keep view and selection apart,
// so the wheel moves the view and scroll_mode never enters into it.
wheel_apply :: proc(a: ^App, target: Wheel_Target, notch: int) {
    if notch == 0 {
        return
    }
    d := notch * WHEEL_LINES
    switch target {
    case .None:
    case .Media:
    // Media pan/zoom is C8 (media_fit_rect is already pure, so it is a small job when
    // it comes). Listed rather than folded into .None so the pane is visibly accounted
    // for and a notch here is a deliberate no-op, not an unhandled case.
    case .Editor:
        if len(a.editor.buffers) == 0 {
            return
        }
        // Detaching the view from the caret is what makes this a real scroll rather than a
        // nudge inside a caret-shaped cage — and it is what lets ONE branch serve both
        // scroll_modes, since neither policy runs while detached (buffer_scroll_apply).
        // The next keystroke re-attaches, so the caret is never lost for long.
        buffer_scroll_by(editor_current(&a.editor), d, glfw.GetTime())
    case .Terminal:
        t := term_current(a)
        if t == nil {
            return
        }
        if t.on_altscreen {
            // A full-screen TUI owns its own scrollback; ours holds nothing useful for
            // it. Forward the notches so the wheel drives ITS scroll — as a wheel if it
            // tracks the mouse, else as the page key it groks (terminal_scroll_tui).
            for _ in 0 ..< abs(notch) {
                terminal_scroll_tui(t, notch < 0 ? -1 : 1)
            }
        } else {
            // Our scrollback is only reachable through the copy cursor (terminal_view_top
            // returns the live bottom unless sel_active), so scrolling back IS moving it.
            // extend = false, so this scrolls without laying down a selection span.
            terminal_sel_move(t, d, false)
        }
    case .Git_Diff:
        git_diff_scroll(&a.git, d)
    case .Git_Sidebar:
        // git_sidebar_move, not git_move_sel: the latter is the KEY path and refuses
        // unless the sidebar holds the region focus, whereas a wheel scrolls whatever it
        // is over. Focus is deliberately not stolen — focus-follows-click is C8.
        git_sidebar_move(&a.git, d)
    case .List:
        switch a.aux_mode {
        case .FileTree:
            filetree_move(&a.tree, d)
        case .Grep:
            grep_move(&a.grep, d)
        case .Config:
            // Whatever currently owns the selection moves: an open dropdown's choices, or
            // the row list when nothing is open. One proc, shared with the pane's Up/Down
            // (config_dropdown_move) — the refusal that used to sit here existed only
            // because the dropdown had no geometry outside draw_config, and C5b gave it
            // some, so it is gone rather than preserved.
            config_dropdown_move(a, d)
        case .Procmon:
            // The signal selector and the kill-arm prompt still have no geometry outside
            // draw_procmon, so a notch over one does nothing rather than moving the list
            // underneath it — the refusal the config branch above has just shed, waiting on
            // the same fix (C5c). Otherwise the notch moves the process list, including
            // when the pointer is over the graph band: the band does not scroll, and
            // per-region routing needs the geometry C5c extracts.
            pm := &a.procmon
            if !pm.sig_open && !pm.kill_armed {
                procmon_select(pm, pm.sel + d)
            }
        case .Terminal, .Git:
        // Not list panes; wheel_target never routes them here.
        }
    }
}

// Convert a GLFW cursor position (window coordinates) to framebuffer pixels — trap 1 in
// the header. The ratio is derived from the two sizes rather than assumed to be App.scale.
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
    a.mouse.x, a.mouse.y = mouse_to_fb(window, xpos, ypos)
    a.mouse.known = true
}

// The left button: held state (fed to Clay, and from C7 to the drag machine) plus a
// pending press for a pane to claim. The press is NOT routed here — see Mouse.click — but
// the click RUN is counted here, because that is a property of the input stream (how close
// two presses were in time and space) rather than of whatever they landed on.
//
// Release is deliberately not a verb: a click acts on press, the way every list does, so a
// row is selected the moment the button goes down.
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || button != glfw.MOUSE_BUTTON_LEFT {
        return
    }
    a.mouse.down = action != glfw.RELEASE
    if !a.mouse.down || !a.mouse_on {
        return
    }
    // A press can be the first pointer event the window ever sees, exactly as a wheel notch
    // can (a cursor already sitting over a freshly opened window reports no motion), so ask
    // GLFW outright rather than resolving against a position we never received.
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
    m.click = true
}

// A wheel notch: resolve where it landed, then apply it. GLFW's yoffset is positive for a
// scroll UP, which is the opposite of every "lines down" convention downstream, so the
// sign flips exactly once — here.
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
    // Accumulate, then spend whole notches and keep the remainder (see Mouse.accum).
    // int() truncates toward zero, so the leftover always carries the same sign.
    a.mouse.accum += -yoffset
    notch := int(a.mouse.accum)
    a.mouse.accum -= f64(notch)
    wheel_apply(a, wheel_target(a, a.lay, a.mouse.x, a.mouse.y), notch)
}

// Hand Clay this frame's pointer, so PointerOver / OnHover resolve during the declarations
// that follow. Called from render before anything is declared. With the mouse configured
// off — or before the first pointer event — the pointer is parked off-screen so nothing
// can hover, which is cheaper and clearer than making every declaration check the flag.
mouse_feed_clay :: proc(a: ^App) {
    if !a.mouse_on || !a.mouse.known {
        clay.SetPointerState({-1, -1}, false)
        return
    }
    clay.SetPointerState({f32(a.mouse.x), f32(a.mouse.y)}, a.mouse.down)
}
