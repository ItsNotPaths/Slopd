package txt

// Quotes are their own close. Shared with the editor's autopair, which decides WHEN to pair;
// this only says what a character pairs with.
pair_close :: proc(open: rune) -> (close: rune, ok: bool) {
    switch open {
    case '(':
        return ')', true
    case '[':
        return ']', true
    case '{':
        return '}', true
    case '"':
        return '"', true
    case '\'':
        return '\'', true
    case '`':
        return '`', true
    }
    return 0, false
}
