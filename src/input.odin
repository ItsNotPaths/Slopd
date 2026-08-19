package main

import "base:runtime"
import "vendor:glfw"
import "wake"

// GLFW events in, one Action out. No verbs and no chords here: this tracks what is held, asks
// bind.odin which Action a keystroke names, and hands it to action.odin.
//
// The route: bookkeeping, held keys, an open context menu, then the lookup (Global plus the
// surface's own context). Whatever nothing claims reaches a live terminal, which is the only
// thing separating the terminal from a pane. An Alt chord is never the job's.
//
// Non-modal and Alt-rooted: bare keys stay free for typing, navigation is the arrow keys only,
// and pane / terminal navigation lives under Alt.

// A key that qualifies the next keystroke rather than being one. Super and CapsLock count.
key_is_modifier :: proc(key: i32) -> bool {
    switch key {
    case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT,
         glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL,
         glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT,
         glfw.KEY_LEFT_SUPER, glfw.KEY_RIGHT_SUPER,
         glfw.KEY_CAPS_LOCK:
        return true
    }
    return false
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    wake.mark() // a keystroke earns a frame, even one handle_key ignores
    handle_key(a, key, action, mods)
}

// The focused editable owns it — the same one the Text binds act on, so typing and editing
// cannot disagree about which box they are in.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || a.alt_held || codepoint < 32 {
        return
    }
    wake.mark()
    a.last_input_at = glfw.GetTime()
    a.blink_base = a.last_input_at // caret solid, then blinking
    a.move_all_armed = false // typing is not a motion
    mouse_stand_down(a)

    // A live terminal is not an editable: characters go to the job, not a Doc.
    if tf := term_focused(a); tf != nil {
        terminal_input_rune(tf, codepoint)
        return
    }
    config_edit_sync(a) // the highlighted row owns the Doc before the keystroke
    kind, d := active_editable(a)
    switch kind {
    case .None:
        return
    case .Buffer:
        b := editor_current(&a.editor) // the one editable that closes a bracket
        if !buffer_autopair(b, codepoint) {
            buffer_insert_rune(b, codepoint)
        }
    case .Config_Search:
        doc_insert_rune(d, codepoint)
        config_pane_filter(&a.config_pane) // live as you type
    case .Command_Line, .Browse_Path, .Workspace_Find, .Config_Value:
        // Its rows follow the line on a version compare, so this is the plain insert.
        doc_insert_rune(d, codepoint)
    }
}

handle_key :: proc(a: ^App, key, action, mods: i32) {
    if action == glfw.PRESS || action == glfw.REPEAT {
        now := glfw.GetTime()
        a.blink_base = now
        a.last_input_at = now // the perf log's keystroke->present timestamp

        // A bare modifier does not stand the pointer down: Alt+click needs the cursor on screen
        // to aim with, and Ctrl held is the filetree's chord bar.
        if !key_is_modifier(key) {
            mouse_stand_down(a)
        }
    }

    // Not binds: each qualifies the NEXT keystroke and drives an overlay while down.
    switch key {
    case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT:
        a.alt_held = action != glfw.RELEASE
        if action == glfw.PRESS {
            anim_start(&a.switcher_anim, glfw.GetTime(), 0, 1, SWITCHER_DUR)
        }
        return // Alt alone asks for nothing
    case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL:
        a.ctrl_held = action != glfw.RELEASE
        if action == glfw.PRESS {
            anim_start(&a.chord_anim, glfw.GetTime(), 0, 1, SWITCHER_DUR)
        }
    case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
        a.shift_held = action != glfw.RELEASE
    case glfw.KEY_A:
        a.a_held = action != glfw.RELEASE // held with an arrow, it lays a cursor trail
    }

    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }

    // A mid-frame click may have left a text row; settle it before anything reads it.
    if a.focus == .Aux && a.aux_mode == .Config {
        config_edit_sync(a)
    }

    // The menu owns four keys; any other closes it and is then handled normally, so a menu
    // opened by a stray press never swallows the keystroke you meant.
    if ctxmenu_shown(a) && !key_is_modifier(key) {
        switch key {
        case glfw.KEY_ESCAPE:
            ctxmenu_close(a)
            return
        case glfw.KEY_UP:
            ctxmenu_move(a, -1)
            return
        case glfw.KEY_DOWN:
            ctxmenu_move(a, 1)
            return
        case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
            ctxmenu_choose(a)
            return
        }
        ctxmenu_close(a)
    }

    // The move-all prefix is spent by the next real key, never by a bare modifier.
    all := false
    if !key_is_modifier(key) {
        all = a.move_all_armed
        a.move_all_armed = false
    }

    if a.alt_held && a.a_held && cursor_trail(a, key) {
        return
    }

    chord := Chord{key, mods & CHORD_MODS}
    if binds_pane_key(a, chord) {
        return
    }
    if bind_dispatch(a, chord, key, all) {
        return
    }

    // Unclaimed keys reach a live terminal; an Alt chord never does, bound or not.
    if mods & glfw.MOD_ALT != 0 {
        return
    }
    if tf := term_focused(a); tf != nil {
        terminal_input_key(tf, key, mods)
    }
}

// The chord's holders in turn, until one takes it: a verb answering false has nothing to do
// where you pressed it, and the next row holding the chord gets its turn. A swallowed chord ends
// the walk instead — the open line has it. Bounded by the table, which cannot hold more.
bind_dispatch :: proc(a: ^App, chord: Chord, key: i32, all: bool) -> bool {
    ctx := bind_ctx(a, chord)
    for skip in 0 ..< len(a.binds) {
        b, ok := bind_find(a.binds[:], chord, ctx, skip)
        if !ok || cl_swallows(a, b) {
            break
        }
        if action_run(a, b.act, int(key - b.chord.key), chord.mods & glfw.MOD_SHIFT != 0, all) {
            return true
        }
    }
    return false
}

// A pane chord under an open line would move focus out from under it, and Alt+C would clear it.
// Only the window-level verbs reach past.
@(private = "file")
cl_swallows :: proc(a: ^App, b: Bind) -> bool {
    if !a.cl_active || .Global not_in bind_ctxs(b.act) {
        return false
    }
    #partial switch b.act {
    case .Escape, .Font_Grow, .Font_Shrink, .Font_Reset:
        return false
    }
    return true
}

// Claimed before the table it edits: unbinding `nav.down` must not lock you out of the pane that
// fixes it. Eight chords, declining the rest, so Alt+E and the zoom still get you out. While
// CAPTURING it takes everything — to bind Alt+F you have to press Alt+F — bar Escape, which
// cancels, and is therefore the one chord that can never be bound.
@(private = "file")
binds_pane_key :: proc(a: ^App, c: Chord) -> bool {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Binds {
        return false
    }
    bp := &a.binds_pane
    if bp.capture == .Add || bp.capture == .Rebind {
        if key_is_modifier(c.key) {
            return true // a held Ctrl is not the chord; wait for what it qualifies
        }
        if c.key == glfw.KEY_ESCAPE {
            bp.capture = .None
        } else {
            binds_pane_take(bp, c)
        }
        return true
    }
    switch c.key {
    case glfw.KEY_ESCAPE:
        if bp.capture != .Confirm {
            return false // nothing pending: Escape is the view's
        }
        bp.capture = .None
    case glfw.KEY_UP:
        binds_pane_move(bp, -1)
    case glfw.KEY_DOWN:
        binds_pane_move(bp, 1)
    case glfw.KEY_LEFT:
        binds_pane_cycle(bp, -1)
    case glfw.KEY_RIGHT:
        binds_pane_cycle(bp, 1)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        binds_pane_activate(a)
    case glfw.KEY_BACKSPACE:
        binds_pane_delete(bp)
    case glfw.KEY_EQUAL:
        if c.mods != glfw.MOD_ALT {
            return false
        }
        binds_pane_activate(a, add = true)
    case glfw.KEY_MINUS:
        if c.mods != glfw.MOD_ALT {
            return false
        }
        binds_pane_delete(bp)
    case glfw.KEY_S:
        if c.mods != glfw.MOD_CONTROL {
            return false
        }
        binds_pane_save(a)
    case:
        return false
    }
    return true
}

// Esc collapses it. A held-key chord rather than a bind: what you hold is a modifier.
@(private = "file")
cursor_trail :: proc(a: ^App, key: i32) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    m: Motion
    switch key {
    case glfw.KEY_UP:
        m = .Up
    case glfw.KEY_DOWN:
        m = .Down
    case glfw.KEY_LEFT:
        m = .Left
    case glfw.KEY_RIGHT:
        m = .Right
    case:
        return false
    }
    doc_move(d, m)
    doc_drop_anchor(d)
    return true
}
