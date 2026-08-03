package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
mkbuf :: proc(text: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, text)
    return b
}

@(private = "file")
lstr :: proc(b: ^app.Buffer, i: int) -> string {
    return app.line_string(&b.lines[i], context.temp_allocator)
}

@(test)
test_buffer_newline :: proc(t: ^testing.T) {
    b := mkbuf("hello")
    defer app.buffer_destroy(&b)
    app.buffer_motion(&b, .Right)
    app.buffer_motion(&b, .Right) // column 2
    app.buffer_newline(&b)
    testing.expect_value(t, len(b.lines), 2)
    testing.expect_value(t, lstr(&b, 0), "he")
    testing.expect_value(t, lstr(&b, 1), "llo")
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].head.col, 0)
}

@(test)
test_buffer_join :: proc(t: ^testing.T) {
    b := mkbuf("ab\ncd")
    defer app.buffer_destroy(&b)
    app.buffer_motion(&b, .Down) // line 1, column 0
    app.buffer_backspace(&b) // joins into the previous line
    testing.expect_value(t, len(b.lines), 1)
    testing.expect_value(t, lstr(&b, 0), "abcd")
    testing.expect_value(t, b.cursors[0].head.line, 0)
    testing.expect_value(t, b.cursors[0].head.col, 2)
}

@(test)
test_buffer_vertical_goal :: proc(t: ^testing.T) {
    b := mkbuf("hello\nhi\nworld")
    defer app.buffer_destroy(&b)
    app.buffer_motion(&b, .End) // column 5 on "hello"; goal = 5
    app.buffer_motion(&b, .Down) // "hi" is short -> clamps to 2
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].head.col, 2)
    app.buffer_motion(&b, .Down) // "world" -> goal 5 restored
    testing.expect_value(t, b.cursors[0].head.col, 5)
}

// load -> save must round-trip the file's final newline (or its absence) byte for
// byte: a normal POSIX file keeps its trailing '\n', an unterminated one stays so.
@(test)
test_buffer_save_preserves_final_newline :: proc(t: ^testing.T) {
    for src in ([]string{"a\nb\n", "a\nb", "", "\n"}) {
        path := "slopd_nl_roundtrip.tmp"
        testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
        defer os.remove(path)

        b: app.Buffer
        defer app.buffer_destroy(&b)
        testing.expect(t, app.buffer_load(&b, path))
        testing.expect(t, app.buffer_save(&b))

        out, err := os.read_entire_file_from_path(path, context.temp_allocator)
        testing.expect(t, err == nil)
        testing.expect_value(t, string(out), src)
    }
}

// External edits to the open file must flow into a CLEAN buffer (so a later save can't
// clobber them), while an unchanged file is a no-op and a DIRTY buffer keeps the user's
// in-progress work. The forced-stale stamp dodges filesystem mtime granularity.
@(test)
test_buffer_reload_if_changed :: proc(t: ^testing.T) {
    path := "slopd_reload.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\ntwo\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))

    // Unchanged on disk: a no-op (the stamp matches).
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, lstr(&b, 0), "one")

    // External rewrite of a clean buffer: it reloads, and the caret clamps into range.
    app.buffer_motion(&b, .Down) // caret to line 1, past the soon-shorter end
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("ALPHA\n")) == nil)
    b.disk_mtime = {} // guarantee a change is seen regardless of mtime resolution
    testing.expect(t, app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, len(b.lines), 1)
    testing.expect_value(t, lstr(&b, 0), "ALPHA")
    testing.expect_value(t, b.cursors[0].head.line, 0) // clamped from line 1

    // A dirty buffer in PROMPT mode is a real conflict: the external change is NOT pulled
    // in; a decision is flagged and the disk stamp is left unadopted so it keeps asserting.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("BETA\n")) == nil)
    b.dirty = true
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    testing.expect_value(t, lstr(&b, 0), "ALPHA") // untouched

    // "Keep mine" resolves it and caches against the current disk version: the edits stay,
    // and a re-check no longer conflicts (no re-prompt until the file changes AGAIN).
    app.buffer_conflict_resolve(&b, false)
    testing.expect(t, !b.conflict)
    testing.expect_value(t, lstr(&b, 0), "ALPHA")
    testing.expect(t, !app.buffer_reload_if_changed(&b, true)) // stamp adopted -> quiet
    testing.expect(t, !b.conflict)

    // A fresh on-disk change re-raises the conflict; "reload" then takes the disk version.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("GAMMA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    app.buffer_conflict_resolve(&b, true)
    testing.expect(t, !b.conflict)
    testing.expect(t, !b.dirty)
    testing.expect_value(t, lstr(&b, 0), "GAMMA")

    // RELAXED mode (prompt_on_conflict = false): a dirty buffer over a disk change keeps
    // the edits silently — no conflict raised, and the stamp IS adopted so it stays quiet.
    b.dirty = true
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("DELTA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, false))
    testing.expect(t, !b.conflict) // never raised
    testing.expect_value(t, lstr(&b, 0), "GAMMA") // edits untouched
    testing.expect(t, !app.buffer_reload_if_changed(&b, false)) // stamp adopted -> quiet
    testing.expect(t, !b.conflict)
}

// A reload passes b.path to buffer_load, which frees the old b.path — a naive
// free-then-clone-from-arg would dangle it (use-after-free) and later saves would write to
// garbage. After a reload the path must still be valid: edit, save, and confirm the edit
// round-trips to the SAME file on disk.
@(test)
test_buffer_reload_preserves_path :: proc(t: ^testing.T) {
    path := "slopd_reload_path.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("orig\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))

    // Force a reload through buffer_reload_keep_view (clean buffer + changed stamp).
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("disk\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, b.path, path) // path survived the reload

    // The clinching check: an edit saved after the reload must land on the same file.
    app.buffer_insert_rune(&b, 'Z')
    testing.expect(t, app.buffer_save(&b))
    saved, serr := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, serr == nil)
    testing.expect(t, strings.has_prefix(string(saved), "Z"))
}

@(test)
test_ring_contains :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/x/y.txt") // freed by editor_destroy

    testing.expect(t, !app.ring_contains(&a, "/x/y.txt")) // clean
    b.dirty = true
    testing.expect(t, app.ring_contains(&a, "/x/y.txt"))
    testing.expect(t, !app.ring_contains(&a, "/x/other.txt"))
}

// --- scroll policy (buffer_scroll_target; the renderer only consumes it) ---

@(private = "file")
numbered :: proc(n: int) -> app.Buffer {
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< n {
        strings.write_int(&b, i)
        strings.write_byte(&b, '\n')
    }
    return mkbuf(strings.to_string(b))
}

// FOLLOW (the default): the view holds still while the caret is inside it, then moves the
// minimum — up to the caret when it steps above, down to put it on the bottom row.
@(test)
test_scroll_follow :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10

    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 0) // caret on line 0
    app.doc_reset_cursor(&b.doc, app.Pos{5, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 0) // still on screen: no move
    app.doc_reset_cursor(&b.doc, app.Pos{12, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 3) // caret onto the bottom row
    b.scroll = 3
    app.doc_reset_cursor(&b.doc, app.Pos{1, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 1) // stepped above: top = caret
}

// MIDDLE: the topmost cursor is pinned to the middle row, so every motion moves the text.
// Clamped at the top of the file (nothing above line 0 to show); at the end it keeps
// centring and lets the view run past the last line.
@(test)
test_scroll_middle :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10

    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 0) // clamped at the top
    app.doc_reset_cursor(&b.doc, app.Pos{40, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 35)
    app.doc_reset_cursor(&b.doc, app.Pos{41, 0})
    // one line down = one row of text:
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 36)
    app.doc_reset_cursor(&b.doc, app.Pos{99, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 94) // past the end, still centred

    // Multi-cursor: the FIRST (topmost) cursor frames the view, not the primary (which
    // is the roaming caret at the bottom of a dropped trail).
    app.doc_reset_cursor(&b.doc, app.Pos{50, 0})
    app.doc_drop_anchor(&b.doc)
    app.doc_move(&b.doc, .Down, false, 8) // primary now on line 58, first cursor on 50
    testing.expect_value(t, app.doc_top_cursor_line(&b.doc), 50)
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 45)
}
