package txt

// Indentation geometry over a raw line. Shared by folds, whitespace markers, indent guides and
// the document's own auto-indent, so "how deep is this line" is defined once.

// For .Tab, width is a tab's display column count; for .Spaces, how many a Tab press inserts.
Indent_Kind :: enum {
    Tab,
    Spaces,
}
Indent :: struct {
    kind:  Indent_Kind,
    width: int,
}

// In cells. Space and tab are one byte each and a tab advances one cell today, so over the
// indent run bytes and cells are the same count.
line_indent_cols :: proc(src: []u8) -> int {
    n := 0
    for c in src {
        if c != ' ' && c != '\t' {
            break
        }
        n += 1
    }
    return n
}

// Nothing but whitespace. Such a line carries no indent, so guides flow through it.
line_is_blank :: proc(src: []u8) -> bool {
    return line_indent_cols(src) == len(src)
}
