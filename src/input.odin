package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "vendor:glfw"

// Input: GLFW key events -> mutations on App. Non-modal, Alt-rooted. Bare keys
// stay free for typing; navigation uses the ARROW KEYS only (no hjkl aliases — in a
// non-modal editor those letters have to type). Pane/terminal navigation lives under
// Alt.
//
// Binds:
//   Alt+Left/Right            focus editor / aux pane
//   Alt+C                     open the command line
//   Alt+F/T/G/P               aux mode: FileTree / Terminal / Git / Procmon
//   Alt+1..9                  jump to terminal session N (i3-style)
//   Alt+N / Alt+Q             terminal: new / close session (max 99)
//   Alt+Up/Down               terminal: switch session (switcher shows while Alt held)
//   Ctrl+Alt+Up/Down          terminal: move the row-only copy cursor (scrolls history)
//   Shift+Alt+Up/Down         terminal: extend a line selection from the copy cursor
//   Ctrl+Shift+C              terminal: copy the selected lines (Esc / typing exits)
//   Alt+[ / Alt+]             nudge the split
//   Alt+A (+ arrow)           drop a cursor / lay a multi-cursor trail (Esc collapses)
//   Alt+M                     one-shot prefix: next motion moves every cursor
//   Esc                       cancel CL / move-all / multi-cursor, else Zen on + flip pane side
//   Ctrl+= / Ctrl+- / Ctrl+0  font zoom: grow / shrink / reset text in every pane (global)
// Bare keys go to the focused editable (see cl_handle_key / buffer_key): typing,
// motion, Tab, undo/redo (Ctrl+Z/Y), save (Ctrl+S), clipboard (Ctrl+C/X/V).

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
    a.blink_base = glfw.GetTime() // typing: caret solid, then resumes blinking
    a.move_all_armed = false // typing isn't a motion; cancel a pending move-all
    if a.cl_active {
        doc_insert_rune(&a.cl.doc, codepoint)
    } else if tf := term_focused(a); tf != nil {
        terminal_input_rune(tf, codepoint)
    } else if a.focus == .Aux && a.aux_mode == .Config && codepoint >= 32 {
        // Only the search box takes text (filtering live); setting and language rows
        // are dropdowns, navigated with the arrows.
        cp := &a.config_pane
        if config_pane_is_search(cp.sel) && cp.open == .None {
            doc_insert_rune(&cp.search, codepoint)
            config_pane_filter(cp) // live filter as you type
        }
    } else if a.focus == .Editor && codepoint >= 32 {
        b := editor_current(&a.editor)
        if !buffer_autopair(b, codepoint) {
            buffer_insert_rune(b, codepoint)
        }
    }
}

handle_key :: proc(a: ^App, key, action, mods: i32) {
    if action == glfw.PRESS || action == glfw.REPEAT {
        a.blink_base = glfw.GetTime() // any keypress holds the caret solid, then blinks
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
    editing := a.cl_active || a.focus == .Editor // an editable owns the keys

    // Escape: a focused live terminal gets it first (so vim etc. see it) — Esc is
    // carved out of the Zen toggle there. Otherwise cancel the command line, clear a
    // pending move-all prefix, or collapse a multi-cursor set; with nothing to cancel
    // it drives Zen — turning it on (never off), then flipping the shown pane side.
    if key == glfw.KEY_ESCAPE {
        if a.cl_chain.waiting {
            cl_chain_clear(a) // abandon a stuck/pending && chain (the shell command runs on)
        } else if ts := term_sel_target(a); ts != nil && ts.sel_active {
            terminal_sel_reset(ts) // first Esc leaves line-select, back to the input line
        } else if tf := term_focused(a); tf != nil {
            terminal_input_key(tf, key, mods)
        } else if a.cl_active {
            cl_cancel(a)
        } else if a.move_all_armed {
            a.move_all_armed = false
        } else if a.focus == .Editor && len(d.cursors) > 1 {
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
            cl_open(a)

        case glfw.KEY_W: // open the command line pre-filled for a line jump
            cl_inject(a, "j ")

        case glfw.KEY_1 ..= glfw.KEY_9: // i3-style quick-jump to terminal N
            term_focus(a, int(key - glfw.KEY_1) + 1)

        case glfw.KEY_F:
            set_aux(a, .FileTree)
        case glfw.KEY_T:
            set_aux(a, .Terminal)
            term_ensure(a) // spawn t1 on first reveal of the terminal pane
        case glfw.KEY_G:
            set_aux(a, .Git)
        case glfw.KEY_P:
            set_aux(a, .Procmon)

        case glfw.KEY_N:
            if a.aux_mode == .Terminal {
                term_new(a)
            }
        case glfw.KEY_Q:
            if a.aux_mode == .Terminal {
                term_close_active(a)
            }

        // Alt+Up/Down: in the editor, jump app.jump_lines lines (Shift extends the
        // selection). In the terminal pane the bare chord cycles session; Ctrl+Alt
        // moves the row-only copy cursor (scrolling into scrollback), Shift+Alt grows
        // a line selection from it — Ctrl+Shift+C then copies (see the routing below).
        case glfw.KEY_UP, glfw.KEY_DOWN:
            dir := key == glfw.KEY_UP ? -1 : 1
            if a.focus == .Editor {
                motion: Motion = key == glfw.KEY_UP ? .Up : .Down
                buffer_motion(editor_current(&a.editor), motion, mods & glfw.MOD_SHIFT != 0, false, a.jump_lines)
            } else if a.aux_mode == .Terminal && term_count(a) > 0 {
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
            a.split = clampf(a.split - 0.02, 0.15, 0.85)
        case glfw.KEY_RIGHT_BRACKET:
            a.split = clampf(a.split + 0.02, 0.15, 0.85)
        }
        return
    }

    // Global font zoom: Ctrl +/- resizes text in every pane, Ctrl+0 resets. Gated on
    // Ctrl-without-Alt so bare =/-/0 still type into the focused editable, and handled
    // here (not in the per-pane key procs) because the zoom isn't owned by any pane.
    // The main loop re-bakes the atlas next frame from app.font_px.
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
    if !is_modifier_key(key) {
        all = a.move_all_armed
        a.move_all_armed = false
    }
    if a.cl_active {
        cl_handle_key(a, key, mods, all)
    } else if a.focus == .Editor {
        buffer_key(a, key, mods, all)
    } else if a.focus == .Aux && a.aux_mode == .FileTree {
        filetree_key(a, key, mods)
    } else if a.focus == .Aux && a.aux_mode == .Config {
        config_key(a, key, mods)
    }
}

// Editing keys shared by the command line and the buffer (the CL is a one-line
// buffer): horizontal motion (Ctrl = word), Home/End, and readline Ctrl+A/Ctrl+E,
// with Shift extending the selection and `all` (the Alt+M prefix) moving every
// cursor. Returns true if the key was a motion it handled.
@(private = "file")
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

// Command-line key handling. Shares edit_motion with the buffer; differs only in
// Enter (submit) and Up/Down (history).
cl_handle_key :: proc(a: ^App, key, mods: i32, all: bool) {
    d := &a.cl.doc
    ctrl := mods & glfw.MOD_CONTROL != 0
    if edit_motion(d, key, mods, all) {
        return
    }
    switch key {
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
        cl_submit(a)

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
        buffer_newline(b)
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
    case glfw.KEY_UP:
        buffer_motion(b, .Up, shift, all)
    case glfw.KEY_DOWN:
        buffer_motion(b, .Down, shift, all)
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
    if !t.sel_active {
        return
    }
    clipboard_set(a, terminal_selection_text(t), nil)
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
// joined string + pieces), freeing the previous remembered copy.
@(private = "file")
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

// Filetree key handling (bare keys, when the filetree aux pane is focused).
filetree_key :: proc(a: ^App, key, mods: i32) {
    ft := &a.tree
    switch key {
    case glfw.KEY_DOWN:
        filetree_move(ft, 1)
    case glfw.KEY_UP:
        filetree_move(ft, -1)
    case glfw.KEY_RIGHT:
        filetree_enter(ft) // into the selected folder
    case glfw.KEY_LEFT:
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

// Config aux pane key handling (bare keys, when the Config pane is focused). Non-modal,
// arrow-keys-only: Up/Down move between rows; the highlighted row owns the rest. A
// setting or language row opens a dropdown on Right/Enter (choices for a setting, grammar
// actions for a language); the search box edits in place (typed chars via char_callback).
config_key :: proc(a: ^App, key, mods: i32) {
    cp := &a.config_pane

    if cp.open != .None {
        config_dropdown_key(a, key)
        return
    }

    switch key {
    case glfw.KEY_UP:
        config_nav(a, -1)
        return
    case glfw.KEY_DOWN:
        config_nav(a, 1)
        return
    }

    // A setting row: Right / Enter opens its choice dropdown.
    if s, ok := config_pane_setting(cp.sel); ok {
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
            config_activate(a)
        }
        return
    }

    // The search box (the only text-input row): Left/Right move the caret;
    // Backspace/Delete edit and refilter the language list live.
    d := &cp.search
    if edit_motion(d, key, mods, false) {
        return
    }
    ctrl := mods & glfw.MOD_CONTROL != 0
    switch key {
    case glfw.KEY_BACKSPACE:
        if ctrl {doc_delete_word_back(d)} else {doc_backspace(d)}
        config_pane_filter(cp)
    case glfw.KEY_DELETE:
        if ctrl {doc_delete_word_forward(d)} else {doc_delete(d)}
        config_pane_filter(cp)
    }
}

// Row navigation (no dropdown open): just move the selection. Settings apply on
// dropdown-select now, so there's no inline editor to commit/seed across the move.
@(private = "file")
config_nav :: proc(a: ^App, delta: int) {
    config_pane_move(&a.config_pane, delta)
}

// Right / Enter on a language row opens its options dropdown.
@(private = "file")
config_activate :: proc(a: ^App) {
    cp := &a.config_pane
    if li, ok := config_pane_lang_index(cp, cp.sel); ok {
        cp.open = .Lang
        cp.open_idx = li // the language index, stable under filtering
        cp.opt_sel = -1 // selection stays on the language root; -1 = the root row
    }
}

// Navigation within an open dropdown — dispatched to the setting or language variant.
@(private = "file")
config_dropdown_key :: proc(a: ^App, key: i32) {
    switch a.config_pane.open {
    case .Setting:
        config_setting_dropdown_key(a, key)
    case .Lang:
        config_lang_dropdown_key(a, key)
    case .None:
    }
}

// A settings choice dropdown: Up/Down pick within the options (clamped), Left cancels,
// Enter/Right commits the highlighted choice (validated + persisted) and closes.
@(private = "file")
config_setting_dropdown_key :: proc(a: ^App, key: i32) {
    cp := &a.config_pane
    s := Setting(cp.open_idx)
    opts := setting_options(a, s)
    switch key {
    case glfw.KEY_DOWN:
        cp.opt_sel = min(cp.opt_sel + 1, len(opts) - 1)
    case glfw.KEY_UP:
        cp.opt_sel = max(cp.opt_sel - 1, 0)
    case glfw.KEY_LEFT:
        cp.open = .None // cancel, keep the setting row selected
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER, glfw.KEY_RIGHT:
        if cp.opt_sel >= 0 && cp.opt_sel < len(opts) {
            setting_commit(a, s, opts[cp.opt_sel])
        }
        cp.open = .None
    }
}

// Navigation within an open language dropdown. Arrow keys only.
@(private = "file")
config_lang_dropdown_key :: proc(a: ^App, key: i32) {
    cp := &a.config_pane
    if cp.open_idx < 0 || cp.open_idx >= len(cp.langs) {
        cp.open = .None
        return
    }
    lang := &cp.langs[cp.open_idx] // open_idx is a language index
    buf: [len(LangOption)]LangOption
    opts := lang_options(lang.present, buf[:])
    // opt_sel == -1 is the language root (still selected while open); 0.. are options.
    switch key {
    case glfw.KEY_DOWN:
        if cp.opt_sel >= len(opts) - 1 {
            cp.open = .None // step out below the dropdown
            config_nav(a, 1)
        } else {
            cp.opt_sel += 1
        }
    case glfw.KEY_UP:
        if cp.opt_sel <= -1 {
            cp.open = .None // step off the root, upward
            config_nav(a, -1)
        } else {
            cp.opt_sel -= 1
        }
    case glfw.KEY_LEFT:
        cp.open = .None // collapse, keep the language row selected
    case glfw.KEY_ENTER, glfw.KEY_KP_ENTER, glfw.KEY_RIGHT:
        if cp.opt_sel == -1 {
            cp.open = .None // re-Enter on the root minimises
        } else {
            config_run_option(a, lang.name, opts[cp.opt_sel])
            cp.open = .None
        }
    }
}

// A chosen language option builds a `slopd ...` command and runs it in t1 (the
// master CL terminal) — the same stubbed seam as the command line's shell path, so
// these light up when libvterm injection lands. The CLI flags themselves work today.
@(private = "file")
config_run_option :: proc(a: ^App, lang: string, opt: LangOption) {
    cmd: string
    switch opt {
    case .Health:
        cmd = fmt.tprintf("slopd --health %s", lang)
    case .Install:
        cmd = fmt.tprintf("slopd --grammar install %s", lang)
    case .Update:
        cmd = fmt.tprintf("slopd --grammar update %s", lang)
    case .Uninstall:
        cmd = fmt.tprintf("slopd --grammar uninstall %s", lang)
    }
    run_in_t1(a, cmd)
}

// Bare modifier keys (Shift/Ctrl/Super on their way into a chord) — used so the
// one-shot move-all prefix survives them to reach the actual motion key, and so a
// modifier press (e.g. the Ctrl of Ctrl+Shift+C) doesn't drop a terminal selection.
is_modifier_key :: proc(key: i32) -> bool {
    switch key {
    case glfw.KEY_LEFT_SHIFT,
         glfw.KEY_RIGHT_SHIFT,
         glfw.KEY_LEFT_CONTROL,
         glfw.KEY_RIGHT_CONTROL,
         glfw.KEY_LEFT_SUPER,
         glfw.KEY_RIGHT_SUPER,
         glfw.KEY_CAPS_LOCK:
        return true
    }
    return false
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
