package tests

import app "../slopd"
import "core:strings"
import "core:testing"
import "../syntax"
import "../ui"
import "../pty"
import "../edit"

// The embedded documents (about.odin). The release is the binary, so the LICENSE and the
// README are #load-ed rather than shipped beside it — which makes two things worth pinning
// that no GUI check would catch: the licence text is actually IN there (GPL-3 requires a
// copy to accompany the program, and an empty #load would silently ship none), and an
// embedded buffer can never be written to a file named after its display name.

@(test)
test_embedded_license_carries_the_real_text :: proc(t: ^testing.T) {
    src := app.embedded_doc_source(.License)
    testing.expect(t, len(src) > 10_000, "LICENSE embed looks empty or truncated")
    testing.expect(t, strings.contains(src, "GNU GENERAL PUBLIC LICENSE"))
    testing.expect(t, strings.contains(src, "MIT License")) // the bundled third-party notices
    testing.expect(t, strings.contains(src, "SIL Open Font License"))
}

// The registry moved from a file beside the binary into the binary; an empty embed would
// leave every file unhighlighted with no error anywhere.
@(test)
test_embedded_language_registry_parses :: proc(t: ^testing.T) {
    g := syntax.load_grammars()
    defer syntax.grammars_destroy(g)
    testing.expect(t, len(g) > 100, "language registry embed looks empty")
    odin, found := syntax.grammar_find(g, "odin")
    testing.expect(t, found)
    if found {
        testing.expect(t, strings.contains(odin.repo, "tree-sitter-odin"))
    }
}

// An embedded doc is an ordinary buffer except that it has no file: `:w` must refuse it, and
// the disk poller must not stat a path that is really just a name.
@(test)
test_embedded_buffer_never_touches_disk :: proc(t: ^testing.T) {
    a: app.App
    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)

    app.open_embedded_doc(&a, .License)
    b := edit.editor_current(&a.editor)
    testing.expect(t, b.embedded)
    testing.expect_value(t, b.path, "LICENSE")
    testing.expect(t, !edit.buffer_on_disk(b))
    testing.expect_value(t, edit.buffer_save(b), edit.Save_Result.No_Path) // an embedded doc must not write to ./LICENSE
    testing.expect(t, !edit.buffer_reload_if_changed(b, true))
    testing.expect(t, !edit.buffer_reload_keep_view(b))
}

// Re-running the builtin returns to the buffer it already made rather than stacking a
// second copy of the same document.
@(test)
test_embedded_doc_reopens_in_place :: proc(t: ^testing.T) {
    a: app.App
    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)

    app.open_embedded_doc(&a, .License)
    n := len(a.editor.buffers)
    first := a.editor.active
    app.open_embedded_doc(&a, .License)
    testing.expect_value(t, len(a.editor.buffers), n)
    testing.expect_value(t, a.editor.active, first)

    app.open_embedded_doc(&a, .Readme) // a DIFFERENT doc still gets its own buffer
    testing.expect_value(t, len(a.editor.buffers), n + 1)
    testing.expect_value(t, edit.editor_current(&a.editor).path, "README.md")
}

// Both spellings of both doc builtins must be RECOGNISED by cl_run_builtin — an unknown name
// stops the chain, so the tail `:ls` reaching the filetree is the proof. A missing one used to
// fail quietly instead, running the name in t1 and leaving the editor alone, which is how the
// upper-case pair was found. Same guarantee as the view commands' test.
@(test)
test_doc_commands_are_builtins :: proc(t: ^testing.T) {
    for name in ([]string{"readme", "license", "README", "LICENSE"}) {
        a: app.App
        edit.editor_init(&a.editor)
        append(&a.terminals, new(pty.Terminal)) // an unknown name echoes into t1; never spawn one
        defer {
            app.cl_chain_clear(&a)
            edit.editor_destroy(&a.editor)
            free(a.terminals[0])
            delete(a.terminals)
        }
        app.cl_exec(&a, strings.concatenate({":", name, " && :ls"}, context.temp_allocator))
        testing.expectf(t, a.aux_mode == app.AuxMode.FileTree, "%s is not a builtin", name)
    }
}

// End-to-end: the command actually lands the document in the editor ring.
@(test)
test_license_command_opens_the_doc :: proc(t: ^testing.T) {
    a: app.App
    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)

    app.cl_exec(&a, ":license")
    b := edit.editor_current(&a.editor)
    testing.expect(t, b.embedded)
    testing.expect_value(t, b.path, "LICENSE")
    testing.expect_value(t, a.focus, ui.Focus.Editor)

    app.cl_exec(&a, ":README")
    testing.expect_value(t, edit.editor_current(&a.editor).path, "README.md")

    n := len(a.editor.buffers)
    app.cl_exec(&a, ":readme") // the other spelling must reach that buffer, not a second one
    testing.expect_value(t, len(a.editor.buffers), n)
    testing.expect_value(t, edit.editor_current(&a.editor).path, "README.md")
}
