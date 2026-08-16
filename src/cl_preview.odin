package main

import "core:slice"
import "core:strings"

// Live feedback for the builtin command line: while you type a `:` line the editor shows what
// that line WOULD do, and Esc puts everything back the way it was.
//
// **The engine is a version compare, not a per-edit hook.** `a.cl.doc.version` bumps on every
// mutation of the typed line — a keystroke, a paste, a backspace, a history recall, a
// multi-cursor edit — so one test per frame catches all of them and no edit path has to
// remember to call anything. (The injection alert in cmdline.odin already reads the version
// this way; this is the same trick carrying a bigger payload.)
//
// **A preview writes only fields it saved first.** No text edit, no disk read, nothing added to
// or taken out of the buffer ring. That one rule is what makes it safe to re-run on a keystroke,
// and it turns the cancel path into a straight field copy back rather than an undo.
//
// **What is borrowed is not always the page.** `:grep` moves the Grep pane's results aside and
// lists its own there, so the aux mode and the pane itself are saved the same way a caret is;
// `:j` and `:f` leave both untouched. And because its search is a PROCESS over the whole
// project rather than a read of memory, it is the one preview on a timer (CL_GREP_DELAY).
//
// It also sets the limit on `:j`: a BARE LINE previews, a FILE argument does not. Resolving a
// file name walks the project tree (find_nearest_file), which is far too much for a keystroke,
// and a cheaper rule here would name a different file than the one Enter opens — a preview that
// disagrees with its own command is worse than no preview.
//
// The three ways out, all of them through this file:
//   Esc     cl_cancel  -> cl_preview_restore, and the view is as you left it
//   Enter   cl_submit  -> cl_preview_commit: the landing STAYS, and the builtin runs over it
//   typing  the line stops asking for this preview -> restore, then build the new one

// What the typed line is asking to be shown. One case per previewing builtin; a builtin with no
// case here simply has no preview, which is every other one.
Preview_Kind :: enum {
    None,
    Jump, // `:j <line>`   — the caret on the target line, the view carried there behind it
    Find, // `:f <text>`   — every hit marked, the caret on one of them, Up/Down to cycle
    Grep, // `:grep <re>`  — the results in the Grep pane, the aux pane you were on kept aside
}

CLPreview :: struct {
    kind:    Preview_Kind,
    cl_ver:  u64, // the command line's doc version this was last evaluated at
    buf_ver: u64, // and the previewed buffer's — a reload under it invalidates what was found
    // A rebuild is owed, and `due` is when it may run: this frame for a preview that reads
    // memory, a pause later for `:grep`. Until then the LAST preview stays up.
    pending: bool,
    due:     f64,
    saved:   Preview_Save,
}

// What a preview borrows and owes back. Everything a preview may touch is named here, and it
// may touch nothing else — see the header.
Preview_Save :: struct {
    live:             bool, // a preview is applied right now, and these fields are its picture
    focus:            Focus,
    aux:              AuxMode, // the aux pane it turned away from
    grep:             GrepPane, // and, for `:grep`, the results it moved aside — the whole pane
    // The WHOLE cursor set, cloned. doc_reset_cursor collapses a multi-cursor trail, and one
    // saved Pos could never put one back. Empty when the preview never touched a page (`:grep`).
    cursors:          []Cursor,
    primary:          int,
    scroll:           int,
    hscroll:          int,
    scroll_detached:  f64,
    hscroll_detached: f64,
}

// How long a `:grep` line must sit unchanged before its search runs. The other previews read
// memory and answer on the keystroke; this one spawns grep over the whole project, so it waits
// for a pause in the typing — and leaves the last results up while it waits, rather than
// blinking the pane away between letters.
CL_GREP_DELAY :: 0.15

// Shortest `:grep` pattern that previews. A letter or two matches most of a project: the search
// costs a walk of the tree and the answer says nothing.
CL_GREP_MIN :: 2

// The tick, once a frame (main.odin). Cheap at rest: two integer compares and out.
cl_preview_sync :: proc(a: ^App, now: f64) {
    p := &a.cl_preview
    b := main_text_buffer(a)
    if !a.cl_active || !a.cl_preview_on {
        cl_preview_restore(a) // the line closed, or the setting went off
        p.pending = false
        return
    }
    bv := b == nil ? 0 : b.version
    if a.cl.doc.version != p.cl_ver || bv != p.buf_ver { // typed, or reloaded underneath it
        p.cl_ver, p.buf_ver = a.cl.doc.version, bv
        p.pending = true
        p.due = now + cl_preview_delay(a)
    }
    if p.pending && now >= p.due {
        p.pending = false
        cl_preview_build(a, b)
    }
}

// The wait the line the user is holding asks for (see CL_GREP_DELAY). app_next_wake schedules
// the frame it comes due in, so a pause in the typing is enough to make the search run.
@(private = "file")
cl_preview_delay :: proc(a: ^App) -> f64 {
    name, _, ok := cl_preview_call(doc_string(&a.cl.doc, context.temp_allocator))
    return ok && name == "grep" ? CL_GREP_DELAY : 0
}

// Drop whatever is showing and build what the line now asks for. The restore runs FIRST every
// time: the new preview has to photograph a pristine view, never one the last preview moved.
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

// The builtin the typed line is calling. ok=false unless the WHOLE line is ONE builtin: an
// unsigilled line is a shell command, whose effects are not ours to guess, and a `&&` chain
// has no single thing to show — its first step is not what the line does.
@(private = "file")
cl_preview_call :: proc(line: string) -> (name, args: string, ok: bool) {
    if strings.contains(line, "&&") {
        return "", "", false
    }
    return cl_builtin_call(line)
}

// --- the previews ---

// `:j <line>`: put the caret on the target line and let the scroll policy carry the view to it.
// Moving the CARET rather than the scroll is the whole implementation — buffer_scroll_apply, the
// current-line bar and the caret itself then show the target with no new code, and one saved
// cursor set puts every part of it back.
@(private = "file")
preview_jump :: proc(a: ^App, b: ^Buffer, args: string) {
    if b == nil {
        return
    }
    // The same parse the builtin commits with, so the two can never land in different places;
    // it answers false for a file argument, which is the form that does not preview.
    pos, ok := cl_jump_line(b, args)
    if !ok {
        return
    }
    preview_begin(a, b, .Jump)
    set_focus(a, .Editor)
    doc_reset_cursor(&b.doc, pos)
}

// `:f <text>`: mark every hit and sit the caret on the one nearest where you started.
@(private = "file")
preview_find :: proc(a: ^App, b: ^Buffer, args: string) {
    query := strings.trim_space(args)
    if b == nil || query == "" {
        return
    }
    anchor := b.cursors[b.primary].head // read BEFORE the picture: the caret is still yours
    preview_begin(a, b, .Find)
    set_focus(a, .Editor)
    find_set(&a.find, b, query, anchor)
    a.find.show = true
    if pos, ok := find_pos(&a.find); ok {
        doc_reset_cursor(&b.doc, pos)
    }
}

// `:grep <re>`: run the project search and list it in the Grep pane, with the pane you were on
// kept aside for the Esc. The one preview that borrows the AUX side rather than the page — it
// moves no caret and reads no buffer, so `nil` stands in for the picture of a page.
//
// **The old results are MOVED aside, not copied.** A GrepPane owns everything it holds, so one
// struct swap saves the whole of it and the preview starts on an empty pane; the swap back is
// the restore, and whichever pane ends up in the slot is the one preview_end frees.
//
// A lone hit LISTS here where the builtin would jump straight into the file (`grep_pane: off`):
// a preview may not open anything. The pane still shows the hit Enter then lands on.
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

// Up/Down while a find preview holds hits: step through them, wrapping. Returns false when
// there is nothing to cycle, and the command line's history keys stand (input.odin).
//
// Cycling deliberately does NOT go through the sync tick: moving a cursor bumps no version, so
// the preview built for this query stays built and the step is not undone next frame.
//
// A `:grep` preview does NOT cycle, so Up/Down stay the history keys while one is up: Enter
// re-runs the search and would drop the pick anyway, and the pane takes the arrows itself the
// moment the line closes.
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

// Photograph the view and declare the preview live. `b` is the page it is about to move, or nil
// for a preview that moves none.
//
// The TURN is the caller's: a preview nobody can see is not one, and each kind is shown
// somewhere else — the editor for `:j`/`:f`, the Grep pane for `:grep`. (The command line keeps
// the keys whatever holds focus, so nothing about typing changes.)
//
// Called once per preview, always straight after the restore in cl_preview_build, so it can
// never overwrite a picture still owed back.
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

// Put the view back and forget the preview. A no-op when nothing is saved, so every caller can
// reach for it without asking first.
cl_preview_restore :: proc(a: ^App) {
    s := &a.cl_preview.saved
    if !s.live {
        return
    }
    if b := main_text_buffer(a); b != nil && len(s.cursors) > 0 {
        // Clamped on the way back: the file can be RELOADED under a live preview (view_poll_disk),
        // and a cursor saved against the old text must not return pointing past the new end.
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
        a.grep, s.grep = s.grep, a.grep // your results back; the preview's go to be freed
    }
    a.aux_mode = s.aux
    set_focus(a, s.focus)
    preview_end(a)
}

// Forget the preview WITHOUT undoing it — the Enter path. What it put on screen is what you
// asked for, so the caret stays exactly where the preview (and any cycling) left it.
cl_preview_commit :: proc(a: ^App) {
    preview_end(a)
}

// The tail both ways out share. The marks come down either way: Enter answers the question and
// Esc withdraws it, and neither leaves a page still lit up behind a closed command line.
//
// The saved slot always holds the DISCARDED grep pane by now — the old results on the Enter
// path, the preview's own on the Esc path, which swapped them — so one free serves both.
@(private = "file")
preview_end :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
    grep_destroy(&a.cl_preview.saved.grep)
    a.cl_preview.saved = {}
    a.cl_preview.kind = .None
    a.find.show = false
}

// Teardown. Only the owned allocations matter: nothing is going back on screen, so this is the
// free and not the restore.
cl_preview_destroy :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
    grep_destroy(&a.cl_preview.saved.grep)
}
