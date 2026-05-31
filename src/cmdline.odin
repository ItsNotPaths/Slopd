package main

import "core:strconv"
import "core:strings"

// The master command line: a single editable Line plus a history ring and an
// executor. It lives in the status strip (rendering) and is driven by input.odin
// while a.cl_active. Output never lands here — builtins mutate app state, shell
// commands route to a terminal (stubbed until libvterm).
CommandLine :: struct {
    line:     Line,
    history:  [dynamic]string,
    hist_idx: int, // index into history; == len(history) means the live edit
}

cl_destroy :: proc(a: ^App) {
    for s in a.cl.history {
        delete(s)
    }
    delete(a.cl.history)
    line_destroy(&a.cl.line)
}

cl_open :: proc(a: ^App) {
    a.cl_active = true
    line_clear(&a.cl.line)
    a.cl.hist_idx = len(a.cl.history)
}

// Pre-fill the command line with text and open it (filetree Shift+Enter -> cd).
cl_inject :: proc(a: ^App, text: string) {
    cl_open(a)
    line_set(&a.cl.line, text)
}

cl_cancel :: proc(a: ^App) {
    a.cl_active = false
    line_clear(&a.cl.line)
}

cl_submit :: proc(a: ^App) {
    input := strings.trim_space(line_string(&a.cl.line, context.temp_allocator))
    a.cl_active = false
    line_clear(&a.cl.line)
    if input == "" {
        return
    }
    append(&a.cl.history, strings.clone(input))
    cl_exec(a, input)
}

// Up: recall an older entry.
cl_history_prev :: proc(a: ^App) {
    if a.cl.hist_idx > 0 {
        a.cl.hist_idx -= 1
        line_set(&a.cl.line, a.cl.history[a.cl.hist_idx])
    }
}

// Down: recall a newer entry, or return to the live (empty) edit.
cl_history_next :: proc(a: ^App) {
    if a.cl.hist_idx < len(a.cl.history) {
        a.cl.hist_idx += 1
        if a.cl.hist_idx == len(a.cl.history) {
            line_clear(&a.cl.line)
        } else {
            line_set(&a.cl.line, a.cl.history[a.cl.hist_idx])
        }
    }
}

// Parses and dispatches a submitted command. Builtins (goto + cd) are handled
// for real; shell commands and tN-injection are stubbed until terminals exist.
cl_exec :: proc(a: ^App, input: string) {
    fields := strings.fields(input, context.temp_allocator)
    if len(fields) == 0 {
        return
    }
    cmd := fields[0]

    // tN prefix -> focus terminal N. A trailing command would be injected there
    // (stub for now); a bare tN is just a goto.
    if len(cmd) >= 2 && cmd[0] == 't' && all_digits(cmd[1:]) {
        n, _ := strconv.parse_int(cmd[1:], 10)
        term_focus(a, n)
        return
    }

    switch cmd {
    case "ls": // goto filetree
        a.aux_mode = .FileTree
        a.focus = .Aux
    case "gs": // goto git
        a.aux_mode = .Git
        a.focus = .Aux
    case "cd": // builtin: set project root + t1 cwd (stub until terminals exist)
    case: // shell command -> inject into t1 (stub), surface the terminal
        term_focus(a, 1)
    }
}

// Switch to terminal session n (1-based), surfacing the terminal pane. Shared by
// the command line (tN) and Alt+1..9. Clamps n into the existing session range.
term_focus :: proc(a: ^App, n: int) {
    a.aux_mode = .Terminal
    a.focus = .Aux
    if a.term_count > 0 {
        a.term_active = clamp(n - 1, 0, a.term_count - 1)
    }
}

@(private = "file")
all_digits :: proc(s: string) -> bool {
    if len(s) == 0 {
        return false
    }
    for c in s {
        if c < '0' || c > '9' {
            return false
        }
    }
    return true
}
