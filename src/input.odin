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
        line_insert_rune(&a.cl.line, codepoint)
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

    if action != glfw.PRESS && action != glfw.REPEAT {
        return
    }

    // While the command line is active it owns bare keys (the focused editable).
    if a.cl_active {
        cl_handle_key(a, key, mods)
        return
    }

    if key == glfw.KEY_ESCAPE {
        glfw.SetWindowShouldClose(window, true)
        return
    }

    // Bare keys go to the focused element (the buffer becomes a target in part 3).
    if mods & glfw.MOD_ALT == 0 {
        if a.focus == .Aux && a.aux_mode == .FileTree {
            filetree_key(a, key, mods)
        }
        return
    }

    switch key {
    case glfw.KEY_H, glfw.KEY_LEFT:
        a.focus = .Editor
    case glfw.KEY_L, glfw.KEY_RIGHT:
        a.focus = .Aux

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
    l := &a.cl.line
    shift := mods & glfw.MOD_SHIFT != 0
    ctrl := mods & glfw.MOD_CONTROL != 0

    switch key {
    case glfw.KEY_ESCAPE:
        cl_cancel(a)
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        cl_submit(a)

    case glfw.KEY_LEFT:
        if ctrl {
            line_move_word_left(l, shift)
        } else {
            line_move_left(l, shift)
        }
    case glfw.KEY_RIGHT:
        if ctrl {
            line_move_word_right(l, shift)
        } else {
            line_move_right(l, shift)
        }
    case glfw.KEY_HOME:
        line_move_home(l, shift)
    case glfw.KEY_END:
        line_move_end(l, shift)
    case glfw.KEY_A:
        if ctrl do line_move_home(l, shift) // readline: line start
    case glfw.KEY_E:
        if ctrl do line_move_end(l, shift) // readline: line end

    case glfw.KEY_BACKSPACE:
        if ctrl {
            line_delete_word_back(l)
        } else {
            line_delete_back(l)
        }
    case glfw.KEY_DELETE:
        if ctrl {
            line_delete_word_forward(l)
        } else {
            line_delete_forward(l)
        }

    case glfw.KEY_UP:
        cl_history_prev(a)
    case glfw.KEY_DOWN:
        cl_history_next(a)
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
