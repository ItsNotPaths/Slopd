package tests

import app ".."
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Real-shell integration: drive cl_exec against an actual forked shell (lazily
// spawned by the first injection) and pump the && chain the way the main loop does.
// These verify command behaviour the deterministic tests can't — real exit codes,
// real output, and the pager-neutralization that keeps a chained `git status` from
// hanging. Commands are fast + deterministic; the polls carry a generous timeout.

@(private = "file")
TIMEOUT_STEPS :: 250 // * 20ms = ~5s budget per wait

@(private = "file")
teardown :: proc(a: ^app.App) {
    app.cl_chain_clear(a)
    app.term_destroy_all(a) // kill the shell + join its reader thread
}

// Run a CL line and pump its chain to completion (or timeout). Returns whether the
// chain finished.
@(private = "file")
run_cl :: proc(a: ^app.App, line: string) -> bool {
    app.cl_exec(a, line)
    for _ in 0 ..< TIMEOUT_STEPS {
        for term in a.terminals {
            app.terminal_drain(term)
        }
        app.cl_chain_pump(a)
        if !a.cl_chain.waiting && len(a.cl_chain.steps) == 0 {
            return true
        }
        time.sleep(20 * time.Millisecond)
    }
    return false
}

@(private = "file")
grid_text :: proc(term: ^app.Terminal, alloc := context.temp_allocator) -> string {
    sb := strings.builder_make(alloc)
    for row in 0 ..< term.rows {
        for col in 0 ..< term.cols {
            if r := app.terminal_cell_rune(term, row, col); r >= 0x20 && r < 0x7f {
                strings.write_rune(&sb, r)
            }
        }
    }
    return strings.to_string(sb)
}

// Poll the (single) session's grid until it contains `sub`.
@(private = "file")
wait_grid :: proc(a: ^app.App, sub: string) -> bool {
    for _ in 0 ..< TIMEOUT_STEPS {
        free_all(context.temp_allocator)
        for term in a.terminals {
            app.terminal_drain(term)
            if strings.contains(grid_text(term), sub) {
                return true
            }
        }
        time.sleep(20 * time.Millisecond)
    }
    return false
}

@(test)
test_sh_chain_success_advances :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    testing.expect(t, run_cl(&a, "true && :ls"), "chain should finish")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree) // :ls ran after `true`
}

@(test)
test_sh_chain_failure_short_circuits :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    testing.expect(t, run_cl(&a, "false && :ls"), "chain should finish")
    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, ":ls skipped after `false`")
}

@(test)
test_sh_chain_specific_exit_code :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    testing.expect(t, run_cl(&a, "sh -c 'exit 3' && :ls"), "chain should finish")
    testing.expect(t, a.aux_mode != app.AuxMode.FileTree, "non-zero exit skips the goto")
}

@(test)
test_sh_chain_multi_wait :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    // Two real waited steps (shell, builtin, shell, builtin).
    testing.expect(t, run_cl(&a, "true && :gs && true && :ls"), "two-wait chain should finish")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
}

@(test)
test_sh_chain_coalesced_both_run :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    // Adjacent shell segments coalesce into one injection joined by &&; reaching the
    // final `:ls` (FileTree) proves both ran and exited 0 in the shell.
    testing.expect(t, run_cl(&a, "echo a && echo b && :ls"), "coalesced chain should finish")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
}

@(test)
test_sh_chain_pager_neutralized :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    // git status forced to page through a BLOCKING pager. The runner neutralizes the
    // pager for waited steps, so this must finish (and reach :ls) rather than hang.
    // Outside a work tree git exits non-zero and the `&&` stops the chain, which would fail
    // this for the wrong reason: the pager is what is under test, not the checkout.
    if !inside_git_work_tree() {
        fmt.println("[skip] not inside a git work tree; `git status` cannot page")
        return
    }
    line := "git -c pager.status=true -c core.pager='less -+F' status && :ls"
    testing.expect(t, run_cl(&a, line), "pager-neutralized chain must not hang")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
}

@(test)
test_sh_plain_command_executes :: proc(t: ^testing.T) {
    a: app.App
    defer teardown(&a)
    // A lone command injects plain (no sentinel). Arithmetic output differs from the
    // echoed input, so finding it proves the shell actually ran the command.
    app.cl_exec(&a, "echo R$((6 * 7))X")
    testing.expect(t, wait_grid(&a, "R42X"), "arithmetic output proves execution")
}

@(private = "file")
inside_git_work_tree :: proc() -> bool {
    st, _, _, err := os.process_exec(
        os.Process_Desc{command = {"git", "rev-parse", "--is-inside-work-tree"}},
        context.temp_allocator,
    )
    return err == nil && st.exit_code == 0
}
