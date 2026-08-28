package tests

import app ".."
import "core:testing"
import "../txt"

// Workspace-wide find and replace (replace.odin). The two halves are tested apart, because they
// fail apart: the PARSE and the SCAN are pure, and the EDIT is a buffer in and a buffer out. The
// disk half — grep naming the files, the ring taking them — is grep_run's, already covered.

@(private = "file")
mkbuf :: proc(text: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, text)
    return b
}

// --- the parse ---

// A destructive builtin guesses at nothing: two arguments, or nothing happens.
@(test)
test_rep_parse_takes_two_arguments :: proc(t: ^testing.T) {
    old, new, ok := app.rep_parse("foo bar")
    testing.expect(t, ok, "`foo bar` is two bare words")
    testing.expect_value(t, old, "foo")
    testing.expect_value(t, new, "bar")

    _, _, ok = app.rep_parse("foo")
    testing.expect(t, !ok, "one argument names no replacement")

    _, _, ok = app.rep_parse("")
    testing.expect(t, !ok, "an empty line names nothing")

    // Not silently read as `foo` -> `bar`: the third word means the line was misunderstood.
    _, _, ok = app.rep_parse("foo bar baz")
    testing.expect(t, !ok, "trailing junk is rejected, not guessed at")
}

// A phrase and an empty replacement both need a spelling, and quotes are the one the rest of the
// command line already uses (`:j "my file" 40`).
@(test)
test_rep_parse_reads_quotes :: proc(t: ^testing.T) {
    old, new, ok := app.rep_parse(`"old text" "new text"`)
    testing.expect(t, ok, "quoted phrases are two arguments")
    testing.expect_value(t, old, "old text")
    testing.expect_value(t, new, "new text")

    // Deleting every hit. This is why the pane carries a flag and not an empty string.
    old, new, ok = app.rep_parse(`"foo" ""`)
    testing.expect(t, ok, "an empty replacement is still a replacement")
    testing.expect_value(t, old, "foo")
    testing.expect_value(t, new, "")

    // The other way round is not a replace at all: there is nothing to find.
    _, _, ok = app.rep_parse(`"" "foo"`)
    testing.expect(t, !ok, "an empty pattern matches everywhere and is refused")
}

// --- the scan ---

// Byte offsets, so an Edit can be built straight from them, and the whole document at once: a
// grep hit carries only the FIRST match on its line, which is the reason this scan exists.
@(test)
test_rep_offsets_finds_every_occurrence :: proc(t: ^testing.T) {
    offs := app.rep_offsets("foo bar foo\nfoo", "foo")
    testing.expect_value(t, len(offs), 3)
    testing.expect_value(t, offs[0], 0)
    testing.expect_value(t, offs[1], 8) // the SECOND on line 0, the one a grep hit would miss
    testing.expect_value(t, offs[2], 12)
}

// Past the hit it took, as find.odin scans: `aa` in `aaa` is one match, never two.
@(test)
test_rep_offsets_do_not_overlap :: proc(t: ^testing.T) {
    offs := app.rep_offsets("aaa", "aa")
    testing.expect_value(t, len(offs), 1)
    testing.expect_value(t, offs[0], 0)
}

// Literal and case-sensitive, unlike `:f`'s smart case: replacing `foo` must not rewrite `Foo`.
@(test)
test_rep_offsets_are_case_sensitive :: proc(t: ^testing.T) {
    testing.expect_value(t, len(app.rep_offsets("Foo foo FOO", "foo")), 1)
    testing.expect_value(t, len(app.rep_offsets("nothing here", "foo")), 0)
    testing.expect_value(t, len(app.rep_offsets("anything", "")), 0) // matches everywhere; refused
}

// --- the edit ---

// Offsets are BYTES, so a multi-byte rune before the match must not shift the landing.
@(test)
test_rep_replaces_after_a_multibyte_rune :: proc(t: ^testing.T) {
    b := mkbuf("héllo foo\nfoo")
    defer app.buffer_destroy(&b)

    testing.expect_value(t, app.rep_buffer_replace(&b, "foo", "bar"), 2)
    testing.expect_value(t, txt.doc_string(&b.doc, context.temp_allocator), "héllo bar\nbar")
}

// ONE undo step for the whole file, which is what buys the gesture back: doc_commit journals the
// batch, so a single undo in that file returns all of it.
@(test)
test_rep_is_one_undo_step_per_file :: proc(t: ^testing.T) {
    b := mkbuf("foo\nfoo\nfoo")
    defer app.buffer_destroy(&b)

    testing.expect_value(t, app.rep_buffer_replace(&b, "foo", "bar"), 3)
    testing.expect_value(t, txt.doc_string(&b.doc, context.temp_allocator), "bar\nbar\nbar")
    testing.expect(t, b.dirty, "a replaced buffer joins the unsaved ring")

    testing.expect(t, txt.doc_undo(&b.doc), "the batch is journalled")
    testing.expect_value(t, txt.doc_string(&b.doc, context.temp_allocator), "foo\nfoo\nfoo")
}

// A replacement holding the pattern does not feed itself: the edits are computed against the
// document as it was, then applied together.
@(test)
test_rep_does_not_rescan_its_own_output :: proc(t: ^testing.T) {
    b := mkbuf("foo foo")
    defer app.buffer_destroy(&b)

    testing.expect_value(t, app.rep_buffer_replace(&b, "foo", "foofoo"), 2)
    testing.expect_value(t, txt.doc_string(&b.doc, context.temp_allocator), "foofoo foofoo")
}

// A miss changes nothing at all — no edit, no undo step, and the buffer stays clean.
@(test)
test_rep_leaves_a_missed_buffer_clean :: proc(t: ^testing.T) {
    b := mkbuf("nothing here")
    defer app.buffer_destroy(&b)

    testing.expect_value(t, app.rep_buffer_replace(&b, "foo", "bar"), 0)
    testing.expect(t, !b.dirty, "a buffer with no match is not dirtied")
    testing.expect(t, !txt.doc_undo(&b.doc), "and nothing was journalled")
}

// --- the pane ---

// Two hits in one file and one in another, so the rows and the file count both have something to
// get wrong. The ctx slices point at caller-owned arrays: torn down with `delete`, not
// grep_destroy.
@(private = "file")
rep_fixture :: proc(a: ^app.App, c0, c1, c2: []string) {
    a.project_root = "/proj"
    append(
        &a.grep.hits,
        app.GrepHit{path = "/proj/a.odin", line = 2, text = "foo", ctx = c0, ctx_first = 1},
        app.GrepHit{path = "/proj/a.odin", line = 5, text = "foo", ctx = c1, ctx_first = 4},
        app.GrepHit{path = "/proj/b.odin", line = 2, text = "foo", ctx = c2, ctx_first = 1},
    )
    a.grep.query = "foo"
}

// The preview's whole point: the rows read as the files WILL read, not as they read now.
@(test)
test_rep_rows_show_the_replacement :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"x", "foo", "y"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)
    a.grep.replace = "bar"
    a.grep.replacing = true

    rows := app.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    for r in rows {
        testing.expect(t, r.text != "foo", "a row still shows the old text")
    }
    testing.expect_value(t, rows[2].text, "bar") // the match line under a.odin:2
}

// Every row and not only the matched one: a context line can hold the pattern too, and one line
// must not read two ways in two blocks.
@(test)
test_rep_rows_replace_in_context_lines :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"foo above", "foo", "foo below"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)
    a.grep.replace = "bar"
    a.grep.replacing = true

    rows := app.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    testing.expect_value(t, rows[1].text, "bar above") // context, not the match
    testing.expect_value(t, rows[3].text, "bar below")
}

// With no replace in flight the rows are untouched, so `:grep` is unaffected by any of this.
@(test)
test_grep_rows_are_untouched_without_a_replace :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"x", "foo", "y"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)

    rows := app.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    testing.expect_value(t, rows[2].text, "foo")
}

// The title says which of the two searches is up, and a `:rep` names both halves.
@(test)
test_grep_head_names_the_search :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"x", "foo", "y"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)

    testing.expect_value(t, app.grep_head(&a.grep), "grep: foo   (3)")
    a.grep.replace = "bar"
    a.grep.replacing = true
    testing.expect_value(t, app.grep_head(&a.grep), "rep: foo → bar   (3)")

    empty: app.App
    testing.expect_value(t, app.grep_head(&empty.grep), "grep")
}

// Hits arrive grouped by file, so the count is one pass. Two of the three are the same file.
@(test)
test_grep_file_count :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"x", "foo", "y"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)

    testing.expect_value(t, app.grep_file_count(&a.grep), 2)

    empty: app.App
    testing.expect_value(t, app.grep_file_count(&empty.grep), 0)
}

// --- the preview and its hint ---

// The Grep pane is borrowed exactly as `:grep` borrows it, and Esc puts the old results back.
@(test)
test_preview_rep_borrows_the_pane :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    app.cl_init(&a.cl)
    defer {
        app.editor_destroy(&a.editor)
        app.cl_destroy(&a)
        app.cl_preview_destroy(&a)
        app.grep_destroy(&a.grep)
    }
    a.cl_active = true
    a.cl_preview_on = true
    app.grep_set(&a.grep, "older", nil)
    a.aux_mode = .FileTree

    txt.doc_set_text(&a.cl.doc, ":rep foo bar")
    app.cl_preview_sync(&a, 0)
    app.cl_preview_sync(&a, 1) // the search waits for a pause, as `:grep` does

    testing.expect_value(t, a.cl_preview.kind, app.Preview_Kind.Replace)
    testing.expect_value(t, a.aux_mode, app.AuxMode.Grep)
    testing.expect_value(t, a.grep.query, "foo")
    testing.expect_value(t, a.grep.replace, "bar")
    testing.expect(t, a.grep.replacing, "the pane knows it is showing a replace")

    app.cl_cancel(&a)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.grep.query, "older") // the old results, not the preview's
    testing.expect(t, !a.grep.replacing, "and they are a plain search again")
}

// A PROMPT until the line parses, then a REPORT of what the commit would touch. Both kinds live
// in one hint, as `:reload`'s and `:f`'s do.
@(test)
test_rep_hint_prompts_then_counts :: proc(t: ^testing.T) {
    a: app.App // nothing here is owned by the pane: the fixture's strings are literals

    testing.expect_value(t, app.cl_rep_hint(&a, ""), "(<old> <new>)")
    testing.expect_value(t, app.cl_rep_hint(&a, "foo"), "(<old> <new>)")
    // Parses, but no preview is up — silent, so results from an earlier search cannot speak.
    testing.expect_value(t, app.cl_rep_hint(&a, "foo bar"), "")
    // A pattern the preview declines still commits, so the line says why it is quiet.
    testing.expect_value(t, app.cl_rep_hint(&a, "x y"), "(too short to preview)")

    c0 := [?]string{"x", "foo", "y"}
    c1 := [?]string{"p", "foo", "q"}
    c2 := [?]string{"m", "foo", "n"}
    rep_fixture(&a, c0[:], c1[:], c2[:])
    defer delete(a.grep.hits)
    a.cl_preview.kind = .Replace

    testing.expect_value(t, app.cl_rep_hint(&a, "foo bar"), "(3 in 2 files · Shift+Enter)")
}
