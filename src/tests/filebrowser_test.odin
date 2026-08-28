package tests

import app "../slopd"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "vendor:glfw"

// History, the path bar's segments, and the grid arithmetic — all host-independent for
// filetree.odin's reason, so it exercises without a window.

@(private = "file")
tmpdir :: proc(name: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    return filepath.join({base, name}, context.temp_allocator) or_else ""
}

// The path becomes a list of (name, where it goes). The root is always first, and every
// segment's path is a PREFIX of the one being browsed, which makes clicking one an ordinary
// navigation.
@(test)
test_filebrowser_segments :: proc(t: ^testing.T) {
    segs := app.filebrowser_segments("/home/paths/src")
    testing.expect_value(t, len(segs), 4)
    testing.expect_value(t, segs[0].name, "/")
    testing.expect_value(t, segs[0].path, "/")
    testing.expect_value(t, segs[1].name, "home")
    testing.expect_value(t, segs[1].path, "/home")
    testing.expect_value(t, segs[3].name, "src")
    testing.expect_value(t, segs[3].path, "/home/paths/src")

    // The root alone is one segment: a trailing empty name would be a button going nowhere.
    root := app.filebrowser_segments("/")
    testing.expect_value(t, len(root), 1)
    testing.expect_value(t, root[0].path, "/")

    // A trailing slash must not produce an empty segment either.
    trail := app.filebrowser_segments("/home/paths/")
    testing.expect_value(t, len(trail), 3)
    testing.expect_value(t, trail[2].name, "paths")
}

// A path wider than the bar drops segments from the LEFT, since the directory you are in matters
// more than the root you came from. The last segment always survives.
@(test)
test_filebrowser_seg_first :: proc(t: ^testing.T) {
    segs := app.filebrowser_segments("/home/paths/projects/slopd")
    testing.expect_value(t, len(segs), 5) // "/", home, paths, projects, slopd

    // Wide enough for everything: nothing is dropped.
    testing.expect_value(t, app.filebrowser_seg_first(segs, 100), 0)

    // Each segment costs its runes plus one cell of separator, so 21 cells is exactly the last
    // three and one fewer drops another. The boundary either side, so it is a boundary.
    testing.expect_value(t, app.filebrowser_seg_first(segs, 21), 2)
    testing.expect_value(t, app.filebrowser_seg_first(segs, 20), 3)

    // Narrower than the last segment still shows the last segment.
    testing.expect_value(t, app.filebrowser_seg_first(segs, 1), 4)
    testing.expect_value(t, app.filebrowser_seg_first(segs, 0), 4)

    testing.expect_value(t, app.filebrowser_seg_first(nil, 10), 0)
}

// `~`, an absolute path, or one relative to where you are: the same three cases `:cd` takes.
@(test)
test_filebrowser_path_resolve :: proc(t: ^testing.T) {
    testing.expect_value(t, app.filebrowser_path_resolve("/home/me", "/etc/ssl"), "/etc/ssl")
    testing.expect_value(t, app.filebrowser_path_resolve("/home/me", "src/app"), "/home/me/src/app")
    testing.expect_value(t, app.filebrowser_path_resolve("/home/me/src", ".."), "/home/me")
    testing.expect_value(t, app.filebrowser_path_resolve("/home/me", "  /etc  "), "/etc") // trimmed

    // An empty line is HOME, not the empty path: a bare `:cd`'s answer.
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" {
        testing.expect_value(t, app.filebrowser_path_resolve("/home/me", ""), home)
        testing.expect_value(t, app.filebrowser_path_resolve("/home/me", "~"), home)
    }
}

// The reason `ft.scroll` can mean "first visible row" under both presentations: a row is an
// entry in List and a row of tiles in Grid, and the anchor is derived rather than stored.
@(test)
test_filebrowser_grid :: proc(t: ^testing.T) {
    testing.expect_value(t, app.filebrowser_grid_cols(300, 100), 3)
    testing.expect_value(t, app.filebrowser_grid_cols(299, 100), 2)

    // Never zero: below one tile's width the grid is a single clipped column.
    testing.expect_value(t, app.filebrowser_grid_cols(40, 100), 1)
    testing.expect_value(t, app.filebrowser_grid_cols(0, 100), 1)
    testing.expect_value(t, app.filebrowser_grid_cols(300, 0), 1)

    // Rows round up: a part-full last row is still one you can scroll to.
    testing.expect_value(t, app.filebrowser_grid_rows(9, 3), 3)
    testing.expect_value(t, app.filebrowser_grid_rows(10, 3), 4)
    testing.expect_value(t, app.filebrowser_grid_rows(0, 3), 0)

    ft: app.FileTree
    ft.selected = 7
    testing.expect_value(t, app.filebrowser_anchor(&ft, .List, 3), 7) // the entry itself
    testing.expect_value(t, app.filebrowser_anchor(&ft, .Grid, 3), 2) // its tile row
}

// Cut in RUNES with a '~' marking the cut: bytes would truncate a two-byte character
// mid-sequence and draw a replacement glyph.
@(test)
test_filebrowser_elide :: proc(t: ^testing.T) {
    testing.expect_value(t, app.filebrowser_elide("short", 10), "short")
    testing.expect_value(t, app.filebrowser_elide("exactly10c", 10), "exactly10c")
    testing.expect_value(t, app.filebrowser_elide("a-very-long-filename", 10), "a-very-lo~")
    testing.expect_value(t, app.filebrowser_elide("ünïcödé-name", 6), "ünïcö~")
    testing.expect_value(t, app.filebrowser_elide("anything", 0), "")
}

// Over a real directory tree, because a navigation reloads the listing. The rule that makes
// forward mean anything: arriving by any other route drops it.
@(test)
test_filebrowser_history :: proc(t: ^testing.T) {
    dir := tmpdir("slopd_fb_hist")
    a_dir := filepath.join({dir, "a"}, context.temp_allocator) or_else ""
    b_dir := filepath.join({dir, "b"}, context.temp_allocator) or_else ""
    os.remove(a_dir);os.remove(b_dir);os.remove(dir)
    os.make_directory(dir)
    os.make_directory(a_dir)
    os.make_directory(b_dir)
    defer {
        os.remove(a_dir)
        os.remove(b_dir)
        os.remove(dir)
    }

    ft: app.FileTree
    br: app.FileBrowser
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)
    defer app.filebrowser_destroy(&br)

    testing.expect(t, !app.filebrowser_can_back(&br), "a fresh browser has nowhere to go back to")

    app.filebrowser_navigate(&br, &ft, a_dir)
    testing.expect_value(t, ft.dir, a_dir)
    testing.expect(t, app.filebrowser_can_back(&br))
    testing.expect(t, !app.filebrowser_can_forward(&br))

    app.filebrowser_back(&br, &ft)
    testing.expect_value(t, ft.dir, dir)
    testing.expect(t, app.filebrowser_can_forward(&br), "back must leave something to go forward to")
    if e := app.filetree_selected(&ft); e != nil {
        testing.expect_value(t, e.path, a_dir) // the cursor lands on where we came back from
    }

    app.filebrowser_forward(&br, &ft)
    testing.expect_value(t, ft.dir, a_dir)
    testing.expect(t, !app.filebrowser_can_forward(&br))

    // Back, then elsewhere: the branch we came back from is gone.
    app.filebrowser_back(&br, &ft)
    testing.expect(t, app.filebrowser_can_forward(&br))
    app.filebrowser_navigate(&br, &ft, b_dir)
    testing.expect_value(t, ft.dir, b_dir)
    testing.expect(t, !app.filebrowser_can_forward(&br), "a fresh navigation must clear the forward stack")

    // Navigating to where you already are is not a history entry, or clicking the last
    // path-bar segment would stack duplicates.
    before := app.filebrowser_can_back(&br)
    app.filebrowser_navigate(&br, &ft, b_dir)
    testing.expect_value(t, app.filebrowser_can_back(&br), before)
    testing.expect_value(t, ft.dir, b_dir)
}

// A set of destinations: adding one twice is not two rows, and the index is what the menu asks
// to decide between "add" and "remove". The persistence is config_test's.
@(test)
test_filebrowser_places :: proc(t: ^testing.T) {
    path := "/tmp/slopd_fb_places.config"
    os.remove(path)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    br: app.FileBrowser
    defer app.filebrowser_destroy(&br)

    testing.expect(t, app.filebrowser_place_add(&br, "/home/me/src"))
    testing.expect_value(t, len(br.places), 1)
    testing.expect_value(t, br.places[0].name, "src") // named for its base
    testing.expect_value(t, app.filebrowser_place_index(&br, "/home/me/src"), 0)
    testing.expect_value(t, app.filebrowser_place_index(&br, "/nope"), -1)

    testing.expect(t, !app.filebrowser_place_add(&br, "/home/me/src"), "a duplicate must not be added")
    testing.expect_value(t, len(br.places), 1)
    testing.expect(t, !app.filebrowser_place_add(&br, ""), "the empty path is not a place")

    testing.expect(t, app.filebrowser_place_remove(&br, 0))
    testing.expect_value(t, len(br.places), 0)
    testing.expect(t, !app.filebrowser_place_remove(&br, 0), "removing off the end must not underflow")

    // First run, or a deleted block: HOME, whichever standard folders under it exist, and the
    // root. Nothing is invented, so only the two certain rows are asserted.
    def := app.filebrowser_default_places(context.allocator)
    defer {
        for p in def {
            delete(p.name);delete(p.path)
        }
        delete(def)
    }
    home, root := false, false
    for p in def {
        if p.name == "Home" {
            home = true
        }
        if p.path == "/" {
            root = true
        }
        testing.expect(t, os.is_dir(p.path), "a default place points at something that is not a directory")
    }
    testing.expect(t, root, "the filesystem root is always a place")
    testing.expect_value(t, home, os.get_env("HOME", context.temp_allocator) != "")
}

// One chord table, two presentations. The file ops are Surface binds and both faces are the
// Surface context, so this asserts the claim `file_pane` rests on: the browser changes what the
// arrows and the top bar do, and nothing about `^c`. Driven through action_run.
@(test)
test_filetree_ops_chords :: proc(t: ^testing.T) {
    dir := tmpdir("slopd_fb_chords")
    os.remove(filepath.join({dir, "a.txt"}, context.temp_allocator) or_else "")
    os.remove(dir)
    os.make_directory(dir)
    defer {
        os.remove(filepath.join({dir, "a.txt"}, context.temp_allocator) or_else "")
        os.remove(filepath.join({dir, "a_copy.txt"}, context.temp_allocator) or_else "")
        os.remove(dir)
    }
    testing.expect(t, os.write_entire_file(filepath.join({dir, "a.txt"}, context.temp_allocator) or_else "", transmute([]byte)string("hi")) == nil)

    a: app.App
    a.focus = .Aux // the file pane has the keys; without it every op below is a no-op
    app.filetree_load(&a.tree, dir)
    defer app.filetree_destroy(&a.tree)
    for e, i in a.tree.entries {
        if e.name == "a.txt" {
            a.tree.selected = i
        }
    }
    run :: proc(a: ^app.App, act: app.Action) -> bool {
        return app.action_run(a, act, 0, false, false)
    }

    // ^y marks, ^u clears: marking is only ever "what does an op act on".
    testing.expect(t, run(&a, .File_Mark))
    testing.expect_value(t, len(a.tree.marks), 1)
    testing.expect(t, run(&a, .File_Marks_Clear))
    testing.expect_value(t, len(a.tree.marks), 0)

    // ^c fills the clipboard from the row under the cursor when nothing is marked, and says
    // what the paste will be.
    testing.expect(t, run(&a, .Clip_Copy))
    testing.expect_value(t, len(a.tree.clip), 1)
    testing.expect_value(t, a.tree.clip_mode, app.Clip_Mode.Copy)
    testing.expect(t, run(&a, .Clip_Cut))
    testing.expect_value(t, a.tree.clip_mode, app.Clip_Mode.Cut)

    // A copy survives its paste, so the same set can go into several directories.
    testing.expect(t, run(&a, .Clip_Copy))
    testing.expect(t, run(&a, .Clip_Paste))
    testing.expect(t, os.exists(filepath.join({dir, "a_copy.txt"}, context.temp_allocator) or_else ""))
    testing.expect_value(t, len(a.tree.clip), 1)

    // A file op declines when the file pane does not have the keys, which is what lets ^y be
    // Redo in the editor and Mark here.
    a.focus = .Editor
    testing.expect(t, !run(&a, .File_Mark), "^y in the editor must not reach the listing")
    testing.expect_value(t, len(a.tree.marks), 0)
}
