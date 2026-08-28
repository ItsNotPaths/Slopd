package tests

import app ".."
import "core:fmt"
import "core:strings"
import "core:testing"
import "../txt"

// The piece table is the byte storage under Doc (src/txt/piecetable.odin). Nothing here touches the
// editor: a table is a document's bytes plus a line index, and every test below reads it back as
// a string and compares against the same edit done to a plain Odin string. That equivalence IS
// the contract — a splice may rearrange pieces however it likes as long as the bytes agree.

@(private = "file")
mk :: proc(s: string) -> txt.Piece_Table {
    pt: txt.Piece_Table
    txt.pt_init(&pt)
    txt.pt_load(&pt, transmute([]u8)s)
    return pt
}

// The whole document, read back through the piece walk.
@(private = "file")
str :: proc(pt: ^txt.Piece_Table) -> string {
    return string(txt.pt_read(pt, 0, pt.size, context.temp_allocator))
}

@(private = "file")
splice :: proc(pt: ^txt.Piece_Table, lo, hi: int, text: string) -> int {
    return txt.pt_splice(pt, lo, hi, transmute([]u8)text)
}

// The same replacement done to a string, so a test states the expected result once.
@(private = "file")
want :: proc(s: string, lo, hi: int, text: string) -> string {
    return strings.concatenate({s[:lo], text, s[hi:]}, context.temp_allocator)
}

// Every line's text, joined with '|' — the line index made readable. Uses pt_line, so it also
// exercises the borrow/copy split.
@(private = "file")
lines :: proc(pt: ^txt.Piece_Table) -> string {
    out := make([dynamic]string, 0, txt.pt_line_count(pt), context.temp_allocator)
    for i in 0 ..< txt.pt_line_count(pt) {
        append(&out, string(txt.pt_line(pt, i, context.temp_allocator)))
    }
    return strings.join(out[:], "|", context.temp_allocator)
}

// Re-derives the line index from the bytes and compares. The index is maintained incrementally
// by pt_splice, so this is the check that the increment never drifts from the truth.
@(private = "file")
expect_lines_agree :: proc(t: ^testing.T, pt: ^txt.Piece_Table, loc := #caller_location) {
    s := str(pt)
    scratch: txt.Piece_Table
    txt.pt_init(&scratch)
    defer txt.pt_destroy(&scratch)
    txt.pt_load(&scratch, transmute([]u8)s)
    testing.expect_value(t, lines(pt), lines(&scratch), loc = loc)
}

@(test)
test_pt_load_and_read :: proc(t: ^testing.T) {
    pt := mk("ab\ncd\nef")
    defer txt.pt_destroy(&pt)

    testing.expect_value(t, pt.size, 8)
    testing.expect_value(t, str(&pt), "ab\ncd\nef")
    testing.expect_value(t, txt.pt_line_count(&pt), 3)
    testing.expect_value(t, lines(&pt), "ab|cd|ef")

    // A sub-range, and the line ranges the index reports.
    testing.expect_value(t, string(txt.pt_read(&pt, 3, 5, context.temp_allocator)), "cd")
    lo, hi := txt.pt_line_range(&pt, 1)
    testing.expect_value(t, lo, 3)
    testing.expect_value(t, hi, 5) // the '\n' at 5 is NOT part of the line
    testing.expect_value(t, txt.pt_line_len(&pt, 1), 2)
}

// A trailing newline opens an empty last line; an empty document is one empty line. Both are
// the plain reading of "lines are the runs between newlines", and Doc leans on it.
@(test)
test_pt_line_edges :: proc(t: ^testing.T) {
    empty := mk("")
    defer txt.pt_destroy(&empty)
    testing.expect_value(t, txt.pt_line_count(&empty), 1)
    testing.expect_value(t, txt.pt_line_len(&empty, 0), 0)
    testing.expect_value(t, len(txt.pt_line(&empty, 0, context.temp_allocator)), 0)

    trailing := mk("a\n")
    defer txt.pt_destroy(&trailing)
    testing.expect_value(t, txt.pt_line_count(&trailing), 2)
    testing.expect_value(t, lines(&trailing), "a|")
}

@(test)
test_pt_line_at_off :: proc(t: ^testing.T) {
    pt := mk("ab\ncd\nef") // starts at 0, 3, 6
    defer txt.pt_destroy(&pt)

    testing.expect_value(t, txt.pt_line_at_off(&pt, 0), 0)
    testing.expect_value(t, txt.pt_line_at_off(&pt, 2), 0) // the '\n' belongs to the line before
    testing.expect_value(t, txt.pt_line_at_off(&pt, 3), 1)
    testing.expect_value(t, txt.pt_line_at_off(&pt, 6), 2)
    testing.expect_value(t, txt.pt_line_at_off(&pt, 8), 2) // the end of the document
    testing.expect_value(t, txt.pt_line_at_off(&pt, 99), 2) // past it: clamped, never off the index
}

// A splice at every offset of a small document, insert and replace, checked against the same
// edit done to a string. The boundaries a piece table gets wrong — the start of a piece, its
// middle, its end — are all in here because every offset is.
@(test)
test_pt_splice_every_offset :: proc(t: ^testing.T) {
    base := "ab\ncd\nef"
    for lo in 0 ..= len(base) {
        for hi in lo ..= len(base) {
            for text in ([]string{"", "X", "X\nY"}) {
                pt := mk(base)
                defer txt.pt_destroy(&pt)
                delta := splice(&pt, lo, hi, text)
                exp := want(base, lo, hi, text)
                testing.expectf(
                    t,
                    str(&pt) == exp,
                    "splice(%d,%d,%q): got %q want %q",
                    lo,
                    hi,
                    text,
                    str(&pt),
                    exp,
                )
                testing.expect_value(t, delta, len(text) - (hi - lo))
                testing.expect_value(t, pt.size, len(exp))
                expect_lines_agree(t, &pt)
            }
        }
    }
}

// Edits stacked on edits, so later splices land inside pieces earlier ones made — the case a
// single splice from a fresh load never reaches.
@(test)
test_pt_splice_layered :: proc(t: ^testing.T) {
    pt := mk("one\ntwo\nthree")
    defer txt.pt_destroy(&pt)
    s := "one\ntwo\nthree"

    steps := [][3]int{{0, 0, 0}, {4, 7, 1}, {2, 2, 2}, {0, 5, 0}, {6, 9, 2}, {1, 3, 1}}
    texts := []string{"A", "", "\n\n", "z", "Q\nR", ""}
    for st, i in steps {
        lo := min(st[0], len(s))
        hi := min(max(st[1], lo), len(s))
        splice(&pt, lo, hi, texts[i])
        s = want(s, lo, hi, texts[i])
        testing.expect_value(t, str(&pt), s)
        testing.expect_value(t, pt.size, len(s))
        expect_lines_agree(t, &pt)
    }
}

// Typing is a run of one-byte inserts at a moving caret, and it must NOT push a piece each time.
// The first keystroke splits; every one after it extends the piece that split made. Mid-file, so
// this is the ordinary case and not the append-at-the-end special one.
@(test)
test_pt_typing_coalesces :: proc(t: ^testing.T) {
    pt := mk("ab\ncd\nef")
    defer txt.pt_destroy(&pt)

    at := 4 // inside "cd"
    for i in 0 ..< 200 {
        splice(&pt, at + i, at + i, "x")
    }
    testing.expect_value(t, pt.size, 8 + 200)
    testing.expect_value(t, str(&pt), fmt.tprintf("ab\nc%sd\nef", strings.repeat("x", 200, context.temp_allocator)))
    testing.expectf(t, len(pt.pieces) <= 3, "200 keystrokes left %d pieces, expected 3", len(pt.pieces))
    expect_lines_agree(t, &pt)
}

// Typing at the very end of the document takes the same path, and from an empty table — where
// there is no piece to extend on the first keystroke and no append block yet.
@(test)
test_pt_typing_from_empty :: proc(t: ^testing.T) {
    pt := mk("")
    defer txt.pt_destroy(&pt)
    for i in 0 ..< 100 {
        splice(&pt, i, i, "y")
    }
    testing.expect_value(t, str(&pt), strings.repeat("y", 100, context.temp_allocator))
    testing.expectf(t, len(pt.pieces) == 1, "expected 1 piece, got %d", len(pt.pieces))
}

// An append larger than a chunk gets a block of its own, so one append is always ONE piece and
// no piece straddles a block — which is what lets pt_span hand tree-sitter a contiguous run.
@(test)
test_pt_big_append_is_one_piece :: proc(t: ^testing.T) {
    pt := mk("head")
    defer txt.pt_destroy(&pt)

    big := strings.repeat("z", txt.PT_CHUNK * 2 + 7, context.temp_allocator)
    splice(&pt, 4, 4, big)
    testing.expect_value(t, pt.size, 4 + len(big))
    testing.expect_value(t, len(pt.pieces), 2)
    testing.expect_value(t, len(txt.pt_span(&pt, 4)), len(big)) // contiguous, in one block
    testing.expect_value(t, str(&pt), fmt.tprintf("head%s", big))
}

// pt_span answers the run from an offset to the end of its piece, and stops at a piece boundary
// rather than lying about how much is contiguous. pt_read stitches across, pt_line borrows when
// it can and copies when the line has been split.
@(test)
test_pt_span_and_line_borrow :: proc(t: ^testing.T) {
    pt := mk("ab\ncd\nef")
    defer txt.pt_destroy(&pt)

    testing.expect_value(t, string(txt.pt_span(&pt, 0)), "ab\ncd\nef") // one piece after a load
    testing.expect_value(t, len(txt.pt_span(&pt, pt.size)), 0) // nothing at the end

    splice(&pt, 4, 4, "X") // splits "cd" -> the middle line is now three pieces
    testing.expect_value(t, str(&pt), "ab\ncXd\nef")
    testing.expect_value(t, string(txt.pt_span(&pt, 3)), "c") // stops at the split
    testing.expect_value(t, string(txt.pt_line(&pt, 1, context.temp_allocator)), "cXd") // stitched
    expect_lines_agree(t, &pt)
}

// Compaction flattens every block into one and must be byte-identical, with the line index
// untouched — it moves bytes between blocks, never within the document.
@(test)
test_pt_compact :: proc(t: ^testing.T) {
    pt := mk("one\ntwo\nthree")
    defer txt.pt_destroy(&pt)
    for i in 0 ..< 50 {
        splice(&pt, 4 + i, 4 + i, "q")
        splice(&pt, 0, 0, "p")
    }
    before := strings.clone(str(&pt), context.temp_allocator)
    before_lines := strings.clone(lines(&pt), context.temp_allocator)
    testing.expect(t, len(pt.pieces) > 1)

    txt.pt_compact(&pt)
    testing.expect_value(t, len(pt.pieces), 1)
    testing.expect_value(t, len(pt.blocks), 1)
    testing.expect_value(t, str(&pt), before)
    testing.expect_value(t, lines(&pt), before_lines)

    // And the table stays editable afterwards: the append tail was reset, not left dangling.
    splice(&pt, 2, 2, "!")
    testing.expect_value(t, str(&pt), fmt.tprintf("%s!%s", before[:2], before[2:]))
    expect_lines_agree(t, &pt)
}

@(test)
test_pt_should_compact :: proc(t: ^testing.T) {
    pt := mk("abc")
    defer txt.pt_destroy(&pt)
    testing.expect(t, !txt.pt_should_compact(&pt))
    // Scattered inserts fragment; typing runs do not. Each pair here lands somewhere new.
    for i in 0 ..< txt.PT_COMPACT_PIECES {
        splice(&pt, pt.size / 2, pt.size / 2, "-")
    }
    testing.expect(t, txt.pt_should_compact(&pt))
    txt.pt_compact(&pt)
    testing.expect(t, !txt.pt_should_compact(&pt))
}

// A whole-document replacement through pt_splice, and a reload over an edited table: both are
// paths Doc takes on a file swap, and either leaving a stale block or a stale line index shows
// up here rather than in the editor.
@(test)
test_pt_replace_all_and_reload :: proc(t: ^testing.T) {
    pt := mk("ab\ncd")
    defer txt.pt_destroy(&pt)

    splice(&pt, 0, pt.size, "x\ny\nz")
    testing.expect_value(t, str(&pt), "x\ny\nz")
    testing.expect_value(t, lines(&pt), "x|y|z")

    txt.pt_load(&pt, transmute([]u8)string("fresh\ncontent"))
    testing.expect_value(t, str(&pt), "fresh\ncontent")
    testing.expect_value(t, lines(&pt), "fresh|content")
    testing.expect_value(t, len(pt.pieces), 1)
    testing.expect_value(t, pt.tail, -1)
}

// UTF-8 is bytes to the table and nothing else — it must never split or interpret a rune, only
// carry the offsets it is given. (Landing a Pos on a rune boundary is Doc's job, not this one.)
@(test)
test_pt_utf8_is_just_bytes :: proc(t: ^testing.T) {
    pt := mk("héllo\nwörld") // é and ö are two bytes each
    defer txt.pt_destroy(&pt)

    testing.expect_value(t, pt.size, 13)
    testing.expect_value(t, txt.pt_line_count(&pt), 2)
    testing.expect_value(t, string(txt.pt_line(&pt, 0, context.temp_allocator)), "héllo")
    testing.expect_value(t, string(txt.pt_line(&pt, 1, context.temp_allocator)), "wörld")

    splice(&pt, 8, 8, "ü") // between 'w' and 'ö' — line 1 starts at 7, 'w' is one byte
    testing.expect_value(t, str(&pt), "héllo\nwüörld")
    expect_lines_agree(t, &pt)
}
