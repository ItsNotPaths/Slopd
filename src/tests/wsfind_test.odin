package tests

import app "../slopd"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "vendor:glfw"
import "../txt"
import "../ui"
import "../search"
import "../edit"

// The workspace prompt's model (wsfind.odin): what a typed line matches, what the list holds
// when nothing is typed, and what the keys do to it. Host-independent — no window, no Clay —
// because the prompt is a list plus a line, and both are state.

@(private = "file")
tmp :: proc(name: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    return filepath.join({base, name}, context.temp_allocator) or_else ""
}

// Fuzzy matching is a SUBSEQUENCE test with a score, so the claims worth pinning are the two
// halves of that: which strings match at all, and which of two matches is the better one.
@(test)
test_wsfind_score :: proc(t: ^testing.T) {
    _, ok := search.wsfind_score("src/wsfind.odin", "wsf")
    testing.expect(t, ok)
    _, ok = search.wsfind_score("src/wsfind.odin", "WSFIND") // case-folded both ways
    testing.expect(t, ok)
    _, ok = search.wsfind_score("src/wsfind.odin", "ws find") // spaces are gaps you need not spell
    testing.expect(t, ok)
    _, ok = search.wsfind_score("src/wsfind.odin", "wsz")
    testing.expect(t, !ok, "a rune that is not there must not match")
    _, ok = search.wsfind_score("src/wsfind.odin", "dnifsw")
    testing.expect(t, !ok, "the order of the query is part of the query")

    // A run landing together beats the same letters scattered, and a hit in the base name beats
    // one buried in the directories above it.
    run, _ := search.wsfind_score("src/wsfind.odin", "wsfind")
    scattered, _ := search.wsfind_score("src/window_ui_stuff.odin", "wsfind")
    testing.expect(t, run > scattered)

    base, _ := search.wsfind_score("src/theme.odin", "theme")
    dir, _ := search.wsfind_score("theme/a.odin", "theme")
    testing.expect(t, base > dir)
}

// A row is LISTED relative to the root it was scanned from; anything outside it (a dirty buffer
// from elsewhere) keeps its absolute path, since a relative one would name the wrong file.
@(test)
test_wsfind_rel :: proc(t: ^testing.T) {
    testing.expect_value(t, search.wsfind_rel("/home/me/src", "/home/me/src/app.odin"), "app.odin")
    testing.expect_value(t, search.wsfind_rel("/home/me/src", "/home/me/src/a/b.odin"), "a/b.odin")
    testing.expect_value(t, search.wsfind_rel("/home/me/src", "/etc/hosts"), "/etc/hosts")
    testing.expect_value(t, search.wsfind_rel("", "/etc/hosts"), "/etc/hosts")
}

// The scan walks the tree once, when the prompt opens: files at any depth, dotted DIRECTORIES
// skipped (a `.git` is not somewhere you jump), dotted files kept (a `.gitignore` is), and the
// configured exclusions left out — the same list a `:grep` is handed (exclude.odin).
@(test)
test_wsfind_scan :: proc(t: ^testing.T) {
    root := tmp("slopd_wsfind_scan")
    sub := filepath.join({root, "sub"}, context.temp_allocator) or_else ""
    hidden := filepath.join({root, ".hidden"}, context.temp_allocator) or_else ""
    vendor := filepath.join({root, "vendor"}, context.temp_allocator) or_else ""
    write :: proc(dir, name: string) -> string {
        p := filepath.join({dir, name}, context.temp_allocator) or_else ""
        _ = os.write_entire_file(p, transmute([]byte)string("x"))
        return p
    }
    os.make_directory(root)
    os.make_directory(sub)
    os.make_directory(hidden)
    os.make_directory(vendor)
    a_odin := write(root, "a.odin")
    ignore := write(root, ".gitignore")
    b_odin := write(sub, "b.odin")
    c_odin := write(hidden, "c.odin")
    d_odin := write(vendor, "d.odin")
    defer {
        for p in ([?]string{a_odin, ignore, b_odin, c_odin, d_odin}) {
            os.remove(p)
        }
        os.remove(vendor);os.remove(hidden);os.remove(sub);os.remove(root)
    }

    ws: search.WS_Find
    search.wsfind_init(&ws)
    defer search.wsfind_destroy(&ws)
    search.wsfind_scan(&ws, root, search.exclude_split("vendor"))

    testing.expect_value(t, ws.root, root)
    found: [3]bool
    for p in ws.files {
        switch p {
        case a_odin:
            found[0] = true
        case ignore:
            found[1] = true
        case b_odin:
            found[2] = true
        case c_odin:
            testing.expect(t, false, "a dotted directory must not be walked")
        case d_odin:
            testing.expect(t, false, "an excluded directory must not be walked")
        }
    }
    testing.expect_value(t, len(ws.files), 3)
    testing.expect(t, found[0] && found[1] && found[2])

    // …and with nothing excluded, `vendor` is just another folder: the list is the config's,
    // not a rule baked into the scan.
    search.wsfind_scan(&ws, root)
    testing.expect_value(t, len(ws.files), 4)
}

// The two lists the prompt shows, and the one thing that switches between them: an empty line
// lists the open ring, and the first character replaces it with the filter.
@(test)
test_wsfind_rows :: proc(t: ^testing.T) {
    a: app.App
    search.wsfind_init(&a.wsfind)
    defer search.wsfind_destroy(&a.wsfind)
    defer edit.editor_destroy(&a.editor)
    ring :: proc(a: ^app.App, path: string, dirty: bool) {
        b: edit.Buffer
        txt.doc_init(&b.doc)
        b.path = strings.clone(path)
        b.dirty = dirty
        append(&a.editor.buffers, b)
    }
    ring(&a, "/w/src/clean.odin", false) // saved, but open: listed under the unsaved ones
    ring(&a, "/w/src/theme.odin", true)
    ring(&a, "", true) // a scratch buffer has nowhere to jump to, saved or not

    ws := &a.wsfind
    for p in ([?]string{"/w/src/theme.odin", "/w/src/window_ui.odin", "/w/README.md"}) {
        append(&ws.files, strings.clone(p))
    }
    ws.root = strings.clone("/w")

    // Unsaved first whatever order the ring holds them in, then the saved ones behind.
    app.wsfind_build(&a)
    testing.expect_value(t, len(ws.rows), 2)
    testing.expect_value(t, ws.rows[0].path, "/w/src/theme.odin")
    testing.expect(t, ws.rows[0].dirty, "an unsaved row is the star")
    testing.expect_value(t, ws.rows[1].path, "/w/src/clean.odin")
    testing.expect(t, !ws.rows[1].dirty)

    // Typed: the ring is gone and the rows are matches, best first — and the one that is also
    // unsaved keeps its star, which is the whole reason the flag is per ROW and not per list.
    txt.doc_set_text(&ws.query, "theme")
    app.wsfind_build(&a)
    testing.expect_value(t, len(ws.rows), 1)
    testing.expect_value(t, ws.rows[0].path, "/w/src/theme.odin")
    testing.expect(t, ws.rows[0].dirty)

    txt.doc_set_text(&ws.query, "win")
    app.wsfind_build(&a)
    testing.expect_value(t, len(ws.rows), 1)
    testing.expect_value(t, ws.rows[0].path, "/w/src/window_ui.odin")
    testing.expect(t, !ws.rows[0].dirty)

    txt.doc_set_text(&ws.query, "zzz")
    app.wsfind_build(&a)
    testing.expect_value(t, len(ws.rows), 0)
    testing.expect_value(t, ws.selected, 0) // a new list starts at its best answer

    // …and emptying the line brings the ring back: the prompt has no third state.
    txt.doc_set_text(&ws.query, "")
    app.wsfind_build(&a)
    testing.expect_value(t, len(ws.rows), 2)
}

// The keys, through action_run — the one seam a chord, a click and a menu item all reach.
// **The prompt is an EDITABLE**, which is the load-bearing part: with it up the pane is the Text
// context, so the file ops (`^y`, `^d`) do not resolve at all and cannot act on a listing that
// is not on screen.
@(test)
test_wsfind_keys :: proc(t: ^testing.T) {
    root := tmp("slopd_wsfind_keys")
    os.make_directory(root)
    file := filepath.join({root, "target.txt"}, context.temp_allocator) or_else ""
    _ = os.write_entire_file(file, transmute([]byte)string("hi"))
    defer {os.remove(file);os.remove(root)}

    a: app.App
    a.project_root = strings.clone(root, context.temp_allocator) // no app_destroy here: arena it
    search.wsfind_init(&a.wsfind)
    defer search.wsfind_destroy(&a.wsfind)
    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)
    run :: proc(a: ^app.App, act: app.Action) -> bool {
        return app.action_run(a, act, 0, false, false)
    }

    testing.expect(t, run(&a, .Ws_Find))
    testing.expect(t, app.wsfind_shown(&a), "Alt+P shows the file pane with the prompt on it")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.focus, ui.Focus.Aux)
    kind, _ := app.active_editable(&a)
    testing.expect_value(t, kind, app.Editable.Workspace_Find)

    // …which puts the pane in the TEXT context, so `^y` is the editable's chord and never
    // file.mark — the file ops cannot reach a listing that is not on screen.
    ctx := app.bind_ctx(&a, app.Chord{glfw.KEY_Y, glfw.MOD_CONTROL})
    testing.expect_value(t, ctx, app.Bind_Ctx.Text)

    // The scan found the file, so typing its name lists it and Enter opens it.
    txt.doc_set_text(&a.wsfind.query, "target")
    app.wsfind_sync(&a) // the rows follow the line on a version compare, once a frame
    testing.expect_value(t, len(a.wsfind.rows), 1)
    testing.expect_value(t, a.wsfind.rows[0].path, file)

    // Up/Down are the LIST's here, not the line's — one row, so both are clamped no-ops.
    testing.expect(t, run(&a, .Nav_Down))
    testing.expect_value(t, a.wsfind.selected, 0)

    testing.expect(t, run(&a, .Activate))
    testing.expect(t, !a.wsfind.open, "opening a row closes the prompt")
    testing.expect_value(t, a.focus, ui.Focus.Editor)
    testing.expect_value(t, edit.editor_current(&a.editor).path, file)

    // Esc closes it without opening anything, leaving the listing as it was found.
    testing.expect(t, run(&a, .Ws_Find))
    testing.expect(t, a.wsfind.open)
    testing.expect(t, run(&a, .Escape))
    testing.expect(t, !a.wsfind.open)
}
