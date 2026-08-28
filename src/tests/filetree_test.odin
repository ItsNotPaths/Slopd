package tests

import app "../slopd"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Navigation runs against the real working directory, so what is asserted is the ROUND TRIP:
// descend into a folder and come back, and you are where you started. Naming the folder we
// expect to land in would test the checkout's directory name instead of the navigation.
@(test)
test_filetree_nav :: proc(t: ^testing.T) {
    ft: app.FileTree
    app.filetree_init(&ft)
    defer app.filetree_destroy(&ft)

    start := strings.clone(ft.dir, context.temp_allocator)
    src := -1
    for e, i in ft.entries {
        if e.name == "src" {
            src = i
            break
        }
    }
    if src < 0 {
        fmt.println("[skip] no src/ under the working directory; run from the project root")
        return
    }

    ft.selected = src
    app.filetree_enter(&ft)
    testing.expect(t, strings.has_suffix(ft.dir, "src"))

    app.filetree_parent(&ft)
    testing.expect_value(t, ft.dir, start)
}

// --- file-op fixtures ---------------------------------------------------------

@(private = "file")
join :: proc(parts: ..string) -> string {
    return filepath.join(parts, context.temp_allocator) or_else ""
}

@(private = "file")
rmrf :: proc(path: string) {
    if os.is_dir(path) {
        if f, err := os.open(path); err == nil {
            it := os.read_directory_iterator_create(f)
            for fi in os.read_directory_iterator(&it) {
                rmrf(join(path, fi.name))
            }
            os.read_directory_iterator_destroy(&it)
            os.close(f)
        }
    }
    os.remove(path)
}

@(private = "file")
write_file :: proc(path, content: string) {
    _ = os.write_entire_file(path, transmute([]u8)content)
}

@(private = "file")
sel_by_name :: proc(ft: ^app.FileTree, name: string) -> int {
    for e, i in ft.entries {
        if e.name == name {
            return i
        }
    }
    return -1
}

// Yank a file, paste it (Copy) into the same dir -> a "_copy" duplicate with the same
// bytes, leaving the original; then the duplicate is what a delete would target — the
// pane no longer removes anything itself, it stages `rm -rf` in the command line.
@(test)
test_filetree_copy_paste :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := join(base, "slopd_ft_copy")
    rmrf(dir)
    os.make_directory(dir)
    defer rmrf(dir)
    write_file(join(dir, "a.txt"), "hello")

    ft: app.FileTree
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)

    i := sel_by_name(&ft, "a.txt")
    testing.expect(t, i >= 0)
    ft.selected = i
    app.filetree_mark_toggle(&ft)
    testing.expect(t, app.filetree_marked(&ft, join(dir, "a.txt")))

    app.filetree_clip_take(&ft, .Copy)
    app.filetree_paste(&ft)
    testing.expect(t, os.exists(join(dir, "a.txt"))) // original survives a copy
    dup := join(dir, "a_copy.txt")
    testing.expect(t, os.exists(dup))
    data, _ := os.read_entire_file(dup, context.temp_allocator)
    testing.expect(t, string(data) == "hello")

    ft.selected = sel_by_name(&ft, "a_copy.txt")
    targets := app.filetree_targets(&ft, false, context.temp_allocator)
    testing.expect_value(t, len(targets), 1)
    testing.expect_value(t, targets[0], dup)
    testing.expect(t, os.exists(dup)) // asking for the targets deletes nothing
}

// Cut a file, navigate into a subdir, paste -> the file MOVES there and the marked set
// empties (its sources are gone).
@(test)
test_filetree_cut_move :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := join(base, "slopd_ft_cut")
    sub := join(dir, "sub")
    rmrf(dir)
    os.make_directory(dir)
    os.make_directory(sub)
    defer rmrf(dir)
    write_file(join(dir, "f.txt"), "data")

    ft: app.FileTree
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)

    ft.selected = sel_by_name(&ft, "f.txt")
    app.filetree_mark_toggle(&ft)
    app.filetree_clip_take(&ft, .Cut)

    ft.selected = sel_by_name(&ft, "sub")
    app.filetree_enter(&ft) // descend into sub
    app.filetree_paste(&ft)

    testing.expect(t, os.exists(join(sub, "f.txt"))) // moved in
    testing.expect(t, !os.exists(join(dir, "f.txt"))) // gone from source
    testing.expect(t, len(ft.clip) == 0) // a cut is spent by its paste
    testing.expect(t, len(ft.marks) == 0) // and the marks naming the moved sources go with it
}

// Shift+Up/Down sweep marks a contiguous run as the cursor moves, idempotently (a row
// re-crossed stays marked, not toggled off).
@(test)
test_filetree_sweep :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := join(base, "slopd_ft_sweep")
    rmrf(dir)
    os.make_directory(dir)
    defer rmrf(dir)
    write_file(join(dir, "a.txt"), "")
    write_file(join(dir, "b.txt"), "")
    write_file(join(dir, "c.txt"), "")

    ft: app.FileTree
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)

    ft.selected = sel_by_name(&ft, "a.txt")
    app.filetree_mark_sweep(&ft, 1) // marks a + b, lands on b
    app.filetree_mark_sweep(&ft, 1) // marks b + c, lands on c
    testing.expect(t, len(ft.marks) == 3) // a, b, c all marked
    testing.expect(t, app.filetree_marked(&ft, join(dir, "b.txt")))

    app.filetree_mark_sweep(&ft, -1) // re-cross b: idempotent, no un-mark
    testing.expect(t, len(ft.marks) == 3)
}

// Reset clears marks without touching files; with a marked set, the delete targets are
// the whole set (which the host turns into one `rm -rf` command line).
@(test)
test_filetree_reset_and_targets :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := join(base, "slopd_ft_del")
    rmrf(dir)
    os.make_directory(dir)
    defer rmrf(dir)
    write_file(join(dir, "x.txt"), "x")
    write_file(join(dir, "y.txt"), "y")

    ft: app.FileTree
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)

    ft.selected = sel_by_name(&ft, "x.txt");app.filetree_mark_toggle(&ft)
    ft.selected = sel_by_name(&ft, "y.txt");app.filetree_mark_toggle(&ft)
    testing.expect(t, len(ft.marks) == 2)

    app.filetree_marks_reset(&ft)
    testing.expect(t, len(ft.marks) == 0)
    testing.expect(t, os.exists(join(dir, "x.txt"))) // reset is non-destructive

    ft.selected = sel_by_name(&ft, "x.txt");app.filetree_mark_toggle(&ft)
    ft.selected = sel_by_name(&ft, "y.txt");app.filetree_mark_toggle(&ft)
    marked := app.filetree_targets(&ft, true, context.temp_allocator)
    testing.expect_value(t, len(marked), 2)
    cmd := app.rm_command(marked, context.temp_allocator)
    testing.expect(t, strings.contains(cmd, app.sh_quote(join(dir, "x.txt"), context.temp_allocator)))
    testing.expect(t, strings.contains(cmd, app.sh_quote(join(dir, "y.txt"), context.temp_allocator)))
    testing.expect(t, os.exists(join(dir, "x.txt"))) // staging a command deletes nothing
}

// A non-".." row is executable-tagged from its own mode bits, so Shift+Enter knows a
// script/binary from a document (the run-vs-open-in-the-desktop split).
@(test)
test_filetree_exec_bit :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := join(base, "slopd_ft_exec")
    rmrf(dir)
    os.make_directory(dir)
    defer rmrf(dir)
    write_file(join(dir, "plain.txt"), "hi")
    write_file(join(dir, "run.sh"), "#!/bin/sh\necho hi\n")
    _ = os.chmod(join(dir, "run.sh"), os.Permissions{.Read_User, .Write_User, .Execute_User})

    ft: app.FileTree
    app.filetree_load(&ft, dir)
    defer app.filetree_destroy(&ft)

    testing.expect(t, !ft.entries[sel_by_name(&ft, "plain.txt")].exec)
    testing.expect(t, ft.entries[sel_by_name(&ft, "run.sh")].exec)
}
