package tests

import app "../slopd"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../edit"
import "../txt"

// A dialog App: the launch flags parsed and applied, browsing `dir`. Built by hand rather than
// through app_boot, which would want a config file, a grep worker and a window. Freed by
// pick_free.
@(private = "file")
pick_app :: proc(a: ^app.App, dir: string, args: ..string) {
    a.aux_mode = .FileTree
    a.project_root = strings.clone(dir) // what a relative `:return` argument resolves against
    app.cl_init(&a.cl)
    edit.editor_init(&a.editor)
    app.filetree_load(&a.tree, dir)
    app.app_launch(a, app.parse_launch_args(args))
}

@(private = "file")
pick_free :: proc(a: ^app.App) {
    app.filetree_destroy(&a.tree)
    edit.editor_destroy(&a.editor)
    app.pick_destroy(&a.pick)
    app.cl_destroy(a)
    delete(a.project_root)
}

@(private = "file")
cl_text :: proc(a: ^app.App) -> string {
    return txt.doc_string(&a.cl.doc, context.temp_allocator)
}

@(test)
test_pick_flags_parse :: proc(t: ^testing.T) {
    got := app.parse_launch_args(
        []string{"--pick=save", "--pick-out=/tmp/answer", "--pick-name=cat.png", "--pick-title=firefox"},
    )
    testing.expect_value(t, got.pick, app.Pick_Mode.Save)
    testing.expect_value(t, got.pick_out, "/tmp/answer")
    testing.expect_value(t, got.pick_name, "cat.png")
    testing.expect_value(t, got.pick_title, "firefox")
    testing.expect_value(t, got.pick_multi, false)
    // The path catch-all must not have eaten any of them.
    testing.expect_value(t, got.path, "")

    multi := app.parse_launch_args([]string{"--pick=open", "--pick-multi"})
    testing.expect_value(t, multi.pick, app.Pick_Mode.Open)
    testing.expect_value(t, multi.pick_multi, true)

    testing.expect_value(t, app.parse_launch_args([]string{"--pick=dir"}).pick, app.Pick_Mode.Dir)
    // An unknown mode is no dialog at all, rather than a half-configured one.
    testing.expect_value(t, app.parse_launch_args([]string{"--pick=nonsense"}).pick, app.Pick_Mode.None)
}

// A bare `slopd` is not a dialog, so `:return` has nothing to answer.
@(test)
test_pick_off_by_default :: proc(t: ^testing.T) {
    a: app.App
    pick_app(&a, "/tmp")
    defer pick_free(&a)

    testing.expect(t, !app.pick_live(&a))
    testing.expect(t, app.pick_refusal(&a, []string{"/tmp"}, false) != "")
    testing.expect(t, app.pick_label(&a) == "")
}

// A save arrives knowing the answer, so the line is staged before a key is pressed.
@(test)
test_pick_save_stages_the_suggested_name :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_stage"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)

    a: app.App
    pick_app(&a, dir, "--pick=save", "--pick-out=/tmp/slopd_pick_out", "--pick-name=cat.png")
    defer pick_free(&a)

    testing.expect(t, app.pick_live(&a))
    testing.expect(t, a.cl_active)
    testing.expect(t, a.cl.injected) // the alert colour, so it reads as staged
    testing.expect_value(t, cl_text(&a), ":return /tmp/slopd_pick_stage/cat.png")
    // Full on the file pane, the same arrangement --util asks for.
    testing.expect_value(t, a.view, app.View.Full)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
}

// The whole point of staging: edit the tail, press Enter, and a new name is written.
@(test)
test_pick_return_writes_the_edited_path :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_edit"
    out := "/tmp/slopd_pick_edit_out"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)
    defer _ = os.remove(out)

    a: app.App
    pick_app(&a, dir, "--pick=save", strings.concatenate({"--pick-out=", out}, context.temp_allocator))
    defer pick_free(&a)

    app.cl_exec(&a, ":return image-2.png") // relative: resolved against the workspace
    testing.expect(t, a.quit)

    data, _ := os.read_entire_file_from_path(out, context.temp_allocator)
    testing.expect(t, data != nil)
    want := strings.concatenate({a.project_root, "/image-2.png\n"}, context.temp_allocator)
    testing.expect_value(t, string(data), want)
}

// Existing files are the whole reason the line is editable, so overwriting takes the bang.
@(test)
test_pick_save_refuses_an_existing_file :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_over"
    out := "/tmp/slopd_pick_over_out"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)
    defer _ = os.remove(out)

    have := filepath.join({dir, "cat.png"}, context.temp_allocator) or_else ""
    _ = os.write_entire_file(have, transmute([]byte)string("x"))
    defer _ = os.remove(have)

    a: app.App
    pick_app(&a, dir, "--pick=save", strings.concatenate({"--pick-out=", out}, context.temp_allocator))
    defer pick_free(&a)

    testing.expect(t, strings.contains(app.pick_refusal(&a, []string{have}, false), "exists"))
    testing.expect_value(t, app.pick_refusal(&a, []string{have}, true), "")

    // A folder is never a file, bang or not.
    testing.expect(t, app.pick_refusal(&a, []string{dir}, true) != "")
    // Nor is a name under a folder that is not there.
    missing := filepath.join({dir, "nope", "cat.png"}, context.temp_allocator) or_else ""
    testing.expect(t, strings.contains(app.pick_refusal(&a, []string{missing}, true), "no such folder"))
}

@(test)
test_pick_open_refusals :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_open"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)

    one := filepath.join({dir, "a.txt"}, context.temp_allocator) or_else ""
    two := filepath.join({dir, "b.txt"}, context.temp_allocator) or_else ""
    _ = os.write_entire_file(one, transmute([]byte)string("a"))
    _ = os.write_entire_file(two, transmute([]byte)string("b"))
    defer _ = os.remove(one)
    defer _ = os.remove(two)

    a: app.App
    pick_app(&a, dir, "--pick=open", "--pick-out=/tmp/slopd_pick_open_out")
    defer pick_free(&a)

    testing.expect_value(t, app.pick_refusal(&a, []string{one}, false), "")
    testing.expect(t, strings.contains(app.pick_refusal(&a, []string{}, false), "no path"))
    testing.expect(t, strings.contains(app.pick_refusal(&a, []string{dir}, false), "folder"))
    testing.expect(t, strings.contains(app.pick_refusal(&a, []string{one, two}, false), "one file"))

    a.pick.multiple = true
    testing.expect_value(t, app.pick_refusal(&a, []string{one, two}, false), "")
}

// A folder request answers with the folder being browsed, whatever row is selected.
@(test)
test_pick_dir_answers_with_the_browsed_folder :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_dir"
    out := "/tmp/slopd_pick_dir_out"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)
    defer _ = os.remove(out)

    a: app.App
    pick_app(&a, dir, "--pick=dir", strings.concatenate({"--pick-out=", out}, context.temp_allocator))
    defer pick_free(&a)

    app.cl_exec(&a, ":return")
    testing.expect(t, a.quit)

    data, _ := os.read_entire_file_from_path(out, context.temp_allocator)
    testing.expect(t, data != nil)
    testing.expect_value(t, string(data), strings.concatenate({dir, "\n"}, context.temp_allocator))
}

// A path holding a space survives the round trip, because a staged line is quoted for the
// chain splitter and `:return` reads it back with the same rule.
@(test)
test_pick_stages_and_reads_back_an_awkward_name :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_pick_space"
    out := "/tmp/slopd_pick_space_out"
    _ = os.make_directory(dir)
    defer _ = os.remove(dir)
    defer _ = os.remove(out)

    awkward := filepath.join({dir, "my report && notes.txt"}, context.temp_allocator) or_else ""
    _ = os.write_entire_file(awkward, transmute([]byte)string("x"))
    defer _ = os.remove(awkward)

    a: app.App
    pick_app(&a, dir, "--pick=open", strings.concatenate({"--pick-out=", out}, context.temp_allocator))
    defer pick_free(&a)

    app.pick_stage(&a, []string{awkward})
    app.cl_exec(&a, cl_text(&a)) // exactly what Enter on the staged line does
    testing.expect(t, a.quit)

    data, _ := os.read_entire_file_from_path(out, context.temp_allocator)
    testing.expect(t, data != nil)
    testing.expect_value(t, string(data), strings.concatenate({awkward, "\n"}, context.temp_allocator))
}

// Nothing written means cancelled, and that is the state after every way out that is not
// `:return` — Esc, `:q`, a closed window, a kill.
@(test)
test_pick_cancel_writes_nothing :: proc(t: ^testing.T) {
    out := "/tmp/slopd_pick_cancel_out"
    _ = os.remove(out)

    a: app.App
    pick_app(&a, "/tmp", "--pick=open", strings.concatenate({"--pick-out=", out}, context.temp_allocator))
    defer pick_free(&a)

    app.cl_cancel(&a)
    testing.expect(t, !os.exists(out))
}

// What a desktop entry's %f hands us, and what every other program on the machine takes.
// It must not shadow a flag, and later must win so a launcher beats a wrapper's default.
@(test)
test_bare_path_argument :: proc(t: ^testing.T) {
    testing.expect_value(t, app.parse_launch_args([]string{"/home/fig/Downloads"}).path, "/home/fig/Downloads")
    testing.expect_value(t, app.parse_launch_args([]string{"--util", "/tmp"}).path, "/tmp")
    testing.expect(t, app.parse_launch_args([]string{"--util", "/tmp"}).util)

    // Flags stay flags.
    testing.expect_value(t, app.parse_launch_args([]string{"--tui"}).path, "")
    testing.expect_value(t, app.parse_launch_args([]string{"--perflog"}).path, "")
    testing.expect_value(t, app.parse_launch_args([]string{"--pick=save"}).path, "")

    // Both forms name the same thing, and the last one wins.
    testing.expect_value(t, app.parse_launch_args([]string{"--/a", "/b"}).path, "/b")
    testing.expect_value(t, app.parse_launch_args([]string{"/b", "--/a"}).path, "/a")
}
