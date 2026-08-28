package tests

import app ".."
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../txt"

// A file pane gesture stages a command line rather than acting behind a modal, which means the
// NAME OF A FILE ends up inside a line the chain will parse. `&&` is that chain's operator, so
// a name carrying one must not be able to add a step to the line it appears in.

// A quoted `&&` between two SHELL parts is harmless -- cl_parse coalesces adjacent shell
// segments back into one step, so a bad split there rejoins invisibly. It only bites when the
// tail is a builtin, which is exactly what a staged line's tail is. Hence these run the gesture.
@(private = "file")
HOSTILE_DIRS :: []string {
    "slopd_inject && :readme", // the chain's operator, plainly
    `slopd_inject "q" && :readme`, // …behind an escaped quote, which the quoting has to carry
}

// Alt+Enter on a folder stages `:cd <path>`. `:cd` takes the whole rest of the line, so a space
// needs no quoting -- but `&&` splits the line before any builtin sees it, and the tail runs as
// its own step. With `folder_cd: run` it runs with no review at all.
@(test)
test_cd_gesture_cannot_be_split_by_a_folder_name :: proc(t: ^testing.T) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    for name in HOSTILE_DIRS {
        dir := filepath.join({cwd, name}, context.temp_allocator) or_else ""
        testing.expect(t, os.make_directory(dir) == nil)
        defer os.remove(dir)

        a: app.App
        app.editor_init(&a.editor)
        defer app.editor_destroy(&a.editor)
        append(&a.tree.entries, app.FileEntry{name = name, path = strings.clone(dir), is_dir = true})
        defer app.filetree_destroy(&a.tree)

        app.filetree_cd_selected(&a) // staged, not run: folder_cd_run is false by default
        line := txt.doc_string(&a.cl.doc, context.temp_allocator)

        // Running the staged line must set the root and NOTHING else. `:readme` is the payload:
        // a builtin, so it needs no shell, and it puts a buffer in the ring -- which `:cd` never
        // does, unlike the aux pane it legitimately refreshes.
        before := len(a.editor.buffers)
        app.cl_exec(&a, line)
        app.cl_chain_clear(&a)
        testing.expectf(
            t,
            len(a.editor.buffers) == before,
            "a folder name added a step to the staged line: %q",
            line,
        )
        // …and the root it DID set is the folder, whole. Quoting that survived the splitter but
        // mangled the name would be the same bug wearing the other hat.
        testing.expectf(t, a.project_root == dir, "`:cd` landed on %q, not %q", a.project_root, dir)
    }
}

@(private = "file")
HOSTILE_NAMES :: []string {
    "plain.txt",
    "my notes.md", // the case the old quoting was written for
    "a && rm -rf ~", // the chain's operator, with spaces
    "a&&b", // …and without: the old rule only quoted on a space
    "say \"hi\".txt", // a quote, which would close the quoting that carries it
    "back\\slash",
    "quote'and\"both",
    "$(whoami)",
    "`id`",
    "semi;colon|pipe",
    "(paren)",
    "ünïcødé.md",
}

// The staged form must survive the round trip EXACTLY: the builtin that reads it back has to
// get the name it was given, whatever is in it. A quoting that only defeated the splitter but
// mangled the path would trade one bug for another.
@(test)
test_quoted_arg_round_trips :: proc(t: ^testing.T) {
    for name in HOSTILE_NAMES {
        q := app.cl_quote_arg(name, context.temp_allocator)
        testing.expectf(t, app.unquote_arg(q) == name, "unquote_arg lost %q (staged as %s)", name, q)

        // `:j` reads its path with first_arg, which takes ONE field off the front of the line,
        // so the same name has to survive with a line number behind it.
        line := strings.concatenate({q, " 40"}, context.temp_allocator)
        raw, value := app.first_arg(line)
        testing.expectf(t, value == name, "first_arg lost %q (staged as %s)", name, q)
        testing.expectf(
            t,
            strings.trim_space(line[len(raw):]) == "40",
            "first_arg mis-measured %q, leaving %q",
            name,
            line[len(raw):],
        )
    }
}

// `:tu` types `cd <root>` straight into every unlocked terminal, and a project root is a
// directory NAME. Inside DOUBLE quotes a shell still expands `$( )`, a backtick and a `$var`,
// so the quoting has to be the kind that expands nothing. `^h` on a folder is `:cd` plus `:tu`
// in one keystroke, which is how a browsed folder reaches a live shell.
@(private = "file")
HOSTILE_ROOTS :: []string {
    "slopd_root_$(touch pwned)", // command substitution
    "slopd_root_`touch pwned`", // …and its older spelling
    "slopd_root_$HOME", // a bare variable
    `slopd_root_a"b`, // a double quote, which ends the quoting that carries it
    "slopd_root_a'b", // a single quote, which ends the OTHER kind
    "slopd_root_x && touch pwned",
}

// Run the line a real shell, because the question is what a shell does with it. The answer must
// be: change to exactly that directory, print nothing else, create nothing.
@(test)
test_tu_cd_line_survives_a_real_shell :: proc(t: ^testing.T) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    for name in HOSTILE_ROOTS {
        dir := filepath.join({cwd, name}, context.temp_allocator) or_else ""
        testing.expect(t, os.make_directory(dir) == nil)
        defer os.remove(dir)

        cmd := app.cd_command(dir, context.temp_allocator)
        script := strings.concatenate({cmd, "pwd"}, context.temp_allocator)
        _, out, _, err := os.process_exec(
            os.Process_Desc{command = {"sh", "-c", script}},
            context.temp_allocator,
        )
        testing.expectf(t, err == nil, "sh could not run %q", script)
        testing.expectf(
            t,
            strings.trim_space(string(out)) == dir,
            "`:tu` landed on %q, not %q — from %q",
            strings.trim_space(string(out)),
            dir,
            script,
        )
    }
    // Nothing the names asked for actually ran.
    testing.expect(t, !os.exists("pwned"), "a folder name ran a command in the terminal")
}
