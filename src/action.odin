package main

import "core:strings"
import "vendor:glfw"

// Actions — every verb Slopd has, named once. bind.odin turns a keystroke into one of these and
// `action_run` is the only thing that performs one, so a verb reached from a key, a click, a menu
// or (next) a config line is the same verb and cannot drift.
//
// **Most actions are answered by whichever surface has the keys.** `Nav_Down` moves the caret in
// the editor, the selection in a list, the result in grep, and pans an image; `Clip_Copy` copies
// text, or files, or a terminal's selection. That is what keeps the arrows and the clipboard out
// of the bind table six times over — and it is why the bind contexts (bind.odin) only have to say
// where a chord may MEAN something, never which pane acts.
//
// A pane-specific action asks for its own target first (`tree_target`, `media_target`, ...) and
// does nothing when that pane is not the one with the keys. Those helpers are the guard rail: ^Y
// pressed in the grep pane must not mark a file in a listing you cannot see.

Action :: enum {
    None,

    // --- focus, panes and the command line ---
    Focus_Editor,
    Focus_Aux,
    Aux_Filetree,
    Aux_Terminal,
    Aux_Grep,
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

// --- who has the keys --- Six small questions, each asked in one place. They are the reason the
// bind table needs four contexts rather than one per pane: a chord says WHAT to do, and these say
// WHERE, so an action pressed at the wrong surface is a no-op instead of a surprise.

// Which editable owns the keystrokes, and its Doc. Where this is not `.None`, a bare key TYPES —
// which is the whole of the Text/Surface split. char_callback asks the same question, so the keys
// that type and the keys that edit can never disagree about which box they are in.
Editable :: enum {
    None,
    Buffer,
    Command_Line,
    Browse_Path,
    Config_Search,
    Config_Value,
}

active_editable :: proc(a: ^App) -> (Editable, ^Doc) {
    if a.cl_active {
        return .Command_Line, &a.cl.doc // a transient overlay that owns the keys while it is up
    }
    if filebrowser_path_live(a) {
        return .Browse_Path, &a.filebrowser.path
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        // Two kinds of row take text — the language filter and a free-text setting. An open
        // dropdown is a closed list, so it takes none. (config_edit_sync must have settled
        // `edit` against the highlighted row before this is read; handle_key does that.)
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

// The buffer the editor's own chords act on, or nil when the editor is not the surface with the
// keys — so ^Z typed into the config pane's search box does not undo behind it.
buffer_target :: proc(a: ^App) -> ^Buffer {
    if a.cl_active || a.focus != .Editor || a.main != .Text {
        return nil
    }
    return editor_current(&a.editor)
}

// The listing the file chords act on, or nil when the file pane is not the one with the keys.
// One model under both faces, so this does not care which is being drawn.
tree_target :: proc(a: ^App) -> ^FileTree {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .FileTree {
        return nil
    }
    return &a.tree
}

// The browser's own state — history, places, which view — or nil when the file pane is absent or
// wearing the `ls` face. What the LISTING has no concept of lives here and nowhere else.
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

// Perform one action. `n` is the offset within a bind covering a run of keys (Alt+3 is Term_Goto
// with n == 2), `extend` says Shift was down, and `all` that an Alt+M prefix is being spent.
//
// Returns false when the action DECLINED — it had no target, or the surface it found wants the
// keystroke to go somewhere else. Only the terminal does anything with that answer: a declined
// key reaches the job, which is how ^C interrupts when there is no selection to copy.
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
        term_ensure(a) // spawn t1 on first reveal of the terminal pane
    case .Aux_Grep:
        set_aux(a, .Grep) // re-focus the results pane (last search)
    case .Split_Shrink:
        a.split = clampf(a.split - 0.02, SPLIT_MIN, SPLIT_MAX)
    case .Split_Grow:
        a.split = clampf(a.split + 0.02, SPLIT_MIN, SPLIT_MAX)
    case .Escape:
        escape_run(a, all)
    case .Cl_Open:
        cl_open(a) // an empty line: what you type is a SHELL command
    case .Cl_Open_Builtin:
        cl_open(a, ":") // the same line with the builtin sigil pre-typed
    case .Cl_Open_Jump:
        cl_inject(a, ":j ")
    case .Git_Tool:
        git_tool_open(a) // hand the project root to the configured external tool
    case .Follow:
        // The same gesture at either surface: go to what is under the cursor. In the editor
        // that is a definition, a URL, a [[file]] or a colour; in the file pane it is a folder.
        if tree_target(a) != nil {
            filetree_cd_selected(a)
        } else if buffer_target(a) != nil {
            link_follow(a)
        } else {
            return false
        }

    // --- terminal sessions ---
    case .Term_Goto:
        term_focus(a, n + 1) // i3-style: a session past the last one opens the next
    case .Term_New, .Term_Close, .Term_Lock, .Term_Prev, .Term_Next:
        return term_pane_run(a, act)
    case .Term_Sel_Up, .Term_Sel_Down:
        // The copy cursor is a cursor IN a pane, so unlike the session verbs it wants that pane
        // FOCUSED — the rule PageUp has always been on (term_sel_target).
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
        doc_drop_anchor(d)
    case .Move_All:
        // The one-shot prefix: the next motion moves every cursor instead of the free caret.
        // handle_key has already spent whatever was pending, so this only ever arms.
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
    case .Jump_Up, .Jump_Down:
        // In the editor ^Up/^Down jump `jump_lines` at a time. Anywhere else there is nothing
        // to jump OVER, so they are the plain move — which is what the command line's history
        // and a list's selection have always done with them.
        up := act == .Jump_Up
        if b := buffer_target(a); b != nil {
            buffer_motion(b, up ? .Up : .Down, extend, all, a.jump_lines)
            return true
        }
        return nav_run(a, up ? .Up : .Down, extend, all)
    case .Delete_Back, .Delete_Forward, .Delete_Word_Back, .Delete_Word_Forward:
        return delete_run(a, act)
    case .Indent, .Fold_Toggle, .Save, .Undo, .Redo:
        return buffer_run(a, act)

    // --- the file pane, the browser's chrome, the image surface ---
    case .File_Mark,
         .File_Marks_Clear,
         .File_Delete,
         .File_Copy_Path,
         .File_Props,
         .File_Workspace,
         .File_Edit,
         .Parent:
        return file_run(a, act, extend)
    case .Browse_Back, .Browse_Forward, .Browse_Reload, .Browse_View, .Browse_Place:
        return browse_run(a, act, n)
    case .Media_Zoom_In, .Media_Zoom_Out, .Media_Fit:
        return media_run(a, act)
    }
    return
}

// --- the pane families --- One guard each, so "does this verb reach this pane" is asked once
// per family rather than once per verb, and a family added later cannot forget to ask.

// The terminal PANE's verbs. They want the pane UP, not focused: closing or switching a session
// while you type in the editor is a pane-level choice, which is the line between these and the
// copy cursor.
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
            t.locked = !t.locked // tu skips a locked cwd; the switcher greys its number
        }
    case .Term_Prev, .Term_Next:
        if n := term_count(a); n > 0 {
            a.term_active = (a.term_active + (act == .Term_Prev ? -1 : 1) + n) % n
        }
    }
    return true
}

// The editor's own verbs — the ones needing a Buffer's dirty flag, undo history or folds rather
// than just a Doc. They decline everywhere else, so ^S in the config pane's search box does not
// save the file behind it.
@(private = "file")
buffer_run :: proc(a: ^App, act: Action) -> bool {
    b := buffer_target(a)
    if b == nil {
        return false
    }
    #partial switch act {
    case .Indent:
        buffer_tab(b, a.indent)
    case .Fold_Toggle:
        // With folding off ^Enter is still an Enter: a chord that silently does nothing reads
        // as a broken key rather than as a disabled feature.
        if a.folding {buffer_fold_toggle(a, b)} else {buffer_enter(a, b)}
    case .Save:
        // A file we may read and not write stages a `sudo cp` line in the CL rather than failing
        // silently — cl_save is the one save gesture `:w` shares.
        _ = cl_save(a, b)
    case .Undo:
        buffer_undo(b)
    case .Redo:
        buffer_redo(b)
    }
    return true
}

// The file pane's ops, identical under both faces. Extending is the second half of the pair
// wherever there is one: the marked SET rather than the row, the browsed DIRECTORY rather than
// the entry — which is what `e` being nil says below.
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
        filetree_rm_selected(a, extend)
    case .File_Copy_Path:
        clipboard_set(a, strings.clone(e != nil ? e.path : ft.dir), nil) // owned: it takes them
    case .File_Props:
        filetree_props(a, e != nil ? e.path : ft.dir)
    case .File_Workspace:
        cl_workspace(a, ft.dir) // the browsed dir becomes the project root; the terminals follow
    case .File_Edit:
        filetree_edit_selected(a) // open in the editor even when Enter would run it
    case .Parent:
        // The only way out of a GRID, where Left/Right step a tile. It works in the listing too:
        // the two faces differ in pixels, never in what you can reach.
        if browse_target(a) != nil {filebrowser_parent(a)} else {filetree_parent(ft)}
    }
    return true
}

// The browser's top bar and sidebar — absent under the `ls` face, where there is no chrome for
// them to drive, so the whole family declines there.
@(private = "file")
browse_run :: proc(a: ^App, act: Action, n: int) -> bool {
    if browse_target(a) == nil {
        return false
    }
    #partial switch act {
    case .Browse_Back:
        filebrowser_button(a, .Back)
    case .Browse_Forward:
        filebrowser_button(a, .Forward)
    case .Browse_Reload:
        filebrowser_button(a, .Reload)
    case .Browse_View:
        filebrowser_button(a, .View) // list <-> grid, the toggle button's keyboard twin
    case .Browse_Place:
        filebrowser_place_open(a, n + 1) // the sidebar's
    }
    return true
}

// The image surface. Bare keys, which only a surface with nothing to type into can have.
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

// --- the polymorphic verbs --- One proc each, holding every surface's answer, so adding a pane
// means writing its rows here rather than finding four switch statements.

// The four arrows. Not a motion: it is "step, the way this surface steps".
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
        // A live `:f` preview BORROWS Up/Down to cycle its matches — cycling results is what
        // those keys mean everywhere else a result list is up, and a find query is one. History
        // is still there the moment the preview has nothing to cycle.
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
        // The open path line is ONE line: it has no rows to walk, and the listing under it must
        // not walk either while you are typing a destination.
        if n == .Up || n == .Down {
            return false
        }
        doc_step(d, n, extend, all)
        return true
    case .Config_Search, .Config_Value:
        // A text row still walks the ROWS on Up/Down — the pane is a form, and leaving the row
        // is how you commit it. Left/Right are the caret's, as in any other one-line box.
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
    if ft := tree_target(a); ft != nil {
        filetree_nav(a, ft, n, extend)
        return true
    }
    return false
}

// Enter: whatever this surface calls "do the thing I am pointing at". Extending is the second
// half of the pair wherever there is one — a file opens in the DESKTOP's app rather than ours.
@(private = "file")
activate_run :: proc(a: ^App, extend: bool) -> bool {
    kind, _ := active_editable(a)
    switch kind {
    case .Command_Line:
        cl_submit(a)
        return true
    case .Browse_Path:
        filebrowser_path_commit(a)
        return true
    case .Config_Value:
        config_edit_commit(a)
        return true
    case .Config_Search:
        return true // the filter is live as you type; there is nothing to submit
    case .Buffer:
        buffer_enter(a, editor_current(&a.editor)) // newline with auto-indent / brace expansion
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
    if ft := tree_target(a); ft != nil {
        switch {
        case extend:
            filetree_open_selected(a) // hand it to the desktop, or stage its run command
        case browse_target(a) != nil:
            filebrowser_activate(a) // into the folder, through the history
        case:
            filetree_activate_selected(a)
        }
        return true
    }
    return false
}

// Copy / cut. The editable answers first: with the browser's path line open, ^C is the TEXT you
// are typing, not the file the listing happens to be on.
@(private = "file")
clip_take :: proc(a: ^App, cut: bool) -> bool {
    kind, d := active_editable(a)
    switch kind {
    case .Buffer:
        if cut {editor_cut(a)} else {editor_copy(a)}
        return true
    case .Command_Line, .Browse_Path, .Config_Search, .Config_Value:
        field_copy(a, d, cut) // a field with nothing selected copies nothing, and still claims it
        return true
    case .None:
    }
    if ft := tree_target(a); ft != nil {
        // FILL the clipboard from the marked set, or from the row under the cursor when nothing
        // is marked, and say which the paste will be. A cut is spent by its paste; a copy is not.
        filetree_clip_take(ft, cut ? .Cut : .Copy)
        return true
    }
    // A terminal has a selection to copy and nothing to cut. **With nothing selected ^C is not a
    // copy at all** — it is the interrupt, so this declines and the job gets the keystroke.
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
    case .Command_Line, .Browse_Path, .Config_Search, .Config_Value:
        field_paste(a, d)
        return true
    case .None:
    }
    if ft := tree_target(a); ft != nil {
        filetree_paste(ft) // apply the clipboard to the browsed dir
        return true
    }
    // Claimed on the PANE rather than on a live shell, so a dead session swallows it: falling
    // through would reach the job as ^V, which is readline's quoted-insert.
    if ts := term_sel_target(a); ts != nil {
        term_paste(a, ts)
        return true
    }
    return false
}

// A motion with no vertical meaning (words, Home/End). Every editable takes these the same way,
// which is why they need no per-surface branch.
@(private = "file")
motion_run :: proc(a: ^App, m: Motion, extend, all: bool) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    if all {doc_move_all(d, m, extend)} else {doc_move(d, m, extend)}
    return true
}

@(private = "file")
delete_run :: proc(a: ^App, act: Action) -> bool {
    kind, d := active_editable(a)
    if kind == .None {
        return false
    }
    // Two axes, not four verbs: which side of the caret, and whether Ctrl widens it to a word.
    back := act == .Delete_Back || act == .Delete_Word_Back
    word := act == .Delete_Word_Back || act == .Delete_Word_Forward
    // The buffer keeps its own dirty flag and undo history, so it has its own four; every
    // one-line field shares the Doc's.
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
    case back && word: doc_delete_word_back(d)
    case back:         doc_backspace(d)
    case word:         doc_delete_word_forward(d)
    case:              doc_delete(d)
    }
    // The language filter re-runs on an edit rather than on a motion, which is what this is.
    if kind == .Config_Search {
        config_pane_filter(&a.config_pane)
    }
    return true
}

// --- the per-pane answers --- Kept beside the dispatcher rather than in each pane's file, so
// "what do the arrows do here" is one page to read.

// Escape's cascade: it cancels the innermost thing there is to cancel, and drives Zen only when
// there is nothing. A focused live terminal gets it FIRST, so vim and its kin see it.
@(private = "file")
escape_run :: proc(a: ^App, move_all_pending: bool) {
    kind, d := active_editable(a)
    ts, tf := term_sel_target(a), term_focused(a)
    switch {
    case a.cl_chain.waiting:
        cl_chain_clear(a) // abandon a stuck/pending && chain (the shell command runs on)
    case ts != nil && (ts.sel_active || ts.msel_on):
        // First Esc leaves the selection, back to the input line — whichever way it was made.
        terminal_sel_reset(ts)
    case tf != nil:
        terminal_input_key(tf, glfw.KEY_ESCAPE, 0) // vim and its kin must see it
    case kind == .Command_Line:
        cl_cancel(a)
    case kind == .Browse_Path:
        filebrowser_path_cancel(a) // the path bar goes back to being buttons
    case move_all_pending:
    // The prefix was armed and this keystroke spent it. Swallowing it here IS the cancel.
    case kind == .Buffer && len(d.cursors) > 1:
        doc_collapse_to_primary(d)
    case:
        zen_escape(a) // turn Zen on (never off), then flip the shown pane side
    }
}

// The config pane's arrows. An open dropdown owns them; otherwise Up/Down walk the rows and
// Right opens whatever the highlighted row offers. A free-text row never reaches here — it is
// Text, not Surface — so Left has nothing to do but cancel a dropdown.
@(private = "file")
config_nav :: proc(a: ^App, cp: ^ConfigPane, n: Nav) {
    if cp.open != .None {
        switch n {
        case .Up:
            config_dropdown_move(a, -1)
        case .Down:
            config_dropdown_move(a, 1)
        case .Left:
            cp.open = .None // cancel, keep the row selected
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

// Right / Enter on the highlighted row: open whatever choices it has. Package-level because the
// pointer's double click means the same thing (config_click).
config_open_selected :: proc(a: ^App, cp: ^ConfigPane) {
    switch {
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

// The file pane's arrows — the one place the two faces genuinely differ. A GRID row is `br.cols`
// entries wide (filebrowser_frame writes it: only the geometry knows how many tiles fit), and
// there Left/Right step a tile rather than leaving the folder.
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
            filetree_parent(ft) // up to the parent
        }
    case .Right:
        switch {
        case grid:
            filetree_move(ft, 1)
        case br == nil:
            filetree_enter(ft) // into the selected folder
        case:
            if e := filetree_selected(ft); e != nil && e.is_dir {
                filebrowser_activate(a)
            }
        }
    }
}

// Left/Right on a Doc, with the Alt+M prefix applied. The two horizontal arrows are the only
// motion every editable shares with every list, so this is where the Nav enum meets Motion.
@(private = "file")
doc_step :: proc(d: ^Doc, n: Nav, extend, all: bool) {
    m: Motion = n == .Left ? .Left : .Right
    if all {doc_move_all(d, m, extend)} else {doc_move(d, m, extend)}
}
