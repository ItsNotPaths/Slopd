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

// The quit/write builtins guard on the unsaved ring (ring_dirty_count): an unnamed
// buffer can't be written yet, so `wa` leaves it dirty; giving it a path lets `wa`
// save it and clear the ring. The window-closing paths (clean `q` / `q!`) and the
// t1-echo refusal need a live GLFW window / terminal, so they aren't exercised here.
@(test)
test_cl_write_ring :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)

    b := app.editor_current(&a.editor)

    // Unnamed: `wa` can't save it, so it stays in the ring.
    b.dirty = true
    app.cl_exec(&a, "wa")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 1)

    // Named: `wa` writes it and the ring clears.
    path := "/tmp/slopd_quit_test.txt"
    b.path = strings.clone(path)
    b.dirty = true
    app.cl_exec(&a, "wa")
    testing.expect_value(t, app.ring_dirty_count(&a.editor), 0)
    os.remove(path)
}

@(test)
test_cl_goto :: proc(t: ^testing.T) {
    a: app.App
    app.cl_exec(&a, "ls")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.focus, app.Focus.Aux)
    app.cl_exec(&a, "gs")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Git)
}

@(test)
test_cl_jump :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9") // 10 lines

    app.cl_exec(&a, "j 3") // absolute, 1-based -> line index 2
    testing.expect_value(t, b.cursors[b.primary].head.line, 2)
    testing.expect_value(t, a.focus, app.Focus.Editor)

    app.cl_exec(&a, "jump 6") // `jump` alias, line index 5
    testing.expect_value(t, b.cursors[b.primary].head.line, 5)

    app.cl_exec(&a, "j +2") // relative down from 5
    testing.expect_value(t, b.cursors[b.primary].head.line, 7)

    app.cl_exec(&a, "j -4") // relative up from 7
    testing.expect_value(t, b.cursors[b.primary].head.line, 3)

    app.cl_exec(&a, "j 999") // clamps to the last line
    testing.expect_value(t, b.cursors[b.primary].head.line, 9)

    app.cl_exec(&a, "j -999") // clamps to the first line
    testing.expect_value(t, b.cursors[b.primary].head.line, 0)
}

@(test)
test_cl_terminal_prefix :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 3)
    defer free_sessions(&a)
    app.cl_exec(&a, "t2")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 1)
    app.cl_exec(&a, "t9") // clamps to the last session
    testing.expect_value(t, a.term_active, 2)
}

@(test)
test_cl_shell_stub :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 2)
    defer free_sessions(&a)
    app.cl_exec(&a, "echo hi") // unknown -> shell -> t1
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 0)
}

@(test)
test_cl_history :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_destroy(&a)

    app.doc_set_text(&a.cl.doc, "ls")
    app.cl_submit(&a)
    app.doc_set_text(&a.cl.doc, "gs")
    app.cl_submit(&a)

    app.cl_open(&a) // hist_idx parked at the live edit
    app.cl_history_prev(&a);testing.expect_value(t, val(&a), "gs")
    app.cl_history_prev(&a);testing.expect_value(t, val(&a), "ls")
    app.cl_history_next(&a);testing.expect_value(t, val(&a), "gs")
    app.cl_history_next(&a);testing.expect_value(t, val(&a), "") // back to live
}

// The command line's extensible ghost hint: a recognised command with no argument yet shows
// its arg example; once an argument is typed (or the command is unknown) the hint drops.
@(test)
test_cl_ghost_hint :: proc(t: ^testing.T) {
    testing.expect_value(t, app.cl_ghost_hint("reload"), "(y/n)")
    testing.expect_value(t, app.cl_ghost_hint("reload "), "(y/n)") // trailing space, no arg yet
    testing.expect_value(t, app.cl_ghost_hint("reload y"), "") // argument typed -> no hint
    testing.expect_value(t, app.cl_ghost_hint("ls"), "") // recognised command, no hint defined
    testing.expect_value(t, app.cl_ghost_hint(""), "") // empty line
}

// The `reload` builtin settles a pending disk-change conflict: `reload n` keeps the edits
// (and caches), `reload y` re-reads from disk. With no conflict, `reload` is a manual refresh.
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

    // `reload n` keeps my edits and clears the conflict.
    app.cl_exec(&a, "reload n")
    testing.expect(t, !b.conflict)
    testing.expect_value(t, app.line_string(&b.lines[0], context.temp_allocator), "mine")

    // Re-raise, then `reload y` takes the disk version (edits discarded, buffer clean).
    b.conflict = true
    app.cl_exec(&a, "reload y")
    testing.expect(t, !b.conflict)
    testing.expect(t, !b.dirty)
    testing.expect_value(t, app.line_string(&b.lines[0], context.temp_allocator), "disk")

    // With no conflict, a bare `reload` is a manual re-read from disk (discards edits).
    app.buffer_set_text(b, "scratch")
    b.dirty = true
    app.cl_exec(&a, "reload")
    testing.expect_value(t, app.line_string(&b.lines[0], context.temp_allocator), "disk")
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

// --- chain parser (cl_parse: pure, no shell) ---

@(test)
test_cl_parse_segments :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "git add . && gs")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, steps[0].shell, "first segment is shell")
    testing.expect_value(t, steps[0].text, "git add .")
    testing.expect(t, !steps[1].shell, "gs is a builtin")
    testing.expect_value(t, steps[1].text, "gs")
}

@(test)
test_cl_parse_coalesce_shell :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "a && b && gs") // adjacent shell segments keep their &&
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
    app.cl_parse(&a, "t3 git status") // tN sets the chain's shell target
    testing.expect_value(t, a.cl_chain.target, 3)
    testing.expect_value(t, len(a.cl_chain.steps), 1)
    testing.expect(t, a.cl_chain.steps[0].shell, "remainder is a shell command")
    testing.expect_value(t, a.cl_chain.steps[0].text, "git status")
}

@(test)
test_cl_parse_cd_tu_builtins :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "cd src && tu") // both are captured builtins, never shell
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect(t, !steps[0].shell, "cd is a builtin")
    testing.expect_value(t, steps[0].text, "cd src")
    testing.expect(t, !steps[1].shell, "tu is a builtin")
    testing.expect_value(t, steps[1].text, "tu")
}

// `cd` sets the project root: absolute paths land verbatim, relative ones resolve
// against the current root, and a non-directory leaves the root untouched.
@(test)
test_cl_cd_project_root :: proc(t: ^testing.T) {
    a: app.App
    defer delete(a.project_root)
    app.cl_exec(&a, "cd /tmp")
    testing.expect_value(t, a.project_root, "/tmp")
    app.cl_exec(&a, "cd ..") // relative: /tmp/.. -> /
    testing.expect_value(t, a.project_root, "/")
    app.cl_exec(&a, "cd /no/such/dir/zzz") // typo: root unchanged
    testing.expect_value(t, a.project_root, "/")
}

// A config-driven CL action either stages its command (opens the CL, runs nothing) or
// runs it at once (no CL) — the filetree folder cd via a.folder_cd_run.
@(test)
test_cl_dispatch_stage_vs_run :: proc(t: ^testing.T) {
    a: app.App
    defer delete(a.project_root)
    defer app.cl_destroy(&a) // staging opens the CL doc; free it (else it leaks)

    app.cl_dispatch(&a, "cd /tmp", false) // stage
    testing.expect(t, a.cl_active, "stage opens the command line")
    testing.expect_value(t, val(&a), "cd /tmp")
    testing.expect_value(t, a.project_root, "") // not executed
    app.cl_cancel(&a)

    app.cl_dispatch(&a, "cd /tmp", true) // run
    testing.expect(t, !a.cl_active, "run leaves the command line closed")
    testing.expect_value(t, a.project_root, "/tmp") // executed
}

// --- chain runner (&& honours exit status; exit codes simulated, no shell) ---

@(test)
test_cl_chain_success_runs_builtin :: proc(t: ^testing.T) {
    a: app.App
    tm := new(app.Terminal)
    tm.alive = true // fake live session; pty is -1 so writes are no-ops
    append(&a.terminals, tm)
    defer {app.cl_chain_clear(&a);free(tm);delete(a.terminals)}

    app.cl_exec(&a, "build_thing && gs")
    testing.expect(t, a.cl_chain.waiting, "should block on the shell step's exit")

    tm.exit_ready = true // shell reports success
    tm.exit_id = a.cl_chain.wait_id
    tm.exit_code = 0
    app.cl_chain_pump(&a)

    testing.expect_value(t, a.aux_mode, app.AuxMode.Git) // gs ran
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain finished")
}

@(test)
test_cl_chain_failure_short_circuits :: proc(t: ^testing.T) {
    a: app.App
    tm := new(app.Terminal)
    tm.alive = true
    append(&a.terminals, tm)
    defer {app.cl_chain_clear(&a);free(tm);delete(a.terminals)}

    app.cl_exec(&a, "build_thing && gs")
    testing.expect(t, a.cl_chain.waiting, "should block on the shell step's exit")

    tm.exit_ready = true // shell reports failure
    tm.exit_id = a.cl_chain.wait_id
    tm.exit_code = 1
    app.cl_chain_pump(&a)

    testing.expect(t, a.aux_mode != app.AuxMode.Git, "gs must be skipped on failure")
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain cleared")
}

// --- more parser combinations (cl_parse: pure, no shell) ---

@(test)
test_cl_parse_builtin_then_shell :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "gs && echo hi")
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
    app.cl_parse(&a, "make && gs && ./run")
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
test_cl_parse_bare_tN_is_goto_only :: proc(t: ^testing.T) {
    a: app.App
    fake_sessions(&a, 4)
    defer {app.cl_chain_clear(&a);free_sessions(&a)}
    app.cl_parse(&a, "t4")
    testing.expect_value(t, a.cl_chain.target, 4)
    testing.expect_value(t, len(a.cl_chain.steps), 0) // no command — just the goto
}

@(test)
test_cl_parse_empty_segments_skipped :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "gs &&  && ls") // stray empty segment from a double &&
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 2)
    testing.expect_value(t, steps[0].text, "gs")
    testing.expect_value(t, steps[1].text, "ls")
}

@(test)
test_cl_parse_put_keeps_args :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "put cat -n")
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 1)
    testing.expect(t, !steps[0].shell, "put is a builtin")
    testing.expect_value(t, steps[0].text, "put cat -n")
}

@(test)
test_cl_parse_grep_is_builtin :: proc(t: ^testing.T) {
    a: app.App
    defer app.cl_chain_clear(&a)
    app.cl_parse(&a, "grep foo") // hijacked into the project search, never the shell
    steps := a.cl_chain.steps[:]
    testing.expect_value(t, len(steps), 1)
    testing.expect(t, !steps[0].shell, "grep is a builtin")
    testing.expect_value(t, steps[0].text, "grep foo")
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

    app.cl_exec(&a, "build && gs && deploy && ls") // shell, builtin, shell, builtin
    testing.expect(t, a.cl_chain.waiting, "waiting on `build`")
    feed_exit(&a, tm, 0) // build ok -> gs runs -> `deploy` injected
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

    app.cl_exec(&a, "build && gs && deploy && ls")
    feed_exit(&a, tm, 0) // build ok -> gs -> `deploy` waits
    feed_exit(&a, tm, 7) // deploy FAILS -> ls must be skipped

    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, "ls skipped after a mid-chain failure")
    testing.expect(t, !a.cl_chain.waiting && len(a.cl_chain.steps) == 0, "chain cleared")
}

@(test)
test_cl_chain_first_failure_stops_all :: proc(t: ^testing.T) {
    a: app.App
    tm := fake_live(&a)
    defer free_live(&a, tm)
    a.aux_mode = app.AuxMode.Config // a known starting pane

    app.cl_exec(&a, "build && gs && ls")
    feed_exit(&a, tm, 1) // build fails immediately -> no builtin runs

    testing.expect(t, a.aux_mode != app.AuxMode.Git, "gs skipped")
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

// A delete stages one `rm -rf` over every target, tailed by the `ls` builtin so the
// listing re-reads once it exits 0. No targets stages nothing at all.
@(test)
test_rm_command :: proc(t: ^testing.T) {
    one := app.rm_command({"/tmp/a b.txt"}, context.temp_allocator)
    testing.expect_value(t, one, "rm -rf '/tmp/a b.txt' && ls")

    many := app.rm_command({"/tmp/x", "/tmp/y"}, context.temp_allocator)
    testing.expect_value(t, many, "rm -rf '/tmp/x' '/tmp/y' && ls")

    testing.expect_value(t, app.rm_command(nil, context.temp_allocator), "")
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
