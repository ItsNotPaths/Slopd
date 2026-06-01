package main

import "base:runtime"
import "core:fmt"
import "vendor:glfw"

// Input: GLFW key events -> mutations on App. Non-modal, Alt-rooted. Bare keys
// stay free for typing (and for navigating a focused aux pane later); navigation
// between panes lives under Alt.
//
// hjkl and the arrow keys are interchangeable: h/Left, j/Down, k/Up, l/Right.
//
// Binds:
//   Alt+H/Left, Alt+L/Right   focus editor / aux pane
//   Alt+C                     open the command line
//   Alt+F/T/G/P               aux mode: FileTree / Terminal / Git / Procmon
//   Alt+1..9                  jump to terminal session N (i3-style)
//   Alt+N / Alt+Q             terminal: new / close session (max 99)
//   Alt+K/Up, Alt+J/Down      terminal: switch session (switcher shows while Alt held)
//   Alt+[ / Alt+]             nudge the split
//   Esc                       quit
// While the command line is active it owns bare keys (see cl_handle_key).

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil {
        return
    }
    handle_key(a, window, key, action, mods)
}

// Unicode text input. The focused editable owns it; for now that is the command
// line when active. (The buffer becomes a target in Part 3.) Alt-combos like
// Alt+C must not leak their letter in, hence the alt_held guard.
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
    context = runtime.default_context()
    a := (^App)(glfw.GetWindowUserPointer(window))
    if a == nil || a.alt_held {
        return
    }
    if a.cl_active {
        doc_insert_rune(&a.cl.doc, codepoint)
    } else if a.focus == .Editor && codepoint >= 32 {
        buffer_insert_rune(editor_current(&a.editor), codepoint)
    }
}

handle_key :: proc(a: ^App, window: glfw.WindowHandle, key, action, mods: i32) {
    // Track Alt held — drives the terminal-session overlay.
    if key == glfw.KEY_LEFT_ALT || key == glfw.KEY_RIGHT_ALT {
        if action == glfw.PRESS {
            a.alt_held = true
        } else if action == glfw.RELEASE {
            a.alt_held = false
        }
        return
    }

    // Track A held (Alt+A + direction is the cursor-drop chord). Don't return: A
    // is still an ordinary key (typing, the command line's Ctrl+A).
    if key == glfw.KEY_A {
        if action == glfw.PRESS {
            a.a_held = true
        } else if action == glfw.RELEASE {
            a.a_held = false
        }
    }

    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }

    // While the command line is active it owns bare keys (the focused editable).
    if a.cl_active {
        cl_handle_key(a, key, mods)
        return
    }

    // Escape: collapse a multi-cursor set back to one, else quit.
    if key == glfw.KEY_ESCAPE {
        b := editor_current(&a.editor)
        if a.focus == .Editor && len(b.cursors) > 1 {
            doc_collapse_to_primary(&b.doc)
        } else {
            glfw.SetWindowShouldClose(window, true)
        }
        return
    }

    // Cursor-drop chord: Alt+A held + a direction drops a cursor and steps that
    // way (hold Alt+A, tap arrows to lay a trail). Not a mode — only while A is
    // physically held. hjkl == arrows. Intercepts before the Alt nav switch.
    if a.alt_held && a.a_held && a.focus == .Editor {
        b := &editor_current(&a.editor).doc
        switch key {
        case glfw.KEY_UP, glfw.KEY_K:
            doc_add_cursor(b, -1, 0);return
        case glfw.KEY_DOWN, glfw.KEY_J:
            doc_add_cursor(b, +1, 0);return
        case glfw.KEY_LEFT, glfw.KEY_H:
            doc_add_cursor(b, 0, -1);return
        case glfw.KEY_RIGHT, glfw.KEY_L:
            doc_add_cursor(b, 0, +1);return
        }
    }

    // Bare keys go to the focused element.
    if mods & glfw.MOD_ALT == 0 {
        if a.focus == .Editor {
            buffer_key(a, key, mods)
        } else if a.focus == .Aux && a.aux_mode == .FileTree {
            filetree_key(a, key, mods)
        }
        return
    }

    switch key {
    case glfw.KEY_H, glfw.KEY_LEFT:
        a.focus = .Editor
    case glfw.KEY_L, glfw.KEY_RIGHT:
        a.focus = .Aux

    // Alt+A is the cursor-drop chord (handled above with a direction); on its own
    // it is a no-op — the caret is already a cursor at the current location.
    case glfw.KEY_A:

    case glfw.KEY_C:
        cl_open(a)

    case glfw.KEY_1 ..= glfw.KEY_9: // i3-style quick-jump to terminal N
        term_focus(a, int(key - glfw.KEY_1) + 1)

    case glfw.KEY_F:
        set_aux(a, .FileTree)
    case glfw.KEY_T:
        set_aux(a, .Terminal)
    case glfw.KEY_G:
        set_aux(a, .Git)
    case glfw.KEY_P:
        set_aux(a, .Procmon)

    case glfw.KEY_N:
        if a.aux_mode == .Terminal && a.term_count < 99 {
            a.term_count += 1
            a.term_active = a.term_count - 1 // focus the new session
        }
    case glfw.KEY_Q:
        if a.aux_mode == .Terminal && a.term_count > 1 {
            a.term_count -= 1
            if a.term_active >= a.term_count {
                a.term_active = a.term_count - 1
            }
        }

    // Alt+Up/Down is exclusively terminal-session switching.
    case glfw.KEY_K, glfw.KEY_UP:
        if a.aux_mode == .Terminal && a.term_count > 0 {
            a.term_active = (a.term_active - 1 + a.term_count) % a.term_count
        }
    case glfw.KEY_J, glfw.KEY_DOWN:
        if a.aux_mode == .Terminal && a.term_count > 0 {
            a.term_active = (a.term_active + 1) % a.term_count
        }

    case glfw.KEY_LEFT_BRACKET:
        a.split = clampf(a.split - 0.02, 0.15, 0.85)
    case glfw.KEY_RIGHT_BRACKET:
        a.split = clampf(a.split + 0.02, 0.15, 0.85)
    }
}

// Command-line key handling (active only). Bare keys edit; Ctrl jumps by word and
// (A/E) to the line ends, readline-style; Shift extends the selection.
cl_handle_key :: proc(a: ^App, key, mods: i32) {
    d := &a.cl.doc
    shift := mods & glfw.MOD_SHIFT != 0
    ctrl := mods & glfw.MOD_CONTROL != 0

    switch key {
    case glfw.KEY_ESCAPE:
        cl_cancel(a)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        cl_submit(a)

    case glfw.KEY_LEFT:
        if ctrl {
            doc_move_word_left(d, shift)
        } else {
            doc_move_left(d, shift)
        }
    case glfw.KEY_RIGHT:
        if ctrl {
            doc_move_word_right(d, shift)
        } else {
            doc_move_right(d, shift)
        }
    case glfw.KEY_HOME:
        doc_move_home(d, shift)
    case glfw.KEY_END:
        doc_move_end(d, shift)
    case glfw.KEY_A:
        if ctrl do doc_move_home(d, shift) // readline: line start
    case glfw.KEY_E:
        if ctrl do doc_move_end(d, shift) // readline: line end

    case glfw.KEY_BACKSPACE:
        if ctrl {
            doc_delete_word_back(d)
        } else {
            doc_backspace(d)
        }
    case glfw.KEY_DELETE:
        if ctrl {
            doc_delete_word_forward(d)
        } else {
            doc_delete(d)
        }

    case glfw.KEY_UP:
        cl_history_prev(a)
    case glfw.KEY_DOWN:
        cl_history_next(a)
    }
}

// Buffer key handling (bare keys, when the editor is focused). hjkl TYPE here —
// only the arrow keys move (non-modal). Ctrl jumps by word, deletes a word, saves.
buffer_key :: proc(a: ^App, key, mods: i32) {
    b := editor_current(&a.editor)
    ctrl := mods & glfw.MOD_CONTROL != 0
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        buffer_newline(b)
    case glfw.KEY_TAB:
        buffer_indent(b, a.indent)
    case glfw.KEY_BACKSPACE:
        if ctrl {
            buffer_delete_word_back(b)
        } else {
            buffer_backspace(b)
        }
    case glfw.KEY_DELETE:
        buffer_delete(b)
    case glfw.KEY_LEFT:
        if ctrl {
            buffer_word_left(b)
        } else {
            buffer_left(b)
        }
    case glfw.KEY_RIGHT:
        if ctrl {
            buffer_word_right(b)
        } else {
            buffer_right(b)
        }
    case glfw.KEY_UP:
        buffer_up(b)
    case glfw.KEY_DOWN:
        buffer_down(b)
    case glfw.KEY_HOME:
        buffer_home(b)
    case glfw.KEY_END:
        buffer_end(b)
    case glfw.KEY_S:
        if ctrl {
            _ = buffer_save(b)
        }
    }
}

// Filetree key handling (bare keys, when the filetree aux pane is focused).
filetree_key :: proc(a: ^App, key, mods: i32) {
    ft := &a.tree
    switch key {
    case glfw.KEY_J, glfw.KEY_DOWN:
        filetree_move(ft, 1)
    case glfw.KEY_K, glfw.KEY_UP:
        filetree_move(ft, -1)
    case glfw.KEY_L, glfw.KEY_RIGHT:
        filetree_enter(ft) // into the selected folder
    case glfw.KEY_H, glfw.KEY_LEFT:
        filetree_parent(ft) // up to the parent
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        if mods & glfw.MOD_SHIFT != 0 {
            // Shift+Enter on a dir: set the project root via the command line.
            if e := filetree_selected(ft); e != nil && e.is_dir {
                cl_inject(a, fmt.tprintf("cd %s", e.path))
            }
        } else if path, is_file := filetree_activate(ft); is_file {
            open_file(a, path)
        }
    }
}

// Jumping to an aux mode focuses the aux pane (like the command-line goto does).
set_aux :: proc(a: ^App, mode: AuxMode) {
    a.aux_mode = mode
    a.focus = .Aux
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
