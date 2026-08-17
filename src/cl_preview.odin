package main

import "core:slice"
import "core:strings"

// While you type a `:` line the editor shows what that line WOULD do, and Esc puts everything
// back.
//
// The engine is a version compare, not a per-edit hook: `a.cl.doc.version` bumps on every
// mutation of the typed line, so one test per frame catches all of them.
//
// A preview writes only fields it saved first — no text edit, no disk read, nothing in or out
// of the buffer ring. That is what makes it safe on a keystroke and makes cancel a field copy.
//
// What is borrowed is not always the page: `:grep` moves the Grep pane's results aside and
// lists its own there. Its search is a process over the whole project, so it is the one preview
// on a timer (CL_GREP_DELAY). The same cost sets the limit on `:j`: a bare line previews, a
// file argument does not, because resolving a name walks the project tree.
//
// The three ways out, all through this file:
//   Esc     cl_cancel  -> cl_preview_restore, and the view is as you left it
//   Enter   cl_submit  -> cl_preview_commit: the landing stays, and the builtin runs over it
//   typing  restore, then build the new one

// One case per previewing builtin; every other builtin has no preview.
Preview_Kind :: enum {
    None,
    Jump, // `:j <line>`   caret on the target line, the view carried behind it
    Find, // `:f <text>`   every hit marked, Up/Down to cycle
    Grep, // `:grep <re>`  results in the Grep pane, the pane you were on kept aside
}

CLPreview :: struct {
    kind:    Preview_Kind,
    cl_ver:  u64, // the command line's doc version this was last evaluated at
    buf_ver: u64, // and the buffer's — a reload under it invalidates what was found
    // A rebuild is owed, and `due` is when it may run: this frame for a memory read, a pause
    // later for `:grep`. Until then the last preview stays up.
    pending: bool,
    due:     f64,
    saved:   Preview_Save,
}

// Everything a preview may touch is named here, and it may touch nothing else.
Preview_Save :: struct {
    live:             bool, // a preview is applied right now, and these fields are its picture
    focus:            Focus,
    aux:              AuxMode, // the aux pane it turned away from
    grep:             GrepPane, // for `:grep`, the whole pane it moved aside
    // The WHOLE cursor set: doc_reset_cursor collapses a trail, and one saved Pos could not put
    // it back. Empty when the preview never touched a page.
    cursors:          []Cursor,
    primary:          int,
    scroll:           int,
    hscroll:          int,
    scroll_detached:  f64,
    hscroll_detached: f64,
}

// How long a `:grep` line sits unchanged before its search runs. The last results stay up while
// it waits, rather than blinking the pane away between letters.
CL_GREP_DELAY :: 0.15

// A letter or two matches most of a project: the walk costs, and the answer says nothing.
CL_GREP_MIN :: 2

// Once a frame (main.odin). Two integer compares at rest.
cl_preview_sync :: proc(a: ^App, now: f64) {
    p := &a.cl_preview
    b := main_text_buffer(a)
    if !a.cl_active || !a.cl_preview_on {
        cl_preview_restore(a) // the line closed, or the setting went off
        p.pending = false
        return
    }
    bv := b == nil ? 0 : b.version
    if a.cl.doc.version != p.cl_ver || bv != p.buf_ver { // typed, or reloaded underneath
        p.cl_ver, p.buf_ver = a.cl.doc.version, bv
        p.pending = true
        p.due = now + cl_preview_delay(a)
    }
    if p.pending && now >= p.due {
        p.pending = false
        cl_preview_build(a, b)
    }
}

// app_next_wake schedules the frame it comes due in, so a pause in the typing runs the search.
@(private = "file")
cl_preview_delay :: proc(a: ^App) -> f64 {
    name, _, ok := cl_preview_call(doc_string(&a.cl.doc, context.temp_allocator))
    return ok && name == "grep" ? CL_GREP_DELAY : 0
}

// The restore runs first every time: the new preview must photograph a pristine view.
@(private = "file")
cl_preview_build :: proc(a: ^App, b: ^Buffer) {
    cl_preview_restore(a)
    name, args, ok := cl_preview_call(doc_string(&a.cl.doc, context.temp_allocator))
    if !ok {
        return
    }
    switch name {
    case "j", "jump":
        preview_jump(a, b, args)
    case "f", "find":
        preview_find(a, b, args)
    case "grep":
        preview_grep(a, args)
    }
}

// ok=false unless the whole line is one builtin: a shell command's effects are not ours to
// guess, and a `&&` chain has no single thing to show.
@(private = "file")
cl_preview_call :: proc(line: string) -> (name, args: string, ok: bool) {
    if strings.contains(line, "&&") {
        return "", "", false
    }
    return cl_builtin_call(line)
}

// --- the previews ---

// Move the CARET and let the scroll policy carry the view: buffer_scroll_apply, the current-line
// bar and the caret then show the target with no new code, and one saved cursor set undoes it.
@(private = "file")
preview_jump :: proc(a: ^App, b: ^Buffer, args: string) {
    if b == nil {
        return
    }
    // The parse the builtin commits with, so the two cannot land in different places. It
    // answers false for a file argument, the form that does not preview.
    pos, ok := cl_jump_line(b, args)
    if !ok {
        return
    }
    preview_begin(a, b, .Jump)
    set_focus(a, .Editor)
    doc_reset_cursor(&b.doc, pos)
}

@(private = "file")
preview_find :: proc(a: ^App, b: ^Buffer, args: string) {
    query := strings.trim_space(args)
    if b == nil || query == "" {
        return
    }
    anchor := b.cursors[b.primary].head // before the picture: the caret is still yours
    preview_begin(a, b, .Find)
    set_focus(a, .Editor)
    find_set(&a.find, b, query, anchor)
    a.find.show = true
    if pos, ok := find_pos(&a.find); ok {
        doc_reset_cursor(&b.doc, pos)
    }
}

// The one preview that borrows the aux side rather than the page, so `nil` stands in for the
// picture of a page. The old results are MOVED aside, not copied: a GrepPane owns everything it
// holds, so one struct swap saves it and the swap back is the restore.
//
// A lone hit LISTS here where the builtin would jump straight in: a preview may not open
// anything.
@(private = "file")
preview_grep :: proc(a: ^App, args: string) {
    query := cl_grep_query(args)
    if len(query) < CL_GREP_MIN {
        return
    }
    preview_begin(a, nil, .Grep)
    set_aux(a, .Grep)
    a.cl_preview.saved.grep = a.grep
    a.grep = {}
    grep_set(&a.grep, query, grep_project(a, query))
}

// Step through a find preview's hits, wrapping. False when there is nothing to cycle, and the
// history keys stand. Cycling does not go through the sync tick: moving a cursor bumps no
// version, so the preview stays built. A `:grep` preview does not cycle — Enter re-runs the
// search and would drop the pick anyway.
cl_preview_step :: proc(a: ^App, dir: int) -> bool {
    b := main_text_buffer(a)
    if a.cl_preview.kind != .Find || b == nil || len(a.find.matches) == 0 {
        return false
    }
    find_step(&a.find, dir)
    if pos, ok := find_pos(&a.find); ok {
        doc_reset_cursor(&b.doc, pos)
    }
    return true
}

// --- borrow and return ---

// `b` is the page it is about to move, or nil for a preview that moves none. The TURN is the
// caller's, since each kind is shown somewhere else. Called once per preview, straight after
// the restore, so it can never overwrite a picture still owed back.
@(private = "file")
preview_begin :: proc(a: ^App, b: ^Buffer, kind: Preview_Kind) {
    a.cl_preview.kind = kind
    a.cl_preview.saved = Preview_Save {
        live  = true,
        focus = a.focus,
        aux   = a.aux_mode,
    }
    if b == nil {
        return
    }
    a.cl_preview.saved.cursors = slice.clone(b.cursors[:])
    a.cl_preview.saved.primary = b.primary
    a.cl_preview.saved.scroll = b.scroll
    a.cl_preview.saved.hscroll = b.hscroll
    a.cl_preview.saved.scroll_detached = b.scroll_detached
    a.cl_preview.saved.hscroll_detached = b.hscroll_detached
}

// A no-op when nothing is saved, so callers need not ask first.
cl_preview_restore :: proc(a: ^App) {
    s := &a.cl_preview.saved
    if !s.live {
        return
    }
    if b := main_text_buffer(a); b != nil && len(s.cursors) > 0 {
        // Clamped: the file can be reloaded under a live preview, and a cursor saved against
        // the old text must not return pointing past the new end.
        clear(&b.cursors)
        for c in s.cursors {
            append(&b.cursors, Cursor{
                anchor = doc_clamp_pos(&b.doc, c.anchor),
                head   = doc_clamp_pos(&b.doc, c.head),
                goal   = c.goal,
            })
        }
        b.primary = clamp(s.primary, 0, len(b.cursors) - 1)
        b.scroll = s.scroll
        b.hscroll = s.hscroll
        b.scroll_detached = s.scroll_detached
        b.hscroll_detached = s.hscroll_detached
    }
    if a.cl_preview.kind == .Grep {
        a.grep, s.grep = s.grep, a.grep // yours back; the preview's go to be freed
    }
    a.aux_mode = s.aux
    set_focus(a, s.focus)
    preview_end(a)
}

// The Enter path: forget without undoing, so the caret stays where the preview left it.
cl_preview_commit :: proc(a: ^App) {
    preview_end(a)
}

// The tail both ways out share; the marks come down either way. The saved slot holds the
// discarded grep pane by now — the old results on Enter, the preview's own on Esc, which
// swapped them — so one free serves both.
@(private = "file")
preview_end :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
    grep_destroy(&a.cl_preview.saved.grep)
    a.cl_preview.saved = {}
    a.cl_preview.kind = .None
    a.find.show = false
}

// Nothing is going back on screen, so this is the free and not the restore.
cl_preview_destroy :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
    grep_destroy(&a.cl_preview.saved.grep)
}
