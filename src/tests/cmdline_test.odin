package tests

import app ".."
import "core:testing"

@(private = "file")
val :: proc(l: ^app.Line) -> string {
    return app.line_string(l, context.temp_allocator)
}

@(test)
test_cl_goto :: proc(t: ^testing.T) {
    a: app.App
    a.term_count = 3
    app.cl_exec(&a, "ls")
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.focus, app.Focus.Aux)
    app.cl_exec(&a, "gs")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Git)
}

@(test)
test_cl_terminal_prefix :: proc(t: ^testing.T) {
    a: app.App
    a.term_count = 3
    app.cl_exec(&a, "t2")
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 1)
    app.cl_exec(&a, "t9") // clamps to the last session
    testing.expect_value(t, a.term_active, 2)
}

@(test)
test_cl_shell_stub :: proc(t: ^testing.T) {
    a: app.App
    a.term_count = 2
    app.cl_exec(&a, "echo hi") // unknown -> shell -> t1
    testing.expect_value(t, a.aux_mode, app.AuxMode.Terminal)
    testing.expect_value(t, a.term_active, 0)
}

@(test)
test_cl_history :: proc(t: ^testing.T) {
    a: app.App
    a.term_count = 1
    defer app.cl_destroy(&a)

    app.line_set(&a.cl.line, "ls")
    app.cl_submit(&a)
    app.line_set(&a.cl.line, "gs")
    app.cl_submit(&a)

    app.cl_open(&a) // hist_idx parked at the live edit
    app.cl_history_prev(&a);testing.expect_value(t, val(&a.cl.line), "gs")
    app.cl_history_prev(&a);testing.expect_value(t, val(&a.cl.line), "ls")
    app.cl_history_next(&a);testing.expect_value(t, val(&a.cl.line), "gs")
    app.cl_history_next(&a);testing.expect_value(t, val(&a.cl.line), "") // back to live
}
