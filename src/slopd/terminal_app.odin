package main
import "../pty"


// Sessions. A Terminal is a PTY and a grid and knows nothing of the program holding it; the
// list of them, which one is current, and what closing the last one means, are the App's.

term_count :: proc(a: ^App) -> int {
    return len(a.terminals)
}

term_current :: proc(a: ^App) -> ^pty.Terminal {
    if a.term_active < 0 || a.term_active >= len(a.terminals) {
        return nil
    }
    return a.terminals[a.term_active]
}

// Spawn the first session only when the pane is shown, so no terminal costs no shell.
term_ensure :: proc(a: ^App) {
    if len(a.terminals) == 0 {
        term_new(a)
    }
}

term_new :: proc(a: ^App) {
    if len(a.terminals) >= pty.TERM_MAX {
        return
    }
    t := new(pty.Terminal)
    if !pty.terminal_spawn(t, pty.TERM_INIT_ROWS, pty.TERM_INIT_COLS, a.project_root) {
        free(t)
        return
    }
    append(&a.terminals, t)
    a.term_active = len(a.terminals) - 1
}

// Close the active session (Alt+Q), keeping at least one alive.
term_close_active :: proc(a: ^App) {
    if len(a.terminals) <= 1 {
        return
    }
    t := a.terminals[a.term_active]
    if a.cl_chain.wait_term == t {
        cl_chain_clear(a) // a pending chain was waiting on this session
    }
    pty.terminal_close(t)
    free(t)
    ordered_remove(&a.terminals, a.term_active)
    if a.term_active >= len(a.terminals) {
        a.term_active = len(a.terminals) - 1
    }
}

term_destroy_all :: proc(a: ^App) {
    for t in a.terminals {
        pty.terminal_close(t)
        free(t)
    }
    delete(a.terminals)
}

// The focused session if live. `alive` is read without the lock — a stale read only sends a
// keystroke to an exited shell, where the write to the closed master is dropped.
term_focused :: proc(a: ^App) -> ^pty.Terminal {
    if a.cl_active { // the command line overlays the pane and owns keys
        return nil
    }
    if a.focus != .Aux || a.aux_mode != .Terminal {
        return nil
    }
    t := term_current(a)
    if t == nil || !pty.terminal_alive(t) {
        return nil
    }
    return t
}

// Owner of the line-selection / copy keys: the active terminal when focused, alive or not
// (you can still copy a dead shell's output).
term_sel_target :: proc(a: ^App) -> ^pty.Terminal {
    if a.cl_active || a.focus != .Aux || a.aux_mode != .Terminal {
        return nil
    }
    return term_current(a)
}
