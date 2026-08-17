package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// In-buffer search: the mechanism under `:f`/`:find` and the live preview that runs it as you
// type.
//
// Literal, never a regex — `:grep` is the pattern search, and this answers "where else is that
// word on THIS page". Smart case: an all-lowercase query matches either case, one with a capital
// matches exactly, which is also the only way to ask for a case-sensitive search.
//
// The state lives on App because three parts share it: the preview writes it as you type, the
// builtin writes it for a line recalled from history, and the editor paints the marks.
Find :: struct {
    query:   string, // owned; "" = nothing searched
    matches: [dynamic]Find_Match, // in line order, then column order
    cur:     int, // the match the caret is on
    // Paint the marks. Set by whoever ran the search: the preview wants them up while you type,
    // and Enter takes them down and keeps the caret.
    show:    bool,
}

// A byte span on one line. Bytes, like Pos: the painter converts to cells against the row it is
// drawing.
Find_Match :: struct {
    line: int,
    col:  int, // 0-based BYTE column
    n:    int, // length in BYTES
}

// A query of "e" over a large file otherwise costs a list nobody can use and a paint that walks
// it. The count in the strip says where it stopped.
FIND_LIMIT :: 4096

find_destroy :: proc(f: ^Find) {
    delete(f.query)
    delete(f.matches)
}

// Lands `cur` on the first hit at or after `from`, wrapping when every hit is behind it. The
// anchor is a parameter, not the live caret: the preview re-runs this on every keystroke, and
// reading the caret would walk the landing further down the file with each letter.
find_set :: proc(f: ^Find, b: ^Buffer, query: string, from: Pos) {
    q := strings.clone(query) // before the old one goes: a caller may pass f.query back
    delete(f.query)
    f.query = q
    clear(&f.matches)
    f.cur = 0
    if query == "" {
        return
    }
    find_scan(f, b, query)
    f.cur = find_index_from(f.matches[:], from)
}

// In line order, non-overlapping: the scan resumes past the hit it took, so `aa` in `aaa` is
// one match.
@(private = "file")
find_scan :: proc(f: ^Find, b: ^Buffer, query: string) {
    pat := utf8.string_to_runes(query, context.temp_allocator)
    if len(pat) == 0 {
        return
    }
    fold := find_folds_case(query)
    for line in 0 ..< doc_line_count(&b.doc) {
        src := doc_line(&b.doc, line)
        for col := 0; col < len(src); {
            n, hit := match_at(src, col, pat, fold)
            if !hit {
                _, sz := utf8.decode_rune(src[col:])
                col += max(sz, 1) // a candidate starts at a rune, never inside one
                continue
            }
            append(&f.matches, Find_Match{line = line, col = col, n = n})
            if len(f.matches) >= FIND_LIMIT {
                return
            }
            col += n
        }
    }
}

// How many BYTES it took, since a folded match can differ in length from the query. `fold`
// lowers both sides: the smart-case rule.
@(private = "file")
match_at :: proc(src: []u8, col: int, pat: []rune, fold: bool) -> (n: int, ok: bool) {
    i := col
    for p in pat {
        if i >= len(src) {
            return 0, false
        }
        r, sz := utf8.decode_rune(src[i:])
        x, y := r, p
        if fold {
            x, y = unicode.to_lower(x), unicode.to_lower(y)
        }
        if x != y {
            return 0, false
        }
        i += max(sz, 1)
    }
    return i - col, true
}

// A query with no upper-case rune matches either case.
@(private = "file")
find_folds_case :: proc(query: string) -> bool {
    for r in query {
        if unicode.is_upper(r) {
            return false
        }
    }
    return true
}

// Wrapping to 0 when every match is behind it. An empty list answers 0 too, and find_pos
// says so.
@(private = "file")
find_index_from :: proc(ms: []Find_Match, from: Pos) -> int {
    for m, i in ms {
        if m.line > from.line || (m.line == from.line && m.col >= from.col) {
            return i
        }
    }
    return 0
}

// Wrapping both ways. No matches is a no-op.
find_step :: proc(f: ^Find, dir: int) {
    if n := len(f.matches); n > 0 {
        f.cur = (f.cur + dir + n) % n
    }
}

// ok=false when there is no match to sit on.
find_pos :: proc(f: ^Find) -> (Pos, bool) {
    if f.cur < 0 || f.cur >= len(f.matches) {
        return {}, false
    }
    m := f.matches[f.cur]
    return Pos{m.line, m.col}, true
}

// One past the end when there is none at or after it. A binary search, because the paint asks
// once per visible row and the list is in line order.
find_first_on_line :: proc(ms: []Find_Match, line: int) -> int {
    lo, hi := 0, len(ms)
    for lo < hi {
        mid := (lo + hi) / 2
        if ms[mid].line < line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}
