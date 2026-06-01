package main

import "core:os"
import "core:strings"

// The text editor: a list of open Buffers (the ring) with one active. Each Buffer
// is a Doc (the shared multi-cursor editing core) plus file/view state, so every
// motion and edit op is the same code the command line uses. Multi-cursor native:
// single-cursor is just N == 1. The UI to spawn extra cursors is still to come.

Buffer :: struct {
    using doc: Doc, // lines + cursors
    path:      string, // owned; "" = unnamed/scratch
    scroll:    int, // first visible line (view state, clamped at render)
    dirty:     bool,
}

Editor :: struct {
    buffers: [dynamic]Buffer,
    active:  int,
}

editor_init :: proc(e: ^Editor) {
    b: Buffer
    doc_init(&b.doc) // one empty line, one cursor
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
    defer a.focus = .Editor

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
}

buffer_load :: proc(b: ^Buffer, path: string) -> bool {
    src, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return false
    }
    buffer_set_text(b, string(src))
    delete(b.path)
    b.path = strings.clone(path)
    b.dirty = false
    return true
}

buffer_save :: proc(b: ^Buffer) -> bool {
    if b.path == "" {
        return false // save-as not implemented yet
    }
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)
    for &l, i in b.lines {
        if i > 0 {
            strings.write_byte(&sb, '\n')
        }
        for r in l.text {
            strings.write_rune(&sb, r)
        }
    }
    if os.write_entire_file(b.path, transmute([]u8)strings.to_string(sb)) != nil {
        return false
    }
    b.dirty = false
    return true
}

// --- editing (thin wrappers over the Doc core; mark the buffer dirty) ---

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
    b.dirty |= doc_insert_rune(&b.doc, r)
}

buffer_indent :: proc(b: ^Buffer, indent: Indent) {
    b.dirty |= doc_indent(&b.doc, indent)
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

// --- movement (no edits; the Doc ops wrap across line boundaries) ---

buffer_left :: proc(b: ^Buffer) {
    doc_move_left(&b.doc)
}

buffer_right :: proc(b: ^Buffer) {
    doc_move_right(&b.doc)
}

buffer_word_left :: proc(b: ^Buffer) {
    doc_move_word_left(&b.doc)
}

buffer_word_right :: proc(b: ^Buffer) {
    doc_move_word_right(&b.doc)
}

buffer_up :: proc(b: ^Buffer) {
    doc_move_up(&b.doc)
}

buffer_down :: proc(b: ^Buffer) {
    doc_move_down(&b.doc)
}

buffer_home :: proc(b: ^Buffer) {
    doc_move_home(&b.doc)
}

buffer_end :: proc(b: ^Buffer) {
    doc_move_end(&b.doc)
}
