package main

import "core:strings"
import "vendor:glfw"
import "../txt"
import "../ui"

// The clipboard and the painter: one needs the window, the other is a Clay paint callback,
// and both are the product's side of a text field.

// doc_cut's own no-selection case is "the line", which here is the same whole value.
field_copy :: proc(a: ^App, d: ^txt.Doc, cut: bool) -> (changed: bool) {
    if txt.doc_line_count(d) == 0 {
        return false
    }
    lo, hi := ui.field_span(d)
    if text := txt.doc_text(d, lo, hi); text != "" {
        clipboard_set(a, text, nil) // takes ownership of the clone
    }
    return cut ? txt.doc_cut(d) : false
}

// Cut at the first newline: a second line would be text you can neither see nor delete.
field_paste :: proc(a: ^App, d: ^txt.Doc) -> bool {
    clip := clipboard_get(a)
    if i := strings.index_byte(clip, '\n'); i >= 0 {
        clip = clip[:i]
    }
    return txt.doc_paste(d, clip)
}

