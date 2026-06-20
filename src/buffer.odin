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
    folds:         [dynamic]Fold, // collapsed blocks (Ctrl+Enter); see fold.odin
    fold_nlines:   int, // line count the folds were valid at (drop them when it changes)
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

// Expand every fold in every buffer (folding turned off in config).
editor_clear_folds :: proc(e: ^Editor) {
    for &b in e.buffers {
        clear(&b.folds)
        b.fold_nlines = len(b.lines)
    }
}

// --- cross-part seams (called by the filetree / command line) ---

// Loads path into the main pane: an image routes to the media viewer (Image surface);
// any other file is text — reactivates an existing buffer for it, reuses the scratch
// buffer if it's untouched, otherwise opens a new buffer. Focuses the main pane either way.
open_file :: proc(a: ^App, path: string) {
    defer set_focus(a, .Editor)

    // Image (and future media): decode into the viewer instead of the text ring, and flip
    // the main pane to .Image. A failed decode leaves the current surface untouched.
    if is_media_path(path) {
        if m, ok := media_load(path); ok {
            media_destroy(&a.media)
            a.media = m
            a.main = .Image
        }
        return
    }

    a.main = .Text // a text file flips the main pane back to the editor
    e := &a.editor
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

// How many open buffers hold unsaved changes (the ring's size). The quit/write
// builtins guard on this so a stray `q` can't discard work.
ring_dirty_count :: proc(e: ^Editor) -> int {
    n := 0
    for &b in e.buffers {
        if b.dirty {
            n += 1
        }
    }
    return n
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
    delete(b.folds)
    delete(b.path)
}

buffer_set_text :: proc(b: ^Buffer, text: string) {
    doc_set_text(&b.doc, text)
    b.scroll = 0
    b.scroll_anim = {} // settled at the top; a reused scratch buffer won't smear from its old scroll
    clear(&b.folds) // a wholesale text swap invalidates every fold range
    b.fold_nlines = len(b.lines)
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

// A plain newline at every cursor, no auto-indent (the editor uses buffer_enter; this is the
// dumb primitive for programmatic splits + tests).
buffer_newline :: proc(b: ^Buffer) {
    b.dirty |= doc_newline(&b.doc)
}

// Enter in the editor: a newline that keeps the code indented (the auto-indent + brace
// expansion standard editors have). The new line copies the current line's leading
// whitespace, plus one indent unit when the line opens a block at the caret (its last
// non-blank char is an opener `([{`). With a grammar loaded, tree-sitter suppresses an opener
// that actually sits inside a string or comment. Special case: a single caret between a
// freshly-typed bracket pair (`{|}`, `[|]`, `(|)`) expands across three lines, caret on an
// indented middle line. Heuristic-first (works with no grammar installed); tree-sitter refines.
buffer_enter :: proc(a: ^App, b: ^Buffer) {
    d := &b.doc

    // Brace-pair expansion: a lone caret between an opener and its matching closer.
    if len(d.cursors) == 1 && !cursor_has_selection(d.cursors[0]) {
        c := d.cursors[0]
        line := &d.lines[c.head.line]
        prev := c.head.col > 0 ? line.text[c.head.col - 1] : 0
        if enter_expands_pair(prev, char_at(line, c.head.col)) &&
           !ts_in_string_or_comment(a, b, c.head.line, c.head.col - 1) {
            base := line_lead(line)
            inner := grow_indent(base, a.indent)
            if doc_insert_runes(d, expand_runes(inner, base)) {
                b.dirty = true
            }
            doc_reset_cursor(d, Pos{c.head.line + 1, len(inner)}) // onto the indented middle line
            return
        }
    }

    // General case (incl. multi-cursor): each cursor gets a newline + its own computed indent.
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        append(&edits, Edit{lo, hi, newline_indent(enter_indent(a, b, lo)), 0})
    }
    if doc_commit(d, edits[:]) {
        b.dirty = true
    }
}

// The indentation the line after Enter should start with: the current line's leading
// whitespace, plus one unit when the line opens a block at the caret.
@(private = "file")
enter_indent :: proc(a: ^App, b: ^Buffer, pos: Pos) -> []rune {
    lead := line_lead(&b.lines[pos.line])
    if enter_opens_block(a, b, pos) {
        return grow_indent(lead, a.indent)
    }
    return lead
}

// Opens a block at the caret = its last non-blank char before the caret is an opener `([{`
// that's real code (tree-sitter rules out one inside a string/comment when a grammar exists).
@(private = "file")
enter_opens_block :: proc(a: ^App, b: ^Buffer, pos: Pos) -> bool {
    line := &b.lines[pos.line]
    at := -1
    for i := pos.col - 1; i >= 0; i -= 1 {
        if line.text[i] != ' ' && line.text[i] != '\t' {
            at = i
            break
        }
    }
    if at < 0 {
        return false
    }
    switch line.text[at] {
    case '(', '[', '{':
        return !ts_in_string_or_comment(a, b, pos.line, at)
    }
    return false
}

// True when Enter between `prev` and `next` should expand a bracket pair (quotes excluded —
// splitting a string across lines isn't wanted).
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

// A line's leading whitespace, as a sub-slice of its runes (read before any edit mutates it).
@(private = "file")
line_lead :: proc(l: ^Line) -> []rune {
    return l.text[:line_indent_cols(l)]
}

// `lead` plus one indentation unit.
@(private = "file")
grow_indent :: proc(lead: []rune, ind: Indent) -> []rune {
    unit := indent_runes(ind)
    out := make([]rune, len(lead) + len(unit), context.temp_allocator)
    copy(out, lead)
    copy(out[len(lead):], unit)
    return out
}

// "\n" followed by the given indentation.
@(private = "file")
newline_indent :: proc(indent: []rune) -> []rune {
    out := make([]rune, 1 + len(indent), context.temp_allocator)
    out[0] = '\n'
    copy(out[1:], indent)
    return out
}

// "\n" + inner + "\n" + base — the three-line body for brace-pair expansion (the caret lands
// at the end of the `inner` line).
@(private = "file")
expand_runes :: proc(inner, base: []rune) -> []rune {
    out := make([]rune, 2 + len(inner) + len(base), context.temp_allocator)
    out[0] = '\n'
    copy(out[1:], inner)
    out[1 + len(inner)] = '\n'
    copy(out[2 + len(inner):], base)
    return out
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

buffer_motion :: proc(b: ^Buffer, motion: Motion, select := false, all := false, count := 1) {
    buffer_sync_folds(b) // a prior same-frame edit may have invalidated the fold set
    if all {
        doc_move_all(&b.doc, motion, select, count)
    } else {
        doc_move(&b.doc, motion, select, count)
    }
    buffer_skip_hidden(b, motion)
}

// Keeps cursors off folded (hidden) lines after a motion. A cursor that stepped into
// a collapsed block is snapped to the fold's visible edge in the direction it moved:
// backward motions land on the header above the fold, forward motions on the first
// visible line past it — so a single Up/Down/arrow steps cleanly over a fold.
@(private = "file")
buffer_skip_hidden :: proc(b: ^Buffer, motion: Motion) {
    if len(b.folds) == 0 {
        return
    }
    forward := motion == .Right || motion == .Word_Right || motion == .Down || motion == .End
    vertical := motion == .Up || motion == .Down
    for &c in b.cursors {
        if !buffer_line_hidden(b, c.head.line) {
            continue
        }
        target := forward ? buffer_next_visible(b, c.head.line) : buffer_prev_visible(b, c.head.line)
        // Vertical motion keeps the goal column; a horizontal wrap lands at the line
        // edge it would have reached (end of the header / start of the line past it).
        col := vertical ? min(c.goal, line_len(&b.lines[target])) : (forward ? 0 : line_len(&b.lines[target]))
        p := Pos{target, col}
        if !cursor_has_selection(c) {
            c.anchor = p
        }
        c.head = p
        if !vertical {
            c.goal = col
        }
    }
    doc_merge_cursors(&b.doc)
}
