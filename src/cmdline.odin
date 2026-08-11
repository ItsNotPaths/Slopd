package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "vendor:glfw"

// The master command line: a one-line Doc (the shared multi-cursor core, so every motion/edit
// op is reused from the buffer — Enter submits instead of splitting) plus a history ring and
// an executor. Output never lands here: builtins mutate app state, shell commands go to a
// terminal session. Driven by input.odin while a.cl_active.
CommandLine :: struct {
    using doc:  Doc,
    history:  [dynamic]string,
    hist_idx: int, // index into history; == len(history) means the live edit
    // Injection alert: a UI gesture pre-filled the line rather than the user typing it, and
    // the text renders in the alert colour until touched. Tracked by version so any edit
    // clears the alert with no per-edit hook; `inject_ver` is the pristine mark.
    injected:   bool,
    inject_ver: u64,
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
    a.cl.injected = false // a fresh open is the user's own line, not an injection
}

// Pre-fill the command line with text and open it (a UI gesture staging a command
// for the user to review and run with Enter — e.g. the filetree folder cd).
cl_inject :: proc(a: ^App, text: string) {
    cl_open(a)
    cl_recall(a, text)
    // Any edit bumps doc.version past this mark and the alert clears itself (draw_command_line).
    a.cl.injected = true
    a.cl.inject_ver = a.cl.doc.version
}

// A UI gesture producing a FULL command line either stages it (reviewable default) or runs
// it, chosen per action by config. Gestures that pre-fill an INCOMPLETE command for the user
// to finish (e.g. Alt+W's "j ") call cl_inject directly instead.
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

// A submitted line is a chain of `&&` segments, each a Slopd BUILTIN or a SHELL command. A step runs
// only once the preceding shell step exits 0, detected asynchronously via the OSC sentinel, so the
// chain pumps a frame at a time. Adjacent shell segments coalesce and keep their `&&` for the shell.
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

// Build the chain from a submitted line (no execution — split out so parsing is unit-testable
// on its own). A new line abandons any pending chain first.
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

// Advance the chain as far as it can go this frame: resolve a pending shell step's exit code
// (short-circuiting on failure), run builtins inline, inject the next shell step. A non-final
// shell step is wrapped with the exit sentinel and we return to wait; the final one is plain.
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

// Inject a shell command into the chain's target terminal. The final step runs plain; a
// non-final step is wrapped so the shell reports its exit code back via the private OSC.
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
    // A waited step runs in a subshell with the pager neutralised: a pager (git's `less`) would
    // block forever on a keypress and stall the whole chain. The trailing `;printf` always runs,
    // reporting the group's exit code via the private OSC (\033/\007/%d reach the shell verbatim).
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

// Run a Slopd builtin. Always succeeds, so a following chain step proceeds.
@(private = "file")
cl_run_builtin :: proc(a: ^App, text: string) -> bool {
    name := first_field(text)
    args := strings.trim_space(text[len(name):])
    switch name {
    case "ls":
        set_aux(a, .FileTree)
        filetree_reload(&a.tree) // `ls` is also the REFRESH gesture — and the tail of a staged rm
    case "gs":
        git_tool_open(a) // hand the project root to the configured external git tool
    case "cf":
        set_aux(a, .Config)
        config_pane_refresh(&a.config_pane)
    case "zen", "zm":
        view_toggle_zen(a)
    case "full", "fm":
        view_toggle_full(a)
    case "normal", "nm":
        view_normal(a) // not a toggle: the arrangement by name, from any view
    case "put":
        cl_put(a, args)
    case "j", "jump":
        cl_jump(a, args)
    case "grep":
        cl_grep(a, args)
    case "cd":
        cl_cd(a, args)
    case "reload":
        cl_reload(a, args)
    case "tu":
        cl_tu(a)
    case "w", "wa", "q", "q!", "wq", "wqa", "waq":
        cl_quit(a, name)
    }
    return true
}

// Quit/write builtins — the ONLY way to close Slopd (Esc never quits), guarded by the unsaved RING
// so a mistyped quit can't throw away work. buffer_save can't write an unnamed buffer, so a write
// leaving work dirty refuses. Refusals ECHO into t1: **keep messages apostrophe-free**.
@(private = "file")
cl_quit :: proc(a: ^App, cmd: string) {
    switch cmd {
    case "w":
        if !buffer_save(editor_current(&a.editor)) {
            cl_echo_t1(a, "w: no filename (save-as not yet supported)")
        }
    case "wa":
        cl_write_all(a)
    case "q!":
        glfw.SetWindowShouldClose(a.window, true)
    case "q":
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf("q: %d unsaved buffer(s) — wqa to save+quit, q! to discard", n))
        } else {
            glfw.SetWindowShouldClose(a.window, true)
        }
    case "wq":
        buffer_save(editor_current(&a.editor))
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf("wq: %d other unsaved buffer(s) — wqa or q!", n))
        } else {
            glfw.SetWindowShouldClose(a.window, true)
        }
    case "wqa", "waq":
        cl_write_all(a)
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf("wqa: %d buffer(s) could not be saved — q! to discard", n))
        } else {
            glfw.SetWindowShouldClose(a.window, true)
        }
    }
}

// Save every dirty buffer in the ring; returns how many remain dirty (an unnamed one stays).
@(private = "file")
cl_write_all :: proc(a: ^App) -> int {
    for &b in a.editor.buffers {
        if b.dirty {
            buffer_save(&b)
        }
    }
    return ring_dirty_count(&a.editor)
}

// Surface a Slopd message in t1 by running a single-quoted `echo`, so feedback lands in a
// real terminal (lazily spawning t1) rather than the status strip.
@(private = "file")
cl_echo_t1 :: proc(a: ^App, msg: string) {
    run_in_t1(a, fmt.tprintf("echo '%s'", msg))
}

// `cd [dir]` (builtin): set the PROJECT ROOT — captured by Slopd, never sent to a shell. Only an
// existing directory is accepted, so a typo leaves the root untouched. New terminals spawn here;
// `tu` syncs the unlocked ones.
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

// `tu` (terminal update): push `cd <project root>` into every UNLOCKED live terminal at once.
// Locked sessions (Alt+L) keep their own cwd. A background sync — it changes no focus.
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

// `reload [y|n]`: settle a pending disk-change conflict, which auto-stages this command in the CL.
//   reload y   re-reads the file, DISCARDING the unsaved edits
//   reload n   keeps your edits and CACHES it, so it stops asking until the file changes again
// A bare `reload` while conflicted is deliberately a NO-OP: an accidental Enter on the staged line
// must not silently discard edits. With no conflict it is a manual refresh (vim's :e!).
@(private = "file")
cl_reload :: proc(a: ^App, args: string) {
    if a.main != .Text || len(a.editor.buffers) == 0 {
        return
    }
    b := editor_current(&a.editor)
    arg := strings.to_lower(strings.trim_space(args), context.temp_allocator)
    if b.conflict {
        switch arg { // resolving a conflict needs an explicit answer; bare `reload` waits
        case "y", "yes": buffer_conflict_resolve(b, true) // take the disk version
        case "n", "no":  buffer_conflict_resolve(b, false) // keep my edits, cache the decision
        }
        return
    }
    switch arg { // no conflict: a manual refresh (re-read, discarding any unsaved edits)
    case "", "y", "yes": buffer_reload_keep_view(b)
    }
}

// `j [file] [line]` / `jump ...`: reveal a location through the shared jump_to primitive.
//   j N            move to a line in the current buffer (1-based absolute, matching the gutter)
//   j +N / j -N    move relative to the current line
//   j <file>       open <file> (name-first under the project root, or a system-wide /abs path)
//   j <file> N     open <file> and go to line N (a +N/-N here is relative to the file's top)
// A bare-number first field is always a line in the current buffer. Out-of-range lines clamp.
@(private = "file")
cl_jump :: proc(a: ^App, args: string) {
    s := strings.trim_space(args)
    if s == "" {
        return
    }
    b := editor_current(&a.editor)
    cur := b.cursors[b.primary].head

    first := first_field(s)
    rest := strings.trim_space(s[len(first):])

    // `j <line>`: the first field is a line number, no file. Keep the column where it fits.
    if line, ok := parse_line_spec(first, cur.line); ok && rest == "" {
        line = clamp(line, 0, len(b.lines) - 1)
        jump_to(a, "", line, min(cur.col, line_len(&b.lines[line])))
        return
    }
    // Otherwise the first field is a file; an optional second field is its line.
    path, found := jump_resolve_path(a, first)
    if !found {
        return
    }
    line := 0
    if rest != "" {
        line, _ = parse_line_spec(rest, 0) // +/- here is relative to the file's top
    }
    jump_to(a, path, max(line, 0), 0)
}

// `grep [flags] <pattern>`: hijack the user's grep into a PROJECT-WIDE search landing in the Grep
// pane. Leading `-flags` are discarded (grep_run forces its own); the rest is the pattern, kept
// whole, as a regex. **A pattern beginning with '-' can't be expressed** — the flag-strip eats it.
@(private = "file")
cl_grep :: proc(a: ^App, args: string) {
    query := strings.trim_space(args)
    for query != "" && query[0] == '-' { // drop a leading flag field, then re-trim
        query = strings.trim_space(query[len(first_field(query)):])
    }
    if query == "" {
        return
    }
    hits := grep_run(a.project_root, query)
    grep_set(&a.grep, query, hits)
    if len(hits) == 1 && !a.grep_pane_always {
        grep_open_hit(a, hits[0]) // sole match, shortcut enabled: jump straight, no pane
    } else {
        set_aux(a, .Grep) // list them (an empty set shows "(no matches)")
    }
}

// `put [text]`: type the literal text then the editor's selection into the target terminal,
// with NO trailing newline (composes a command at the prompt).
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

// --- shell command builders --- UI gestures stage a REAL shell line in the CL rather than
// hiding the work behind a modal prompt: you read it, edit it, Enter, and it lands in history.
// Pure string builders, so they unit-test without an App; callers are the filetree chords.

// Wrap s in single quotes so spaces and metacharacters in a path stay literal. An embedded
// single quote closes, escapes and reopens ('\'') — the one form safe in every POSIX shell.
sh_quote :: proc(s: string, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    strings.write_byte(&b, '\'')
    for i in 0 ..< len(s) {
        if s[i] == '\'' {
            strings.write_string(&b, `'\''`)
        } else {
            strings.write_byte(&b, s[i])
        }
    }
    strings.write_byte(&b, '\'')
    return strings.to_string(b)
}

// The staged line for a filetree delete: `rm -rf '<path>' ... && ls`. The trailing `ls` is our
// own builtin — once the rm exits 0 the chain runs it, re-reading the listing and refocusing the
// filetree. "" when nothing is selected, and the caller then stages nothing.
rm_command :: proc(paths: []string, alloc := context.allocator) -> string {
    if len(paths) == 0 {
        return ""
    }
    b := strings.builder_make(alloc)
    strings.write_string(&b, "rm -rf")
    for p in paths {
        strings.write_byte(&b, ' ')
        strings.write_string(&b, sh_quote(p, context.temp_allocator))
    }
    strings.write_string(&b, " && ls")
    return strings.to_string(b)
}

// The staged line that RUNS a file, or "" when it isn't ours to run (the caller hands those to
// desktop_open). Executables run by quoted path; a NON-executable shell script still runs under
// `bash`, since chmod +x is the step people skip. The trailing space is so args type straight on.
run_command :: proc(path: string, executable: bool, alloc := context.allocator) -> string {
    quoted := sh_quote(path, context.temp_allocator)
    if executable {
        return strings.concatenate({quoted, " "}, alloc)
    }
    switch filepath.ext(path) {
    case ".sh", ".bash":
        return strings.concatenate({"bash ", quoted, " "}, alloc)
    }
    return ""
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

// Run a command in t1, the master CL terminal: surfaces it and runs — no chaining.
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

// The inline ghost hint: a faint argument example drawn past the typed text once a command is
// recognised, dropped once you start typing the argument so it never overlaps real input. Give a
// command a hint by adding a case. "" = no hint; leading whitespace yields no command, so none.
cl_ghost_hint :: proc(line: string) -> string {
    name := first_field(line)
    if name == "" || strings.trim_space(line[len(name):]) != "" {
        return "" // no command yet, or an argument is already typed
    }
    switch name {
    case "reload": return "(y/n)"
    }
    return ""
}

@(private = "file")
cl_is_builtin :: proc(name: string) -> bool {
    switch name {
    case "ls", "gs", "cf", "zen", "zm", "full", "fm", "normal", "nm", "put", "j", "jump", "grep",
         "cd", "reload", "tu", "w", "wa", "q", "q!", "wq", "wqa", "waq":
        return true
    }
    return false
}

// Switch to terminal session n (1-based), surfacing the terminal pane. Shared by the command
// line (tN) and Alt+1..9; clamps n into the existing session range.
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
