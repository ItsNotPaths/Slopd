package tests

import app ".."
import "core:fmt"
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
    return string(app.doc_line(&b.doc, i, context.temp_allocator))
}

@(test)
test_buffer_newline :: proc(t: ^testing.T) {
    b := mkbuf("hello")
    defer app.buffer_destroy(&b)
    app.buffer_motion(&b, .Right)
    app.buffer_motion(&b, .Right) // column 2
    app.buffer_newline(&b)
    testing.expect_value(t, app.doc_line_count(&b.doc), 2)
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
    testing.expect_value(t, app.doc_line_count(&b.doc), 1)
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

// load -> save round-trips the file's final newline, or its absence, byte for byte.
@(test)
test_buffer_save_preserves_final_newline :: proc(t: ^testing.T) {
    for src in ([]string{"a\nb\n", "a\nb", "", "\n"}) {
        path := "slopd_nl_roundtrip.tmp"
        testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
        defer os.remove(path)

        b: app.Buffer
        defer app.buffer_destroy(&b)
        testing.expect(t, app.buffer_load(&b, path))
        testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)

        out, err := os.read_entire_file_from_path(path, context.temp_allocator)
        testing.expect(t, err == nil)
        testing.expect_value(t, string(out), src)
    }
}

// A CRLF file is edited as if it were LF and written back the way it came, so one changed line
// is one changed line on disk. `crlf` is per buffer, so flipping it converts the file.
@(test)
test_buffer_crlf_roundtrip :: proc(t: ^testing.T) {
    path := "slopd_crlf.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("a\r\nb\r\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))
    testing.expect(t, b.crlf)
    testing.expect_value(t, app.doc_line_count(&b.doc), 2)
    testing.expect_value(t, lstr(&b, 1), "b") // no '\r' in the document itself

    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)
    out, err := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect_value(t, string(out), "a\r\nb\r\n")

    // `:crlf` converts: the same document, the other ending.
    b.crlf = false
    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)
    out2, err2 := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, err2 == nil)
    testing.expect_value(t, string(out2), "a\nb\n")

    // An LF file is not promoted, and a lone '\r' is content, not a break.
    testing.expect(t, !app.crlf_file("a\nb\r\n"))
    testing.expect(t, !app.crlf_file("a\rb"))
    testing.expect(t, app.crlf_file("a\r\nb\n"))
}

// The save writes a sibling temp file and renames it over the target: the file keeps its
// permissions, no temp file is left behind, and a read-only file still refuses. Its own folder,
// so the leftover check sees this save alone.
@(test)
test_buffer_save_is_atomic :: proc(t: ^testing.T) {
    dir := "slopd_atomic_dir"
    testing.expect(t, os.make_directory(dir) == nil)
    defer os.remove_all(dir)
    path := fmt.tprintf("%s/slopd_atomic.tmp", dir)
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\n")) == nil)
    mode := os.Permissions{.Read_User, .Write_User, .Execute_User}
    testing.expect(t, os.chmod(path, mode) == nil)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))
    app.doc_insert_text(&b.doc, "X")
    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)

    fi, err := os.stat(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect(t, fi.mode == mode) // the target's own bits, not a fresh file's defaults

    left, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
    testing.expect(t, derr == nil)
    testing.expect_value(t, len(left), 1) // the file alone: the temp one is gone

    // Read-only: refused before anything is written, so the sudo staging still has its case.
    if os.get_euid() != 0 { // root is refused nothing
        testing.expect(t, os.chmod(path, {.Read_User}) == nil)
        testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Denied)
        testing.expect(t, os.chmod(path, mode) == nil)
    }
}

// A symlinked file is saved THROUGH the link: the rename lands on the target, so the link is
// still a link afterwards.
@(test)
test_buffer_save_follows_symlink :: proc(t: ^testing.T) {
    target := "slopd_symlink_target.tmp"
    link := "slopd_symlink.tmp"
    testing.expect(t, os.write_entire_file(target, transmute([]u8)string("one\n")) == nil)
    defer os.remove(target)
    os.remove(link)
    testing.expect(t, os.symlink(target, link) == nil)
    defer os.remove(link)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, link))
    app.doc_insert_text(&b.doc, "X")
    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)

    fi, err := os.lstat(link, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect(t, fi.type == .Symlink, "the save replaced the link with a regular file")
    out, rerr := os.read_entire_file_from_path(target, context.temp_allocator)
    testing.expect(t, rerr == nil)
    testing.expect_value(t, string(out), "Xone\n")
}

// External edits flow into a CLEAN buffer, so a later save cannot clobber them; an unchanged
// file is a no-op and a DIRTY buffer keeps the user's work. The forced-stale stamp dodges
// filesystem mtime granularity.
@(test)
test_buffer_reload_if_changed :: proc(t: ^testing.T) {
    path := "slopd_reload.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\ntwo\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))

    // Unchanged on disk: a no-op, since the stamp matches.
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, lstr(&b, 0), "one")

    // An external rewrite of a clean buffer reloads, and the caret clamps into range.
    app.buffer_motion(&b, .Down) // caret to line 1, past the soon-shorter end
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("ALPHA\n")) == nil)
    b.disk_mtime = {} // so a change is seen whatever the mtime resolution
    testing.expect(t, app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, app.doc_line_count(&b.doc), 1)
    testing.expect_value(t, lstr(&b, 0), "ALPHA")
    testing.expect_value(t, b.cursors[0].head.line, 0) // clamped from line 1

    // A dirty buffer in prompt mode is a real conflict: the change is not pulled in, and the
    // stamp is left unadopted so it keeps asserting.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("BETA\n")) == nil)
    b.dirty = true
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    testing.expect_value(t, lstr(&b, 0), "ALPHA") // untouched

    // "Keep mine" resolves it and caches against the current disk version, so a re-check no
    // longer conflicts.
    app.buffer_conflict_resolve(&b, false)
    testing.expect(t, !b.conflict)
    testing.expect_value(t, lstr(&b, 0), "ALPHA")
    testing.expect(t, !app.buffer_reload_if_changed(&b, true)) // stamp adopted -> quiet
    testing.expect(t, !b.conflict)

    // A fresh on-disk change re-raises it, and "reload" takes the disk version.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("GAMMA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, true))
    testing.expect(t, b.conflict)
    app.buffer_conflict_resolve(&b, true)
    testing.expect(t, !b.conflict)
    testing.expect(t, !b.dirty)
    testing.expect_value(t, lstr(&b, 0), "GAMMA")

    // Relaxed mode: a dirty buffer over a disk change keeps the edits silently, and the stamp
    // IS adopted so it stays quiet.
    b.dirty = true
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("DELTA\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, !app.buffer_reload_if_changed(&b, false))
    testing.expect(t, !b.conflict) // never raised
    testing.expect_value(t, lstr(&b, 0), "GAMMA") // edits untouched
    testing.expect(t, !app.buffer_reload_if_changed(&b, false)) // stamp adopted -> quiet
    testing.expect(t, !b.conflict)
}

// A reload passes b.path to buffer_load, which frees the old b.path: a naive
// free-then-clone-from-arg would dangle it and later saves would write to garbage.
@(test)
test_buffer_reload_preserves_path :: proc(t: ^testing.T) {
    path := "slopd_reload_path.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("orig\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))

    // Force a reload: a clean buffer and a changed stamp.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("disk\n")) == nil)
    b.disk_mtime = {}
    testing.expect(t, app.buffer_reload_if_changed(&b, true))
    testing.expect_value(t, b.path, path) // the path survived the reload

    // An edit saved after the reload must land on the same file.
    app.buffer_insert_rune(&b, 'Z')
    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)
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

// Follow: the view holds still while the caret is inside it, then moves the minimum.
@(test)
test_scroll_follow :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10

    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 0) // caret on line 0
    app.doc_reset_cursor(&b.doc, app.Pos{5, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 0) // on screen: no move
    app.doc_reset_cursor(&b.doc, app.Pos{12, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 3) // caret onto the bottom row
    b.scroll = 3
    app.doc_reset_cursor(&b.doc, app.Pos{1, 0})
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, false), 1) // above: top = caret
}

// Middle: the topmost cursor is pinned to the middle row, so every motion moves the text.
// Clamped at the top; at the end it keeps centring and lets the view run past the last line.
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

    // Multi-cursor: the topmost cursor frames the view, not the primary.
    app.doc_reset_cursor(&b.doc, app.Pos{50, 0})
    app.doc_drop_anchor(&b.doc)
    app.doc_move(&b.doc, .Down, false, 8) // primary now on line 58, first cursor on 50
    testing.expect_value(t, app.doc_top_cursor_line(&b.doc), 50)
    testing.expect_value(t, app.buffer_scroll_target(&b, ROWS, true), 45)
}

// --- detached scroll (buffer_scroll_apply; the wheel's half of the policy) ---
//
// The wheel cuts the view loose from the caret, and while it is loose NEITHER policy may run:
// both derive the top from the caret. A keystroke re-attaches.

// Detached, the view stays where the wheel put it, under both scroll_modes — which is the whole
// reason for detaching rather than special-casing Middle.
@(test)
test_scroll_detached_holds :: proc(t: ^testing.T) {
    ROWS :: 10
    for center in ([?]bool{false, true}) {
        b := numbered(100)
        defer app.buffer_destroy(&b)
        app.doc_reset_cursor(&b.doc, app.Pos{5, 0}) // caret near the top, view following

        app.buffer_scroll_by(&b, 60, 100) // wheel: 60 lines down, detached at t=100
        testing.expect_value(t, b.scroll, 60)

        // Frames pass with no keystroke: the view holds, a screen and a half from a caret the
        // policy would have chased.
        app.buffer_scroll_apply(&b, ROWS, center, 50)
        testing.expect_value(t, b.scroll, 60)
        app.buffer_scroll_apply(&b, ROWS, center, 50)
        testing.expect_value(t, b.scroll, 60)
    }
}

// A keystroke re-attaches and the policy resumes from the caret, which is what stops a
// scrolled-away view hiding your edits.
@(test)
test_scroll_detached_reattaches_on_input :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10
    app.doc_reset_cursor(&b.doc, app.Pos{5, 0})

    app.buffer_scroll_by(&b, 60, 100)
    app.buffer_scroll_apply(&b, ROWS, false, 50) // no input since: still detached
    testing.expect_value(t, b.scroll, 60)

    app.buffer_scroll_apply(&b, ROWS, false, 101) // a keystroke lands after the detach
    testing.expect_value(t, b.scroll_detached, f64(0)) // re-attached…
    testing.expect_value(t, b.scroll, 5) // …and Follow pulled the view back to the caret

    // Still attached on later frames, with no second detach to undo.
    app.doc_reset_cursor(&b.doc, app.Pos{40, 0})
    app.buffer_scroll_apply(&b, ROWS, false, 102)
    testing.expect_value(t, b.scroll, 31) // caret onto the bottom row
}

// With nothing detached, buffer_scroll_apply is exactly the policy, so the wheel cannot have
// changed keyboard behaviour.
@(test)
test_scroll_attached_is_the_policy :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10
    app.doc_reset_cursor(&b.doc, app.Pos{40, 0})

    app.buffer_scroll_apply(&b, ROWS, true, 0)
    testing.expect_value(t, b.scroll, app.buffer_scroll_target(&b, ROWS, true))
    b.scroll = 0
    app.buffer_scroll_apply(&b, ROWS, false, 0)
    testing.expect_value(t, b.scroll, app.buffer_scroll_target(&b, ROWS, false))
}

// Bounded by the buffer, not free-running: the wheel cannot park the top before line 0 or past
// the last. buffer_set_text re-attaches.
@(test)
test_scroll_detached_bounds :: proc(t: ^testing.T) {
    b := numbered(100)
    defer app.buffer_destroy(&b)
    ROWS :: 10

    app.buffer_scroll_by(&b, -50, 100) // wheel up from the top
    testing.expect_value(t, b.scroll, 0)
    app.buffer_scroll_by(&b, 5000, 100) // and far past the end
    testing.expect_value(t, b.scroll, 99)
    app.buffer_scroll_apply(&b, ROWS, false, 50)
    testing.expect_value(t, b.scroll, 99)

    app.buffer_set_text(&b, "one\ntwo\n")
    testing.expect_value(t, b.scroll_detached, f64(0))
    testing.expect_value(t, b.scroll, 0)
}

// --- the sudo save --- A file we may read and not write is the one save failure with a way
// forward, so `.Denied` is what tells Ctrl+S and `:w` to stage the `sudo cp` line.
@(test)
test_buffer_save_denied :: proc(t: ^testing.T) {
    path := "slopd_denied.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("disk\n")) == nil)
    defer os.remove(path)
    testing.expect(t, os.chmod(path, {.Read_User}) == nil)

    // As root an unwritable mode is not unwritable, so the case cannot be produced.
    if os.write_entire_file(path, transmute([]u8)string("probe\n")) == nil {
        fmt.println("[skip] running as root: a 0400 file is still writable")
        return
    }

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))
    app.buffer_insert_rune(&b, 'X')
    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Denied)
    testing.expect(t, b.dirty, "a refused save must leave the buffer dirty")

    // Neither of the other two is a permission problem: an embedded doc has nowhere to write
    // to, and a vanished folder is a plain failure.
    e: app.Buffer
    defer app.buffer_destroy(&e)
    app.buffer_set_text(&e, "x")
    testing.expect_value(t, app.buffer_save(&e), app.Save_Result.No_Path)
    e.path = strings.clone("/no-such-folder-zz/x.txt")
    testing.expect_value(t, app.buffer_save(&e), app.Save_Result.Failed)
}

// The bytes the buffer WOULD write, compared against the file. What lets a builtin that marks
// work clean be safe to type anywhere.
@(test)
test_buffer_matches_disk :: proc(t: ^testing.T) {
    path := "slopd_matches.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("one\ntwo\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))
    testing.expect(t, app.buffer_matches_disk(&b))

    app.buffer_insert_rune(&b, 'X') // edited, and the disk has not moved
    testing.expect(t, !app.buffer_matches_disk(&b))

    // Root, via the staged cp, writes exactly what we hold: it matches, so marking it saved is
    // honest.
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("Xone\ntwo\n")) == nil)
    testing.expect(t, app.buffer_matches_disk(&b))
    b.dirty = true
    app.buffer_mark_saved(&b)
    testing.expect(t, !b.dirty)
    testing.expect(t, !b.conflict)

    // An unnamed buffer never matches: there is no file to be equal to.
    u: app.Buffer
    defer app.buffer_destroy(&u)
    app.buffer_set_text(&u, "x")
    testing.expect(t, !app.buffer_matches_disk(&u))
}

// --- horizontal scroll (the column axis; buffer_hscroll_target / _apply) ---
//
// No soft wrap, so a long line runs off the right edge and this is how it is reached. The
// policy is deliberately not the vertical one: no Middle mode, and a margin the caret is never
// allowed inside, so typing at the right edge shows the columns you are about to fill.

HCOLS :: 20 // a 20-column text region; HSCROLL_PAD (8) fits twice inside it

// Home, hold, and the minimum move at either edge. The caret is never nearer an edge than
// HSCROLL_PAD once there is room for the margin.
@(test)
test_hscroll_margin :: proc(t: ^testing.T) {
    P :: app.HSCROLL_PAD

    // Near home the left clamp wins, so the view stays at column 0 rather than scrolling the
    // start of the line off for a margin that is not needed.
    testing.expect_value(t, app.buffer_hscroll_target(0, 0, HCOLS), 0)
    testing.expect_value(t, app.buffer_hscroll_target(0, 5, HCOLS), 0)

    // The last column that leaves the margin intact holds the view…
    testing.expect_value(t, app.buffer_hscroll_target(0, HCOLS - 1 - P, HCOLS), 0)
    // …and one past it moves by exactly one column.
    testing.expect_value(t, app.buffer_hscroll_target(0, HCOLS - P, HCOLS), 1)
    testing.expect_value(t, app.buffer_hscroll_target(0, 100, HCOLS), 100 + P - HCOLS + 1)

    // Inside the padded window the view holds, which stops it sliding under every keystroke.
    testing.expect_value(t, app.buffer_hscroll_target(89, 100, HCOLS), 89)
    testing.expect_value(t, app.buffer_hscroll_target(89, 97, HCOLS), 89)

    // Walking back left moves the minimum too, keeping the same margin.
    testing.expect_value(t, app.buffer_hscroll_target(89, 96, HCOLS), 88)
    testing.expect_value(t, app.buffer_hscroll_target(89, 20, HCOLS), 12)
    // …all the way home: Home on a long line puts column 0 back on screen.
    testing.expect_value(t, app.buffer_hscroll_target(89, 0, HCOLS), 0)
}

// A pane too narrow for two margins halves them out; without it the two pull opposite ways and
// the view oscillates by a column every frame.
@(test)
test_hscroll_narrow_pane :: proc(t: ^testing.T) {
    // 5 columns: pad falls to 2.
    testing.expect_value(t, app.buffer_hscroll_target(0, 10, 5), 10 + 2 - 5 + 1)
    testing.expect_value(t, app.buffer_hscroll_target(8, 10, 5), 8) // and then holds
    testing.expect_value(t, app.buffer_hscroll_target(8, 9, 5), 7)

    // One column wide: no margin is possible, so the caret sits in the only cell.
    testing.expect_value(t, app.buffer_hscroll_target(0, 5, 1), 5)
    // A pane with no text region yet pins home rather than going negative.
    testing.expect_value(t, app.buffer_hscroll_target(30, 40, 0), 0)
}

@(private = "file")
wide :: proc(cols: int) -> app.Buffer {
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "short\n")
    for _ in 0 ..< cols {
        strings.write_byte(&b, 'x')
    }
    strings.write_string(&b, "\nshort\n")
    return mkbuf(strings.to_string(b))
}

// Attached, it is the policy bounded by the widest line ON SCREEN, generous by exactly the
// margin, so a caret parked at end-of-line keeps its context.
@(test)
test_hscroll_apply_bounds :: proc(t: ^testing.T) {
    b := wide(300)
    defer app.buffer_destroy(&b)
    COLS :: 80
    app.doc_reset_cursor(&b.doc, app.Pos{1, 300}) // end of the long line

    app.buffer_hscroll_apply(&b, COLS, 300, 0)
    testing.expect_value(t, b.hscroll, 300 + app.HSCROLL_PAD - COLS + 1)
    // The caret lands inside the window with the full margin to its right.
    testing.expect_value(t, 300 - b.hscroll, COLS - 1 - app.HSCROLL_PAD)

    // A window of only short lines has nothing to scroll to, so the view pins home.
    app.buffer_hscroll_apply(&b, COLS, 5, 0)
    testing.expect_value(t, b.hscroll, 0)
}

// The vertical state machine on the other axis. Pinned separately because the two stamps are
// independent: scrolling sideways must not re-frame the page.
@(test)
test_hscroll_detach_and_reattach :: proc(t: ^testing.T) {
    b := wide(300)
    defer app.buffer_destroy(&b)
    COLS :: 80
    app.doc_reset_cursor(&b.doc, app.Pos{1, 0}) // caret at home, view following

    app.buffer_hscroll_by(&b, 120, 100) // Shift+wheel right, detached at t = 100
    testing.expect_value(t, b.hscroll, 120)
    testing.expect_value(t, b.scroll_detached, f64(0)) // the page was not touched

    // Frames pass with no keystroke: the column holds, far from a caret the policy would have
    // dragged it back to.
    app.buffer_hscroll_apply(&b, COLS, 300, 50)
    testing.expect_value(t, b.hscroll, 120)

    // A keystroke after the stamp re-attaches, and the policy pulls back to the caret.
    app.buffer_hscroll_apply(&b, COLS, 300, 101)
    testing.expect_value(t, b.hscroll_detached, f64(0))
    testing.expect_value(t, b.hscroll, 0)
}

// Bounded like the detached page: the callback cannot clamp, so the frame does, with one notch
// of overshoot at most.
@(test)
test_hscroll_detached_bounds :: proc(t: ^testing.T) {
    b := wide(300)
    defer app.buffer_destroy(&b)
    COLS :: 80

    app.buffer_hscroll_by(&b, -50, 100) // left from home
    testing.expect_value(t, b.hscroll, 0)

    app.buffer_hscroll_by(&b, 5000, 100) // far past the end of the longest line
    app.buffer_hscroll_apply(&b, COLS, 300, 50)
    testing.expect_value(t, b.hscroll, 300 + app.HSCROLL_PAD - COLS + 1)
}

// A wheel-detached page holds its column too: the caret is only guaranteed on screen while the
// vertical view follows it, so the axes hold together and one keystroke re-attaches both.
@(test)
test_hscroll_holds_while_page_detached :: proc(t: ^testing.T) {
    b := wide(300)
    defer app.buffer_destroy(&b)
    COLS :: 80
    app.doc_reset_cursor(&b.doc, app.Pos{1, 250}) // deep into the long line

    app.buffer_hscroll_apply(&b, COLS, 300, 0)
    at := b.hscroll
    testing.expect(t, at > 0, "the policy followed the caret out along the line")

    // The wheel scrolls the page away, and the column must not chase a caret off screen.
    app.buffer_scroll_by(&b, 60, 100)
    app.buffer_hscroll_apply(&b, COLS, 5, 50) // only short lines drawn now
    testing.expect_value(t, b.hscroll, 0) // bounded to what is there

    // …and the keystroke that re-attaches the page re-attaches the column.
    app.buffer_scroll_apply(&b, 10, false, 101)
    app.buffer_hscroll_apply(&b, COLS, 300, 101)
    testing.expect_value(t, b.hscroll, at)
}

// Both axes settle at home: a reused scratch buffer must not smear sideways.
@(test)
test_hscroll_reset_on_set_text :: proc(t: ^testing.T) {
    b := wide(300)
    defer app.buffer_destroy(&b)
    app.buffer_hscroll_by(&b, 120, 100)
    app.buffer_set_text(&b, "fresh")
    testing.expect_value(t, b.hscroll, 0)
    testing.expect_value(t, b.hscroll_detached, f64(0))
    testing.expect_value(t, b.hscroll_anim.to, f32(0))
}

// pt_compact is the only thing that flattens a splintered table, and a save is where it runs.
// Without the call the piece count only ever grows, and every line an edit split costs a copy
// to read from then on.
@(test)
test_save_compacts_a_splintered_table :: proc(t: ^testing.T) {
    path := "slopd_compact.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("hello world\n")) == nil)
    defer os.remove(path)

    b: app.Buffer
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_load(&b, path))

    // Scattered single-rune inserts: each one splits a piece, and none of them coalesce.
    for i in 0 ..< app.PT_COMPACT_PIECES {
        app.doc_reset_cursor(&b.doc, {0, i % 2 == 0 ? 0 : 3})
        app.doc_insert_rune(&b.doc, 'z')
    }
    testing.expect(t, app.pt_should_compact(&b.doc.pt))
    want := app.doc_string(&b.doc, context.temp_allocator)

    testing.expect_value(t, app.buffer_save(&b), app.Save_Result.Ok)
    testing.expect(t, !app.pt_should_compact(&b.doc.pt), "a save must flatten the table")
    testing.expect_value(t, app.doc_string(&b.doc, context.temp_allocator), want)
}
