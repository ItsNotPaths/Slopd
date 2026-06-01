package main

import "core:strconv"
import "core:strings"

// The master command line: a one-line Doc (the shared multi-cursor editing core,
// so every motion/edit op is reused from the buffer — Enter just submits instead
// of splitting) plus a history ring and an executor. It lives in the status strip
// (rendering) and is driven by input.odin while a.cl_active. Output never lands
// here — builtins mutate app state, shell commands route to a terminal (stubbed
// until libvterm).
CommandLine :: struct {
    using doc: Doc,
    history:   [dynamic]string,
    hist_idx:  int, // index into history; == len(history) means the live edit
}

cl_init :: proc(cl: ^CommandLine) {
    doc_init(&cl.doc)
}

cl_destroy :: proc(a: ^App) {
    for s in a.cl.history {
        delete(s)
    }
    delete(a.cl.history)
    doc_destroy(&a.cl.doc)
}

cl_open :: proc(a: ^App) {
    a.cl_active = true
    doc_clear(&a.cl.doc)
    a.cl.hist_idx = len(a.cl.history)
}

// Pre-fill the command line with text and open it (filetree Shift+Enter -> cd).
cl_inject :: proc(a: ^App, text: string) {
    cl_open(a)
    cl_recall(a, text)
}

cl_cancel :: proc(a: ^App) {
    a.cl_active = false
    doc_clear(&a.cl.doc)
}

cl_submit :: proc(a: ^App) {
    input := strings.trim_space(doc_string(&a.cl.doc, context.temp_allocator))
    a.cl_active = false
    doc_clear(&a.cl.doc)
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
        cl_recall(a, a.cl.history[a.cl.hist_idx])
    }
}

// Down: recall a newer entry, or return to the live (empty) edit.
cl_history_next :: proc(a: ^App) {
    if a.cl.hist_idx < len(a.cl.history) {
        a.cl.hist_idx += 1
        if a.cl.hist_idx == len(a.cl.history) {
            doc_clear(&a.cl.doc)
        } else {
            cl_recall(a, a.cl.history[a.cl.hist_idx])
        }
    }
}

// Swap the line's text and park the cursor at the end (recall / inject).
@(private = "file")
cl_recall :: proc(a: ^App, text: string) {
    doc_set_text(&a.cl.doc, text)
    doc_cursor_to_end(&a.cl.doc)
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
        term_focus(a, strconv.parse_int(cmd[1:], 10) or_else 0)
        return
    }

    switch cmd {
    case "ls": // goto filetree
        set_aux(a, .FileTree)
    case "gs": // goto git
        set_aux(a, .Git)
    case "zen", "zm": // toggle zen mode (full-width editor; aux on focus only)
        view_toggle_zen(a)
    case "cd": // builtin: set project root + t1 cwd (stub until terminals exist)
    case: // shell command -> inject into t1 (stub), surface the terminal
        term_focus(a, 1)
    }
}

// Switch to terminal session n (1-based), surfacing the terminal pane. Shared by
// the command line (tN) and Alt+1..9. Clamps n into the existing session range.
term_focus :: proc(a: ^App, n: int) {
    a.aux_mode = .Terminal
    set_focus(a, .Aux)
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
