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
    Jump, // `:j <line>`  — the caret on the target line, the view carried there behind it
    Find, // `:f <text>`  — every hit marked, the caret on one of them, Up/Down to cycle
}

CLPreview :: struct {
    kind:    Preview_Kind,
    cl_ver:  u64, // the command line's doc version this was last evaluated at
    buf_ver: u64, // and the previewed buffer's — a reload under it invalidates what was found
    saved:   Preview_Save,
}

// What a preview borrows and owes back. Everything a preview may touch is named here, and it
// may touch nothing else — see the header.
Preview_Save :: struct {
    live:             bool, // a preview is applied right now, and these fields are its picture
    focus:            Focus,
    // The WHOLE cursor set, cloned. doc_reset_cursor collapses a multi-cursor trail, and one
    // saved Pos could never put one back.
    cursors:          []Cursor,
    primary:          int,
    scroll:           int,
    hscroll:          int,
    scroll_detached:  f64,
    hscroll_detached: f64,
}

// The tick, once a frame (main.odin). Cheap at rest: two integer compares and out.
cl_preview_sync :: proc(a: ^App) {
    p := &a.cl_preview
    b := main_text_buffer(a)
    if !a.cl_active || !a.cl_preview_on || b == nil {
        cl_preview_restore(a) // the line closed, the setting went off, or there is no page for it
        return
    }
    if a.cl.doc.version == p.cl_ver && b.version == p.buf_ver {
        return // nothing typed, and nothing reloaded underneath it
    }
    cl_preview_build(a, b)
    p.cl_ver = a.cl.doc.version
    p.buf_ver = b.version
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
    // The same parse the builtin commits with, so the two can never land in different places;
    // it answers false for a file argument, which is the form that does not preview.
    pos, ok := cl_jump_line(b, args)
    if !ok {
        return
    }
    preview_begin(a, b, .Jump)
    doc_reset_cursor(&b.doc, pos)
}

// `:f <text>`: mark every hit and sit the caret on the one nearest where you started.
@(private = "file")
preview_find :: proc(a: ^App, b: ^Buffer, args: string) {
    query := strings.trim_space(args)
    if query == "" {
        return
    }
    anchor := b.cursors[b.primary].head // read BEFORE the picture: the caret is still yours
    preview_begin(a, b, .Find)
    find_set(&a.find, b, query, anchor)
    a.find.show = true
    if pos, ok := find_pos(&a.find); ok {
        doc_reset_cursor(&b.doc, pos)
    }
}

// Up/Down while a find preview holds hits: step through them, wrapping. Returns false when
// there is nothing to cycle, and the command line's history keys stand (input.odin).
//
// Cycling deliberately does NOT go through the sync tick: moving a cursor bumps no version, so
// the preview built for this query stays built and the step is not undone next frame.
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

// Photograph the view, declare the preview live, and turn to the editor — a preview nobody can
// see is not one, and in Full view the editor is off screen until focus asks for it. (The
// command line keeps the keys whatever holds focus, so nothing about typing changes.)
//
// Called once per preview, always straight after the restore in cl_preview_build, so it can
// never overwrite a picture still owed back.
@(private = "file")
preview_begin :: proc(a: ^App, b: ^Buffer, kind: Preview_Kind) {
    a.cl_preview.kind = kind
    a.cl_preview.saved = Preview_Save {
        live             = true,
        focus            = a.focus,
        cursors          = slice.clone(b.cursors[:]),
        primary          = b.primary,
        scroll           = b.scroll,
        hscroll          = b.hscroll,
        scroll_detached  = b.scroll_detached,
        hscroll_detached = b.hscroll_detached,
    }
    set_focus(a, .Editor)
}

// Put the view back and forget the preview. A no-op when nothing is saved, so every caller can
// reach for it without asking first.
cl_preview_restore :: proc(a: ^App) {
    s := &a.cl_preview.saved
    if !s.live {
        return
    }
    if b := main_text_buffer(a); b != nil {
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
@(private = "file")
preview_end :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
    a.cl_preview.saved = {}
    a.cl_preview.kind = .None
    a.find.show = false
}

// Teardown. Only the owned allocation matters: nothing is going back on screen, so this is the
// free and not the restore.
cl_preview_destroy :: proc(a: ^App) {
    delete(a.cl_preview.saved.cursors)
}
