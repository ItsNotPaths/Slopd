package tests

import app "../slopd"
import "../txt"
import "core:fmt"
import "core:strings"
import "core:testing"
import "../edit"

// Syntax-highlighting tests, over the odin grammar. The suite builds its own grammars and
// caches them; tests/grammars.odin owns that, and the skip-vs-fail policy with it.

// A representative odin snippet, long enough to scroll: procs, keywords, types,
// strings, comments, numbers, operators — so highlighting should produce many colours.
@(private = "file")
SNIPPET :: `package demo

import "core:fmt"

// a doc comment
Point :: struct {
    x: int,
    y: int,
}

add :: proc(a: int, b: int) -> int {
    return a + b
}

main :: proc() {
    p := Point{x = 1, y = 2}
    sum := add(p.x, p.y)
    if sum > 0 {
        fmt.println("positive", sum)
    } else {
        fmt.println("non-positive")
    }
    for i in 0 ..< 10 {
        fmt.println(i)
    }
}
`

@(private = "file")
mkbuf :: proc() -> edit.Buffer {
    b: edit.Buffer
    edit.buffer_set_text(&b, SNIPPET)
    b.path = strings.clone("demo.odin") // owned: buffer_destroy frees it
    return b
}

// Each token below must paint its expected theme slot. This is the heart of the
// regression: before predicate evaluation + later-pattern-wins precedence, gated rules
// (capitalised->@type, ALL_CAPS->@constant, context/self->@variable.builtin) fired on
// every identifier and the catch-all @variable swallowed the rest, so procs/types/etc.
// lost their colour. Positions are (line, col) into SNIPPET; colours are theme-relative
// so the check is independent of the palette.
@(test)
test_highlight_semantic :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)
    b := mkbuf()
    defer edit.buffer_destroy(&b)
    rows := hl_rows(&a, &b)
    th := &a.theme

    Case :: struct {
        line, col: int,
        want: [3]f32,
        what: string,
    }
    cases := []Case {
        {4, 0, th.code_comment, "comment //"},
        {5, 0, th.code_type, "Point type decl"},
        {6, 7, th.code_type, "builtin type int"},
        {10, 0, th.code_function, "proc name add"}, // the headline fix: procs colour
        {10, 7, th.code_keyword, "keyword proc"},
        {11, 4, th.code_keyword, "keyword return"},
        {11, 13, th.code_operator, "operator +"},
        {15, 19, th.code_number, "number 1"},
        {18, 20, th.code_string, "string literal"},
    }
    for c in cases {
        if c.line >= len(rows) || rows[c.line] == nil || c.col >= len(rows[c.line]) {
            testing.expectf(t, false, "%s: position (%d,%d) out of range", c.what, c.line, c.col)
            continue
        }
        got := rows[c.line][c.col]
        testing.expectf(t, got == c.want, "%s at (%d,%d): got %v want %v", c.what, c.line, c.col, got, c.want)
    }
}

// The flash bug: a line's colours must not depend on the scroll offset (first_line).
// We paint the whole buffer, snapshot each line's colours, then re-paint at every
// scroll offset and assert the overlapping lines match byte-for-byte. Any drift is the
// non-deterministic precedence that made tokens flicker between colours while scrolling.
@(test)
test_highlight_scroll_stable :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)
    b := mkbuf()
    defer edit.buffer_destroy(&b)

    n := txt.doc_line_count(&b.doc)
    // Snapshot the full-buffer paint (deep copy — the next highlight_visible frees it).
    full := hl_rows(&a, &b)
    baseline := make([dynamic][3]f32, 0, 256, context.temp_allocator)
    line_off := make([]int, n, context.temp_allocator) // start of each line in `baseline`
    for li in 0 ..< n {
        line_off[li] = len(baseline)
        for c in full[li] {
            append(&baseline, c)
        }
    }

    window := 8
    for top in 1 ..< n {
        rows := app.highlight_visible(&a, &b, top, window)
        for k in 0 ..< window {
            li := top + k
            if li >= n {
                break
            }
            bo := line_off[li]
            line_len := (li + 1 < n ? line_off[li + 1] : len(baseline)) - bo
            if !testing.expectf(
                t,
                len(rows[k]) == line_len,
                "line %d painted %d runes at scroll %d, baseline %d",
                li,
                len(rows[k]),
                top,
                line_len,
            ) {
                continue
            }
            for ci in 0 ..< line_len {
                if !testing.expectf(
                    t,
                    rows[k][ci] == baseline[bo + ci],
                    "line %d rune %d: colour %v at scroll %d != baseline %v (flicker)",
                    li,
                    ci,
                    rows[k][ci],
                    top,
                    baseline[bo + ci],
                ) {
                    break
                }
            }
        }
    }
}

// Debug: dump every mapped capture competing for the snippet, so we can see the
// precedence the .scm intends. Not an assertion — run with `-define:HLDUMP=true`.
HLDUMP :: #config(HLDUMP, false)

@(test)
test_highlight_dump :: proc(t: ^testing.T) {
    when !HLDUMP {
        return
    }
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)
    b := mkbuf()
    defer edit.buffer_destroy(&b)
    app.highlight_dump_captures(&a, &b, 0, txt.doc_line_count(&b.doc))
}

// --- incremental reparse ---
//
// A content change is folded into the cached tree as a ts.Input_Edit (doc.odin records them,
// highlighter_tree replays them) and the parser reuses every subtree the edit did not touch.
// Tree-sitter requires those edits to match the document changes EXACTLY; when they do not it
// does not crash, it quietly produces a wrong tree — so the only honest test is to compare the
// incremental result against a full parse of the same final text.

// Settle the worker, then paint the whole buffer. The painter never waits, so a test that
// asserts on one paint must wait for the tree first. Shared with highlight_stress_test.
hl_rows :: proc(a: ^app.App, b: ^edit.Buffer) -> []app.Row_Colors {
    app.hl_settle(a, b)
    return app.highlight_visible(a, b, 0, txt.doc_line_count(&b.doc))
}

clone_rows :: proc(rows: []app.Row_Colors) -> []app.Row_Colors {
    out := make([]app.Row_Colors, len(rows), context.temp_allocator)
    for r, i in rows {
        out[i] = make(app.Row_Colors, len(r), context.temp_allocator)
        copy(out[i], r)
    }
    return out
}

expect_rows_equal :: proc(t: ^testing.T, got, want: []app.Row_Colors, what: string) {
    testing.expectf(t, len(got) == len(want), "%s: %d rows, want %d", what, len(got), len(want))
    for i in 0 ..< min(len(got), len(want)) {
        if !testing.expectf(
            t,
            len(got[i]) == len(want[i]),
            "%s: line %d is %d cells, want %d",
            what,
            i,
            len(got[i]),
            len(want[i]),
        ) {
            continue
        }
        for c in 0 ..< len(got[i]) {
            if got[i][c] != want[i][c] {
                testing.expectf(t, false, "%s: (%d,%d) got %v want %v", what, i, c, got[i][c], want[i][c])
                break // one report per line is enough to find it
            }
        }
    }
}

// How far behind the highlighter's reader slot is. The log is shared (Doc_Reader), so "is it
// empty" is not the question — "has THIS reader seen everything" is.
@(private = "file")
hl_pending :: proc(d: ^txt.Doc) -> (n: int, lost: bool) {
    c, l := txt.doc_changes_since(d, txt.Doc_Reader.Highlight)
    return len(c), l
}

// The headline: edit a parsed buffer every way the funnel can, reparse incrementally, and
// compare against a buffer holding the same final text that has only ever been parsed whole.
@(test)
test_highlight_incremental_matches_full :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)

    live := mkbuf()
    defer edit.buffer_destroy(&live)

    // Parse it whole once. The changes list is drained by that parse, which is the protocol:
    // the tree and the document are now in step.
    _ = hl_rows(&a, &live)
    n0, lost0 := hl_pending(&live.doc)
    testing.expect_value(t, n0, 0)
    testing.expect(t, !lost0)

    // Rename `add` -> `addend` (a token grows), split a line, and delete a whole line — an
    // insert, a line-count change up and a line-count change down.
    txt.doc_reset_cursor(&live.doc, txt.Pos{10, 3})
    txt.doc_insert_text(&live.doc, "end")
    txt.doc_reset_cursor(&live.doc, txt.Pos{2, 0})
    txt.doc_insert_text(&live.doc, "\n// inserted\n")
    txt.doc_reset_cursor(&live.doc, txt.Pos{0, 0})
    txt.doc_move(&live.doc, .Down, true)
    txt.doc_delete(&live.doc) // takes the first line and its break
    n1, lost1 := hl_pending(&live.doc)
    testing.expect(t, n1 > 0, "no changes recorded")
    testing.expect(t, !lost1)

    // The same text, loaded fresh: nothing to be incremental about, so it parses whole.
    ref: edit.Buffer
    defer edit.buffer_destroy(&ref)
    edit.buffer_set_text(&ref, txt.doc_string(&live.doc, context.temp_allocator))
    ref.path = strings.clone("demo.odin")

    n := txt.doc_line_count(&live.doc)
    testing.expect_value(t, n, txt.doc_line_count(&ref.doc))

    // live goes through tree_edit + an incremental parse; the row cache is replaced by the
    // second call, so the first result is cloned before it is freed under us.
    got := clone_rows(hl_rows(&a, &live))
    n2, _ := hl_pending(&live.doc)
    testing.expect_value(t, n2, 0) // the reparse acked them
    want := hl_rows(&a, &ref)
    expect_rows_equal(t, got, want, "after three edits")
}

// Typing, one character at a time, is the case the whole thing exists for — and the case where
// a small error in the recorded offsets accumulates instead of showing up at once.
@(test)
test_highlight_incremental_through_typing :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)

    live := mkbuf()
    defer edit.buffer_destroy(&live)
    txt.doc_reset_cursor(&live.doc, txt.Pos{11, 4}) // inside the `return a + b` body

    // Reparse after EVERY keystroke, as the painter does — so each one is an incremental step
    // off the tree the previous one left.
    for r in "count := 0; " {
        txt.doc_insert_rune(&live.doc, r)
        _ = hl_rows(&a, &live)
    }
    got := clone_rows(hl_rows(&a, &live))

    ref: edit.Buffer
    defer edit.buffer_destroy(&ref)
    edit.buffer_set_text(&ref, txt.doc_string(&live.doc, context.temp_allocator))
    ref.path = strings.clone("demo.odin")
    want := hl_rows(&a, &ref)
    expect_rows_equal(t, got, want, "after a typed run")
}

// Undo and redo replay patches through the same funnel, so they record changes like any other
// edit — and land back on colours identical to a full parse of what they restored.
@(test)
test_highlight_incremental_through_undo :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)

    live := mkbuf()
    defer edit.buffer_destroy(&live)
    n0 := txt.doc_line_count(&live.doc)
    base := clone_rows(hl_rows(&a, &live))

    txt.doc_reset_cursor(&live.doc, txt.Pos{5, 0})
    txt.doc_insert_text(&live.doc, "// gone\nBox :: struct {}\n")
    _ = hl_rows(&a, &live)
    txt.doc_undo(&live.doc)

    got := clone_rows(hl_rows(&a, &live))
    expect_rows_equal(t, got, base, "after undo")
}

// When the change list overflows, `lost` says the tree cannot be brought forward from it — and
// the reparse has to start over rather than apply a partial edit run to a stale tree.
@(test)
test_highlight_full_parse_when_changes_lost :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "odin", "odin") {
        return
    }
    defer hl_app_destroy(&a)

    live := mkbuf()
    defer edit.buffer_destroy(&live)
    _ = hl_rows(&a, &live)

    // Edit past the cap with no reader keeping up — exactly what a buffer edited off-screen
    // does, since nothing is painting or syncing its folds.
    txt.doc_reset_cursor(&live.doc, txt.Pos{11, 4})
    for _ in 0 ..< txt.DOC_CHANGE_MAX + 10 {
        txt.doc_insert_rune(&live.doc, 'z')
    }
    _, lost := hl_pending(&live.doc)
    testing.expect(t, lost, "the cap did not drop the log")

    got := clone_rows(hl_rows(&a, &live))
    _, still_lost := hl_pending(&live.doc)
    testing.expect(t, !still_lost, "the reparse did not clear the loss")

    ref: edit.Buffer
    defer edit.buffer_destroy(&ref)
    edit.buffer_set_text(&ref, txt.doc_string(&live.doc, context.temp_allocator))
    ref.path = strings.clone("demo.odin")
    want := hl_rows(&a, &ref)
    expect_rows_equal(t, got, want, "after a lost change list")
}
