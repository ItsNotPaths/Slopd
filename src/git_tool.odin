package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Alt+G (and the `gs` command-line builtin): hand the project root to whatever git tool
// the user already uses, and get out of the way.
//
// This replaced a built-in git pane — a Sublime-Merge-lite sidebar + diff viewer + commit
// box, about 3,000 lines of it. The reasoning for the swap is worth keeping: everybody
// already has a git workflow, and a second-best copy of one inside a text editor competes
// with it rather than serving it. Two config keys now do the whole job:
//
//   git_tool: lazygit      the command; the project root is appended as its last argument
//   git_term: 2            which terminal session to run it in — empty/0 spawns it detached
//
// The `git_term` split is what makes one setting cover both kinds of tool. A TUI (lazygit,
// tig, gitui) wants a PTY and a pane to live in, which a Slopd terminal session already is.
// A GUI (sublime_merge, gitkraken, gitg) wants its own window and no terminal at all, and
// tying it to a PTY session would mean quitting Slopd kills it. Neither is the default for
// the other, so the user says which.
//
// Nothing here parses git output, tracks repo state, or draws anything. That is the point.

// Which terminal session a launch should land in. Pure — takes the session COUNT rather
// than the App — so the clamping rule is a unit test rather than something you confirm by
// opening terminals.
//
// The rule: a number names a session, and a number past the end means "the next one".
// Asking for session 8 with three open opens the fourth rather than failing or silently
// landing on the third — you asked for a session that was not there, so you get a new one,
// and you get exactly one no matter how far past the end you aimed. Zero and below mean
// the caller is not using the terminal path at all (see git_tool_open); this still answers
// with a legal slot so callers cannot end up with a zero.
git_term_slot :: proc(count, want: int) -> int {
    return clamp(want, 1, min(count + 1, TERM_MAX))
}

// Launch the configured git tool at the project root.
//
// Three paths, and the empty-tool one is deliberate rather than an oversight: with nothing
// configured, Alt+G opens a shell at the repo root. A key that does nothing at all teaches
// you nothing about why, and "here is a terminal where your git lives" is the honest
// fallback for a program whose answer to advanced git is the terminal pane.
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
    slot := git_term_slot(term_count(a), a.git_term <= 0 ? term_count(a) + 1 : a.git_term)
    if term_count(a) < slot {
        term_new(a) // slot is at most count+1, so one session is always enough
    }
    term_focus(a, slot)

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

// Spawn `cmd` detached, with `cwd` appended as its final argument and as its working
// directory. DOUBLE fork: the grandchild is reparented to init, so nothing here has to reap
// it later — a GUI tool may outlive the editor by hours, and a zombie per launch (or a
// SIGCHLD handler competing with the terminal sessions' own children) is a worse trade than
// one extra fork.
//
// Everything the child touches is built BEFORE the fork, for the reason terminal_spawn
// spells out: in a multithreaded process the child may only use pre-allocated memory until
// exec, because another thread may hold the allocator's lock at the moment we fork.
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
