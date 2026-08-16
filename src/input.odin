package main

import "base:runtime"
import "vendor:glfw"

// Input — GLFW events in, one Action out. This file does no verbs and holds no chord: it tracks
// what is held, asks bind.odin which Action a keystroke names, and hands it to action.odin.
//
// THE WHOLE ROUTE, in order:
//
//   1. Bookkeeping. Blink, the perf timestamp, and standing the pointer down (a BARE MODIFIER
//      does not count — Alt+click needs the cursor on screen to aim with).
//   2. Held keys. Alt / Ctrl / Shift / A, which drive the switcher, the chord bar and the
//      cursor-trail chord. A held key is not a bind: it qualifies the NEXT keystroke for as
//      long as you hold it, which no chord table can say.
//   3. An open context menu, which owns four keys and nothing else.
//   4. The lookup: Global, then the one context the surface with the keys is in (bind.odin).
//   5. The passthrough. Whatever nothing claimed reaches a live terminal — that is the only
//      difference between the terminal and a pane. An Alt chord is never the job's.
//
// **The bind table is the documentation.** The 90-line chord list this header used to carry was
// a copy of the routing below it, and the two could drift; BINDS (bind.odin) is now the one
// place a key is written down.
//
// Non-modal, Alt-rooted: bare keys stay free for typing, navigation is the ARROW KEYS only
// (hjkl have to type), and pane / terminal navigation lives under Alt.
//
// Pointer input (mouse.odin) is ADDITIVE: never the only route to anything, which is what makes
// `mouse: off` a preference rather than a mutilation. Every pointer verb has a keyboard twin,
// and the next one has to as well.
//
//   click                     place the caret / select a row     a motion key, Up / Down
//   Shift+click               extend the selection               Shift + a motion
//   Alt+click                 drop a cursor there                Alt+A, then walk it
//   double click              select the word / open or run it   Ctrl+Left, Shift+Ctrl+Right / Enter
//   triple click              select the line                    Home, Shift+End
//   click a fold marker       expand the block                   Ctrl+Enter
//   right click               open the file-ops menu             hold Ctrl (the chord bar)
//   click a top-bar button    back / forward / reload / view     Ctrl+Left/Right, ^r, ^g
//   click a path segment      go to that folder                  Left, or `cd`
//   click a places row        go to that shortcut                Ctrl+1..9
//   drag                      extend by the grade the press set  Shift + a motion
//   drag the divider          nudge the split                    Alt+[ / Alt+]
//   drag an image             pan the view                       the arrow keys
//   double click an image     reset it to fit                    0 / f
//   wheel                     scroll the view under the pointer  PageUp / PageDown, arrows
//   wheel over an image       zoom about the pointer             Ctrl+= / Ctrl+-
//
// FOUR RULES, the whole of the pointer's behaviour (mouse.odin has the detail):
//   1. A WHEEL SCROLLS A VIEW — never a selection, a caret, or focus; and it DETACHES.
//   2. A CLICK ACTS ON PRESS AND NAMES ONE THING; an unclaimed press dies with the frame.
//   3. FOCUS FOLLOWS THE CLICK, and only the click — never a wheel, never the divider.
//   4. THE KEYBOARD OUTRANKS THE POINTER: any key that does something stands it down. A BARE
//      MODIFIER is excluded — Alt+click needs the cursor on screen to aim with.
//
// The context menu (contextmenu.odin) is the one pointer surface with no keyboard OPENER, and
// it does not need one: every item on it is a chord above, with the chord printed beside it.
// It is a way to read the table with a mouse in your hand, never a way to reach a verb.

// Is this key a bare modifier — one that qualifies the next keystroke rather than being one?
// Super and CapsLock are included: the question is "did the user ask for something".
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
    wake_mark() // a keystroke earns a frame, even one handle_key ignores (chord bars, modifiers)
    handle_key(a, key, action, mods)
}

// Unicode text input. The focused editable owns it — the same one the Text binds act on, asked
// with the same proc, so the keys that TYPE and the keys that EDIT can never disagree about
// which box they are in. Alt-combos like Alt+C must not leak their letter in, hence the guard.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || a.alt_held || codepoint < 32 {
        return
    }
    wake_mark()
    a.last_input_at = glfw.GetTime()
    a.blink_base = a.last_input_at // typing: caret solid, then resumes blinking
    a.move_all_armed = false // typing isn't a motion; cancel a pending move-all
    mouse_stand_down(a) // typing hides the pointer, exactly as a bound key does

    // A live terminal is not an editable: its characters go to the job, not to a Doc.
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
        // Auto-pairs first, else a plain insert — the one editable that closes a bracket for you.
        b := editor_current(&a.editor)
        if !buffer_autopair(b, codepoint) {
            buffer_insert_rune(b, codepoint)
        }
    case .Config_Search:
        doc_insert_rune(d, codepoint)
        config_pane_filter(&a.config_pane) // live filter as you type
    case .Command_Line, .Browse_Path, .Config_Value:
        doc_insert_rune(d, codepoint)
    }
}

handle_key :: proc(a: ^App, key, action, mods: i32) {
    if action == glfw.PRESS || action == glfw.REPEAT {
        now := glfw.GetTime()
        a.blink_base = now // any keypress holds the caret solid, then blinks
        a.last_input_at = now // perf log: timestamp for keystroke->present latency

        // The keyboard takes over: hide the pointer and stop it hovering. A BARE MODIFIER does
        // not count — Alt+click drops a cursor, so holding Alt must leave the cursor on screen
        // to aim with, and Ctrl held is the filetree's chord bar.
        if !key_is_modifier(key) {
            mouse_stand_down(a)
        }
    }

    // --- held keys --- Not binds: each qualifies the NEXT keystroke, and drives an overlay
    // while it is down. The switcher hides while Ctrl or Shift is also held, because Alt+Ctrl
    // and Alt+Shift are the terminal's copy-cursor chords rather than session switching.
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

    // The config pane's inline editor is reconciled against the highlighted row before anything
    // reads it: a mid-frame click may have moved the selection off a text row since the last one.
    if a.focus == .Aux && a.aux_mode == .Config {
        config_edit_sync(a)
    }

    // An open context menu owns the four keys that drive a list of buttons, and NOTHING else: any
    // other key closes it and is then handled normally, so a menu opened by a stray press never
    // swallows the keystroke you meant. A bare modifier leaves it up — Ctrl held is still the
    // chord cheat-sheet, and the menu's hints are what it is advertising.
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

    // The one-shot move-all prefix is spent by the next real key, whatever that key turns out to
    // be — a bare modifier on its way to the motion must not eat it.
    all := false
    if !key_is_modifier(key) {
        all = a.move_all_armed
        a.move_all_armed = false
    }

    if a.alt_held && a.a_held && cursor_trail(a, key) {
        return
    }

    chord := Chord{key, mods & CHORD_MODS}
    if b, ok := bind_find(chord, bind_ctx(a, chord)); ok && !cl_swallows(a, b) {
        if action_run(a, b.act, int(key - b.chord.key), chord.mods & glfw.MOD_SHIFT != 0, all) {
            return
        }
    }

    // Nothing of ours claimed it. A live terminal takes what we did not — that is the whole of
    // what makes it a passthrough rather than a pane. An ALT CHORD IS NEVER THE JOB'S: it was
    // ours whether or not it was bound, so an unused one dies here instead of reaching a shell.
    if mods & glfw.MOD_ALT != 0 {
        return
    }
    if tf := term_focused(a); tf != nil {
        terminal_input_key(tf, key, mods)
    }
}

// Whether an open command line eats this bind. It is a transient overlay that OWNS the keyboard
// while it is up: a pane chord firing under it would move focus out from under a line you are
// still typing, and Alt+C would clear the line outright. Only the window-level verbs reach past
// it — the zoom and Escape. The cursor chords are Text binds, so they never come through here.
@(private = "file")
cl_swallows :: proc(a: ^App, b: Bind) -> bool {
    if !a.cl_active || .Global not_in b.ctx {
        return false
    }
    #partial switch b.act {
    case .Escape, .Font_Grow, .Font_Shrink, .Font_Reset:
        return false
    }
    return true
}

// Alt+A held + an arrow: move the free caret and drop a cursor at the new spot, so holding the
// pair and tapping arrows lays a trail. Esc collapses it. A HELD-KEY chord rather than a bind —
// what you hold is a modifier for as long as you hold it, which a chord table cannot express.
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
