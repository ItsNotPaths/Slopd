package main

import "core:strings"
import "vendor:glfw"
import "../txt"
import "../pty"
import "../edit"

// The system clipboard, plus our memory of the last copy so a multi-cursor paste can put one
// piece back per caret. Every surface's copy/cut/paste ends here (clip_take / clip_put).
//
// The system half is the front-end's, because the two have nothing in common: a window asks its
// window system, and a terminal writes OSC 52 and cannot read at all. `user` is that front-end's
// own handle, opaque here — the same trade ClayCustom.paint makes, and for the same reason.
Clipboard :: struct {
    get:  proc(user: rawptr) -> string, // "" when the front-end has no way to read one
    set:  proc(user: rawptr, s: string),
    user: rawptr,
}

// Falls back to our own last copy, which is what a terminal answers with: OSC 52 is write-only,
// so the system's clipboard is not readable and ours is the only one there is.
clipboard_get :: proc(a: ^App) -> string {
    if a.paste_in != "" {
        return a.paste_in
    }
    if a.clipboard.get == nil {
        return a.clip_joined
    }
    if s := a.clipboard.get(a.clipboard.user); s != "" {
        return s
    }
    return a.clip_joined
}

// Selections, or whole lines when nothing is selected. The pieces are remembered so a later
// equal-count paste can distribute them.
editor_copy :: proc(a: ^App) {
    b := edit.editor_current(&a.editor)
    joined, pieces := txt.doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
}

editor_cut :: proc(a: ^App) {
    b := edit.editor_current(&a.editor)
    joined, pieces := txt.doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
    if txt.doc_cut(&b.doc) {
        b.dirty = true
    }
}

// One piece per caret when the clipboard still holds exactly our last copy and the counts line
// up; otherwise the whole text at every caret.
editor_paste :: proc(a: ^App) {
    b := edit.editor_current(&a.editor)
    clip := clipboard_get(a)
    changed: bool
    if len(a.clip_pieces) > 1 && clip == a.clip_joined && len(a.clip_pieces) == len(b.cursors) {
        changed = txt.doc_paste_pieces(&b.doc, a.clip_pieces)
    } else {
        changed = txt.doc_paste(&b.doc, clip)
    }
    if changed {
        b.dirty = true
    }
}

// Either selection will do: the keyboard's line range, or the mouse's character span. This is
// also the question ^C asks — no span, no copy to make, so the chord is the job's interrupt.
term_has_span :: proc(t: ^pty.Terminal) -> bool {
    return t.sel_active || pty.terminal_msel_has_span(t)
}

// Plain joined text — no per-cursor pieces, so a later paste anywhere is literal.
term_copy :: proc(a: ^App, t: ^pty.Terminal) {
    if !term_has_span(t) {
        return
    }
    clipboard_set(a, pty.terminal_selection_text(t), nil)
}

// The shell gets literal text, and a dead session gets nothing.
term_paste :: proc(a: ^App, t: ^pty.Terminal) {
    if !pty.terminal_alive(t) {
        return
    }
    pty.terminal_paste(t, clipboard_get(a))
}

// Takes ownership of `joined` and `pieces`, freeing the previous remembered copy.
clipboard_set :: proc(a: ^App, joined: string, pieces: []string) {
    if a.clipboard.set != nil {
        a.clipboard.set(a.clipboard.user, joined)
    }

    delete(a.clip_joined)
    for p in a.clip_pieces {
        delete(p)
    }
    delete(a.clip_pieces)
    a.clip_joined = joined
    a.clip_pieces = pieces
}
