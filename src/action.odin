package main

import "core:strings"
import "vendor:glfw"
import "txt"

// Every verb Slopd has, named once. action_run is the only thing that performs one, so a key, a
// click and a menu item reach the same verb.
//
// Most actions are answered by whichever surface has the keys: Nav_Down moves the caret, or the
// selection, or pans an image. That keeps the arrows and the clipboard out of the bind table six
// times over. A pane-specific action asks its own target first and declines elsewhere.

Action :: enum {
    None,

    // --- focus, panes and the command line ---
    Focus_Editor,
    Focus_Aux,
    Aux_Filetree,
    Aux_Terminal,
    Aux_Grep,
    Ws_Find,
    Split_Grow,
    Split_Shrink,
    Escape,
    Cl_Open,
    Cl_Open_Builtin,
    Cl_Open_Jump,
    Git_Tool,
    Follow,

    // --- terminal sessions (the pane, not the job) ---
    Term_Goto,
    Term_New,
    Term_Close,
    Term_Lock,
    Term_Prev,
    Term_Next,
    Term_Sel_Up,
    Term_Sel_Down,

    // --- multi-cursor and the font ---
    Cursor_Drop,
    Move_All,
    Font_Grow,
    Font_Shrink,
    Font_Reset,

    // --- answered by the surface with the keys ---
    Nav_Up,
    Nav_Down,
    Nav_Left,
    Nav_Right,
    Activate,
    Clip_Copy,
    Clip_Cut,
    Clip_Paste,

    // --- an editable has the keys ---
    Move_Word_Left,
    Move_Word_Right,
    Move_Home,
    Move_End,
    Jump_Up,
    Jump_Down,
    Delete_Back,
    Delete_Forward,
    Delete_Word_Back,
    Delete_Word_Forward,
    Indent,
    Outdent,
    Comment_Toggle,
    Move_Doc_Start,
    Move_Doc_End,
    Select_All,
    Select_Line,
    Fold_Toggle,
    Save,
    Undo,
    Redo,

    // --- the file pane, under either face ---
    File_Mark,
    File_Marks_Clear,
    File_Delete,
    File_Copy_Path,
    File_Props,
    File_Workspace,
    File_Edit,
    File_Discard,
    Parent,

    // --- the browser's top bar and sidebar ---
    Browse_Back,
    Browse_Forward,
    Browse_Reload,
    Browse_View,
    Browse_Place,

    // --- the image surface ---
    Media_Zoom_In,
    Media_Zoom_Out,
    Media_Fit,
}

// --- who has the keys --- A chord says WHAT; these say WHERE, so a verb at the wrong surface
// is a no-op rather than a surprise.

// The editable with the keystrokes. Not .None means a bare key TYPES — the Text/Surface split.
Editable :: enum {
    None,
    Buffer,
    Command_Line,
    Browse_Path,
    Workspace_Find,
    Config_Search,
    Config_Value,
}

active_editable :: proc(a: ^App) -> (Editable, ^txt.Doc) {
    if a.cl_active {
        return .Command_Line, &a.cl.doc // owns the keys while it is up
    }
    if wsfind_live(a) {
        // Ahead of the path line, which opening the prompt closes.
        return .Workspace_Find, &a.wsfind.query
    }
    if filebrowser_path_live(a) {
        return .Browse_Path, &a.filebrowser.path
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        // The filter and a free-text setting take text; an open dropdown takes none.
        // config_edit_sync must have settled `edit` first — handle_key does that.
        cp := &a.config_pane
        if cp.open == .None {
            if config_pane_is_search(cp.sel) {
                return .Config_Search, &cp.search
            }
            if s, ok := config_pane_setting(cp.sel); ok && setting_is_text(s) {
                return .Config_Value, &cp.edit
            }
        }
        return .None, nil
    }
    if a.focus == .Editor && a.main == .Text {
        return .Buffer, &editor_current(&a.editor).doc
    }
    return .None, nil
}

// nil when the editor lacks the keys, so ^Z in a search box does not undo behind it.
buffer_target :: proc(a: ^App) -> ^Buffer {
    if a.cl_active || a.focus != .Editor || a.main != .Text {
        return nil
    }
    return editor_current(&a.editor)
}

// One model under both faces, so this does not care which is being drawn.
tree_target :: proc(a: ^App) -> ^FileTree {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .FileTree {
        return nil
    }
    return &a.tree
}

// History, places and which view — what the listing has no concept of. nil under the `ls` face.
browse_target :: proc(a: ^App) -> ^FileBrowser {
    if tree_target(a) == nil || a.file_pane != .Browser {
        return nil
    }
    return &a.filebrowser
}

media_target :: proc(a: ^App) -> ^Media {
    if a.cl_active || a.focus != .Editor || a.main != .Image {
        return nil
    }
    return &a.media
}

grep_target :: proc(a: ^App) -> ^GrepPane {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Grep {
        return nil
    }
    return &a.grep
}

config_target :: proc(a: ^App) -> ^ConfigPane {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Config {
        return nil
    }
    return &a.config_pane
}

// --- the dispatcher ---

// `n` is the offset within a run bind (Alt+3 is Term_Goto with n == 2), `extend` says Shift was
// down, `all` that an Alt+M prefix is being spent. false means DECLINED — no target, or the
// surface wants the keystroke elsewhere. Only the terminal acts on that: a declined key reaches
// the job, which is how ^C interrupts.
action_run :: proc(a: ^App, act: Action, n: int, extend, all: bool) -> (handled: bool) {
    handled = true
    switch act {
    case .None:
        return false

    // --- focus, panes and the command line ---
    case .Focus_Editor:
        set_focus(a, .Editor)
    case .Focus_Aux:
        set_focus(a, .Aux)
    case .Aux_Filetree:
        set_aux(a, .FileTree)
    case .Aux_Terminal:
        set_aux(a, .Terminal)
        term_ensure(a) // spawn t1 on the pane's first reveal
    case .Aux_Grep:
        set_aux(a, .Grep) // re-focus the results pane (last search)
    case .Ws_Find:
        wsfind_open(a) // the file pane, its top bar as the WORKSPACE/ prompt
    case .Split_Shrink:
        a.split = clampf(a.split - 0.02, SPLIT_MIN, SPLIT_MAX)
    case .Split_Grow:
        a.split = clampf(a.split + 0.02, SPLIT_MIN, SPLIT_MAX)
    case .Escape:
        escape_run(a, all)
    case .Cl_Open:
        cl_open(a) // empty: what you type is a shell command
    case .Cl_Open_Builtin:
        cl_open(a, ":") // the same line with the builtin sigil pre-typed
    case .Cl_Open_Jump:
        cl_inject(a, ":j ")
    case .Git_Tool:
        git_tool_open(a)
    case .Follow:
        // A def, URL, [[file]], colour, or a folder.
        if tree_target(a) != nil {
            filetree_cd_selected(a)
        } else if buffer_target(a) != nil {
            link_follow(a)
        } else {
            return false
        }

    // --- terminal sessions ---
    case .Term_Goto:
        term_focus(a, n + 1) // i3-style: past the last opens the next
    case .Term_New, .Term_Close, .Term_Lock, .Term_Prev, .Term_Next:
        return term_pane_run(a, act)
    case .Term_Sel_Up, .Term_Sel_Down:
        // A cursor IN a pane, so unlike the session verbs it wants the pane focused.
        ts := term_sel_target(a)
        if ts == nil {
            return false
        }
        terminal_sel_move(ts, act == .Term_Sel_Up ? -1 : 1, extend)

    // --- multi-cursor and the font ---
    case .Cursor_Drop:
        kind, d := active_editable(a)
        if kind == .None {
            return false
        }
        txt.doc_drop_anchor(d)
    case .Move_All:
        // handle_key has spent whatever was pending, so this only ever arms.
        kind, _ := active_editable(a)
        a.move_all_armed = kind != .None
    case .Font_Grow:
        font_zoom(a, +1)
    case .Font_Shrink:
        font_zoom(a, -1)
    case .Font_Reset:
        font_zoom_reset(a)

    // --- answered by the surface with the keys ---
    case .Nav_Up:
        return nav_run(a, .Up, extend, all)
    case .Nav_Down:
        return nav_run(a, .Down, extend, all)
    case .Nav_Left:
        return nav_run(a, .Left, extend, all)
    case .Nav_Right:
        return nav_run(a, .Right, extend, all)
    case .Activate:
        return activate_run(a, extend)
    case .Clip_Copy, .Clip_Cut:
        return clip_take(a, act == .Clip_Cut)
    case .Clip_Paste:
        return clip_put(a)

    // --- an editable has the keys ---
    case .Move_Word_Left:
        return motion_run(a, .Word_Left, extend, all)
    case .Move_Word_Right:
        return motion_run(a, .Word_Right, extend, all)
    case .Move_Home:
        return motion_run(a, .Home, extend, all)
    case .Move_End:
        return motion_run(a, .End, extend, all)
    case .Move_Doc_Start:
        return motion_run(a, .Doc_Start, extend, all)
    case .Move_Doc_End:
        return motion_run(a, .Doc_End, extend, all)
    case .Jump_Up, .Jump_Down:
        // Elsewhere there is nothing to jump over, so these are the plain move.
        up := act == .Jump_Up
        if b := buffer_target(a); b != nil {
            buffer_motion(b, up ? .Up : .Down, extend, all, a.jump_lines)
            return true
        }
        return nav_run(a, up ? .Up : .Down, extend, all)
    case .Delete_Back, .Delete_Forward, .Delete_Word_Back, .Delete_Word_Forward:
        return delete_run(a, act)
    case .Select_All, .Select_Line:
        return select_run(a, act)
    case .Indent, .Outdent, .Comment_Toggle, .Fold_Toggle, .Save, .Undo, .Redo:
        return buffer_run(a, act)

    // --- the file pane, the browser's chrome, the image surface ---
    case .File_Mark,
         .File_Marks_Clear,
         .File_Delete,
         .File_Copy_Path,
         .File_Props,
         .File_Workspace,
         .File_Edit,
         .File_Discard,
         .Parent:
        return file_run(a, act, extend)
    case .Browse_Back, .Browse_Forward, .Browse_Reload, .Browse_View, .Browse_Place:
        return browse_run(a, act, n)
    case .Media_Zoom_In, .Media_Zoom_Out, .Media_Fit:
        return media_run(a, act)
    }
    return
}

// --- the pane families --- One guard each, asked once per family rather than per verb.

// The pane UP, not focused: switching a session while you type is a pane-level choice.
@(private = "file")
term_pane_run :: proc(a: ^App, act: Action) -> bool {
    if a.aux_mode != .Terminal {
        return false
    }
    #partial switch act {
    case .Term_New:
        term_new(a)
    case .Term_Close:
        term_close_active(a)
    case .Term_Lock:
        if t := term_current(a); t != nil {
            t.locked = !t.locked // `:tu` skips it; the switcher greys its number
        }
    case .Term_Prev, .Term_Next:
        if n := term_count(a); n > 0 {
            a.term_active = (a.term_active + (act == .Term_Prev ? -1 : 1) + n) % n
        }
    }
    return true
}

// Whatever editable has the keys answers these, the command line and a field included: taking
// a whole line or a whole document means the same thing everywhere.
@(private = "file")
select_run :: proc(a: ^App, act: Action) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    if act == .Select_All {
        txt.doc_select_all(d)
    } else {
        txt.doc_select_lines(d) // every cursor takes its own line
    }
    return true
}

// The verbs needing a Buffer's dirty flag, undo history or folds rather than a Doc.
@(private = "file")
buffer_run :: proc(a: ^App, act: Action) -> bool {
    b := buffer_target(a)
    if b == nil {
        return false
    }
    #partial switch act {
    case .Indent:
        buffer_tab(b, a.indent)
    case .Outdent:
        _ = buffer_indent_block(b, a.indent, true)
    case .Comment_Toggle:
        _ = buffer_comment_toggle(b)
    case .Fold_Toggle:
        if a.folding {buffer_fold_toggle(a, b)} else {buffer_enter(a, b)} // off: still Enter
    case .Save:
        _ = cl_save(a, b) // an unwritable file stages a `sudo cp` line
    case .Undo:
        buffer_undo(b)
    case .Redo:
        buffer_redo(b)
    }
    return true
}

// Identical under both faces. Extending takes the second half of the pair: the marked set, or
// the browsed directory, which is what `e` being nil says below.
@(private = "file")
file_run :: proc(a: ^App, act: Action, extend: bool) -> bool {
    ft := tree_target(a)
    if ft == nil {
        return false
    }
    e: ^FileEntry
    if !extend {
        e = filetree_selected(ft)
    }
    #partial switch act {
    case .File_Mark:
        filetree_mark_toggle(ft)
    case .File_Marks_Clear:
        filetree_marks_reset(ft)
    case .File_Delete:
        filetree_rm_selected(a, extend) // the staged `rm -rf` line IS the confirm
    case .File_Copy_Path:
        clipboard_set(a, strings.clone(e != nil ? e.path : ft.dir), nil) // it takes ownership
    case .File_Props:
        filetree_props(a, e != nil ? e.path : ft.dir)
    case .File_Workspace:
        cl_workspace(a, ft.dir) // the browsed dir becomes the root; terminals follow
    case .File_Edit:
        filetree_edit_selected(a) // even when Enter would run it
    case .File_Discard:
        filetree_discard_selected(a) // only ever the entry, never the marked set
    case .Parent:
        // The only way out of a grid, where Left/Right step a tile.
        if browse_target(a) != nil {filebrowser_parent(a)} else {filetree_parent(ft)}
    }
    return true
}

// Absent under the `ls` face, where there is no chrome to drive.
@(private = "file")
browse_run :: proc(a: ^App, act: Action, n: int) -> bool {
    if browse_target(a) == nil {
        return false
    }
    #partial switch act {
    case .Browse_Back:
        filebrowser_button(&a.filebrowser, &a.tree, .Back)
    case .Browse_Forward:
        filebrowser_button(&a.filebrowser, &a.tree, .Forward)
    case .Browse_Reload:
        filebrowser_button(&a.filebrowser, &a.tree, .Reload)
    case .Browse_View:
        filebrowser_button(&a.filebrowser, &a.tree, .View) // the toggle button's keyboard twin
    case .Browse_Place:
        filebrowser_place_open(a, n + 1)
    }
    return true
}

// Bare keys, which only a surface with nothing to type into can have.
@(private = "file")
media_run :: proc(a: ^App, act: Action) -> bool {
    m := media_target(a)
    if m == nil {
        return false
    }
    #partial switch act {
    case .Media_Zoom_In:
        media_zoom(m, MEDIA_ZOOM_STEP)
    case .Media_Zoom_Out:
        media_zoom(m, 1.0 / MEDIA_ZOOM_STEP)
    case .Media_Fit:
        media_fit(m)
    }
    return true
}

// --- the polymorphic verbs --- One proc each, holding every surface's answer.

// "Step, the way this surface steps" — not a motion.
Nav :: enum {
    Up,
    Down,
    Left,
    Right,
}

@(private = "file")
nav_run :: proc(a: ^App, n: Nav, extend, all: bool) -> bool {
    kind, d := active_editable(a)
    switch kind {
    case .Command_Line:
        // A live `:f` preview borrows Up/Down to cycle matches; history has them otherwise.
        switch n {
        case .Up:
            if !cl_preview_step(a, -1) {cl_history_prev(a)}
        case .Down:
            if !cl_preview_step(a, 1) {cl_history_next(a)}
        case .Left, .Right:
            doc_step(d, n, extend, all)
        }
        return true
    case .Buffer:
        b := editor_current(&a.editor)
        switch n {
        case .Up:
            buffer_motion(b, .Up, extend, all)
        case .Down:
            buffer_motion(b, .Down, extend, all)
        case .Left, .Right:
            doc_step(&b.doc, n, extend, all)
        }
        return true
    case .Browse_Path:
        // One line, and the listing under it must not walk while you type.
        if n == .Up || n == .Down {
            return false
        }
        doc_step(d, n, extend, all)
        return true
    case .Workspace_Find:
        // The other one-line bar with a list under it, so Up/Down are the list's.
        switch n {
        case .Up:
            wsfind_move(&a.wsfind, -1)
        case .Down:
            wsfind_move(&a.wsfind, 1)
        case .Left, .Right:
            doc_step(d, n, extend, all)
        }
        return true
    case .Config_Search, .Config_Value:
        // A text row still walks rows: leaving the row is how you commit it.
        switch n {
        case .Up:
            config_pane_move(&a.config_pane, -1)
        case .Down:
            config_pane_move(&a.config_pane, 1)
        case .Left, .Right:
            doc_step(d, n, extend, all)
        }
        return true
    case .None:
    }

    if m := media_target(a); m != nil {
        step := 40 * a.scale
        switch n {
        case .Left:
            media_pan(m, step, 0) // reveal the left edge: content slides right
        case .Right:
            media_pan(m, -step, 0)
        case .Up:
            media_pan(m, 0, step)
        case .Down:
            media_pan(m, 0, -step)
        }
        return true
    }
    if g := grep_target(a); g != nil {
        if n == .Left || n == .Right {
            return false
        }
        grep_move(g, n == .Up ? -1 : 1)
        return true
    }
    if cp := config_target(a); cp != nil {
        config_nav(a, cp, n)
        return true
    }
    if co := color_target(a); co != nil {
        #partial switch n {
        case .Up:
            co.sel = (co.sel - 1 + color_slider_count(&a.color)) % color_slider_count(&a.color)
        case .Down:
            co.sel = (co.sel + 1) % color_slider_count(&a.color)
        case .Left:
            v := color_slider_value(&a.color, co.sel) - 0.02
            color_set_slider(a, co.sel, v)
        case .Right:
            v := color_slider_value(&a.color, co.sel) + 0.02
            color_set_slider(a, co.sel, v)
        }
        return true
    }
    if ft := tree_target(a); ft != nil {
        filetree_nav(a, ft, n, extend)
        return true
    }
    return false
}

// "Do the thing I am pointing at". Extending opens a file in the desktop's app, not ours.
@(private = "file")
activate_run :: proc(a: ^App, extend: bool) -> bool {
    kind, _ := active_editable(a)
    switch kind {
    case .Command_Line:
        // Shift over a `:f` preview takes every hit; it declines and Enter submits as usual.
        if !extend || !cl_submit_all(a) {
            cl_submit(a)
        }
        return true
    case .Browse_Path:
        filebrowser_path_commit(a)
        return true
    case .Workspace_Find:
        wsfind_activate(a) // the prompt closes with it
        return true
    case .Config_Value:
        config_edit_commit(a)
        return true
    case .Config_Search:
        return true // the filter is live; there is nothing to submit
    case .Buffer:
        buffer_enter(a, editor_current(&a.editor)) // auto-indent / brace expansion
        return true
    case .None:
    }

    if g := grep_target(a); g != nil {
        grep_open_selected(a)
        return true
    }
    if cp := config_target(a); cp != nil {
        if cp.open != .None {
            config_choose(a)
        } else {
            config_open_selected(a, cp)
        }
        return true
    }
    if co := color_target(a); co != nil {
        color_close(a, true)
        set_aux(a, .FileTree)
        return true
    }
    if ft := tree_target(a); ft != nil {
        switch {
        case extend:
            filetree_open_selected(a) // to the desktop, or stage its run command
        case browse_target(a) != nil:
            filebrowser_activate(a) // into the folder, through the history
        case:
            filetree_activate_selected(a)
        }
        return true
    }
    return false
}

// The editable answers first: with the path line open, ^C is the text, not the file under it.
@(private = "file")
clip_take :: proc(a: ^App, cut: bool) -> bool {
    kind, d := active_editable(a)
    switch kind {
    case .Buffer:
        if cut {editor_cut(a)} else {editor_copy(a)}
        return true
    case .Command_Line, .Browse_Path, .Workspace_Find, .Config_Search, .Config_Value:
        field_copy(a, d, cut) // nothing selected copies nothing, and still claims the key
        return true
    case .None:
    }
    if ft := tree_target(a); ft != nil {
        // From the marked set, or the row under the cursor. A cut is spent by its paste.
        filetree_clip_take(ft, cut ? .Cut : .Copy)
        return true
    }
    // A terminal has nothing to cut, and with nothing selected ^C is the interrupt — so this
    // declines and the job gets the keystroke.
    if ts := term_sel_target(a); ts != nil && !cut && term_has_span(ts) {
        term_copy(a, ts)
        return true
    }
    return false
}

@(private = "file")
clip_put :: proc(a: ^App) -> bool {
    kind, d := active_editable(a)
    switch kind {
    case .Buffer:
        editor_paste(a)
        return true
    case .Command_Line, .Browse_Path, .Workspace_Find, .Config_Search, .Config_Value:
        field_paste(a, d)
        return true
    case .None:
    }
    if ft := tree_target(a); ft != nil {
        filetree_paste(ft)
        return true
    }
    // Claimed on the pane, not a live shell: falling through would reach the job as ^V.
    if ts := term_sel_target(a); ts != nil {
        term_paste(a, ts)
        return true
    }
    return false
}

// Every editable takes these the same way, so there is no per-surface branch.
@(private = "file")
motion_run :: proc(a: ^App, m: txt.Motion, extend, all: bool) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    if all {txt.doc_move_all(d, m, extend)} else {txt.doc_move(d, m, extend)}
    return true
}

@(private = "file")
delete_run :: proc(a: ^App, act: Action) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    // Two axes, not four verbs: which side of the caret, and whether Ctrl widens to a word.
    back := act == .Delete_Back || act == .Delete_Word_Back
    word := act == .Delete_Word_Back || act == .Delete_Word_Forward
    // The buffer keeps its own dirty flag and undo, so it has its own four.
    if b := buffer_target(a); b != nil {
        switch {
        case back && word: buffer_delete_word_back(b)
        case back:         buffer_backspace(b)
        case word:         buffer_delete_word_forward(b)
        case:              buffer_delete(b)
        }
        return true
    }
    switch {
    case back && word: txt.doc_delete_word_back(d)
    case back:         txt.doc_backspace(d)
    case word:         txt.doc_delete_word_forward(d)
    case:              txt.doc_delete(d)
    }
    // The filter re-runs on an edit, not a motion.
    if kind == .Config_Search {
        config_pane_filter(&a.config_pane)
    }
    return true
}

// --- the per-pane answers --- Beside the dispatcher, so "what do the arrows do here" is one
// page.

// Cancels the innermost thing there is to cancel, and drives Zen only when there is nothing.
@(private = "file")
escape_run :: proc(a: ^App, move_all_pending: bool) {
    kind, d := active_editable(a)
    ts, tf := term_sel_target(a), term_focused(a)
    switch {
    case a.cl_chain.waiting:
        cl_chain_clear(a) // abandon a pending && chain; the shell command runs on
    case a.color.active:
        color_close(a, false)
        set_aux(a, .FileTree)
        return
    case ts != nil && (ts.sel_active || ts.msel_on):
        // The first Esc leaves the selection, whichever way it was made.
        terminal_sel_reset(ts)
    case tf != nil:
        terminal_input_key(tf, glfw.KEY_ESCAPE, 0) // vim and its kin must see it
    case kind == .Command_Line:
        cl_cancel(a)
    case kind == .Browse_Path:
        filebrowser_path_cancel(a) // back to buttons
    case kind == .Workspace_Find:
        wsfind_close(a) // the listing it covered is as you left it
    case move_all_pending:
    // handle_key already spent the prefix; swallowing the key here IS the cancel.
    case kind == .Buffer && len(d.cursors) > 1:
        txt.doc_collapse_to_primary(d)
    case:
        zen_escape(a) // Zen on (never off), then flip the shown side
    }
}

// An open dropdown owns them; otherwise Up/Down walk rows and Right opens what the row offers.
// A free-text row is Text, not Surface, so it never reaches here.
@(private = "file")
config_nav :: proc(a: ^App, cp: ^ConfigPane, n: Nav) {
    if cp.open != .None {
        switch n {
        case .Up:
            config_dropdown_move(a, -1)
        case .Down:
            config_dropdown_move(a, 1)
        case .Left:
            cp.open = .None // cancel, keeping the row selected
        case .Right:
            config_choose(a)
        }
        return
    }
    switch n {
    case .Up:
        config_pane_move(cp, -1)
    case .Down:
        config_pane_move(cp, 1)
    case .Left:
    case .Right:
        config_open_selected(a, cp)
    }
}

// Package-level, because the double click means the same thing.
config_open_selected :: proc(a: ^App, cp: ^ConfigPane) {
    switch {
    case config_pane_is_binds(cp.sel):
        set_aux(a, .Binds)
    case config_pane_is_macros(cp.sel):
        config_open_macros(a)
    case config_pane_is_install(cp.sel):
        config_pane_open_install(a)
    case config_pane_lang(cp, cp.sel) != nil:
        config_pane_open_lang(a)
    case:
        if s, ok := config_pane_setting(cp.sel); ok {
            config_pane_open_setting(a, s)
        }
    }
}

// The one place the two faces genuinely differ: in a grid, Left/Right step a tile rather than
// leaving the folder.
@(private = "file")
filetree_nav :: proc(a: ^App, ft: ^FileTree, n: Nav, extend: bool) {
    br := browse_target(a)
    grid := br != nil && br.view == .Grid
    step := grid ? max(1, br.cols) : 1
    switch n {
    case .Up, .Down:
        d := n == .Up ? -step : step
        if extend {filetree_mark_sweep(ft, d)} else {filetree_move(ft, d)}
    case .Left:
        switch {
        case grid:
            filetree_move(ft, -1)
        case br != nil:
            filebrowser_parent(a)
        case:
            filetree_parent(ft)
        }
    case .Right:
        switch {
        case grid:
            filetree_move(ft, 1)
        case br == nil:
            filetree_enter(ft)
        case:
            if e := filetree_selected(ft); e != nil && e.is_dir {
                filebrowser_activate(a)
            }
        }
    }
}

// Left/Right on a Doc with the Alt+M prefix applied: where Nav meets Motion.
@(private = "file")
doc_step :: proc(d: ^txt.Doc, n: Nav, extend, all: bool) {
    m: txt.Motion = n == .Left ? .Left : .Right
    if all {txt.doc_move_all(d, m, extend)} else {txt.doc_move(d, m, extend)}
}
