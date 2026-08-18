package main

import "core:strings"
import "vendor:glfw"

// The system clipboard, plus our memory of the last copy so a multi-cursor paste can put one
// piece back per caret. Every surface's copy/cut/paste ends here (clip_take / clip_put).

// Selections, or whole lines when nothing is selected. The pieces are remembered so a later
// equal-count paste can distribute them.
editor_copy :: proc(a: ^App) {
    b := editor_current(&a.editor)
    joined, pieces := doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
}

editor_cut :: proc(a: ^App) {
    b := editor_current(&a.editor)
    joined, pieces := doc_copy(&b.doc)
    clipboard_set(a, joined, pieces)
    if doc_cut(&b.doc) {
        b.dirty = true
    }
}

// One piece per caret when the clipboard still holds exactly our last copy and the counts line
// up; otherwise the whole text at every caret.
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

// Either selection will do: the keyboard's line range, or the mouse's character span. This is
// also the question ^C asks — no span, no copy to make, so the chord is the job's interrupt.
term_has_span :: proc(t: ^Terminal) -> bool {
    return t.sel_active || terminal_msel_has_span(t)
}

// Plain joined text — no per-cursor pieces, so a later paste anywhere is literal.
term_copy :: proc(a: ^App, t: ^Terminal) {
    if !term_has_span(t) {
        return
    }
    clipboard_set(a, terminal_selection_text(t), nil)
}

// The shell gets literal text, and a dead session gets nothing.
term_paste :: proc(a: ^App, t: ^Terminal) {
    if !terminal_alive(t) {
        return
    }
    terminal_paste(t, glfw.GetClipboardString(a.window))
}

// Takes ownership of `joined` and `pieces`, freeing the previous remembered copy.
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
