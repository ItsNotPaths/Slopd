package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
val :: proc(a: ^app.App) -> string {
    return app.doc_string(&a.cl.doc, context.temp_allocator)
}

// Stand in N sessions without spawning real shells: term_focus only lazily spawns
// when the list is empty, so unspawned placeholders are enough to exercise routing
// and the tN clamp. Freed with free_sessions.
@(private = "file")
fake_sessions :: proc(a: ^app.App, n: int) {
    for _ in 0 ..< n {
        append(&a.terminals, new(app.Terminal))
    }
}

@(private = "file")
free_sessions :: proc(a: ^app.App) {
    for term in a.terminals {
        free(term)
    }
    delete(a.terminals)
}

// The quit/write builtins guard on the unsaved ring (ring_dirty_count): a buffer with no file
// is not in it, because `wa` has nowhere to write it and no later save could rescue it; giving
// it a path puts it in, and `wa` then saves it back out. The window-closing paths (clean `q` /
// `q!`) and the echo refusal need a live GLFW window / terminal, so they aren't exercised here.
@(test)
test_cl_write_ring :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)

    // No file: `:wa` cannot write it, and it guards nothing.
    b.dirty = true
    app.cl_exec(&a, ":wa")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)

    // Named: it joins the ring, and `:wa` writes it and clears it again.
    path := "/tmp/slopd_quit_test.txt"
    b.path = strings.clone(path)
    b.dirty = true
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 1)
    app.cl_exec(&a, ":wa")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)
    os.remove(path)
}

// `:w <path>` writes a COPY and stays on this file, as vim does: the bytes land there, the
// buffer keeps its own name and its unsaved mark, and the ring is unchanged.
@(test)
test_cl_write_copy :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "mine")
    b.final_newline = false
    b.path = strings.clone("/tmp/slopd_wcopy_src.txt")
    b.dirty = true

    copy_path := "/tmp/slopd_wcopy.txt"
    defer os.remove(copy_path)
    app.cl_exec(&a, strings.concatenate({":w ", copy_path}, context.temp_allocator))

    data, err := os.read_entire_file_from_path(copy_path, context.temp_allocator)
    testing.expect(t, err == nil, "the copy was not written")
    testing.expect_value(t, string(data), "mine")

    testing.expect_value(t, b.path, "/tmp/slopd_wcopy_src.txt") // still its own file
    testing.expect(t, b.dirty, "a copy is not a save: the buffer is still unsaved")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 1)
}

// The other half of the same verb: a buffer with NO file was not copied anywhere, it was named.
// It takes the path, so `^S` writes it from then on — emacs' write-file, not vim's `:w <path>`.
@(test)
test_cl_write_names_a_buffer_with_no_file :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "a note")
    b.final_newline = false
    b.dirty = true // the scratch buffer, typed into

    path := "/tmp/slopd_wname.txt"
    defer os.remove(path)
    app.cl_exec(&a, strings.concatenate({":w ", path}, context.temp_allocator))

    testing.expect_value(t, b.path, path)
    testing.expect(t, !b.dirty, "naming it IS the save")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)

    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect_value(t, string(data), "a note")

    // And from here it is an ordinary file: `^S` writes it where it now lives.
    app.buffer_set_text(b, "edited")
    b.dirty = true
    testing.expect_value(t, app.cl_save(&a, b), app.Save_Result.Ok)
    data, _ = os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, string(data), "edited")
}

// Unsaved edits guard the quit only when a FILE is waiting for them. A buffer with no path has
// nowhere to be written, so it cannot be rescued and must not hold the session open.
@(test)
test_a_buffer_with_no_file_does_not_guard_the_quit :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "typed into the scratch buffer")
    b.dirty = true
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)

    // One with a file behind it guards as it always did.
    named: app.Buffer
    app.doc_init(&named.doc)
    named.path = strings.clone("/tmp/slopd_guard.txt")
    named.dirty = true
    append(&a.editor.buffers, named)
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 1)
}

// What the bang is for: an existing file is refused until `:w!` names it, so a mistyped name
// cannot eat what is already there. A folder that is not there is named rather than guessed at.
@(test)
test_cl_write_refusals :: proc(t: ^testing.T) {
    path := "/tmp/slopd_wrefuse.txt"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("theirs")) == nil)
    defer os.remove(path)

    testing.expect(t, strings.contains(app.cl_write_refusal(path, false), "exists"))
    testing.expect_value(t, app.cl_write_refusal(path, true), "") // `:w!` goes through
    testing.expect_value(t, app.cl_write_refusal("/tmp", false), ":w: that is a directory, not a file")
    testing.expect(t, strings.has_prefix(app.cl_write_refusal("/tmp/slopd_no_dir/x.txt", false), ":w: no such folder"))
    testing.expect_value(t, app.cl_write_refusal("/tmp/slopd_wfresh.txt", false), "") // a free name
}

// `:discard <file>` takes the disk version back for whichever buffer holds that file — not only
// the one on screen — and the file leaves the unsaved ring. The file panes' ^k stages this line.
@(test)
test_cl_discard :: proc(t: ^testing.T) {
    path := "/tmp/slopd_discard.txt"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("on disk\n")) == nil)
    defer os.remove(path)

    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)
    testing.expect(t, app.buffer_load(b, path))
    app.buffer_set_text(b, "my edits")
    b.dirty = true
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 1)
    testing.expect(t, app.ring_contains(&a, path))

    app.cl_exec(&a, strings.concatenate({":discard ", path}, context.temp_allocator))
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)
    testing.expect_value(t, app.doc_string(&b.doc, context.temp_allocator), "on disk")
    testing.expect(t, !app.ring_contains(&a, path))
}

@(test)
test_cl_goto :: proc(t: ^testing.T) {
    a: app.App
    app.cl_exec(&a, ":ls")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.focus, app.Focus.Aux)
}

@(test)
test_cl_jump :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    app.cl_init(&a.cl) // every jump leaves a way back in the history ring
    defer {app.editor_destroy(&a.editor);app.cl_destroy(&a)}
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9") // 10 lines

    app.cl_exec(&a, ":j 3") // absolute, 1-based -> line index 2
    testing.expect_value(t, b.cursors[b.primary].head.line, 2)
    testing.expect_value(t, a.focus, app.Focus.Editor)

    app.cl_exec(&a, ":jump 6") // `:jump` alias, line index 5
    testing.expect_value(t, b.cursors[b.primary].head.line, 5)

    app.cl_exec(&a, ":j +2") // relative down from 5
    testing.expect_value(t, b.cursors[b.primary].head.line, 7)

    app.cl_exec(&a, ":j -4") // relative up from 7
    testing.expect_value(t, b.cursors[b.primary].head.line, 3)

    app.cl_exec(&a, ":j 999") // clamps to the last line
    testing.expect_value(t, b.cursors[b.primary].head.line, 9)

    app.cl_exec(&a, ":j -999") // clamps to the first line
    testing.expect_value(t, b.cursors[b.primary].head.line, 0)
}

// `:tN` names a session. It is a BUILTIN like any other, so it needs its sigil: an
// unsigilled `t2` is a command the shell will fail to find, not a goto.
@(test)
test_cl_terminal_prefix :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 3)
    defer free_sessions(&a)
    app.cl_exec(&a, ":t2")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 1)
    app.cl_exec(&a, ":t9") // clamps to the last session
    testing.expect_value(t, a.term_active, 2)
}

// An unsigilled `t2` is shell: it lands in t1 as a command line, leaving the ACTIVE session
// where it was. The sigil is the whole difference between naming a session and typing at one.
@(test)
test_cl_bare_tN_is_shell :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 3)
    defer {app.cl_chain_clear(&a);free_sessions(&a)}
    a.term_active = 2

    app.cl_parse(&a, "t2 --version")
    testing.expect_value(t, a.cl_chain.target, 1) // the CL's own session — not session 2
    testing.expect_value(t, len(a.cl_chain.steps), 1)
    testing.expect(t, a.cl_chain.steps[0].shell, "an unsigilled tN is a shell command")
    testing.expect_value(t, a.cl_chain.steps[0].text, "t2 --version")
    testing.expect_value(t, a.term_active, 2) // parsing a shell line must not switch sessions
}

// `:tN <rest>`: the session is ours, everything after it is the shell's. `:t2 grep foo` is the
// REAL grep in session 2 — the throw that used to need an opt-out is just an unsigilled word.
@(test)
test_cl_target_then_raw_shell :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 3)
    defer {app.cl_chain_clear(&a);free_sessions(&a)}

    app.cl_parse(&a, ":t2 grep foo")
    testing.expect_value(t, a.cl_chain.target, 2)
    testing.expect_value(t, len(a.cl_chain.steps), 1)
    testing.expect(t, a.cl_chain.steps[0].shell, "grep after :tN is the shell's grep")
    testing.expect_value(t, a.cl_chain.steps[0].text, "grep foo")
}

@(test)
test_cl_shell_stub :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 2)
    defer free_sessions(&a)
    app.cl_exec(&a, "echo hi") // unsigilled -> shell -> t1
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 0)
}

@(test)
test_cl_history :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_destroy(&a)

    app.doc_set_text(&a.cl.doc, ":ls")
    app.cl_submit(&a)
    app.doc_set_text(&a.cl.doc, ":cf")
    app.cl_submit(&a)

    app.cl_open(&a) // hist_idx parked at the live edit
    app.cl_history_prev(&a);testing.expect_value(t, val(&a), ":cf")
    app.cl_history_prev(&a);testing.expect_value(t, val(&a), ":ls")
    app.cl_history_next(&a);testing.expect_value(t, val(&a), ":cf")
    app.cl_history_next(&a);testing.expect_value(t, val(&a), "") // back to live
}

// Alt+; is Alt+C with the sigil pre-typed: the same line, opened with `:` in it and the caret
// past it — and NOT an injection, so the alert ring stays off (the user pressed the key).
@(test)
test_cl_open_prefix :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_destroy(&a)

    app.cl_open(&a, ":")
    testing.expect(t, a.cl_active)
    testing.expect_value(t, val(&a), ":")
    testing.expect_value(t, a.cl.doc.cursors[a.cl.doc.primary].head.col, 1) // caret past the sigil
    testing.expect(t, !a.cl.injected, "a keypress is not a staged command")

    app.cl_open(&a) // Alt+C: the empty, shell-first line
    testing.expect_value(t, val(&a), "")
}

// The command line's extensible ghost hint: a recognised BUILTIN with no argument yet shows its
// arg example; once an argument is typed (or the builtin is unknown) the hint drops. A shell
// line never hints — `reload` without the sigil is somebody else's program, not ours to gloss.
@(test)
test_cl_ghost_hint :: proc(t: ^testing.T) {
    a: app.App // no buffers: nothing is conflicted, so `:reload` reads as a manual refresh
    testing.expect_value(t, app.cl_ghost_hint(&a, ":reload"), "(y/n)")
    testing.expect_value(t, app.cl_ghost_hint(&a, ":reload "), "(y/n)") // trailing space, no arg yet
    testing.expect_value(t, app.cl_ghost_hint(&a, ":reload y"), "") // argument typed -> no hint
    testing.expect_value(t, app.cl_ghost_hint(&a, ":ls"), "") // recognised builtin, no hint defined
    testing.expect_value(t, app.cl_ghost_hint(&a, "reload"), "") // no sigil: a shell command
    testing.expect_value(t, app.cl_ghost_hint(&a, ":"), "") // the sigil alone names nothing
    testing.expect_value(t, app.cl_ghost_hint(&a, ""), "") // empty line
}

// The same builtin, staged against a real conflict, hints the THREE ways out rather than two:
// the staged line is the whole prompt now, and `:w` (overwrite with my version) is not a
// `:reload` argument, so nothing else would ever name it.
@(test)
test_cl_ghost_hint_conflict :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    testing.expect_value(t, app.cl_ghost_hint(&a, ":reload "), "(y/n)")
    app.editor_current(&a.editor).conflict = true
    testing.expect_value(t, app.cl_ghost_hint(&a, ":reload "), "(y = disk / n = mine / :w = overwrite)")
}

// The `:reload` builtin settles a pending disk-change conflict: `:reload n` keeps the edits
// (and caches), `:reload y` re-reads from disk. With no conflict, it is a manual refresh.
@(test)
test_cl_reload_conflict :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    defer app.cl_destroy(&a)

    path := "/tmp/slopd_cl_conflict.txt"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("disk\n")) == nil)
    defer os.remove(path)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "mine")
    b.path = strings.clone(path) // freed by editor_destroy
    b.dirty = true
    b.conflict = true

    // `:reload n` keeps my edits and clears the conflict.
    app.cl_exec(&a, ":reload n")
    testing.expect(t, !b.conflict)
    testing.expect_value(t, string(app.doc_line(&b.doc, 0, context.temp_allocator)), "mine")

    // Re-raise, then `:reload y` takes the disk version (edits discarded, buffer clean).
    b.conflict = true
    app.cl_exec(&a, ":reload y")
    testing.expect(t, !b.conflict)
    testing.expect(t, !b.dirty)
    testing.expect_value(t, string(app.doc_line(&b.doc, 0, context.temp_allocator)), "disk")

    // With no conflict, a bare `:reload` is a manual re-read from disk (discards edits).
    app.buffer_set_text(b, "scratch")
    b.dirty = true
    app.cl_exec(&a, ":reload")
    testing.expect_value(t, string(app.doc_line(&b.doc, 0, context.temp_allocator)), "disk")
}

// An open command line owns keys even when a live terminal is focused (it overlays
// the terminal); otherwise specials like Enter leak to the shell. Regression.
@(test)
test_cl_active_owns_keys_over_terminal :: proc(t: ^testing.T) {
    a: app.App
    tm := new(app.Terminal)
    tm.alive = true
    append(&a.terminals, tm)
    defer {free(tm);delete(a.terminals)}
    a.aux_mode = app.AuxMode.Terminal
    a.focus = app.Focus.Aux
    a.term_active = 0

    testing.expect(t, app.term_focused(&a) == tm, "terminal owns keys when the CL is closed")
    a.cl_active = true
    testing.expect(t, app.term_focused(&a) == nil, "CL owns keys while active")
}

// --- chain parser (cl_parse: pure, no shell). The `:` sigil is the ONLY thing that makes a
// segment a builtin, and the parser strips it: a step's text is the bare `name args`. ---

@(test)
test_cl_parse_segments :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "git add . && :gs")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, steps[0].shell, "first segment is shell")
    testing.expect_value(t, steps[0].text, "git add .")
    testing.expect(t, !steps[1].shell, ":gs is a builtin")
    testing.expect_value(t, steps[1].text, "gs") // stored without the sigil
}

@(test)
test_cl_parse_coalesce_shell :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "a && b && :gs") // adjacent shell segments keep their &&
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect_value(t, steps[0].text, "a && b")
    testing.expect_value(t, steps[1].text, "gs")
}

@(test)
test_cl_parse_target_prefix :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 3)
    defer {app.cl_chain_clear(&a);free_sessions(&a)}
    app.cl_parse(&a, ":t3 git status") // :tN sets the chain's shell target
    testing.expect_value(t, a.cl_chain.target, 3)
    testing.expect_value(t, len(a.cl_chain.steps), 1)
    testing.expect(t, a.cl_chain.steps[0].shell, "remainder is a shell command")
    testing.expect_value(t, a.cl_chain.steps[0].text, "git status")
}

@(test)
test_cl_parse_cd_tu_builtins :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, ":cd src && :tu") // both are captured builtins, never shell
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, !steps[0].shell, "cd is a builtin")
    testing.expect_value(t, steps[0].text, "cd src")
    testing.expect(t, !steps[1].shell, "tu is a builtin")
    testing.expect_value(t, steps[1].text, "tu")
}

// `:cd` sets the project root: absolute paths land verbatim, relative ones resolve
// against the current root, and a non-directory leaves the root untouched.
@(test)
test_cl_cd_project_root :: proc(t: ^testing.T) {
    a: app.App
    defer delete(a.project_root)
    app.cl_exec(&a, ":cd /tmp")
    testing.expect_value(t, a.project_root, "/tmp")
    app.cl_exec(&a, ":cd ..") // relative: /tmp/.. -> /
    testing.expect_value(t, a.project_root, "/")
    app.cl_exec(&a, ":cd /no/such/dir/zzz") // typo: root unchanged
    testing.expect_value(t, a.project_root, "/")
}

// An unsigilled `cd` is the SHELL's: it moves that terminal and leaves Slopd's project root
// exactly where it was. The two `cd`s are different commands, told apart by the sigil.
@(test)
test_cl_bare_cd_is_shell :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 1)
    defer {app.cl_chain_clear(&a);free_sessions(&a);delete(a.project_root)}

    app.cl_parse(&a, "cd /tmp")
    testing.expect_value(t, len(a.cl_chain.steps), 1)
    testing.expect(t, a.cl_chain.steps[0].shell, "an unsigilled cd is the shell's")
    testing.expect_value(t, a.project_root, "") // the project root never moved
}

// "Set workspace here" IS `:cd <dir>` + `:tu`, so the root it leaves behind is the one the typed
// pair would have — with no terminals up, the sync half is the no-op it is meant to be.
@(test)
test_cl_workspace :: proc(t: ^testing.T) {
    a: app.App
    defer delete(a.project_root)
    app.cl_workspace(&a, "/tmp")
    testing.expect_value(t, a.project_root, "/tmp")

    app.cl_workspace(&a, "/no/such/dir/zzz") // a directory that is not there changes nothing
    testing.expect_value(t, a.project_root, "/tmp")
    app.cl_workspace(&a, "")
    testing.expect_value(t, a.project_root, "/tmp")
}

@(private = "file")
tmp_join :: proc(parts: ..string) -> string {
    return strings.join(parts, "/", context.temp_allocator)
}

// `slopd --<path>` on a DIRECTORY: the workspace lands there — the project root new terminals
// spawn in, and the directory the file panes are browsing.
@(test)
test_cl_launch_path_directory :: proc(t: ^testing.T) {
    dir := tmp_join("/tmp", "slopd_launch_dir")
    os.make_directory(dir)
    defer os.remove(dir)

    a: app.App
    app.filetree_init(&a.tree)
    defer {app.filetree_destroy(&a.tree);delete(a.project_root)}

    testing.expect(t, app.cl_launch_path(&a, dir))
    testing.expect_value(t, a.project_root, dir)
    testing.expect_value(t, a.tree.dir, dir)
}

// `slopd --<path>` on a FILE: it opens in the editor, and the workspace is the folder holding
// it — the file is what you asked for, its folder is where you are working.
@(test)
test_cl_launch_path_file :: proc(t: ^testing.T) {
    dir := tmp_join("/tmp", "slopd_launch_file")
    os.make_directory(dir)
    defer os.remove(dir)
    path := tmp_join(dir, "note.txt")
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("hello\n")) == nil)
    defer os.remove(path)

    a: app.App
    app.editor_init(&a.editor)
    app.filetree_init(&a.tree)
    defer {app.editor_destroy(&a.editor);app.filetree_destroy(&a.tree);delete(a.project_root)}

    testing.expect(t, app.cl_launch_path(&a, path))
    testing.expect_value(t, a.project_root, dir) // the folder, not the file
    testing.expect_value(t, a.tree.dir, dir)
    testing.expect_value(t, app.editor_current(&a.editor).path, path)
    testing.expect_value(t, a.focus, app.Focus.Editor) // the opened file is what you look at
}

// A path that is not there is reported (main prints it), and changes nothing: the launch cwd
// stays the root rather than a window opening as if the argument had been honoured.
@(test)
test_cl_launch_path_missing :: proc(t: ^testing.T) {
    a: app.App
    a.project_root = strings.clone("/tmp")
    app.filetree_init(&a.tree)
    defer {app.filetree_destroy(&a.tree);delete(a.project_root)}

    testing.expect(t, !app.cl_launch_path(&a, "/no/such/dir/zzz/file.txt"))
    testing.expect(t, !app.cl_launch_path(&a, ""))
    testing.expect_value(t, a.project_root, "/tmp")
}

// A config-driven CL action either stages its command (opens the CL, runs nothing) or
// runs it at once (no CL) — the filetree folder cd via a.folder_cd_run.
@(test)
test_cl_dispatch_stage_vs_run :: proc(t: ^testing.T) {
    a: app.App
    defer delete(a.project_root)
    defer app.cl_destroy(&a) // staging opens the CL doc; free it (else it leaks)

    app.cl_dispatch(&a, ":cd /tmp", false) // stage
    testing.expect(t, a.cl_active, "stage opens the command line")
    testing.expect_value(t, val(&a), ":cd /tmp")
    testing.expect_value(t, a.project_root, "") // not executed
    app.cl_cancel(&a)

    app.cl_dispatch(&a, ":cd /tmp", true) // run
    testing.expect(t, !a.cl_active, "run leaves the command line closed")
    testing.expect_value(t, a.project_root, "/tmp") // executed
}

// The file panes' ^k stages the line rather than acting, so unsaved work is never thrown away
// unread — the `discard: run` config is the way to skip the reading. An entry with nothing
// unsaved stages nothing at all.
@(test)
test_filetree_discard_stages :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "f.txt", path = "/tmp/ft/f.txt"})
    defer {
        delete(a.tree.entries)
        app.editor_destroy(&a.editor)
        app.cl_destroy(&a)
    }

    app.filetree_discard_selected(&a)
    testing.expect(t, !a.cl_active, "a file with nothing unsaved has nothing to discard")

    b := app.editor_current(&a.editor)
    b.path = strings.clone("/tmp/ft/f.txt")
    b.dirty = true
    app.filetree_discard_selected(&a)
    testing.expect(t, a.cl_active, "the staged line is the confirm")
    testing.expect_value(t, val(&a), ":discard /tmp/ft/f.txt")
}

// --- chain runner (&& honours exit status; exit codes simulated, no shell) ---

@(test)
test_cl_chain_success_runs_builtin :: proc(t: ^testing.T) {
    a: app.App
    tm := new(app.Terminal)
    tm.alive = true // fake live session; pty is -1 so writes are no-ops
    append(&a.terminals, tm)
    defer {app.cl_chain_clear(&a);free(tm);delete(a.terminals)}

    app.cl_exec(&a, "build_thing && :cf")
    testing.expect(t, a.cl_chain.waiting, "should block on the shell step's exit")

    tm.exit_ready = true // shell reports success
    tm.exit_id = a.cl_chain.wait_id
    tm.exit_code = 0
    app.cl_chain_pump(&a)

    testing.expect_value(t, a.aux_mode, app.AuxMode.Config) // cf ran
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain finished")
}

@(test)
test_cl_chain_failure_short_circuits :: proc(t: ^testing.T) {
    a: app.App
    tm := new(app.Terminal)
    tm.alive = true
    append(&a.terminals, tm)
    defer {app.cl_chain_clear(&a);free(tm);delete(a.terminals)}

    app.cl_exec(&a, "build_thing && :cf")
    testing.expect(t, a.cl_chain.waiting, "should block on the shell step's exit")

    tm.exit_ready = true // shell reports failure
    tm.exit_id = a.cl_chain.wait_id
    tm.exit_code = 1
    app.cl_chain_pump(&a)

    testing.expect(t, a.aux_mode != app.AuxMode.Config, "cf must be skipped on failure")
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain cleared")
}

// --- more parser combinations (cl_parse: pure, no shell) ---

@(test)
test_cl_parse_builtin_then_shell :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, ":gs && echo hi")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, !steps[0].shell)
    testing.expect_value(t, steps[0].text, "gs")
    testing.expect(t, steps[1].shell)
    testing.expect_value(t, steps[1].text, "echo hi")
}

@(test)
test_cl_parse_shell_builtin_shell_no_coalesce :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    // A builtin between two shell segments breaks the run — they must NOT coalesce.
    app.cl_parse(&a, "make && :gs && ./run")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 3)
    testing.expect_value(t, steps[0].text, "make")
    testing.expect(t, steps[0].shell)
    testing.expect_value(t, steps[1].text, "gs")
    testing.expect(t, !steps[1].shell)
    testing.expect_value(t, steps[2].text, "./run")
    testing.expect(t, steps[2].shell)
}

@(test)
test_cl_parse_target_only_is_goto :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 4)
    defer {app.cl_chain_clear(&a);free_sessions(&a)}
    app.cl_parse(&a, ":t4")
    testing.expect_value(t, a.cl_chain.target, 4)
    testing.expect_value(t, len(a.cl_chain.steps), 0) // no command — just the goto
}

@(test)
test_cl_parse_empty_segments_skipped :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, ":gs &&  && :ls") // stray empty segment from a double &&
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect_value(t, steps[0].text, "gs")
    testing.expect_value(t, steps[1].text, "ls")
}

// --- quoting: an `&&` is a chain seam only where the SHELL would see an operator ---

// Every line here is ONE command as the shell reads it, so the parser must not cut it in half.
// The naive split did, which is how `rm -rf 'a && b.txt'` used to become two broken fragments
// and an unterminated quote at the shell's prompt.
@(test)
test_cl_parse_quoted_ampersands_are_not_seams :: proc(t: ^testing.T) {
    Case :: struct {
        line, why: string,
    }
    cases := []Case {
        {`echo "a && b"`, "inside double quotes"},
        {`echo 'a && b'`, "inside single quotes"},
        {`echo "it's && fine"`, "an apostrophe inside double quotes opens nothing"},
        {`echo 'say "hi" && bye'`, "a double quote inside single quotes opens nothing"},
        {`echo "a \" && b"`, "an escaped quote does not close the string"},
        {`echo a \&\& b`, "escaped ampersands are characters"},
        {`(cd src && make)`, "a subshell is one command"},
        {`echo $(true && echo hi)`, "a command substitution is one command"},
        {"echo `true && echo hi`", "a backtick substitution is one command"},
        {`echo "open && never closed`, "an unclosed quote swallows the rest"},
    }
    for c in cases {
        a: app.App
        defer app.cl_chain_clear(&a)
        app.cl_parse(&a, c.line)
        steps := a.cl_chain.steps[:]
        testing.expectf(t, len(steps) == 1, "%s: %d steps — %s", c.line, len(steps), c.why)
        if len(steps) == 1 {
            testing.expect_value(t, steps[0].text, c.line) // handed on verbatim, quotes and all
        }
    }
}

// The seams around a quoted `&&` are still found: this is the line `^d` stages for a file whose
// NAME contains `&&`, and both halves have to survive — the shell's `rm` with its quoting intact,
// then our `:ls`.
@(test)
test_cl_parse_seam_outside_the_quotes :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, `rm -rf 'a && b.txt' && :ls`)
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, steps[0].shell)
    testing.expect_value(t, steps[0].text, `rm -rf 'a && b.txt'`)
    testing.expect(t, !steps[1].shell)
    testing.expect_value(t, steps[1].text, "ls")
}

// The path builtins take the quoting the shell taught you, even though their argument is already
// the whole field: `:cd "my dir"` is the directory, not a directory whose name has quotes in it.
@(test)
test_cl_cd_accepts_quoted_path :: proc(t: ^testing.T) {
    dir := "/tmp/slopd cd quoted"
    os.make_directory(dir)
    defer os.remove(dir)

    a: app.App
    defer delete(a.project_root)

    app.cl_exec(&a, `:cd "/tmp/slopd cd quoted"`)
    testing.expect_value(t, a.project_root, dir)

    app.cl_exec(&a, `:cd '/tmp'`) // single quotes too
    testing.expect_value(t, a.project_root, "/tmp")

    app.cl_exec(&a, `:cd "/no/such/dir/zzz"`) // still refuses what is not there
    testing.expect_value(t, a.project_root, "/tmp")
}

// `:j` is the one builtin whose argument is a FIELD rather than the rest of the line, so a name
// with spaces has to be quoted — and the line number after it still has to be found.
@(test)
test_cl_jump_quoted_filename :: proc(t: ^testing.T) {
    dir := "/tmp/slopd_jump_quoted"
    os.make_directory(dir)
    path := "/tmp/slopd_jump_quoted/my notes.md"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("a\nb\nc\nd\n")) == nil)
    defer {os.remove(path);os.remove(dir)}

    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    defer delete(a.project_root)
    a.project_root = strings.clone(dir)

    app.cl_exec(&a, `:j "my notes.md" 3`)
    b := app.editor_current(&a.editor)
    testing.expect_value(t, b.path, path)
    testing.expect_value(t, b.cursors[b.primary].head.line, 2) // 1-based 3
}

// A quoted `&&` in a BUILTIN's argument is the builtin's text, not a seam either — the argument
// reaches it whole, quotes included, since a builtin takes the rest of its segment literally.
@(test)
test_cl_parse_quotes_in_builtin_args :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, `:grep "a && b" && :ls`)
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, !steps[0].shell)
    testing.expect_value(t, steps[0].text, `grep "a && b"`)
    testing.expect_value(t, steps[1].text, "ls")
}

// Coalescing rejoins adjacent shell segments with a real `&&` — and must not disturb what was
// inside their quotes on the way through.
@(test)
test_cl_parse_coalesce_keeps_quotes :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, `echo "x && y" && make && :ls`)
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect_value(t, steps[0].text, `echo "x && y" && make`)
    testing.expect_value(t, steps[1].text, "ls")
}

@(test)
test_cl_parse_put_keeps_args :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, ":put cat -n")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 1)
    testing.expect(t, !steps[0].shell, ":put is a builtin")
    testing.expect_value(t, steps[0].text, "put cat -n")
}

// Grep is the pair the whole change is about: `:grep` is the project search in our pane,
// `grep` is the program, in a terminal. Neither is a fallback for the other, and nothing
// inspects the name to decide — the sigil already did.
@(test)
test_cl_parse_grep_sigil_picks_the_pane_or_the_program :: proc(t: ^testing.T) {
    {
        a: app.App
        defer app.cl_chain_clear(&a)
        app.cl_parse(&a, ":grep foo")
        steps := a.cl_chain.steps[:]
        testing.expect_value(t, len(steps), 1)
        testing.expect(t, !steps[0].shell, ":grep is the Grep pane")
        testing.expect_value(t, steps[0].text, "grep foo")
    }
    {
        a: app.App
        defer app.cl_chain_clear(&a)
        app.cl_parse(&a, "grep -rn foo src/") // the real grep, flags and all
        steps := a.cl_chain.steps[:]
        testing.expect_value(t, len(steps), 1)
        testing.expect(t, steps[0].shell, "an unsigilled grep is the program")
        testing.expect_value(t, steps[0].text, "grep -rn foo src/")
    }
}

// A sigilled name Slopd does not know STOPS the chain (and says so in t1) rather than doing
// nothing: `:` was a promise that this word is ours, so a typo has to be answerable. This is
// also what keeps a name missing from cl_run_builtin's switch from failing silently.
@(test)
test_cl_unknown_builtin_stops_the_chain :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 1) // the report echoes into t1; stand one in so no shell is spawned
    defer {app.cl_chain_clear(&a);free_sessions(&a)}

    app.cl_exec(&a, ":frobnicate && :ls")
    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, ":ls must not run after an unknown name")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal) // the refusal was echoed into t1
    testing.expect_value(t, len(a.cl_chain.steps), 0)
}

// The sigil alone names nothing — an empty step, not an unknown one, and not a shell command
// either. A stray `:` submits as a no-op.
@(test)
test_cl_parse_bare_sigil_is_nothing :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, ":")
    testing.expect_value(t, len(a.cl_chain.steps), 0)
}

// Every view builtin must be a case in cl_run_builtin: an unknown one now stops the chain, so
// the tail `:ls` reaching the filetree is proof the name was recognised. `nm` is the one worth
// naming — it is a real binary on every Linux box (the GNU symbol lister), and before the sigil
// a missing case here would have quietly run THAT instead of rearranging the panes.
@(test)
test_cl_view_commands_are_builtins :: proc(t: ^testing.T) {
    for name in ([]string{"zen", "zm", "full", "fm", "normal", "nm"}) {
        a: app.App
        fake_sessions(&a, 1) // an unrecognised name would echo into t1; never spawn one
        defer {app.cl_chain_clear(&a);free_sessions(&a)}
        app.cl_exec(&a, strings.concatenate({":", name, " && :ls"}, context.temp_allocator))
        testing.expectf(t, a.aux_mode == app.AuxMode.FileTree, "%s is not a builtin", name)
    }
}

// --- multi-step chain runner (&& across several steps; exit codes simulated) ---

@(private = "file")
fake_live :: proc(a: ^app.App) -> ^app.Terminal {
    tm := new(app.Terminal)
    tm.alive = true // pty is -1, so injected writes are no-ops
    append(&a.terminals, tm)
    return tm
}

@(private = "file")
free_live :: proc(a: ^app.App, tm: ^app.Terminal) {
    app.cl_chain_clear(a)
    free(tm)
    delete(a.terminals)
}

// Answer the chain's current shell wait with `code`, then pump.
@(private = "file")
feed_exit :: proc(a: ^app.App, tm: ^app.Terminal, code: int) {
    tm.exit_ready = true
    tm.exit_id = a.cl_chain.wait_id
    tm.exit_code = code
    app.cl_chain_pump(a)
}

@(test)
test_cl_chain_multi_step_all_succeed :: proc(t: ^testing.T) {
    a: app.App
    tm := fake_live(&a)
    defer free_live(&a, tm)

    app.cl_exec(&a, "build && :cf && deploy && :ls") // shell, builtin, shell, builtin
    testing.expect(t, a.cl_chain.waiting, "waiting on `build`")
    feed_exit(&a, tm, 0) // build ok -> cf runs -> `deploy` injected
    testing.expect(t, a.cl_chain.waiting, "waiting on `deploy`")
    feed_exit(&a, tm, 0) // deploy ok -> ls runs

    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree) // final goto reached
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain finished")
}

@(test)
test_cl_chain_mid_failure_stops_rest :: proc(t: ^testing.T) {
    a: app.App
    tm := fake_live(&a)
    defer free_live(&a, tm)

    app.cl_exec(&a, "build && :cf && deploy && :ls")
    feed_exit(&a, tm, 0) // build ok -> cf -> `deploy` waits
    feed_exit(&a, tm, 7) // deploy FAILS -> ls must be skipped

    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, "ls skipped after a mid-chain failure")
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain cleared")
}

@(test)
test_cl_chain_first_failure_stops_all :: proc(t: ^testing.T) {
    a: app.App
    tm := fake_live(&a)
    defer free_live(&a, tm)
    a.aux_mode = app.AuxMode.Grep // a known starting pane

    app.cl_exec(&a, "build && :cf && :ls")
    feed_exit(&a, tm, 1) // build fails immediately -> no builtin runs

    testing.expect(t, a.aux_mode != app.AuxMode.Config, "cf skipped")
    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, "ls skipped")
    testing.expect(t, len(a.cl_chain.steps) == 0, "chain cleared")
}

// --- staged shell commands (the filetree chords build these, see input.odin) ---

// Quoting is the single-quote form, with an embedded quote closed/escaped/reopened, so a
// path with spaces or shell metacharacters survives the round trip to the shell.
@(test)
test_sh_quote :: proc(t: ^testing.T) {
    q :: proc(s: string) -> string {return app.sh_quote(s, context.temp_allocator)}
    testing.expect_value(t, q("/tmp/a.txt"), "'/tmp/a.txt'")
    testing.expect_value(t, q("/tmp/my file; rm -rf ~"), "'/tmp/my file; rm -rf ~'")
    testing.expect_value(t, q("/tmp/it's"), `'/tmp/it'\''s'`)
}

// A delete stages one `rm -rf` over every target, tailed by the `:ls` builtin so the listing
// re-reads once it exits 0 — the shell's half and ours in one readable line. No targets stages
// nothing at all.
@(test)
test_rm_command :: proc(t: ^testing.T) {
    one := app.rm_command({"/tmp/a b.txt"}, context.temp_allocator)
    testing.expect_value(t, one, "rm -rf '/tmp/a b.txt' && :ls")

    many := app.rm_command({"/tmp/x", "/tmp/y"}, context.temp_allocator)
    testing.expect_value(t, many, "rm -rf '/tmp/x' '/tmp/y' && :ls")

    testing.expect_value(t, app.rm_command(nil, context.temp_allocator), "")
}

// Properties is one `stat` run in t1, quoted like any other staged path. **--printf, not -c**:
// only --printf interprets the `\n`s, so a -c here would print four literal backslash-n's and
// one very long line — which is a mutation nothing else in the program would catch.
@(test)
test_properties_command :: proc(t: ^testing.T) {
    cmd := app.properties_command("/tmp/a b.txt", context.temp_allocator)
    testing.expect(t, strings.has_prefix(cmd, "stat --printf '"), "properties must use --printf")
    testing.expect(t, strings.contains(cmd, `\n`), "the format lost its newline escapes")
    testing.expect(t, strings.has_suffix(cmd, " -- '/tmp/a b.txt'"), "the path must be quoted last")

    // Every field the gesture promises: mode, size, owner, mtime and birth time.
    verbs := [?]string{"%A", "%s", "%U:%G", "%y", "%w"}
    for verb in verbs {
        testing.expectf(t, strings.contains(cmd, verb), "the format dropped %s", verb)
    }

    testing.expect_value(t, app.properties_command("", context.temp_allocator), "")
}

// Shift+Enter's run-vs-open split: an executable runs by its own path, a non-executable
// shell script runs under bash, and anything else has no run command (it goes to the
// desktop's default application instead).
@(test)
test_run_command :: proc(t: ^testing.T) {
    testing.expect_value(t, app.run_command("/tmp/tool", true, context.temp_allocator), "'/tmp/tool' ")
    testing.expect_value(t, app.run_command("/tmp/a.sh", true, context.temp_allocator), "'/tmp/a.sh' ")
    bashed := app.run_command("/tmp/a.sh", false, context.temp_allocator)
    testing.expect_value(t, bashed, "bash '/tmp/a.sh' ")
    testing.expect_value(t, app.run_command("/tmp/notes.md", false, context.temp_allocator), "")
    testing.expect_value(t, app.run_command("/tmp/clip.mp4", false, context.temp_allocator), "")
}

// --- the sudo save --- Ctrl+S (and `:w`) on a file permissions refuse stages ONE line that
// carries the buffer over as root. The line is a real chain, and every property that makes it
// safe is a property of the chain: the shell half runs where a password can be typed, and the
// `&&` gates the bookkeeping on its exit code.

@(test)
test_sudo_save_command :: proc(t: ^testing.T) {
    line := app.sudo_save_command("/run/user/1000/slopd-9-1-hosts", "/etc/hosts", context.temp_allocator)
    testing.expect_value(t, line, "sudo cp '/run/user/1000/slopd-9-1-hosts' '/etc/hosts' && :saved")

    // Both paths are quoted, so a space or a metacharacter in either is the shell's text and
    // not its syntax — `cp` must see two arguments whatever the file is called.
    odd := app.sudo_save_command("/tmp/a b", "/etc/x'y && rm -rf ~", context.temp_allocator)
    testing.expect_value(t, odd, `sudo cp '/tmp/a b' '/etc/x'\''y && rm -rf ~' && :saved`)

    testing.expect_value(t, app.sudo_save_command("", "/etc/hosts", context.temp_allocator), "")
    testing.expect_value(t, app.sudo_save_command("/tmp/x", "", context.temp_allocator), "")
}

// The staged line parses into a GATED chain: a shell step, then our builtin. cl_chain_pump runs
// the second only once the first reports exit 0, so a wrong sudo password leaves the buffer
// dirty instead of marking it saved. The `&&` inside the quoted path above is not a seam.
@(test)
test_sudo_save_line_is_a_gated_chain :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)

    app.cl_parse(&a, app.sudo_save_command("/run/x", "/etc/hosts", context.temp_allocator))
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, steps[0].shell, "the copy is the shell's, and needs a TTY for the password")
    testing.expect_value(t, steps[0].text, "sudo cp '/run/x' '/etc/hosts'")
    testing.expect(t, !steps[1].shell, "the tail is our builtin")
    testing.expect_value(t, steps[1].text, "saved")
}

// Staging writes the buffer to a PRIVATE copy and prefills the line pointing at it. The copy is
// byte-for-byte what a save would have written — it is the save, carried by another process.
@(test)
test_save_stage_sudo :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    app.cl_init(&a.cl)
    defer {app.editor_destroy(&a.editor);app.cl_destroy(&a)}

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "one\ntwo")
    b.final_newline = true
    b.path = strings.clone("/etc/slopd-not-written.conf") // never touched: only the LINE names it
    b.dirty = true

    testing.expect(t, app.save_stage_sudo(&a, b))
    testing.expect(t, b.save_tmp != "", "the staged copy was not recorded on the buffer")
    tmp := b.save_tmp

    data, err := os.read_entire_file_from_path(tmp, context.temp_allocator)
    testing.expect(t, err == nil, "the staged copy is not on disk")
    testing.expect_value(t, string(data), "one\ntwo\n")

    // The CL now holds the line, staged (ringed) rather than run — nothing happens until Enter.
    testing.expect(t, a.cl_active)
    testing.expect(t, a.cl.injected)
    testing.expect_value(
        t,
        app.doc_string(&a.cl.doc, context.temp_allocator),
        app.sudo_save_command(tmp, b.path, context.temp_allocator),
    )

    // Restaging replaces the copy rather than leaving a second one behind, and closing the
    // buffer takes the last one with it: root-readable copies of your work do not accumulate.
    testing.expect(t, app.save_stage_sudo(&a, b))
    testing.expect(t, b.save_tmp != tmp, "a restaging must not reuse the name")
    _, gone := os.read_entire_file_from_path(tmp, context.temp_allocator)
    testing.expect(t, gone != nil, "the superseded copy was left on disk")

    last := strings.clone(b.save_tmp, context.temp_allocator)
    app.buffer_drop_save_tmp(b)
    _, gone2 := os.read_entire_file_from_path(last, context.temp_allocator)
    testing.expect(t, gone2 != nil, "the staged copy outlived the buffer")
}

// `:saved` is the chain's last step: it verifies before it believes. The disk holding what the
// buffer holds is the whole claim — which is what the `sudo cp` just made true.
@(test)
test_cl_saved_verifies :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer {app.editor_destroy(&a.editor);app.cl_chain_clear(&a)}

    path := "slopd_cl_saved.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("mine\n")) == nil)
    defer os.remove(path)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "mine")
    b.final_newline = true
    b.path = strings.clone(path) // freed by editor_destroy
    b.dirty = true
    b.conflict = true

    app.cl_exec(&a, ":saved")
    testing.expect(t, !b.dirty, "the file on disk IS this buffer; it is not dirty")
    testing.expect(t, !b.conflict)

    // And on a buffer the disk does not match, it changes nothing at all. (The refusal echoes
    // into t1, which needs a terminal, so the claim is checked through buffer_matches_disk.)
    app.buffer_insert_rune(b, 'X')
    b.dirty = true
    testing.expect(t, !app.buffer_matches_disk(b))
    testing.expect(t, b.dirty)
}

// The staged `sudo cp` line carries no buffer name, and it can sit in the command line while
// you look at something else. Run there, its `:saved` tail must still reach the buffer whose
// file was written -- otherwise the write lands and the buffer stays marked unsaved with no
// way back but another save. Every unsaved buffer is verified against its own file, so the
// one that matches is the one that gets marked.
@(test)
test_cl_saved_reaches_the_buffer_that_was_written :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer {app.editor_destroy(&a.editor);app.cl_chain_clear(&a)}

    written := "slopd_cl_saved_bg.tmp"
    testing.expect(t, os.write_entire_file(written, transmute([]u8)string("theirs\n")) == nil)
    defer os.remove(written)

    // A second buffer joins the ring first: appending would move the first one's storage.
    extra: app.Buffer
    app.buffer_set_text(&extra, "unsaved work")
    extra.dirty = true
    append(&a.editor.buffers, extra)
    a.editor.active = 1

    // The buffer the sudo line was staged for: its file already holds its bytes.
    bg := &a.editor.buffers[0]
    app.buffer_set_text(bg, "theirs")
    bg.final_newline = true
    bg.path = strings.clone(written) // freed by editor_destroy
    bg.dirty = true

    front := &a.editor.buffers[1] // …and the one we are looking at instead
    testing.expect(t, app.editor_current(&a.editor) == front)

    app.cl_exec(&a, ":saved")
    testing.expect(t, !bg.dirty, ":saved must reach the buffer whose file was written")
    testing.expect(t, front.dirty, "a buffer the disk does not hold stays unsaved")
}

// --- the sudo open --- The mirror of the sudo save: a file we may not READ is the one open
// failure with a way forward, so it stages the line that unlocks it and opens it again.

@(test)
test_sudo_open_command :: proc(t: ^testing.T) {
    line := app.sudo_open_command("/etc/shadow", context.temp_allocator)
    testing.expect_value(t, line, "sudo chmod a+r '/etc/shadow' && :j /etc/shadow")

    // Each half is quoted for the reader it has: the shell for the chmod, `:j`'s own argument
    // form for the tail. A metacharacter is text to both.
    odd := app.sudo_open_command("/etc/x'y && rm -rf ~", context.temp_allocator)
    testing.expect_value(t, odd, `sudo chmod a+r '/etc/x'\''y && rm -rf ~' && :j "/etc/x'y && rm -rf ~"`)

    testing.expect_value(t, app.sudo_open_command("", context.temp_allocator), "")
}

// A gated chain, like the save's: the open waits on the chmod's exit code, so a wrong password
// opens nothing.
@(test)
test_sudo_open_line_is_a_gated_chain :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)

    app.cl_parse(&a, app.sudo_open_command("/etc/shadow", context.temp_allocator))
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, steps[0].shell, "the chmod is the shell's, and needs a TTY for the password")
    testing.expect_value(t, steps[0].text, "sudo chmod a+r '/etc/shadow'")
    testing.expect(t, !steps[1].shell, "the tail is our builtin")
    testing.expect_value(t, steps[1].text, "j /etc/shadow")
}

// Every gesture that opens goes through open_file, so the staging lives there: a refused read
// leaves the ring alone and puts the line up for review.
@(test)
test_open_stage_sudo :: proc(t: ^testing.T) {
    path := "slopd_unreadable.tmp"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)string("secret\n")) == nil)
    defer os.remove(path)
    testing.expect(t, os.chmod(path, os.Permissions{}) == nil)

    // As root an unreadable mode is not unreadable, so the case cannot be produced.
    if _, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
        return
    }

    a: app.App
    app.editor_init(&a.editor)
    app.cl_init(&a.cl)
    defer {app.editor_destroy(&a.editor);app.cl_destroy(&a)}

    app.open_file(&a, path)
    testing.expect_value(t, len(a.editor.buffers), 1) // the scratch buffer alone: nothing opened
    testing.expect_value(t, app.editor_current(&a.editor).path, "")

    testing.expect(t, a.cl_active)
    testing.expect(t, a.cl.injected, "the line must be staged, not run")
    testing.expect_value(t, val(&a), app.sudo_open_command(path, context.temp_allocator))

    // The other failures are not ours to answer: a missing file stages nothing.
    testing.expect(t, !app.open_stage_sudo(&a, "slopd-no-such-file.tmp"))
}

// `run_term` is the session the command line works in, not only the file pane's runs: a shell
// line goes there by default, and `:tN` is still the per-line override.
@(test)
test_run_term_is_the_command_lines_session :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    testing.expect_value(t, app.cl_term(&a), 1) // no config loaded: t1

    a.run_term = 3
    app.cl_parse(&a, "make")
    testing.expect_value(t, a.cl_chain.target, 3)

    app.cl_parse(&a, ":t2 make")
    testing.expect_value(t, a.cl_chain.target, 2) // one line, elsewhere
}
