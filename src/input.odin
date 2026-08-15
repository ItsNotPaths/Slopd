package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "vendor:glfw"

// Input: GLFW key events -> mutations on App. Non-modal, Alt-rooted: bare keys stay free for
// typing, navigation is the ARROW KEYS only (hjkl have to type), and pane/terminal navigation
// lives under Alt.
//
// Binds:
//   Alt+Left/Right            focus editor / aux pane
//   Alt+E                     focus the editor (in Full: swap the full-window surface to it)
//   Alt+C                     open the command line
//   Alt+W                     open the command line pre-filled for a line jump ("j ")
//   Alt+Enter                 editor: follow the token under the caret (def / URL / [[file]] / colour);
//                             filetree: cd to the selected folder (stage in CL, or run; config)
//   Enter                     filetree: open the entry — or RUN it, when it is a binary or a
//                             script, in the `run_term` session (Ctrl+O opens one anyway)
//   Shift+Enter               filetree: open the entry in the OS default app (xdg-open); a
//                             binary/script instead stages its run command in the CL, for a
//                             run you want to type arguments onto
//   Alt+F/T/R                 aux mode: FileTree / Terminal / gRep results
//                             (FileTree wears one of two faces — the dired listing or the
//                             file browser — per the `file_pane` config; same model, same
//                             chords, different pixels and different pointer targets)
//   Alt+G                     open the configured git tool at the project root (git_tool.odin)
//   Alt+1..9                  jump to terminal session N (i3-style)
//   Alt+N / Alt+Q             terminal: new / close session (max 99)
//   Alt+L                     terminal: lock/unlock its cwd (tu skips it; number greyed)
//   Alt+Up/Down               terminal: switch session (switcher shows while Alt held)
//   Ctrl+Alt+Up/Down          terminal: move the row-only copy cursor (scrolls our
//                             scrollback); on an alt-screen TUI it drives the TUI's own
//                             scroll at the grid edge (wheel if it tracks the mouse, else
//                             PageUp/Down) so you can reveal + select its content
//   PageUp/PageDown           terminal: same copy-cursor move on a normal shell; on the
//                             alt screen it passes through so the TUI pages its own buffer
//   Shift+Alt+Up/Down         terminal: extend a line selection from the copy cursor
//   Ctrl+Shift+C              terminal: copy the selected lines (Esc / typing exits)
//   Ctrl+Up/Down              editor: jump app.jump_lines lines (Shift extends selection)
//   Alt+[ / Alt+]             nudge the split
//   Alt+A (+ arrow)           drop a cursor / lay a multi-cursor trail (Esc collapses)
//   Alt+M                     one-shot prefix: next motion moves every cursor
//   Esc                       cancel CL / move-all / multi-cursor, else Zen on + flip pane side
//   Ctrl+= / Ctrl+- / Ctrl+0  font zoom: grow / shrink / reset text in every pane (global)
//   Ctrl+Enter                editor: collapse / expand the block opening on the line
// Filetree / file browser chords (filetree_ops_key — the SAME table under both faces):
//   Ctrl+Y / Ctrl+U           mark or unmark the entry / clear every mark
//   Ctrl+C / Ctrl+X / Ctrl+V  copy / cut / paste — the clipboard is filled from the marked
//                             set, or from the row under the cursor when nothing is marked;
//                             a cut is spent by its paste, a copy is not
//   Ctrl+D / Ctrl+Shift+D     delete the entry / the marked set, by staging an `rm -rf`
//   Ctrl+W / Ctrl+Shift+W     copy the entry's path / the browsed directory's
//   Ctrl+O                    open the entry in the EDITOR whatever it is — the way back to a
//                             script that plain Enter now runs
//   Ctrl+I / Ctrl+Shift+I     print the entry's / the browsed directory's properties (mode,
//                             size, owner, mtime, birth) in t1, surfacing it — a `stat` run,
//                             not a dialog, so it lands in scrollback like any other output
// The browser adds its top bar and sidebar on top of those, and nothing else:
//   Ctrl+Left / Ctrl+Right    history back / forward       Ctrl+R  reload
//   Ctrl+G                    list <-> grid                Ctrl+1..9  open place N
//   Backspace                 up a directory (the only way out of a grid, where Left/Right
//                             step a tile rather than leaving the folder)
//
// Bare keys go to the focused editable (see cl_handle_key / buffer_key): typing,
// motion, Tab, undo/redo (Ctrl+Z/Y), save (Ctrl+S), clipboard (Ctrl+C/X/V).
//
// Pointer input (mouse.odin) is ADDITIVE: never the only route to anything above, which is
// what makes `mouse: off` a preference rather than a mutilation. Every pointer verb below has
// a keyboard twin, and the next one has to as well.
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
// Super and CapsLock are included: the question is "did the user ask for something". Alt is
// unreachable in two of the three callers, so one set serves all of them.
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
    handle_key(a, key, action, mods)
}

// Unicode text input. The focused editable owns it: the command line when active,
// otherwise the editor buffer (auto-pairs first, else a plain insert). Alt-combos
// like Alt+C must not leak their letter in, hence the alt_held guard.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || a.alt_held {
        return
    }
    a.last_input_at = glfw.GetTime()
    a.blink_base = a.last_input_at // typing: caret solid, then resumes blinking
    a.move_all_armed = false // typing isn't a motion; cancel a pending move-all
    mouse_stand_down(a) // typing hides the pointer, exactly as a bound key does
    if a.cl_active {
        doc_insert_rune(&a.cl.doc, codepoint)
    } else if tf := term_focused(a); tf != nil {
        terminal_input_rune(tf, codepoint)
    } else if filebrowser_path_live(a) && codepoint >= 32 {
        doc_insert_rune(&a.filebrowser.path, codepoint) // the open path line owns the keys
    } else if a.focus == .Aux && a.aux_mode == .Config && codepoint >= 32 {
        // Two kinds of row take text — the search box (filtering live) and a free-text
        // setting; the rest are dropdowns, navigated with the arrows.
        cp := &a.config_pane
        config_edit_sync(a) // the highlighted row owns the Doc before it owns the keystroke
        if cp.open != .None {
            // An open dropdown swallows typing: it is a closed list, navigated with
            // the arrows, and there is nothing here for a character to mean.
        } else if config_pane_is_search(cp.sel) {
            doc_insert_rune(&cp.search, codepoint)
            config_pane_filter(cp) // live filter as you type
        } else if cp.edit_row == cp.sel {
            doc_insert_rune(&cp.edit, codepoint)
        }
    } else if a.focus == .Editor && a.main == .Text && codepoint >= 32 {
        b := editor_current(&a.editor)
        if !buffer_autopair(b, codepoint) {
            buffer_insert_rune(b, codepoint)
        }
    }
}

handle_key :: proc(a: ^App, key, action, mods: i32) {
    if action == glfw.PRESS || action == glfw.REPEAT {
        now := glfw.GetTime()
        a.blink_base = now // any keypress holds the caret solid, then blinks
        a.last_input_at = now // perf log: timestamp for keystroke->present latency

        // The keyboard takes over: hide the pointer and stop it hovering. A BARE MODIFIER
        // does not count — Alt+click drops a cursor, so holding Alt must leave the cursor on
        // screen to aim with, and Ctrl held is the filetree's chord bar.
        if !key_is_modifier(key) {
            mouse_stand_down(a)
        }
    }

    // Track Alt held — drives the terminal-session overlay (fading it in on press).
    if key == glfw.KEY_LEFT_ALT || key == glfw.KEY_RIGHT_ALT {
        if action == glfw.PRESS {
            a.alt_held = true
            anim_start(&a.switcher_anim, glfw.GetTime(), 0, 1, SWITCHER_DUR)
        } else if action == glfw.RELEASE {
            a.alt_held = false
        }
        return
    }

    // Track Ctrl/Shift held (fall through — they are still ordinary chord modifiers).
    // The switcher hides while either is down: Alt+Ctrl / Alt+Shift are the terminal
    // copy-cursor chords, not session switching.
    switch key {
    case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL:
        a.ctrl_held = action != glfw.RELEASE
        if action == glfw.PRESS {
            anim_start(&a.chord_anim, glfw.GetTime(), 0, 1, SWITCHER_DUR) // fade the filetree chord bar in
        }
    case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
        a.shift_held = action != glfw.RELEASE
    }

    // Track A held (Alt+A + a direction is the cursor-drop chord). Don't return: A
    // is still an ordinary key (typing, readline Ctrl+A). A bare Alt+A press drops a
    // cursor at the active editable's caret (command line or buffer).
    if key == glfw.KEY_A {
        if action == glfw.PRESS {
            a.a_held = true
            if a.alt_held && (a.cl_active || a.focus == .Editor) {
                doc_drop_anchor(active_doc(a))
            }
        } else if action == glfw.RELEASE {
            a.a_held = false
        }
    }

    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }

    d := active_doc(a)
    // An editable owns the keys: the command line, or the editor when the main pane is
    // showing text. An image surface has no doc, so caret/drop/move-all chords no-op there.
    editing := a.cl_active || (a.focus == .Editor && a.main == .Text)

    // An open context menu owns the four keys that drive a list of buttons, and NOTHING else:
    // any other key closes it and is then handled normally, so a menu opened by a stray press
    // never swallows the keystroke you meant. A bare modifier leaves it up — Ctrl held is still
    // the chord cheat-sheet, and the menu's hints are what it is advertising.
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

    // Escape: a focused live terminal gets it first, so vim etc. see it. Otherwise cancel the
    // command line, a move-all prefix, or a multi-cursor set; with nothing to cancel it drives
    // Zen — turning it on (never off), then flipping the shown pane side.
    if key == glfw.KEY_ESCAPE {
        if a.cl_chain.waiting {
            cl_chain_clear(a) // abandon a stuck/pending && chain (the shell command runs on)
        } else if ts := term_sel_target(a); ts != nil && (ts.sel_active || ts.msel_on) {
            // First Esc leaves the selection, back to the input line — whichever way it was
            // made. terminal_sel_reset drops both.
            terminal_sel_reset(ts)
        } else if tf := term_focused(a); tf != nil {
            terminal_input_key(tf, key, mods)
        } else if a.cl_active {
            cl_cancel(a)
        } else if filebrowser_path_live(a) {
            filebrowser_path_cancel(a) // the path bar goes back to being buttons
        } else if a.move_all_armed {
            a.move_all_armed = false
        } else if a.focus == .Editor && a.main == .Text && len(d.cursors) > 1 {
            doc_collapse_to_primary(d)
        } else {
            zen_escape(a)
        }
        return
    }

    // Cursor-drop chord: while Alt+A is held, each arrow moves the free caret and
    // drops a cursor at the new spot (command line or buffer).
    if a.alt_held && a.a_held && editing {
        moved := true
        switch key {
        case glfw.KEY_UP:
            doc_move(d, .Up)
        case glfw.KEY_DOWN:
            doc_move(d, .Down)
        case glfw.KEY_LEFT:
            doc_move(d, .Left)
        case glfw.KEY_RIGHT:
            doc_move(d, .Right)
        case:
            moved = false
        }
        if moved {
            doc_drop_anchor(d)
            return
        }
    }

    // Alt chords. Alt+M (the move-all prefix) and the drop chord above serve both
    // the command line and the buffer; the pane-nav chords are skipped while the
    // command line is active (a transient overlay that owns the rest of its keys).
    if mods & glfw.MOD_ALT != 0 {
        a.move_all_armed = false // any Alt chord cancels a pending move-all
        if key == glfw.KEY_M {
            a.move_all_armed = editing // arm the one-shot move-all prefix
            return
        }
        if a.cl_active {
            return
        }
        switch key {
        case glfw.KEY_LEFT:
            set_focus(a, .Editor)
        case glfw.KEY_RIGHT:
            set_focus(a, .Aux)

        // Alt+A is the cursor-drop chord (handled above); alone it is a no-op.
        case glfw.KEY_A:

        case glfw.KEY_C:
            cl_open(a) // an empty line: what you type is a SHELL command

        case glfw.KEY_SEMICOLON:
            // The same line with the builtin sigil pre-typed — the one keystroke, not a second
            // command line. (A physical key, as GLFW reports it: Alt+; on a US layout.)
            cl_open(a, ":")

        case glfw.KEY_W: // open the command line pre-filled for a line jump
            cl_inject(a, ":j ")

        case glfw.KEY_ENTER, glfw.KEY_KP_ENTER: // editor: follow the token under the caret; filetree: cd
            if a.aux_mode == .FileTree && a.focus == .Aux {
                filetree_cd_selected(a)
            } else if a.focus == .Editor && a.main == .Text {
                link_follow(a) // jump to def / open URL / open [[file]].md / stash a colour
            }

        case glfw.KEY_1 ..= glfw.KEY_9: // i3-style quick-jump to terminal N
            term_focus(a, int(key - glfw.KEY_1) + 1)

        case glfw.KEY_E:
            set_focus(a, .Editor) // swap the full-window surface to the editor (mirror of Alt+T/G/F)
        case glfw.KEY_F:
            set_aux(a, .FileTree)
        case glfw.KEY_T:
            set_aux(a, .Terminal)
            term_ensure(a) // spawn t1 on first reveal of the terminal pane
        case glfw.KEY_G:
            git_tool_open(a) // hand the project root to the configured external git tool
        case glfw.KEY_R:
            set_aux(a, .Grep) // re-focus the grep results pane (last search)

        case glfw.KEY_N:
            if a.aux_mode == .Terminal {
                term_new(a)
            }
        case glfw.KEY_Q:
            if a.aux_mode == .Terminal {
                term_close_active(a)
            }
        case glfw.KEY_L: // lock/unlock the active terminal's cwd (tu skips locked)
            if a.aux_mode == .Terminal {
                if t := term_current(a); t != nil {
                    t.locked = !t.locked
                }
            }

        // Alt+Up/Down drives the terminal pane: bare cycles session, Ctrl+Alt moves the
        // copy cursor into scrollback, Shift+Alt grows a line selection from it, and
        // Ctrl+Shift+C copies. The editor's line jump is Ctrl+Up/Down (buffer_key).
        case glfw.KEY_UP, glfw.KEY_DOWN:
            dir := key == glfw.KEY_UP ? -1 : 1
            if a.aux_mode == .Terminal && term_count(a) > 0 {
                t := term_current(a)
                switch {
                case mods & glfw.MOD_CONTROL != 0:
                    terminal_sel_move(t, dir, false)
                case mods & glfw.MOD_SHIFT != 0:
                    terminal_sel_move(t, dir, true)
                case:
                    a.term_active = (a.term_active + dir + term_count(a)) % term_count(a)
                }
            }

        case glfw.KEY_LEFT_BRACKET:
            a.split = clampf(a.split - 0.02, SPLIT_MIN, SPLIT_MAX)
        case glfw.KEY_RIGHT_BRACKET:
            a.split = clampf(a.split + 0.02, SPLIT_MIN, SPLIT_MAX)
        }
        return
    }

    // Global font zoom. Gated on Ctrl-without-Alt so bare =/-/0 still type, and handled here
    // rather than per-pane because the zoom is not owned by any pane. The main loop re-bakes
    // the atlas next frame from app.font_px.
    if mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_ALT == 0 {
        switch key {
        case glfw.KEY_EQUAL, glfw.KEY_KP_ADD:
            font_zoom(a, +1)
            return
        case glfw.KEY_MINUS, glfw.KEY_KP_SUBTRACT:
            font_zoom(a, -1)
            return
        case glfw.KEY_0, glfw.KEY_KP_0:
            font_zoom_reset(a)
            return
        }
    }

    // Ctrl+Shift+C copies the terminal's line selection to the clipboard (the shell
    // gets plain Ctrl+C; Shift carves out the copy). Checked before the routing below
    // so libvterm never sees it.
    if ts := term_sel_target(a);
       ts != nil && key == glfw.KEY_C && mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_SHIFT != 0 {
        term_copy(a, ts)
        return
    }

    // Ctrl+Shift+V pastes into the terminal, the mirror of the copy above. Gated on the PANE
    // rather than on a live shell so a dead session swallows it: falling through would reach
    // terminal_input_key, which sees only the Ctrl and sends ^V — readline's quoted-insert.
    if ts := term_sel_target(a);
       ts != nil && key == glfw.KEY_V && mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_SHIFT != 0 {
        term_paste(a, ts)
        return
    }

    // PageUp/PageDown alias the copy-cursor move, Shift extending. Only on the NORMAL screen:
    // a full-screen TUI owns its scrollback and must see the key. term_sel_target, not
    // term_focused, to match the selector it aliases — a dead shell scrolls too.
    if ts := term_sel_target(a);
       ts != nil && !ts.on_altscreen && (key == glfw.KEY_PAGE_UP || key == glfw.KEY_PAGE_DOWN) {
        terminal_sel_move(ts, key == glfw.KEY_PAGE_UP ? -1 : 1, mods & glfw.MOD_SHIFT != 0)
        return
    }

    // A focused live terminal owns the rest: send specials + Ctrl-combos to libvterm
    // (printable text arrives via char_callback). Alt chords and the global Ctrl +/-
    // zoom were already handled above, so the shell only ever sees its own keys.
    if tf := term_focused(a); tf != nil {
        terminal_input_key(tf, key, mods)
        return
    }

    // Bare keys go to the focused editable, consuming a pending move-all prefix (a
    // bare modifier on its way to the motion must not eat it).
    all := false
    if !key_is_modifier(key) {
        all = a.move_all_armed
        a.move_all_armed = false
    }
    if a.cl_active {
        cl_handle_key(a, key, mods, all)
    } else if a.focus == .Editor {
        if a.main == .Text {
            buffer_key(a, key, mods, all)
        } else {
            media_key(a, key, mods) // image surface: arrows pan, =/- zoom, 0/f fit
        }
    } else if a.focus == .Aux && a.aux_mode == .FileTree {
        // The two presentations share every file-op chord (filetree_ops_key) and differ only in
        // what the ARROWS mean — which is the difference between a list and a browser.
        switch a.file_pane {
        case .Ls:
            filetree_key(a, key, mods)
        case .Browser:
            filebrowser_key(a, key, mods)
        }
    } else if a.focus == .Aux && a.aux_mode == .Config {
        config_key(a, key, mods)
    } else if a.focus == .Aux && a.aux_mode == .Grep {
        grep_key(a, key, mods)
    }
}

// Grep aux mode keys (arrows only). Up/Down move the highlighted result; Enter opens it in
// the editor (focusing the editor). The results themselves are produced by the CL `grep`
// builtin (cl_grep) or Alt+Enter's multi-definition goto (link.odin).
grep_key :: proc(a: ^App, key, mods: i32) {
    switch key {
    case glfw.KEY_UP:
        grep_move(&a.grep, -1)
    case glfw.KEY_DOWN:
        grep_move(&a.grep, 1)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        grep_open_selected(a)
    }
}

// Editing keys shared by the command line and the buffer: horizontal motion (Ctrl = word),
// Home/End, readline Ctrl+A/Ctrl+E, with Shift extending and `all` (the Alt+M prefix) moving
// every cursor. Returns true if it handled a motion. The aux panes' text boxes reuse it.
edit_motion :: proc(d: ^Doc, key, mods: i32, all: bool) -> bool {
    shift := mods & glfw.MOD_SHIFT != 0
    ctrl := mods & glfw.MOD_CONTROL != 0
    m: Motion
    switch key {
    case glfw.KEY_LEFT:
        m = ctrl ? .Word_Left : .Left
    case glfw.KEY_RIGHT:
        m = ctrl ? .Word_Right : .Right
    case glfw.KEY_HOME:
        m = .Home
    case glfw.KEY_END:
        m = .End
    case glfw.KEY_A:
        if !ctrl {return false}
        m = .Home // readline: start of line
    case glfw.KEY_E:
        if !ctrl {return false}
        m = .End // readline: end of line
    case:
        return false
    }
    if all {
        doc_move_all(d, m, shift)
    } else {
        doc_move(d, m, shift)
    }
    return true
}

// The keys a one-line FIELD takes (field_ui.odin): the motion above, the two deletes with their
// Ctrl word twins, and the clipboard — a text box the pointer can select in must also be one
// `^c` copies out of. `handled` says the key was spent here, so a field can add its own Enter;
// `changed` says the text moved, which is what a live filter re-runs on.
edit_keys :: proc(a: ^App, d: ^Doc, key, mods: i32, all := false) -> (handled, changed: bool) {
    if edit_motion(d, key, mods, all) {
        return true, false
    }
    ctrl := mods & glfw.MOD_CONTROL != 0
    switch key {
    case glfw.KEY_BACKSPACE:
        if ctrl {doc_delete_word_back(d)} else {doc_backspace(d)}
        return true, true
    case glfw.KEY_DELETE:
        if ctrl {doc_delete_word_forward(d)} else {doc_delete(d)}
        return true, true
    case glfw.KEY_C, glfw.KEY_X:
        if !ctrl {return false, false} // a bare c or x is a character to type
        return true, field_copy(a, d, key == glfw.KEY_X)
    case glfw.KEY_V:
        if !ctrl {return false, false}
        return true, field_paste(a, d)
    }
    return false, false
}

// Command-line key handling. The same one-line field keys as the config rows and the path bar —
// it is the third instance of that box — differing only in Enter (submit) and Up/Down (history).
cl_handle_key :: proc(a: ^App, key, mods: i32, all: bool) {
    d := &a.cl.doc
    if handled, _ := edit_keys(a, d, key, mods, all); handled {
        return
    }
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        cl_submit(a)

    case glfw.KEY_UP:
        cl_history_prev(a)
    case glfw.KEY_DOWN:
        cl_history_next(a)
    }
}

// Buffer key handling (bare keys, when the editor is focused). hjkl TYPE here —
// only the arrow keys move (non-modal). Shares edit_motion with the command line;
// adds Enter/Tab, vertical motion, deletes, save, undo/redo, and clipboard.
buffer_key :: proc(a: ^App, key, mods: i32, all: bool) {
    b := editor_current(&a.editor)
    ctrl := mods & glfw.MOD_CONTROL != 0
    shift := mods & glfw.MOD_SHIFT != 0 // extends the selection
    if edit_motion(&b.doc, key, mods, all) {
        return
    }
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        if ctrl && a.folding {
            buffer_fold_toggle(a, b) // collapse/expand the block opening on this line
        } else {
            buffer_enter(a, b) // newline with auto-indent / brace expansion
        }
    case glfw.KEY_TAB:
        buffer_tab(b, a.indent)
    case glfw.KEY_BACKSPACE:
        if ctrl {
            buffer_delete_word_back(b)
        } else {
            buffer_backspace(b)
        }
    case glfw.KEY_DELETE:
        if ctrl {
            buffer_delete_word_forward(b)
        } else {
            buffer_delete(b)
        }
    case glfw.KEY_UP: // Ctrl jumps app.jump_lines at once (Shift extends the selection)
        buffer_motion(b, .Up, shift, all, ctrl ? a.jump_lines : 1)
    case glfw.KEY_DOWN:
        buffer_motion(b, .Down, shift, all, ctrl ? a.jump_lines : 1)
    case glfw.KEY_S:
        if ctrl {
            _ = buffer_save(b)
        }
    case glfw.KEY_Z:
        if ctrl && shift {
            buffer_redo(b) // Ctrl+Shift+Z alias for redo
        } else if ctrl {
            buffer_undo(b)
        }
    case glfw.KEY_Y:
        if ctrl {
            buffer_redo(b)
        }
    case glfw.KEY_C:
        if ctrl {
            editor_copy(a)
        }
    case glfw.KEY_X:
        if ctrl {
            editor_cut(a)
        }
    case glfw.KEY_V:
        if ctrl {
            editor_paste(a)
        }
    }
}

// --- clipboard (system clipboard via GLFW + our remembered multi-cursor copy) ---

// Copy: selections (or whole lines when nothing is selected) to the system
// clipboard, remembering the pieces so a later equal-count paste can distribute.
editor_copy :: proc(a: ^App) {
    b := editor_current(&a.editor)
    joined, pieces := doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
}

// Copy a terminal's selected lines (the line-select cursor's range) to the system
// clipboard. Plain joined text — no per-cursor pieces, so paste anywhere is literal.
term_copy :: proc(a: ^App, t: ^Terminal) {
    // Either selection will do — the keyboard's line range or the mouse's character span.
    // terminal_selection_text picks; this only has to know there is something.
    if !t.sel_active && !terminal_msel_has_span(t) {
        return
    }
    clipboard_set(a, terminal_selection_text(t), nil)
}

// Paste the system clipboard into a terminal. Nothing of ours is remembered the way an editor
// paste remembers pieces — the shell gets literal text, and a dead session gets nothing.
term_paste :: proc(a: ^App, t: ^Terminal) {
    if !t.alive {
        return
    }
    terminal_paste(t, glfw.GetClipboardString(a.window))
}

editor_cut :: proc(a: ^App) {
    b := editor_current(&a.editor)
    joined, pieces := doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
    if doc_cut(&b.doc) {
        b.dirty = true
    }
}

// Paste: distribute one piece per caret when the clipboard still holds exactly our
// last multi-cursor copy and the counts line up; otherwise insert the whole text
// at every caret.
editor_paste :: proc(a: ^App) {
    b := editor_current(&a.editor)
    clip := glfw.GetClipboardString(a.window)
    changed: bool
    if len(a.clip_pieces) > 1 && clip == a.clip_joined && len(a.clip_pieces) == len(b.cursors) {
        changed = doc_paste_pieces(&b.doc, a.clip_pieces)
    } else {
        changed = doc_paste(&b.doc, clip)
    }
    if changed {
        b.dirty = true
    }
}

// Pushes text to the system clipboard and takes ownership of our copy of it (the
// joined string + pieces), freeing the previous remembered copy. Package-level since the
// context menu's "copy path" reaches it too (contextmenu.odin).
clipboard_set :: proc(a: ^App, joined: string, pieces: []string) {
    glfw.SetClipboardString(a.window, strings.clone_to_cstring(joined, context.temp_allocator))
    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
    a.clip_joined = joined
    a.clip_pieces = pieces
}

// The file-op Ctrl chords, shared by BOTH presentations of the pane — the dired listing and the
// browser — which is what makes `file_pane` a choice of pixels rather than of capability.
// Returns true when it handled the key, so a presentation can bind its own chords first.
//
// **Clear cut/copy/paste, no yank mode.** `^c` / `^x` FILL the clipboard from the marked set (or
// the row under the cursor) and say which the paste will be; `^v` applies it here. Marking is
// `^y` and is only ever "what does an op act on" — the pane no longer has a mode you can leave
// set from an hour ago. The destructive chord still stages an `rm -rf` in the command line
// rather than deleting behind a prompt: the CL is the confirm.
filetree_ops_key :: proc(a: ^App, key: i32, shift: bool) -> bool {
    ft := &a.tree
    switch key {
    case glfw.KEY_Y:
        filetree_mark_toggle(ft) // mark/unmark the selected entry
    case glfw.KEY_U:
        filetree_marks_reset(ft) // clear the marked set
    case glfw.KEY_C:
        filetree_clip_take(ft, .Copy)
    case glfw.KEY_X:
        filetree_clip_take(ft, .Cut)
    case glfw.KEY_V:
        filetree_paste(ft) // apply the clipboard to the browsed dir
    case glfw.KEY_D:
        // Ctrl+D deletes the highlighted entry; Ctrl+Shift+D the whole marked set.
        filetree_rm_selected(a, shift)
    case glfw.KEY_W:
        // Ctrl+W copies the selected entry's path; Ctrl+Shift+W the browsed dir's path (where
        // the listing IS, not whatever row is hovered). Owned clone — clipboard_set takes it.
        if shift {
            clipboard_set(a, strings.clone(ft.dir), nil)
        } else if e := filetree_selected(ft); e != nil {
            clipboard_set(a, strings.clone(e.path), nil)
        }
    case glfw.KEY_H:
        cl_workspace(a, ft.dir) // make the browsed dir the project root, and sync the terminals
    case glfw.KEY_O:
        filetree_edit_selected(a) // open in the editor even when Enter would run it
    case glfw.KEY_I:
        // Ctrl+I describes the selected entry in t1, Ctrl+Shift+I the browsed directory — the
        // same entry/directory pair Ctrl+W and Ctrl+Shift+W make of the path. (Not ^p: that was
        // the old paste chord, and a stale reflex must not land on a different verb.)
        if e := filetree_selected(ft); e != nil && !shift {
            filetree_props(a, e.path)
        } else {
            filetree_props(a, ft.dir)
        }
    case:
        return false
    }
    return true
}

// Filetree keys (the `ls` presentation). Arrows + Enter navigate (Shift+Enter opens in the OS
// app); Shift+Up/Down sweep-mark a run; the file ops are the shared Ctrl chords above,
// discoverable via the Ctrl-held chord bar.
filetree_key :: proc(a: ^App, key, mods: i32) {
    ft := &a.tree
    ctrl := mods & glfw.MOD_CONTROL != 0
    shift := mods & glfw.MOD_SHIFT != 0

    if ctrl {
        filetree_ops_key(a, key, shift)
        return
    }

    switch key {
    case glfw.KEY_DOWN:
        if shift {
            filetree_mark_sweep(ft, 1) // mark as the cursor sweeps down
        } else {
            filetree_move(ft, 1)
        }
    case glfw.KEY_UP:
        if shift {
            filetree_mark_sweep(ft, -1)
        } else {
            filetree_move(ft, -1)
        }
    case glfw.KEY_RIGHT:
        filetree_enter(ft) // into the selected folder
    case glfw.KEY_LEFT:
        filetree_parent(ft) // up to the parent
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        if shift {
            filetree_open_selected(a) // hand it to the desktop, or stage its run command
        } else {
            filetree_activate_selected(a)
        }
    }
}

// File browser keys. The file ops are the same chords as the listing's; what is new is the top
// bar's four buttons and the sidebar, each with a chord of its own, and arrows that walk a GRID
// when one is up — Left/Right step a tile there rather than leaving the directory, so Backspace
// is the parent in both views and is the only route out of a grid.
filebrowser_key :: proc(a: ^App, key, mods: i32) {
    ft := &a.tree
    br := &a.filebrowser
    ctrl := mods & glfw.MOD_CONTROL != 0
    shift := mods & glfw.MOD_SHIFT != 0
    grid := br.view == .Grid

    // The open path line takes every key: it is a text field, and the arrows walking the listing
    // under it while you are typing a destination would be two things one keystroke means.
    if br.path_edit {
        filebrowser_path_key(a, key, mods)
        return
    }

    if ctrl {
        switch key {
        case glfw.KEY_LEFT:
            filebrowser_button(a, .Back)
        case glfw.KEY_RIGHT:
            filebrowser_button(a, .Forward)
        case glfw.KEY_R:
            filebrowser_button(a, .Reload)
        case glfw.KEY_G:
            filebrowser_button(a, .View) // list <-> grid, the toggle's keyboard twin
        case glfw.KEY_1 ..= glfw.KEY_9:
            filebrowser_place_open(a, int(key - glfw.KEY_1) + 1) // the sidebar's twin
        case:
            filetree_ops_key(a, key, shift)
        }
        return
    }

    // A grid row is `br.cols` entries wide — written by filebrowser_frame, because only the
    // geometry knows how many tiles fit and the keyboard has no pane rect to ask.
    step := grid ? max(1, br.cols) : 1
    switch key {
    case glfw.KEY_DOWN:
        if shift {
            filetree_mark_sweep(ft, step)
        } else {
            filetree_move(ft, step)
        }
    case glfw.KEY_UP:
        if shift {
            filetree_mark_sweep(ft, -step)
        } else {
            filetree_move(ft, -step)
        }
    case glfw.KEY_RIGHT:
        if grid {
            filetree_move(ft, 1)
        } else if e := filetree_selected(ft); e != nil && e.is_dir {
            filebrowser_activate(a) // into the folder, through the history
        }
    case glfw.KEY_LEFT:
        if grid {
            filetree_move(ft, -1)
        } else {
            filebrowser_parent(a)
        }
    case glfw.KEY_BACKSPACE:
        filebrowser_parent(a)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        if shift {
            filetree_open_selected(a)
        } else {
            filebrowser_activate(a)
        }
    }
}

// The path line's keys, while it is open: the shared field keys, and Enter to go where the line
// says (Esc cancels, with the others in handle_key). The FILE-OP chords are not reachable from
// here — in a text field ^c and ^v mean the text, not the listing.
@(private = "file")
filebrowser_path_key :: proc(a: ^App, key, mods: i32) {
    d := &a.filebrowser.path
    if handled, _ := edit_keys(a, d, key, mods); handled {
        return
    }
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        filebrowser_path_commit(a)
    }
}

// Alt+Enter on a selected folder: set the project root via a `:cd <path>` command —
// staged in the command line for review, or run at once, per the folder_cd config.
// No-op unless a directory is selected.
filetree_cd_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && e.is_dir {
        cl_dispatch(a, fmt.tprintf(":cd %s", e.path), a.folder_cd_run)
    }
}

// What Enter (and its double-click twin) does with a FILE in either presentation: run it when it
// is something we could run, open it otherwise. **A program is not a document** — loading a
// binary into the text ring shows you its bytes, which is never what activating it meant.
//
// It runs in the `run_term` session, surfaced, so its output is in front of you. The trailing
// space run_command leaves for typing arguments is trimmed off: that space is Shift+Enter's,
// which STAGES the same line instead — the two halves of "run it" and "run it with flags".
open_or_run :: proc(a: ^App, path: string, exec: bool) {
    if cmd := run_command(path, exec, context.temp_allocator); cmd != "" {
        run_in_term(a, strings.trim_space(cmd), a.run_term)
        return
    }
    open_file(a, path)
}

// Enter in the dired listing: descend into the folder, or open/run the file. One proc because
// three gestures do it — the chord, the double click and the menu's Open.
filetree_activate_selected :: proc(a: ^App) {
    ft := &a.tree
    e := filetree_selected(ft)
    exec := e != nil && e.exec
    // filetree_activate reloads when it DESCENDS, which frees the listing `path` came from —
    // but it only returns a path on the file branch, where nothing was reloaded.
    if path, is_file := filetree_activate(ft); is_file {
        open_or_run(a, path, exec)
    }
}

// Ctrl+O: open the entry in the EDITOR whatever it is — the way back to a script that Enter now
// runs. Everything else in the pane has a chord, and "edit my +x build script" needed one too.
filetree_edit_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && !e.is_dir && e.name != ".." {
        open_file(a, e.path)
    }
}

// Shift+Enter: open the entry the way the DESKTOP would, via xdg-open. The exception is
// anything we could RUN — a binary or script STAGES its run command in the CL instead, since
// running WITH ARGUMENTS is a decision worth reading first. Plain Enter runs it outright.
filetree_open_selected :: proc(a: ^App) {
    e := filetree_selected(&a.tree)
    if e == nil || e.name == ".." {
        return
    }
    if !e.is_dir {
        if cmd := run_command(e.path, e.exec, context.temp_allocator); cmd != "" {
            cl_inject(a, cmd)
            return
        }
    }
    desktop_open(e.path)
}

// Ctrl+D / Ctrl+Shift+D: stage `rm -rf <paths> && :ls` in the command line. The delete is a
// real shell command you read, edit and run with Enter — no modal confirm, and it lands in CL
// history like anything else. No-op with nothing selected or marked.
filetree_rm_selected :: proc(a: ^App, marked: bool) {
    paths := filetree_targets(&a.tree, marked, context.temp_allocator)
    if cmd := rm_command(paths, context.temp_allocator); cmd != "" {
        cl_inject(a, cmd)
    }
}

// Ctrl+P / Ctrl+Shift+P: print `path`'s properties in t1. It RUNS rather than staging (unlike the
// delete above) because `stat` only reads — there is nothing here to review before it happens —
// and it surfaces the terminal, since properties you cannot see were not sent anywhere. Alt+F
// comes back to the browser with the listing where you left it.
filetree_props :: proc(a: ^App, path: string) {
    if cmd := properties_command(path, context.temp_allocator); cmd != "" {
        run_in_t1(a, cmd)
    }
}

// Config pane keys. Up/Down move between rows and the highlighted row owns the rest: a
// setting or language opens a dropdown on Right/Enter, while the search box and a free-text
// setting edit in place, committing on Enter or when the selection leaves.
config_key :: proc(a: ^App, key, mods: i32) {
    cp := &a.config_pane
    // Settle the selection as it STANDS before acting on this key — whatever moved it here
    // may have left a text row, and the Doc below must match the highlighted row before
    // anything reads it. The move this key makes is settled the same way, by config_frame.
    config_edit_sync(a)

    if cp.open != .None {
        config_dropdown_key(a, key)
        return
    }

    switch key {
    case glfw.KEY_UP:
        config_pane_move(cp, -1)
        return
    case glfw.KEY_DOWN:
        config_pane_move(cp, 1)
        return
    }

    // A setting row: Right / Enter opens its choice dropdown — unless the setting is free
    // text, in which case the row IS an editor and owns these keys itself.
    if s, ok := config_pane_setting(cp.sel); ok {
        if setting_is_text(s) {
            config_text_key(a, &cp.edit, key, mods, false)
            return
        }
        switch key {
        case glfw.KEY_RIGHT, glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
            config_pane_open_setting(a, s)
        }
        return
    }

    // A language row: Right / Enter opens its options dropdown.
    if config_pane_lang(cp, cp.sel) != nil {
        switch key {
        case glfw.KEY_RIGHT, glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
            config_pane_open_lang(a)
        }
        return
    }

    // The search box.
    config_text_key(a, &cp.search, key, mods, true)
}

// The pane's two text rows, on the shared field keys; they differ only in what an edit MEANS
// afterwards, which `filter` picks. The language filter re-runs live and has nothing to
// submit; a setting accumulates and Enter commits it (as does leaving the row).
@(private = "file")
config_text_key :: proc(a: ^App, d: ^Doc, key, mods: i32, filter: bool) {
    handled, changed := edit_keys(a, d, key, mods)
    if changed && filter {
        config_pane_filter(&a.config_pane) // an edit, not a motion, is what re-filters
    }
    if handled {
        return
    }
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        if !filter {config_edit_commit(a)}
    }
}

// Navigation within an open dropdown: Up/Down move (config_dropdown_move owns the difference
// between a setting's clamped list and a language's step-out), Left cancels, Enter/Right
// chooses. Both verbs live in config_pane.odin because a click reaches them too.
@(private = "file")
config_dropdown_key :: proc(a: ^App, key: i32) {
    switch key {
    case glfw.KEY_DOWN:
        config_dropdown_move(a, 1)
    case glfw.KEY_UP:
        config_dropdown_move(a, -1)
    case glfw.KEY_LEFT:
        a.config_pane.open = .None // cancel, keep the row selected
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER, glfw.KEY_RIGHT:
        config_choose(a)
    }
}

// A chosen language option builds a `slopd ...` command and runs it in t1 (the master CL
// terminal), through the same seam the command line's shell path uses. Package-level because
// config_choose calls it: the pointer reaches these options too.
config_run_option :: proc(a: ^App, lang: string, opt: LangOption) {
    // Re-invoke ourselves by absolute path (single-quoted for the shell) so these
    // work in the self-contained release where slopd isn't on PATH.
    self := exe_path(context.temp_allocator)
    cmd: string
    switch opt {
    case .Health:
        cmd = fmt.tprintf("'%s' --health %s", self, lang)
    case .Install:
        cmd = fmt.tprintf("'%s' --grammar install %s", self, lang)
    case .Update:
        cmd = fmt.tprintf("'%s' --grammar update %s", self, lang)
    case .Uninstall:
        cmd = fmt.tprintf("'%s' --grammar uninstall %s", self, lang)
    }
    run_in_t1(a, cmd)
}

// Jumping to an aux mode focuses the aux pane (like the command-line goto does).
set_aux :: proc(a: ^App, mode: AuxMode) {
    a.aux_mode = mode
    set_focus(a, .Aux)
}

clampf :: proc(v, lo, hi: f32) -> f32 {
    if v < lo {
        return lo
    }
    if v > hi {
        return hi
    }
    return v
}
