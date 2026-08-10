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
//      computed one. Mid-animation — the Zen slide, a split adjustment — a recomputed
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

    // The keyboard has taken over: the cursor is hidden and nothing hovers. Set by any key
    // that does something (mouse_stand_down), cleared by any pointer motion or press
    // (mouse_wake). See those two for the reasoning; `cursor_hidden` is only the bookkeeping
    // that keeps mouse_apply_cursor from calling into GLFW every frame.
    stood_down:     bool,
    cursor_hidden:  bool,

    // The modifiers held AT THE PRESS, taken from GLFW's own `mods` rather than read off
    // App.alt_held / shift_held when the pane claims it. Two reasons, and the second is the
    // one that bites: a press is claimed on a later frame than it arrived, so a modifier
    // released in between would be read as never held; and the key-tracking flags only see
    // keys this window received, while `mods` is the state the window system reports with
    // the event itself. Stored as bools so this file stays the only one that knows GLFW's
    // bit values (C7).
    //
    // Ctrl is here for ONE client: the terminal forwards it to a mouse-tracking TUI as
    // MOD_CTRL (C7b), which is the only place in Slopd where a modified click means
    // something to somebody else's program. Shift never reaches a TUI — it is the override
    // that keeps the click local — and Alt never does either, for the same reason the
    // keyboard's Alt-chords never reach the shell.
    click_shift: bool,
    click_ctrl:  bool,
    click_alt:   bool,
}

// --- standing the pointer down while the keyboard is in use ---
//
// Two highlights that both mean "here" are one too many. A list pane paints the row under
// the pointer AND the selected row, and while you are moving the selection with the arrows
// the pointer is not saying anything — it is sitting wherever you left it, lighting a row
// you are not thinking about and competing with the one you are. So a keystroke stands the
// pointer down: the cursor is hidden and nothing hovers, until the pointer does something
// that means the hand is back on it.
//
// This is not a timeout and deliberately not one. A dwell timer would need a wake in the
// scheduler and would make the cursor vanish mid-thought while you read; the keyboard is
// already the unambiguous signal, and it costs nothing to watch.
//
// What wakes it: ANY pointer event — motion, a press, or a wheel event. The wheel was
// briefly excluded on the reasoning that scrolling does not move the pointer, so waking
// would relight whatever the cursor happened to be resting over; that is true and it is not
// the point. Turning a wheel is a hand on the mouse, and a program that keeps the cursor
// hidden while you are visibly using the mouse is wrong about who is driving. Hover
// following a scroll is what hover IS — the row under the pointer changed because the rows
// moved — and the next keystroke stands it straight back down.
//
// **Standing down suppresses HOVER, never a click.** A press wakes the pointer in the
// callback, before any pane gets a chance to claim it, so there is no state in which a
// deliberate click is swallowed — which is why the gate lives at the four places hover is
// PAINTED (hover_shown) and not in any pane's hit test. Clay is still fed the real pointer
// for the same reason: wheel routing asks it where a notch landed (procmon's band, C5c),
// and parking the pointer off-screen to kill hover would quietly break that instead.

// A key that does something: hide the pointer and stop it answering.
mouse_stand_down :: proc(a: ^App) {
    a.mouse.stood_down = true
}

// A pointer event: the hand is back on the mouse, so bring it back.
mouse_wake :: proc(a: ^App) {
    a.mouse.stood_down = false
}

// Whether hover may PAINT this frame. The config toggle (`hover: on|off`) and the stand-down
// state, in one place, because every pane needs both and neither is worth restating four
// times. The hovered item is still resolved while stood down — it costs nothing, it is the
// same call the click needs, and a pane that stopped tracking it would have to re-hit-test
// on the motion event that wakes it.
hover_shown :: proc(a: ^App) -> bool {
    return a.hover_on && !a.mouse.stood_down
}

// Push the cursor's visibility to GLFW, once per frame, from the one state that decides it.
// Called from the main loop rather than from the callbacks on purpose: this way there is a
// single writer and no path can strand a hidden cursor — turning `mouse: off` while the
// pointer is stood down reveals it on the next frame, because the desired state below is
// simply false again.
mouse_apply_cursor :: proc(a: ^App) {
    want := a.mouse_on && a.mouse.stood_down
    if want == a.mouse.cursor_hidden || a.window == nil {
        return
    }
    a.mouse.cursor_hidden = want
    glfw.SetInputMode(a.window, glfw.CURSOR, want ? glfw.CURSOR_HIDDEN : glfw.CURSOR_NORMAL)
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
    None, // the status strip, the inter-pane gutter, off-window
    Editor, // editor pane, Text surface: the buffer's viewport
    Media, // editor pane, Image surface: pan/zoom is C8d, so nothing yet
    Terminal,
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
// ~~The LIST panes are conceptually a cursor in a list, so the wheel moves the SELECTION.~~
// **Reversed: every list pane now DETACHES, exactly as the editor does.** A wheel scrolls
// the VIEW — which is what a wheel means everywhere else in this program (the editor, the
// terminal, the git diff) and everywhere else on the desktop — and the next keystroke that
// reaches that pane re-attaches its policy to the selection (list_scroll_apply, scroll.odin).
//
// The original reasoning was sound and the conclusion was still wrong. MIDDLE really does
// re-derive the top from the selection, so a view-only scroll IS overwritten on the next
// frame — but the answer to that is the detach the editor already had, not a wheel that
// moves the cursor. Moving the selection also had a wart it could not shed: a notch is
// WHEEL_LINES *items*, which in grep meant three BLOCKS, about eighteen display rows for
// one notch. Detached, a notch is three rows in every pane.
//
// The terminal needs no detach: it already keeps view and selection apart, so the wheel
// moves the view and scroll_mode never enters into it.
wheel_apply :: proc(a: ^App, target: Wheel_Target, notch: int) {
    if notch == 0 {
        return
    }
    d := notch * WHEEL_LINES
    switch target {
    case .None:
    case .Media:
    // Media pan/zoom is C8d (media_fit_rect is already pure, so it is a small job when
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
            // The VIEW, not the copy cursor. ~~Our scrollback is only reachable through the
            // copy cursor, so scrolling back IS moving it.~~ That was true and it made the
            // terminal the one pane where a wheel notch moved a cursor — putting a
            // keyboard-only marker on screen that nobody asked for, and dragging a
            // selection's anchor around under it. The view has its own detach now
            // (terminal_scroll_by), exactly as every list pane and the editor do, and rule 10
            // finally holds everywhere: a wheel scrolls the view, never the selection.
            terminal_scroll_by(t, d)
        }
    case .List:
        // Every list pane scrolls its VIEW, through one shared proc. The stamp is the whole
        // mechanism: while it is set the pane's viewport policy does not run, so this write
        // survives the frame in either scroll_mode, and the next keystroke to reach the pane
        // clears it. No total is passed — the callback has no font, no pane rect and, for
        // grep and config, no flattened row list, so it cannot know where the end is;
        // list_scroll_apply clamps on the next frame, which bounds the overshoot at a notch.
        now := glfw.GetTime()
        switch a.aux_mode {
        case .FileTree:
            list_scroll_by(&a.tree.scroll, &a.tree.scroll_detached, d, now)
        case .Grep:
            list_scroll_by(&a.grep.scroll, &a.grep.scroll_detached, d, now)
        case .Config:
            // Including with a dropdown open: its options are spliced into the row list, so
            // scrolling the view carries them along and there is nothing special to do.
            // config_dropdown_move stays the KEYBOARD's, where moving a selection is the
            // point. (That branch was a refusal until C5b and a selection move until now.)
            list_scroll_by(&a.config_pane.scroll, &a.config_pane.scroll_detached, d, now)
        case .Procmon:
            // The one aux mode whose regions stack vertically, so where the notch landed
            // decides what it moves. That question goes to the tree CLAY is holding — the
            // one the last frame painted — rather than to a recomputed procmon_geom, which
            // would be a second copy of the band's height, drifting from the first the
            // moment either changed. It also needs no font: the element knows its own box.
            //
            //   over the band, selector open   walks the 1..31 grid (procmon_sig_move)
            //   over the band, graphs showing  nothing; a graph is a picture, not a view
            //   over the list                  scrolls the list, like every other pane
            //
            // The list stays scrollable while the selector is up or a kill is armed, which
            // the selection-moving version could not allow: a view scroll cannot arm, send
            // or confirm anything, so there is nothing for the capture to protect.
            pm := &a.procmon
            if clay.PointerOver(clay.ID("pm_band")) {
                if pm.sig_open {
                    procmon_sig_move(pm, d)
                }
            } else {
                list_scroll_by(&pm.scroll, &pm.scroll_detached, d, now)
            }
        case .Terminal:
        // Not a list pane; wheel_target never routes it here.
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

// The left button: held state (fed to Clay, and from C7 to the drag machine) plus a
// pending press for a pane to claim. The press is NOT routed here — see Mouse.click — but
// the click RUN is counted here, because that is a property of the input stream (how close
// two presses were in time and space) rather than of whatever they landed on.
//
// Release is deliberately not a verb: a click acts on press, the way every list does, so a
// row is selected the moment the button goes down. It IS the end of a capture, though — see
// below.
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || button != glfw.MOUSE_BUTTON_LEFT {
        return
    }
    a.mouse.down = action != glfw.RELEASE
    if !a.mouse.down {
        // A release still commands no verb, but it ends whatever the press captured (C7c).
        // Reported before the mouse_on gate on purpose: a drag begun and then switched off
        // mid-gesture must still be told the button came up, or the capture outlives the
        // toggle that was meant to have stopped it. drag_release only PARKS the end — the
        // owning pane is owed one more frame at the position the pointer stopped at, since
        // WaitEvents drains a motion and its release together (drag.odin).
        drag_release(a)
        return
    }
    if !a.mouse_on {
        return
    }
    // A press is the hand back on the mouse, so it wakes BEFORE it is parked for a pane to
    // claim — the click then acts at the position it was made, with the cursor visible
    // again from that frame on. Waking after would make the first click of a run act while
    // still stood down, which is the one case where "ignored" would be wrong: the user
    // aimed it.
    mouse_wake(a)
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
    m.click_shift = mods & glfw.MOD_SHIFT != 0
    m.click_ctrl = mods & glfw.MOD_CONTROL != 0
    m.click_alt = mods & glfw.MOD_ALT != 0
    m.click = true
}

// Spend one wheel event: wake the pointer, accumulate the sub-notch travel, then route and
// apply whatever whole notches that produced. GLFW's yoffset is positive for a scroll UP,
// which is the opposite of every "lines down" convention downstream, so the sign flips
// exactly once — here.
//
// Split out of scroll_callback so it is reachable headlessly: everything the callback keeps
// needs a window handle, and everything here is a decision worth a test — the wake, the
// accumulator (which does nothing at all on a device that sends ±1 per notch, so a run on
// this desk says nothing either way about it), and the routing.
//
// THE WAKE IS UNCONDITIONAL, ahead of the accumulator rather than beside the apply: a
// trackpad delivers a long run of fractional events that each spend no notch, and the hand
// is plainly on the pointer throughout. Waking only when a notch lands would leave the
// cursor hidden through exactly the gesture that is most obviously pointer use.
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
