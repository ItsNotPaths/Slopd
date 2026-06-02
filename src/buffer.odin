package main

import "core:os"
import "core:strings"

// The text editor: a list of open Buffers (the ring) with one active. Each Buffer
// is a Doc (the shared multi-cursor editing core) plus file/view state, so every
// motion and edit op is the same code the command line uses. Multi-cursor native:
// single-cursor is just N == 1. The UI to spawn extra cursors is still to come.

Buffer :: struct {
    using doc:     Doc, // lines + cursors
    path:          string, // owned; "" = unnamed/scratch
    scroll:        int, // first visible line, the scroll TARGET (clamped at render)
    scroll_anim:   Anim, // visual top line tweening toward `scroll` (smooth scroll)
    dirty:         bool,
    final_newline: bool, // did the file end in '\n'? preserved on save (POSIX round-trip)
}

Editor :: struct {
    buffers: [dynamic]Buffer,
    active:  int,
}

editor_init :: proc(e: ^Editor) {
    b: Buffer
    doc_init(&b.doc) // one empty line, one cursor
    b.final_newline = true // a fresh file gets the conventional trailing newline
    append(&e.buffers, b)
}

editor_destroy :: proc(e: ^Editor) {
    for &b in e.buffers {
        buffer_destroy(&b)
    }
    delete(e.buffers)
}

editor_current :: proc(e: ^Editor) -> ^Buffer {
    return &e.buffers[e.active]
}

// --- cross-part seams (called by the filetree / command line) ---

// Loads path into the editor: reactivates an existing buffer for it, reuses the
// scratch buffer if it's untouched, otherwise opens a new buffer. Focuses editor.
open_file :: proc(a: ^App, path: string) {
    e := &a.editor
    defer set_focus(a, .Editor)

    for &b, i in e.buffers {
        if b.path == path {
            e.active = i
            return
        }
    }
    cur := editor_current(e)
    if cur.path == "" && !cur.dirty && len(cur.lines) == 1 && len(cur.lines[0].text) == 0 {
        buffer_load(cur, path)
        return
    }
    b: Buffer
    if buffer_load(&b, path) {
        append(&e.buffers, b)
        e.active = len(e.buffers) - 1
    } else {
        buffer_destroy(&b)
    }
}

// Is path open with unsaved changes? (Lights up its '*' in the filetree.)
ring_contains :: proc(a: ^App, path: string) -> bool {
    for &b in a.editor.buffers {
        if b.dirty && b.path == path {
            return true
        }
    }
    return false
}

// --- buffer lifecycle ---

buffer_destroy :: proc(b: ^Buffer) {
    doc_destroy(&b.doc)
    delete(b.path)
}

buffer_set_text :: proc(b: ^Buffer, text: string) {
    doc_set_text(&b.doc, text)
    b.scroll = 0
    b.scroll_anim = {} // settled at the top; a reused scratch buffer won't smear from its old scroll
}

buffer_load :: proc(b: ^Buffer, path: string) -> bool {
    src, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return false
    }
    content := string(src)
    buffer_set_text(b, content)
    delete(b.path)
    b.path = strings.clone(path)
    b.dirty = false
    b.final_newline = strings.has_suffix(content, "\n") // remember it for save
    return true
}

buffer_save :: proc(b: ^Buffer) -> bool {
    if b.path == "" {
        return false // save-as not implemented yet
    }
    // doc_string is the single serializer (lines joined by '\n', no trailing one);
    // re-add the trailing newline only if the loaded file had one.
    data := doc_string(&b.doc, context.temp_allocator)
    if b.final_newline {
        data = strings.concatenate({data, "\n"}, context.temp_allocator)
    }
    if os.write_entire_file(b.path, transmute([]u8)data) != nil {
        return false
    }
    b.dirty = false
    return true
}

// --- editing (thin wrappers over the Doc core; mark the buffer dirty) ---

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
    b.dirty |= doc_insert_rune(&b.doc, r)
}

buffer_newline :: proc(b: ^Buffer) {
    b.dirty |= doc_newline(&b.doc)
}

buffer_backspace :: proc(b: ^Buffer) {
    b.dirty |= doc_backspace(&b.doc)
}

buffer_delete :: proc(b: ^Buffer) {
    b.dirty |= doc_delete(&b.doc)
}

buffer_delete_word_back :: proc(b: ^Buffer) {
    b.dirty |= doc_delete_word_back(&b.doc)
}

buffer_delete_word_forward :: proc(b: ^Buffer) {
    b.dirty |= doc_delete_word_forward(&b.doc)
}

buffer_undo :: proc(b: ^Buffer) {
    if doc_undo(&b.doc) {
        b.dirty = true
    }
}

buffer_redo :: proc(b: ^Buffer) {
    if doc_redo(&b.doc) {
        b.dirty = true
    }
}

// --- movement (no edits; the Doc ops wrap across line boundaries). select=true
// (Shift) grows a selection; all=true (the Alt+M prefix) moves every cursor rather
// than just the free caret. ---

buffer_motion :: proc(b: ^Buffer, motion: Motion, select := false, all := false) {
    if all {
        doc_move_all(&b.doc, motion, select)
    } else {
        doc_move(&b.doc, motion, select)
    }
}
