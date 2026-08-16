package main

import "base:runtime"
import "vendor:glfw"
import "wake"

// Input — GLFW events in, one Action out. No verbs here and no chord: this tracks what is held,
// asks bind.odin which Action a keystroke names, and hands it to action.odin.
//
// The route: bookkeeping, held keys, an open context menu, then the lookup (Global plus the
// surface's own context). Whatever nothing claims reaches a live terminal — the only thing that
// separates the terminal from a pane. An Alt chord is never the job's.
//
// Non-modal, Alt-rooted: bare keys stay free for typing, navigation is the ARROW KEYS only
// (hjkl have to type), and pane / terminal navigation lives under Alt. Pointer input is
// additive and lives in mouse.odin.

// A key that qualifies the next keystroke rather than being one. Super and CapsLock count: the
// question is "did the user ask for something".
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
    wake.mark() // a keystroke earns a frame, even one handle_key ignores (chord bars, modifiers)
    handle_key(a, key, action, mods)
}

// Text input. The focused editable owns it — the same one the Text binds act on, so typing and
// editing cannot disagree about which box they are in. Alt+C must not leak its letter in.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || a.alt_held || codepoint < 32 {
        return
    }
    wake.mark()
    a.last_input_at = glfw.GetTime()
    a.blink_base = a.last_input_at // typing: caret solid, then resumes blinking
    a.move_all_armed = false // typing isn't a motion; cancel a pending move-all
    mouse_stand_down(a) // typing hides the pointer, exactly as a bound key does

    // A live terminal is not an editable: characters go to the job, not to a Doc.
    if tf := term_focused(a); tf != nil {
        terminal_input_rune(tf, codepoint)
        return
    }
    config_edit_sync(a) // the highlighted config row owns the Doc before it owns the keystroke
    kind, d := active_editable(a)
    switch kind {
    case .None:
        return
    case .Buffer:
        b := editor_current(&a.editor) // the one editable that closes a bracket for you
        if !buffer_autopair(b, codepoint) {
            buffer_insert_rune(b, codepoint)
        }
    case .Config_Search:
        doc_insert_rune(d, codepoint)
        config_pane_filter(&a.config_pane) // live filter as you type
    case .Command_Line, .Browse_Path, .Workspace_Find, .Config_Value:
        // The prompt's rows follow its line on a version compare (wsfind_sync), so typing into
        // it is the plain insert every other field's is.
        doc_insert_rune(d, codepoint)
    }
}

handle_key :: proc(a: ^App, key, action, mods: i32) {
    if action == glfw.PRESS || action == glfw.REPEAT {
        now := glfw.GetTime()
        a.blink_base = now // any keypress holds the caret solid, then blinks
        a.last_input_at = now // perf log: timestamp for keystroke->present latency

        // The keyboard stands the pointer down — but a BARE MODIFIER does not: Alt+click needs
        // the cursor on screen to aim with, and Ctrl held is the filetree's chord bar.
        if !key_is_modifier(key) {
            mouse_stand_down(a)
        }
    }

    // Held keys — not binds: each qualifies the NEXT keystroke and drives an overlay while down.
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
            anim_start(&a.chord_anim, glfw.GetTime(), 0, 1, SWITCHER_DUR) // fade the chord bar in
        }
    case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
        a.shift_held = action != glfw.RELEASE
    case glfw.KEY_A:
        a.a_held = action != glfw.RELEASE // Alt+A held + an arrow lays a multi-cursor trail
    }

    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }

    // A mid-frame click may have left a text row: settle it before anything reads it.
    if a.focus == .Aux && a.aux_mode == .Config {
        config_edit_sync(a)
    }

    // The menu owns four keys and nothing else: any other closes it and is then handled normally,
    // so a menu opened by a stray press never swallows the keystroke you meant.
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

    // The move-all prefix is spent by the next real key — a bare modifier must not eat it.
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
    if b, ok := bind_find(a.binds[:], chord, bind_ctx(a, chord)); ok && !cl_swallows(a, b) {
        if action_run(a, b.act, int(key - b.chord.key), chord.mods & glfw.MOD_SHIFT != 0, all) {
            return
        }
    }

    // Unclaimed keys reach a live terminal. An Alt chord never does: it was ours, bound or not.
    if mods & glfw.MOD_ALT != 0 {
        return
    }
    if tf := term_focused(a); tf != nil {
        terminal_input_key(tf, key, mods)
    }
}

// An open command line owns the keyboard: a pane chord under it would move focus out from under
// the line, and Alt+C would clear it outright. Only the window-level verbs reach past.
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

// The binds pane's own keys, claimed before the table it edits — unbinding `nav.down` must not
// lock you out of the pane that fixes it, and `edit.save` is a Text bind a Surface pane would
// never see. It takes eight chords and declines the rest, so Alt+E and the zoom still get you out.
//
// While CAPTURING it takes everything: to bind Alt+F you have to press Alt+F. The one exception
// is Escape, which cancels — so Escape is the one chord that can never be bound.
@(private = "file")
binds_pane_key :: proc(a: ^App, c: Chord) -> bool {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Binds {
        return false
    }
    bp := &a.binds_pane
    if bp.capture == .Add || bp.capture == .Rebind {
        if key_is_modifier(c.key) {
            return true // a held Ctrl is not the chord; wait for the key it qualifies
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
            return false // nothing pending: Escape is the view's, as everywhere else
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

// Alt+A held + an arrow lays a multi-cursor trail; Esc collapses it. A held-key chord rather than
// a bind: what you hold is a modifier for as long as you hold it.
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
