package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Alt+G / `:gs`: hand the project root to whatever git tool the user already uses. Nothing here
// parses git output, tracks repo state or draws anything. Two config keys do the job:
//
//   git_tool: lazygit      the command; the project root is appended as its last argument
//   git_term: 2            which session to run it in — empty/0 spawns it detached
//
// The split covers both kinds of tool: a TUI wants a PTY and a pane, which a session already
// is, while a GUI wants its own window and would die with Slopd if tied to a session.

// Takes the session count rather than the App, so the clamping rule is a unit test: a number
// names a session, one past the end means "the next", however far past you aimed. Never
// below 1. Shared with run_in_term.
term_slot :: proc(count, want: int) -> int {
    return clamp(want, 1, min(count + 1, TERM_MAX))
}

// The empty-tool path is deliberate: a key that does nothing teaches you nothing, and a
// terminal at the root is the honest fallback.
git_tool_open :: proc(a: ^App) {
    root := a.project_root

    // Detached: the tool owns its window and outlives us.
    if a.git_term <= 0 && a.git_tool != "" {
        git_tool_spawn(a.git_tool, root)
        return
    }

    // Terminal-hosted, or the no-tool fallback.
    slot := term_slot(term_count(a), a.git_term <= 0 ? term_count(a) + 1 : a.git_term)
    term_surface(a, slot)

    if a.git_tool == "" {
        return // the shell at the root IS the feature
    }
    t := term_current(a)
    if t == nil {
        return // the pane already shows whatever went wrong
    }
    // The shell parses this, so a git_tool carrying its own flags works unsplit. The root is
    // quoted because a project path may contain spaces.
    line := fmt.tprintf("%s %s\n", a.git_tool, sh_quote(root, context.temp_allocator))
    terminal_write(t, transmute([]u8)line)
}

// `cwd` is appended as the final argument and used as the working dir. Double fork so the
// grandchild reparents to init and needs no reaping. Built BEFORE the fork: post-fork only
// pre-allocated memory is safe until exec.
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
            // GRANDCHILD: its own session, stdio on /dev/null so a chatty tool cannot
            // scribble over our stdout.
            posix.setsid()
            posix.chdir(dir) // best effort
            if fd := posix.open("/dev/null", {.RDWR}); fd >= 0 {
                posix.dup2(fd, posix.STDIN_FILENO)
                posix.dup2(fd, posix.STDOUT_FILENO)
                posix.dup2(fd, posix.STDERR_FILENO)
                if fd > posix.STDERR_FILENO {
                    posix.close(fd)
                }
            }
            posix.execvp(file, raw_data(argv[:]))
            posix._exit(127) // exec failed
        }
        posix._exit(0) // the intermediate child's whole job was to fork
    }
    // PARENT — reap the intermediate child; the grandchild is init's now.
    status: c.int
    posix.waitpid(pid, &status, {})
}
