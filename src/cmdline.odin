package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

// Pre-fill the command line with text and open it (a UI gesture staging a command
// for the user to review and run with Enter — e.g. the filetree folder cd).
cl_inject :: proc(a: ^App, text: string) {
    cl_open(a)
    cl_recall(a, text)
}

// A UI gesture that produces a full command line either STAGES it (cl_inject: pre-fill
// the CL and wait for the user's Enter) or RUNS it immediately — chosen per action by
// config. Staging is the reviewable default; `run` is the insta-enter shortcut. Used
// by the filetree folder cd (a.folder_cd_run); other inject sites that pre-fill an
// INCOMPLETE command for the user to finish (e.g. Alt+W's "j ") stay cl_inject.
cl_dispatch :: proc(a: ^App, text: string, run: bool) {
    if run {
        cl_exec(a, text)
    } else {
        cl_inject(a, text)
    }
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

// A submitted line is a chain of `&&` segments, each a Slopd BUILTIN (goto/zen/put,
// run here) or a SHELL command (injected into a terminal). `&&` is honoured: a step
// only runs once the preceding shell step exits 0 — detected asynchronously via the
// OSC exit sentinel, so the chain is pumped a frame at a time (cl_chain_pump).
// Consecutive shell segments coalesce and keep their `&&` so the shell enforces the
// conditional among them; only a shell step a builtin waits on gets the sentinel.
CLStep :: struct {
    shell: bool,
    text:  string, // owned; freed by cl_chain_clear
}

CLChain :: struct {
    steps:     [dynamic]CLStep,
    idx:       int,
    target:    int, // 1-based terminal for this chain's shell injections
    waiting:   bool, // blocked on the current shell step's exit code
    wait_id:   u64,
    wait_term: ^Terminal,
}

// The private OSC tag must match terminal.odin's OSC_EXIT_TAG.
@(private = "file")
EXIT_OSC :: 697

// Parse a submitted line into a chain and start running it. A new line abandons any
// half-finished chain.
cl_exec :: proc(a: ^App, input: string) {
    cl_parse(a, input)
    cl_chain_pump(a)
}

// Build the chain from a submitted line (no execution — split out so the parsing is
// unit-testable on its own). Populates a.cl_chain; a new line abandons any pending
// chain first.
cl_parse :: proc(a: ^App, input: string) {
    cl_chain_clear(a)
    ch := &a.cl_chain
    ch.target = 1

    rest := strings.trim_space(input)

    // A leading tN sets the target terminal for the chain's shell parts; alone it is
    // just a goto. Stripped before segmenting.
    if first := first_field(rest); is_term_token(first) {
        ch.target = strconv.parse_int(first[1:], 10) or_else 1
        term_focus(a, ch.target)
        rest = strings.trim_space(rest[len(first):])
        if rest == "" {
            return // bare tN — goto only
        }
    }

    for seg in strings.split(rest, "&&", context.temp_allocator) {
        s := strings.trim_space(seg)
        if s == "" {
            continue
        }
        if cl_is_builtin(first_field(s)) {
            append(&ch.steps, CLStep{shell = false, text = strings.clone(s)})
        } else if n := len(ch.steps); n > 0 && ch.steps[n - 1].shell {
            prev := &ch.steps[n - 1] // coalesce adjacent shell segments (real shell &&)
            joined := strings.concatenate({prev.text, " && ", s})
            delete(prev.text)
            prev.text = joined
        } else {
            append(&ch.steps, CLStep{shell = true, text = strings.clone(s)})
        }
    }
}

// Advance the chain as far as it can go this frame: resolve a pending shell step's
// exit code (short-circuiting on failure), run builtins inline, and inject the next
// shell step. A non-final shell step (one a later step depends on) is wrapped with
// the exit sentinel and we return to wait; the final step injects plain.
cl_chain_pump :: proc(a: ^App) {
    ch := &a.cl_chain
    if !ch.waiting && len(ch.steps) == 0 {
        return // nothing running
    }
    if ch.waiting {
        t := ch.wait_term
        if t == nil || !t.alive { // the shell died mid-chain
            cl_chain_clear(a)
            return
        }
        if !(t.exit_ready && t.exit_id == ch.wait_id) {
            return // command still running
        }
        t.exit_ready = false
        ch.waiting = false
        if t.exit_code != 0 { // && short-circuit
            cl_chain_clear(a)
            return
        }
        ch.idx += 1
    }

    for ch.idx < len(ch.steps) {
        step := ch.steps[ch.idx]
        if step.shell {
            last := ch.idx == len(ch.steps) - 1
            cl_inject_shell(a, step.text, last)
            if !last {
                return // wait for the exit code before the next step
            }
        } else if !cl_run_builtin(a, step.text) {
            cl_chain_clear(a)
            return
        }
        ch.idx += 1
    }
    cl_chain_clear(a)
}

// Inject a shell command into the chain's target terminal. The final step runs
// plain; a non-final step is wrapped so the shell reports its exit code back via the
// private OSC, which the runner waits on (see cl_chain_pump).
@(private = "file")
cl_inject_shell :: proc(a: ^App, cmd: string, last: bool) {
    ch := &a.cl_chain
    term_focus(a, ch.target)
    t := term_current(a)
    if t == nil {
        cl_chain_clear(a)
        return
    }
    if last {
        terminal_write(t, transmute([]u8)strings.concatenate({cmd, "\n"}, context.temp_allocator))
        return
    }
    id := a.cl_wait_seq
    a.cl_wait_seq += 1
    t.exit_ready = false // discard any stale report before we arm this one
    // A waited step runs in a subshell with the pager neutralised — there is no point
    // paging a command we're about to `&&`-goto past, and a pager (e.g. git's `less`)
    // would block forever waiting for a keypress, stalling the whole chain. The
    // trailing `;printf` always runs, reporting the group's final exit code via the
    // private OSC (literal \033/\007/%d reach the shell verbatim; libvterm hides it).
    line := fmt.tprintf(
        "(export GIT_PAGER=cat PAGER=cat; %s) ;printf '\\033]%d;%d;%%d\\007' \"$?\"\n",
        cmd,
        EXIT_OSC,
        id,
    )
    terminal_write(t, transmute([]u8)line)
    ch.waiting = true
    ch.wait_id = id
    ch.wait_term = t
}

// Run a Slopd builtin. Returns success (builtins always succeed, so a following
// chain step proceeds).
@(private = "file")
cl_run_builtin :: proc(a: ^App, text: string) -> bool {
    name := first_field(text)
    args := strings.trim_space(text[len(name):])
    switch name {
    case "ls":
        set_aux(a, .FileTree)
    case "gs":
        set_aux(a, .Git)
    case "cf":
        set_aux(a, .Config)
        config_pane_refresh(&a.config_pane)
    case "zen", "zm":
        view_toggle_zen(a)
    case "put":
        cl_put(a, args)
    case "j", "jump":
        cl_jump(a, args)
    case "cd":
        cl_cd(a, args)
    case "tu":
        cl_tu(a)
    }
    return true
}

// `cd [dir]` (builtin): set the PROJECT ROOT — captured by Slopd, never sent to a
// shell. Relative paths resolve against the current root and a leading ~ expands to
// $HOME; a bare `cd` (or `cd ~`) goes home. Only an existing directory is accepted,
// so a typo leaves the root untouched. New terminals spawn here; `tu` syncs the
// unlocked ones; the idle status strip shows it.
@(private = "file")
cl_cd :: proc(a: ^App, args: string) {
    dir := cl_resolve_dir(a, strings.trim_space(args))
    defer delete(dir)
    if dir == "" || !os.is_dir(dir) {
        return
    }
    delete(a.project_root)
    a.project_root = strings.clone(dir)
}

// Resolve a `cd` argument to an absolute, cleaned directory path (owned by caller).
@(private = "file")
cl_resolve_dir :: proc(a: ^App, arg: string) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    raw: string
    switch {
    case arg == "" || arg == "~":
        raw = home != "" ? home : a.project_root
    case strings.has_prefix(arg, "~/"):
        raw = filepath.join({home, arg[2:]}, context.temp_allocator) or_else arg
    case filepath.is_abs(arg):
        raw = arg
    case:
        raw = filepath.join({a.project_root, arg}, context.temp_allocator) or_else arg
    }
    return filepath.clean(raw) or_else strings.clone(raw)
}

// `tu` (terminal update) builtin: push `cd <project root>` into every UNLOCKED live
// terminal so they all follow the project root at once. Locked sessions (Alt+L) keep
// their own cwd. A background sync — it changes no focus, unlike the goto builtins.
@(private = "file")
cl_tu :: proc(a: ^App) {
    if a.project_root == "" {
        return
    }
    line := fmt.tprintf("cd \"%s\"\n", a.project_root)
    for t in a.terminals {
        if t.alive && !t.locked {
            terminal_write(t, transmute([]u8)line)
        }
    }
}

// `j N` / `jump N`: move the editor's cursor to a line and reveal it (the render
// loop scrolls to follow). A bare number is an absolute 1-based line (matching the
// gutter); a signed `+N`/`-N` is relative to the current line. Out-of-range clamps
// to the first/last line. The cursor column is kept where it can fit.
@(private = "file")
cl_jump :: proc(a: ^App, args: string) {
    s := strings.trim_space(args)
    if s == "" {
        return
    }
    n, ok := strconv.parse_int(s, 10) // parses a leading +/-; rejects trailing junk
    if !ok {
        return
    }
    b := editor_current(&a.editor)
    cur := b.cursors[b.primary].head
    target := s[0] == '+' || s[0] == '-' ? cur.line + n : n - 1 // relative vs 1-based absolute
    target = clamp(target, 0, len(b.lines) - 1)
    doc_reset_cursor(&b.doc, Pos{target, min(cur.col, line_len(&b.lines[target]))})
    set_focus(a, .Editor)
}

// `put [text]`: type the literal text then the editor's current selection into the
// target terminal, with NO trailing newline (composes a command at the prompt).
@(private = "file")
cl_put :: proc(a: ^App, args: string) {
    sel := editor_selection_text(a, context.temp_allocator)
    parts := args != "" && sel != "" ? []string{args, " ", sel} : []string{args, sel}
    text := strings.concatenate(parts, context.temp_allocator)
    term_focus(a, a.cl_chain.target)
    if t := term_current(a); t != nil {
        terminal_write(t, transmute([]u8)text)
    }
}

cl_chain_clear :: proc(a: ^App) {
    ch := &a.cl_chain
    for step in ch.steps {
        delete(step.text)
    }
    delete(ch.steps) // free the backing too — commands are rare, so no need to pool it
    ch.steps = nil
    ch.idx = 0
    ch.waiting = false
    ch.wait_term = nil
}

// Run a command in t1, the master CL terminal (the Config pane's language buttons
// and any plain injection). Surfaces t1 and runs the command — no chaining.
run_in_t1 :: proc(a: ^App, cmd: string) {
    term_focus(a, 1)
    if t := term_current(a); t != nil {
        terminal_write(t, transmute([]u8)strings.concatenate({cmd, "\n"}, context.temp_allocator))
    }
}

// The editor's current selection as text, or "" when nothing is selected.
@(private = "file")
editor_selection_text :: proc(a: ^App, alloc := context.temp_allocator) -> string {
    b := editor_current(&a.editor)
    for c in b.cursors {
        if cursor_has_selection(c) {
            joined, _ := doc_copy(&b.doc, alloc)
            return joined
        }
    }
    return ""
}

@(private = "file")
first_field :: proc(s: string) -> string {
    i := 0
    for i < len(s) && s[i] != ' ' && s[i] != '\t' {
        i += 1
    }
    return s[:i]
}

@(private = "file")
is_term_token :: proc(s: string) -> bool {
    return len(s) >= 2 && s[0] == 't' && all_digits(s[1:])
}

@(private = "file")
cl_is_builtin :: proc(name: string) -> bool {
    switch name {
    case "ls", "gs", "cf", "zen", "zm", "put", "j", "jump", "cd", "tu":
        return true
    }
    return false
}

// Switch to terminal session n (1-based), surfacing the terminal pane. Shared by
// the command line (tN) and Alt+1..9. Clamps n into the existing session range.
term_focus :: proc(a: ^App, n: int) {
    a.aux_mode = .Terminal
    set_focus(a, .Aux)
    term_ensure(a) // surfacing a terminal spawns t1 if none exists yet
    if term_count(a) > 0 {
        a.term_active = clamp(n - 1, 0, term_count(a) - 1)
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
