package main

import "core:strings"
import "txt"

// The ring reached through the App: which buffer a pane is looking at, opening a path into it,
// and the Enter that has to know the language before it can indent.

// editor_current behind the two questions every whole-buffer tool asks first. Nil on the image
// surface and on the bare App the tests build.
main_text_buffer :: proc(a: ^App) -> ^Buffer {
    if a.main != .Text || len(a.editor.buffers) == 0 {
        return nil
    }
    return editor_current(&a.editor)
}

// An image routes to the media viewer; anything else is text — an existing buffer for it, or
// the scratch buffer if untouched, or a new one. Focuses the main pane either way.
open_file :: proc(a: ^App, path: string) {
    defer set_focus(a, .Editor)

    // A failed decode leaves the current surface untouched.
    if is_media_path(path) {
        if m, ok := media_load(path); ok {
            media_destroy(&a.media)
            a.media = m
            a.main = .Image
        } else {
            open_stage_sudo(a, path)
        }
        return
    }

    a.main = .Text
    e := &a.editor
    for &b, i in e.buffers {
        if b.path == path && !b.embedded { // an embedded doc's path is a name
            e.active = i
            return
        }
    }
    cur := editor_current(e)
    if cur.path == "" && !cur.dirty && txt.doc_line_count(&cur.doc) == 1 && txt.doc_line_len(&cur.doc, 0) == 0 {
        if !buffer_load(cur, path) {
            open_stage_sudo(a, path)
        }
        return
    }
    b: Buffer
    if buffer_load(&b, path) {
        append(&e.buffers, b)
        e.active = len(e.buffers) - 1
    } else {
        buffer_destroy(&b)
        open_stage_sudo(a, path)
    }
}

// A newline copying the line's leading whitespace, plus one indent unit when the line opens a
// block at the caret. A lone caret between a bracket pair expands across three lines.
// Heuristic-first, so it works with no grammar installed.
buffer_enter :: proc(a: ^App, b: ^Buffer) {
    d := &b.doc

    if len(d.cursors) == 1 && !txt.cursor_has_selection(d.cursors[0]) {
        c := d.cursors[0]
        prev, size := txt.doc_rune_before(d, c.head)
        if enter_expands_pair(prev, txt.doc_rune_at(d, c.head)) &&
           !ts_in_string_or_comment(a, b, c.head.line, c.head.col - size) {
            base := line_lead(d, c.head.line)
            inner := grow_indent(base, a.indent)
            body := strings.concatenate({"\n", inner, "\n", base}, context.temp_allocator)
            if txt.doc_insert_text(d, body) {
                b.dirty = true
            }
            txt.doc_reset_cursor(d, txt.Pos{c.head.line + 1, len(inner)}) // the indented middle line
            return
        }
    }

    // Each cursor gets a newline plus its own computed indent.
    edits := make([dynamic]txt.Edit, 0, len(d.cursors), context.temp_allocator)
    for c in txt.edit_cursors(d) {
        lo, hi := txt.cursor_range(c)
        text := strings.concatenate({"\n", enter_indent(a, b, lo)}, context.temp_allocator)
        append(&edits, txt.Edit{txt.doc_off(d, lo), txt.doc_off(d, hi), text, 0})
    }
    if txt.doc_commit(d, edits[:]) {
        b.dirty = true
    }
}

// The current line's leading whitespace, plus one unit when it opens a block at the caret.
@(private = "file")
enter_indent :: proc(a: ^App, b: ^Buffer, pos: txt.Pos) -> string {
    lead := line_lead(&b.doc, pos.line)
    if enter_opens_block(a, b, pos) {
        return grow_indent(lead, a.indent)
    }
    return lead
}

// The last non-blank char before the caret is an opener `([{` that is real code — tree-sitter
// rules out one inside a string or comment where a grammar exists.
@(private = "file")
enter_opens_block :: proc(a: ^App, b: ^Buffer, pos: txt.Pos) -> bool {
    line := txt.doc_line(&b.doc, pos.line)
    at := -1
    for i := min(pos.col, len(line)) - 1; i >= 0; i -= 1 {
        if line[i] != ' ' && line[i] != '\t' {
            at = i
            break
        }
    }
    if at < 0 {
        return false
    }
    switch line[at] {
    case '(', '[', '{':
        return !ts_in_string_or_comment(a, b, pos.line, at)
    }
    return false
}


// Quotes excluded: splitting a string across lines is not wanted.
@(private = "file")
enter_expands_pair :: proc(prev, next: rune) -> bool {
    switch prev {
    case '(':
        return next == ')'
    case '[':
        return next == ']'
    case '{':
        return next == '}'
    }
    return false
}

// A sub-slice of the line's bytes, so read it before any edit.
@(private = "file")
line_lead :: proc(d: ^txt.Doc, line: int) -> string {
    src := txt.doc_line(d, line)
    return string(src[:txt.line_indent_cols(src)])
}

@(private = "file")
grow_indent :: proc(lead: string, ind: Indent) -> string {
    return strings.concatenate({lead, indent_text(ind)}, context.temp_allocator)
}
