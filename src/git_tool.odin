package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Alt+G (and the `gs` command-line builtin): hand the project root to whatever git tool the
// user already uses, and get out of the way. Nothing here parses git output, tracks repo
// state, or draws anything — that is the point. Two config keys do the whole job:
//
//   git_tool: lazygit      the command; the project root is appended as its last argument
//   git_term: 2            which terminal session to run it in — empty/0 spawns it detached
//
// The `git_term` split makes one setting cover both kinds of tool. A TUI (lazygit, tig,
// gitui) wants a PTY and a pane to live in, which a terminal session already is. A GUI
// (sublime_merge, gitkraken, gitg) wants its own window, and tying it to a PTY session
// would mean quitting Slopd kills it.

// Which terminal session a launch should land in. Pure — takes the session COUNT, not the
// App — so the clamping rule is a unit test: a number names a session, a number past the end
// means "the next one", exactly one however far past you aimed. Never answers below 1.
// Shared with run_in_term: `run_term` names a session by the same rule git_term does.
term_slot :: proc(count, want: int) -> int {
    return clamp(want, 1, min(count + 1, TERM_MAX))
}

// Launch the configured git tool at the project root. The empty-tool path is deliberate: a
// key that does nothing teaches you nothing, and "here is a terminal where your git lives"
// is the honest fallback for a program whose answer to advanced git is the terminal pane.
git_tool_open :: proc(a: ^App) {
    root := a.project_root

    // Detached: the tool owns its own window and outlives us. Nothing to focus, nothing
    // to draw — we fire it and forget it.
    if a.git_term <= 0 && a.git_tool != "" {
        git_tool_spawn(a.git_tool, root)
        return
    }

    // Terminal-hosted (or the no-tool fallback): surface the session, creating it when the
    // configured number names one past the end.
    slot := term_slot(term_count(a), a.git_term <= 0 ? term_count(a) + 1 : a.git_term)
    term_surface(a, slot)

    if a.git_tool == "" {
        return // no tool configured: the shell at the root IS the feature
    }
    t := term_current(a)
    if t == nil {
        return // the spawn failed; the pane already shows whatever went wrong
    }
    // The shell parses this, so a git_tool carrying its own flags ("sublime_merge -n")
    // works without us splitting anything. The root is quoted because a project path may
    // contain spaces and the shell would otherwise read it as two arguments.
    line := fmt.tprintf("%s %s\n", a.git_tool, sh_quote(root, context.temp_allocator))
    terminal_write(t, transmute([]u8)line)
}

// Spawn `cmd` detached, `cwd` appended as its final argument and used as its working dir.
// DOUBLE fork so the grandchild reparents to init and needs no reaping (a GUI tool may
// outlive us). Built BEFORE the fork: post-fork only pre-allocated memory is safe until exec.
@(private = "file")
git_tool_spawn :: proc(cmd, cwd: string) {
    fields := strings.fields(cmd, context.temp_allocator)
    if len(fields) == 0 {
        return
    }
    argv := make([dynamic]cstring, 0, len(fields) + 2, context.temp_allocator)
    for f in fields {
        append(&argv, strings.clone_to_cstring(f, context.temp_allocator))
    }
    append(&argv, strings.clone_to_cstring(cwd, context.temp_allocator))
    append(&argv, nil) // execvp terminator
    file := argv[0]
    dir := strings.clone_to_cstring(cwd, context.temp_allocator)

    pid := posix.fork()
    if pid < 0 {
        return
    }
    if pid == 0 {
        // CHILD — pre-allocated cstrings only, no Odin allocation, ending in exec.
        if posix.fork() == 0 {
            // GRANDCHILD: its own session, detached from our controlling terminal, with
            // stdio on /dev/null so a chatty tool cannot scribble over our stdout.
            posix.setsid()
            posix.chdir(dir) // best effort; a bad root is the tool's problem to report
            if fd := posix.open("/dev/null", {.RDWR}); fd >= 0 {
                posix.dup2(fd, posix.STDIN_FILENO)
                posix.dup2(fd, posix.STDOUT_FILENO)
                posix.dup2(fd, posix.STDERR_FILENO)
                if fd > posix.STDERR_FILENO {
                    posix.close(fd)
                }
            }
            posix.execvp(file, raw_data(argv[:]))
            posix._exit(127) // exec failed: a bad git_tool path lands here
        }
        posix._exit(0) // the intermediate child's whole job was to fork and leave
    }
    // PARENT — reap the intermediate child, which exits immediately. The grandchild is
    // init's problem now.
    status: c.int
    posix.waitpid(pid, &status, {})
}
