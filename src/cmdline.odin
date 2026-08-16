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
//
// **A line is SHELL unless it says otherwise.** A Slopd builtin is named with a leading `:`
// sigil and nothing else is captured — `grep foo` is the real grep in a terminal, `:grep foo`
// is our Grep pane. The command line stopped guessing: what a word means is decided by what
// you typed, not by a list Slopd happens to hold. Alt+C opens the line empty (shell), Alt+;
// opens it with the sigil already typed, and the two are the same line — typing `:` yourself
// after Alt+C is identical.
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

// Open the line, optionally with `prefix` already typed and the caret past it (Alt+; passes the
// `:` sigil). NOT an injection: the user pressed the key, so there is nothing to review and the
// alert ring stays off — the prefix is a keystroke saved, not a command staged.
cl_open :: proc(a: ^App, prefix := "") {
    a.cl_active = true
    doc_clear(&a.cl.doc)
    a.cl.hist_idx = len(a.cl.history)
    a.cl.injected = false // a fresh open is the user's own line, not an injection
    if prefix != "" {
        cl_recall(a, prefix)
    }
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
    cl_preview_restore(a) // whatever the half-typed line was showing goes back where it was
    a.cl_active = false
    doc_clear(&a.cl.doc)
}

cl_submit :: proc(a: ^App) {
    input := strings.trim_space(doc_string(&a.cl.doc, context.temp_allocator))
    cl_preview_commit(a) // keep what the preview landed on; the builtin below runs over it
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

// A submitted line is a chain of `&&` segments, each a Slopd BUILTIN (`:name`) or a SHELL command
// (anything else). A step runs only once the preceding shell step exits 0, detected asynchronously
// via the OSC sentinel, so the chain pumps a frame at a time. Adjacent shell segments coalesce and
// keep their `&&` for the shell. A step's `text` is stored SIGIL-FREE: the `:` is the parser's, and
// cl_run_builtin sees the same `name args` it always did.
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

    // A leading `:tN` builtin sets the target terminal for the chain's shell parts; alone it is
    // just a goto. Stripped before segmenting, so what follows is an ORDINARY line — `:t2 make`
    // throws a raw `make` at session 2, and only a further `:` names a builtin there.
    if first := first_field(rest); is_term_token(first) {
        ch.target = strconv.parse_int(first[2:], 10) or_else 1
        term_focus(a, ch.target)
        rest = strings.trim_space(rest[len(first):])
        if rest == "" {
            return // bare :tN — goto only
        }
    }

    for seg in cl_split_chain(rest) {
        s := strings.trim_space(seg)
        if s == "" {
            continue
        }
        if strings.has_prefix(s, ":") {
            name := strings.trim_space(s[1:])
            if name == "" {
                continue // a bare `:` names no builtin; nothing to run
            }
            append(&ch.steps, CLStep{shell = false, text = strings.clone(name)})
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

// Split a line into `&&` segments the way the SHELL would read it: an `&&` is a chain separator
// only where the shell would see an operator. Inside '...' or "..." it is text, after a backslash
// it is an escaped character, and inside `...`, $(...) or a ( ) subshell it belongs to that
// command — `rm -rf 'a && b.txt' && :ls` is two steps, not four, and the filename survives.
//
// The scanner tracks exactly what changes that answer and nothing else: it never expands, never
// unquotes, and hands each segment on verbatim for the shell to parse properly. Quoting is the
// shell's own job — this only has to find the seams. An UNCLOSED quote or paren swallows the rest
// of the line, which is right: the shell would go on reading too, and there is no seam in there.
//
// Returns slices of `s` (no copies); the backing list is temp-allocated, so the caller must clone
// anything it keeps. Only `&&` is an operator here — `;`, `|` and `||` are the shell's alone and
// ride along inside a segment untouched.
@(private = "file")
cl_split_chain :: proc(s: string, alloc := context.temp_allocator) -> []string {
    out := make([dynamic]string, 0, 4, alloc)
    quote: u8 // 0, '\'' or '"' — the quote we are inside
    depth: int // unquoted ( ) / $( ) nesting
    tick: bool // inside a `...` command substitution
    start, i := 0, 0
    for i < len(s) {
        c := s[i]
        switch {
        case quote == '\'':
            if c == '\'' {quote = 0}
        case quote == '"':
            if c == '\\' && i + 1 < len(s) {
                i += 1 // inside "..." a backslash still escapes the next byte
            } else if c == '"' {
                quote = 0
            }
        case c == '\\':
            i += 1 // outside quotes it escapes anything, an `&` included
        case c == '\'' || c == '"':
            quote = c
        case c == '`':
            tick = !tick
        case c == '(':
            depth += 1
        case c == ')':
            depth = max(depth - 1, 0)
        case c == '&' && !tick && depth == 0 && i + 1 < len(s) && s[i + 1] == '&':
            append(&out, s[start:i])
            i += 2
            start = i
            continue
        }
        i += 1
    }
    append(&out, s[start:])
    return out[:]
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

// Run a Slopd builtin — `text` is the segment with its `:` already stripped. Succeeds (so a
// following chain step proceeds) unless the name is not one of ours: the sigil was a promise
// that this word is a builtin, so a typo SAYS SO in t1 and stops the chain rather than
// vanishing. This switch is the whole builtin registry; a new one is a case here and a row in
// the README's table.
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
    case "readme", "README":
        open_embedded_doc(a, .Readme)
    case "license", "LICENSE":
        open_embedded_doc(a, .License)
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
    case "f", "find":
        cl_find(a, args)
    case "grep":
        cl_grep(a, args)
    case "cd":
        cl_cd(a, args)
    case "reload":
        cl_reload(a, args)
    case "saved":
        cl_saved(a)
    case "tu":
        cl_tu(a)
    case "w", "wa", "q", "q!", "wq", "wqa", "waq":
        cl_quit(a, name)
    case:
        cl_echo_t1(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
        return false
    }
    return true
}

// --- saving --- Every save GESTURE goes through cl_save (Ctrl+S, `:w`), so the two can never
// disagree about what a locked file does. `:wa` and friends stay on the plain buffer_save: a
// write-all that hit three unwritable files has no one line to stage.

// Save the document buffer, and when permissions were the only thing in the way, stage the line
// that gets it there anyway. Returns the result so the caller can word its own refusal.
cl_save :: proc(a: ^App, b: ^Buffer) -> Save_Result {
    res := buffer_save(b)
    // A staged line IS the report, so a denial that stages says nothing further. One that
    // CANNOT stage has to speak, or Ctrl+S on a locked file would do nothing whatsoever.
    if res == .Denied && !save_stage_sudo(a, b) {
        cl_echo_t1(a, "save: permission denied, and no private folder to stage a sudo copy in")
    }
    return res
}

// A save refused for permissions is not a failure to report and forget: the bytes are fine, the
// door is locked. Write them to a private copy and PREFILL the line that carries them over as
// root — the same review-then-Enter gesture the disk conflict uses, and the shell half of the CL
// is the one place a password prompt can actually be typed, since it runs in a real terminal.
//
// False (staging nothing) when there is nowhere private to put the copy, or the copy itself
// fails. The caller has already reported the denial; this only ever ADDS a way forward.
save_stage_sudo :: proc(a: ^App, b: ^Buffer) -> bool {
    dir := save_tmp_dir()
    if dir == "" || !buffer_on_disk(b) {
        return false
    }
    // The pid and the counter are not decoration: a staged line can sit in the CL — or in
    // history — while another buffer is saved, and a copy named for the file alone would hand
    // the older line the newer file's bytes.
    a.save_seq += 1
    name := fmt.tprintf("slopd-%d-%d-%s", os.get_pid(), a.save_seq, filepath.base(b.path))
    tmp := filepath.join({dir, name}, context.temp_allocator) or_else ""
    if tmp == "" {
        return false
    }
    buffer_drop_save_tmp(b) // one staged copy per buffer; the last one is spent
    if os.write_entire_file(tmp, transmute([]u8)buffer_bytes(b), {.Read_User, .Write_User}) != nil {
        return false
    }
    b.save_tmp = strings.clone(tmp)
    line := sudo_save_command(tmp, b.path, context.temp_allocator)
    cl_inject(a, line)
    return true
}

// Where that private copy goes: $XDG_RUNTIME_DIR, else ~/.cache. "" if neither is there, and
// then nothing is staged at all.
//
// **/tmp is not on the list, and that is a security decision.** Root is about to READ this file.
// A shared /tmp lets another local user create the path first and own it, and then swap the
// contents between our write and root's copy — which puts their bytes into the file we were
// asked to save. Both folders here are ours alone.
@(private = "file")
save_tmp_dir :: proc() -> string {
    if d := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); strings.has_prefix(d, "/") && os.is_dir(d) {
        return d
    }
    home := os.get_env("HOME", context.temp_allocator)
    if home == "" {
        return ""
    }
    cache := filepath.join({home, ".cache"}, context.temp_allocator) or_else ""
    return os.is_dir(cache) ? cache : ""
}

// `:saved`: stop calling this buffer dirty, because the disk already holds what it would write.
// The tail of the staged sudo line, and the reason it can be a PLAIN builtin anybody may type:
// it verifies rather than trusts. On a buffer whose bytes are not on disk it does nothing at
// all, so it cannot be used — or mistyped — into marking real work as saved.
@(private = "file")
cl_saved :: proc(a: ^App) {
    if a.main != .Text || len(a.editor.buffers) == 0 {
        return
    }
    b := editor_current(&a.editor)
    if !buffer_matches_disk(b) {
        cl_echo_t1(a, ":saved: the file on disk is not what this buffer holds — nothing changed")
        return
    }
    buffer_mark_saved(b)
}

// Quit/write builtins — the ONLY way to close Slopd (Esc never quits), guarded by the unsaved RING
// so a mistyped quit can't throw away work. buffer_save can't write an unnamed buffer, so a write
// leaving work dirty refuses. Refusals ECHO into t1 (cl_echo_t1), naming what to type WITH the
// sigil, since that is the line that would work.
@(private = "file")
cl_quit :: proc(a: ^App, cmd: string) {
    switch cmd {
    case "w":
        // A denial stages its own `sudo cp` line (cl_save), which IS the message — echoing
        // "permission denied" as well would only bury the line that fixes it.
        switch cl_save(a, editor_current(&a.editor)) {
        case .No_Path: cl_echo_t1(a, ":w: no filename (save-as not yet supported)")
        case .Failed:  cl_echo_t1(a, ":w: could not write the file")
        case .Ok, .Denied:
        }
    case "wa":
        cl_write_all(a)
    case "q!":
        glfw.SetWindowShouldClose(a.window, true)
    case "q":
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf(":q: %d unsaved buffer(s) — :wqa saves+quits, :q! drops", n))
        } else {
            glfw.SetWindowShouldClose(a.window, true)
        }
    case "wq":
        buffer_save(editor_current(&a.editor))
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf(":wq: %d other unsaved buffer(s) — :wqa or :q!", n))
        } else {
            glfw.SetWindowShouldClose(a.window, true)
        }
    case "wqa", "waq":
        cl_write_all(a)
        if n := ring_dirty_count(&a.editor); n > 0 {
            cl_echo_t1(a, fmt.tprintf(":wqa: %d buffer(s) could not be saved — :q! to discard", n))
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

// Surface a Slopd message in t1 by running an `echo`, so feedback lands in a real terminal
// (lazily spawning t1) rather than the status strip. sh_quote does the quoting, so a message
// carrying the user's own text — an unrecognised builtin name — can hold anything at all.
@(private = "file")
cl_echo_t1 :: proc(a: ^App, msg: string) {
    run_in_t1(a, fmt.tprintf("echo %s", sh_quote(msg, context.temp_allocator)))
}

// `:cd [dir]`: set the PROJECT ROOT — Slopd's own notion of where it is working, never a shell's.
// An UNSIGILLED `cd` is the shell's, moving that terminal and nothing else; the sigil is what
// tells the two apart. Only an existing directory is accepted, so a typo leaves the root
// untouched. New terminals spawn here; `:tu` syncs the unlocked ones.
@(private = "file")
cl_cd :: proc(a: ^App, args: string) {
    dir := cl_resolve_path(a, unquote_arg(strings.trim_space(args)))
    defer delete(dir)
    if dir == "" || !os.is_dir(dir) {
        return
    }
    delete(a.project_root)
    a.project_root = strings.clone(dir)
}

// Resolve a path argument (`~`, `~/x`, relative to the project root, or already absolute) to an
// absolute, cleaned path — owned by the caller. Nothing here says the path must exist, or be a
// directory: `cd` checks that itself, and the launch path below accepts a file too.
@(private = "file")
cl_resolve_path :: proc(a: ^App, arg: string) -> string {
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

// `:tu` (terminal update): push `cd <project root>` into every UNLOCKED live terminal at once.
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

// "Set workspace here": `:cd <dir>` then `:tu`, in one call and with no line to submit. Package-
// level because the pointer reaches it (the file panes' context menu) as well as the `^h` chord —
// and it is exactly the two builtins, so what the gesture does is what you could have typed.
cl_workspace :: proc(a: ^App, dir: string) {
    if dir == "" {
        return
    }
    cl_cd(a, dir)
    cl_tu(a)
}

// `slopd --<path>`: the launch path, applied once at startup (main), before the window's first
// frame. A DIRECTORY is opened as the workspace; a FILE opens in the editor with its containing
// folder as the workspace — the same "where am I working" the `^h` chord sets, so launching
// somewhere and setting the workspace there land in the same state. The file panes are pointed at
// it too: `^h` runs the other way round (the browsed dir becomes the root), and at launch there is
// no browsed dir to take it from.
//
// Returns false for a path that does not exist, leaving the launch cwd as the root — main says so
// on stderr rather than opening a window that silently ignored the argument.
cl_launch_path :: proc(a: ^App, arg: string) -> bool {
    if arg == "" { // an empty argument is not "home" here, the way a bare `:cd` is — it is nothing
        return false
    }
    path := cl_resolve_path(a, arg)
    defer delete(path)
    if path == "" || !os.exists(path) {
        return false
    }
    file := !os.is_dir(path) // a regular file (or anything else): work from its folder
    dir := file ? filepath.dir(path) : path // slices into path — not owned, never delete it
    if !os.is_dir(dir) {
        return false
    }
    cl_workspace(a, dir) // :cd + :tu, exactly as the chord and the context menu do it
    filetree_load(&a.tree, dir)
    if file {
        open_file(a, path) // focuses the main pane; a failed load leaves the scratch buffer
    }
    return true
}

// `:reload [y|n]`: settle a pending disk-change conflict, which auto-stages this command in the CL.
//   :reload y   re-reads the file, DISCARDING the unsaved edits
//   :reload n   keeps your edits and CACHES it, so it stops asking until the file changes again
// The third way out is not this builtin at all: `:w` over the staged line writes MY version and
// clears the conflict with it (buffer_save), which is why the hint names it.
// A bare `:reload` while conflicted is deliberately a NO-OP: an accidental Enter on the staged line
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

// `:j [file] [line]` / `:jump ...`: reveal a location through the shared jump_to primitive.
//   :j N            move to a line in the current buffer (1-based absolute, matching the gutter)
//   :j +N / :j -N   move relative to the current line
//   :j <file>       open <file> (name-first under the project root, or a system-wide /abs path)
//   :j <file> N     open <file> and go to line N (a +N/-N here is relative to the file's top)
// A bare-number first field is always a line in the current buffer. Out-of-range lines clamp. A
// name with SPACES in it is quoted (`:j "my notes.md" 12`) — the one place a builtin needs it.
@(private = "file")
cl_jump :: proc(a: ^App, args: string) {
    s := strings.trim_space(args)
    if s == "" {
        return
    }
    b := editor_current(&a.editor)

    // `j <line>`: the first field is a line number, no file.
    if pos, ok := cl_jump_line(b, s); ok {
        jump_to(a, "", pos.line, pos.col)
        return
    }
    // Otherwise the first field is a file; an optional second field is its line.
    raw, first := first_arg(s) // a quoted first field is one path, spaces included
    rest := strings.trim_space(s[len(raw):])
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

// Where a BARE-LINE `:j` argument lands in `b` — clamped into the buffer, keeping the caret's
// column as far as the target line is long. ok=false when the argument is not a lone line
// number, which is to say when it names a FILE.
//
// Split out because the live preview needs the same answer (cl_preview.odin), and a preview
// that computed its own would be free to disagree with the Enter that follows it.
cl_jump_line :: proc(b: ^Buffer, args: string) -> (Pos, bool) {
    s := strings.trim_space(args)
    raw, first := first_arg(s)
    if strings.trim_space(s[len(raw):]) != "" {
        return {}, false // a second field means the first one was a file name
    }
    cur := b.cursors[b.primary].head
    line, ok := parse_line_spec(first, cur.line)
    if !ok {
        return {}, false
    }
    line = clamp(line, 0, len(b.lines) - 1)
    return Pos{line, min(cur.col, line_len(&b.lines[line]))}, true
}

// `:f <text>` / `:find <text>`: search the open buffer and put the caret on a match.
//
// **The landing needs no hand-off from the preview.** The preview leaves the caret exactly on
// the match it cycled to, and "the first match at or after the caret" is then that same match —
// so submitting the line you were previewing keeps your place, and one recalled from history
// with no preview behind it searches forward from wherever you were. One rule, both ways in.
//
// The marks go down: Enter is an answer, and what is left is a caret on the word you asked for.
cl_find :: proc(a: ^App, args: string) {
    b := main_text_buffer(a)
    if b == nil {
        return
    }
    find_set(&a.find, b, strings.trim_space(args), b.cursors[b.primary].head)
    a.find.show = false
    if p, ok := find_pos(&a.find); ok {
        doc_reset_cursor(&b.doc, p)
        set_focus(a, .Editor)
    }
}

// `:grep [flags] <pattern>`: a PROJECT-WIDE search landing in the Grep pane. Asked for by name —
// an unsigilled `grep` is the real one, in a terminal — so this is the pane, not an interception.
// Leading `-flags` are discarded (grep_run forces its own); the rest is the pattern, kept whole,
// as a regex. **A pattern beginning with '-' can't be expressed** — the flag-strip eats it, and
// plain `grep` is the way to search for one.
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

// `:put [text]`: type the literal text then the editor's selection into the target terminal,
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

// The staged line for a filetree delete: `rm -rf '<path>' ... && :ls`. The `rm` is the shell's,
// the sigilled tail is ours — once the rm exits 0 the chain runs it, re-reading the listing and
// refocusing the filetree. "" when nothing is selected, and the caller then stages nothing.
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
    strings.write_string(&b, " && :ls")
    return strings.to_string(b)
}

// The staged line for a save that permissions refused: `sudo cp '<tmp>' '<path>' && :saved`.
//
// `cp` and not `mv`, deliberately. cp writes THROUGH to the destination's existing inode, so the
// file keeps its owner, mode, ACLs and hardlinks, and a symlinked path is followed to what it
// points at. A mv out of the runtime dir crosses a filesystem, which is copy-then-unlink: the
// result is a NEW inode carrying the temp file's root-owned 0600, and /etc/nginx.conf silently
// stops being readable by nginx.
//
// The `&& :saved` is the other half of the design: cl_chain_pump waits on the shell step's exit
// code, so a wrong password — or a Ctrl+C at the prompt — stops the chain before `:saved` runs,
// and the buffer stays dirty. Nothing here claims a save that did not happen.
sudo_save_command :: proc(tmp, path: string, alloc := context.allocator) -> string {
    if tmp == "" || path == "" {
        return ""
    }
    return strings.concatenate(
        {
            "sudo cp ",
            sh_quote(tmp, context.temp_allocator),
            " ",
            sh_quote(path, context.temp_allocator),
            " && :saved",
        },
        alloc,
    )
}

// The line a Properties gesture runs in t1: one `stat` cut to the fields a properties box shows —
// mode, size, owner, and the two timestamps. **--printf, not -c**: only the former interprets the
// `\n`s, and -c would print them literally on one long line.
PROPS_FORMAT :: `stat --printf '%n\n  %A  %s bytes  %U:%G\n  modified %y\n  created  %w\n' -- `

// That line for `path`, or "" when there is nothing to describe. A directory answers too — its
// own entry, not a recursive size, which is what `stat` means by a directory's size.
properties_command :: proc(path: string, alloc := context.allocator) -> string {
    if path == "" {
        return ""
    }
    return strings.concatenate({PROPS_FORMAT, sh_quote(path, context.temp_allocator)}, alloc)
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

// Whether a submitted line is still running: steps left to take, or a shell step whose exit code
// has not come back yet. The disk poll asks, so a chain that rewrites the open file (the sudo
// save) is not interrupted by a prompt about the change it is making.
cl_chain_busy :: proc(a: ^App) -> bool {
    return a.cl_chain.waiting || len(a.cl_chain.steps) > 0
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
    run_in_term(a, cmd, 1)
}

// The same, in the session `n` names — the open ones plus the next, so a `run_term: 8` with
// three sessions open opens the fourth rather than silently landing in the third (term_slot).
run_in_term :: proc(a: ^App, cmd: string, n: int) {
    term_surface(a, term_slot(term_count(a), n))
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

// The first ARGUMENT of a builtin's line: first_field, except that a leading quote runs to its
// partner, so a path with spaces can be written the way the shell taught you (`:j "my file" 40`).
// Returns the span to skip (quotes and all) and the value inside them. An unclosed quote is not a
// quote at all — it falls back to the plain field, since a lone `"` is likelier to be part of a
// name than the start of something.
@(private = "file")
first_arg :: proc(s: string) -> (raw, value: string) {
    if len(s) > 0 && (s[0] == '\'' || s[0] == '"') {
        for i in 1 ..< len(s) {
            if s[i] == s[0] {
                return s[:i + 1], s[1:i]
            }
        }
    }
    f := first_field(s)
    return f, f
}

// Strip ONE matched pair of surrounding quotes from an argument that is the WHOLE rest of the
// line (`:cd "my dir"`). Those builtins never needed the quotes — the argument is already the
// whole field — so honouring the habit beats failing on a directory that is plainly there. Only
// the outer pair goes; quotes inside the name are part of the name.
@(private = "file")
unquote_arg :: proc(s: string) -> string {
    if len(s) >= 2 && (s[0] == '\'' || s[0] == '"') && s[len(s) - 1] == s[0] {
        return s[1:len(s) - 1]
    }
    return s
}

// `:tN` — the builtin naming a terminal session. A LINE PREFIX, not a step: it says where the
// chain's shell parts land, so it is read and stripped before the line is segmented.
@(private = "file")
is_term_token :: proc(s: string) -> bool {
    return len(s) >= 3 && s[0] == ':' && s[1] == 't' && all_digits(s[2:])
}

// The builtin a typed line is calling, split into its name and the rest. ok=false when the line
// names none — it is unsigilled (a shell command) or the sigil stands alone. Shared by the ghost
// hint and the live preview, the two readers of a line that has not been submitted yet.
cl_builtin_call :: proc(line: string) -> (name, args: string, ok: bool) {
    s := strings.trim_space(line)
    if !strings.has_prefix(s, ":") {
        return "", "", false
    }
    body := strings.trim_left_space(s[1:])
    name = first_field(body)
    return name, strings.trim_space(body[len(name):]), name != ""
}

// The inline ghost hint: a faint note drawn past the typed text once a BUILTIN is recognised.
// Give a builtin a hint by adding a case. "" = no hint — and an unsigilled line never has one,
// since a shell command is the shell's to explain, not ours.
//
// Two kinds live here, and the difference is whether the argument has arrived. `:reload` PROMPTS
// — it names the answers it takes, and drops the hint the moment one is typed. `:f` REPORTS —
// it counts what the live preview found, so it has nothing to say until an argument exists. Each
// case decides for itself, which is why the emptiness of `args` is not tested up here.
//
// It takes the App because a hint reads live state: `:reload` means two different things — a
// manual refresh, or the answer to a pending disk conflict — and only the second has a third way
// out worth naming, `:w`. The staged line IS the whole conflict prompt now (strip_ui.odin), so
// the hint is where the three get said.
cl_ghost_hint :: proc(a: ^App, line: string) -> string {
    name, args, ok := cl_builtin_call(line)
    if !ok {
        return ""
    }
    switch name {
    case "reload":
        if args != "" {
            return "" // an answer is typed; the prompt has served its purpose
        }
        return cl_conflict_pending(a) ? "(y = disk / n = mine / :w = overwrite)" : "(y/n)"
    case "f", "find":
        return cl_find_hint(a)
    }
    return ""
}

// What the live `:f` preview found — `(3/17)`, the position within the count, so the strip says
// both how many there are and which one you are standing on as Up/Down cycle them.
//
// Read off the search state rather than the typed line, so it is silent exactly when there is no
// preview to report: before an argument exists, and whenever `cl_preview` is off.
@(private = "file")
cl_find_hint :: proc(a: ^App) -> string {
    if !a.find.show {
        return ""
    }
    if n := len(a.find.matches); n > 0 {
        return fmt.tprintf("(%d/%d)", a.find.cur + 1, n)
    }
    return "(no matches)"
}

// Whether the document pane's buffer is holding a disk-change conflict — the state the staged
// `:reload ` was raised for. Guarded for the bare App the tests build (no buffers at all).
cl_conflict_pending :: proc(a: ^App) -> bool {
    return a.main == .Text && len(a.editor.buffers) > 0 && editor_current(&a.editor).conflict
}

// Switch to terminal session n (1-based), surfacing the terminal pane. Shared by the command
// line (`:tN`) and Alt+1..9; clamps n into the existing session range.
term_focus :: proc(a: ^App, n: int) {
    a.aux_mode = .Terminal
    set_focus(a, .Aux)
    term_ensure(a) // surfacing a terminal spawns t1 if none exists yet
    if term_count(a) > 0 {
        a.term_active = clamp(n - 1, 0, term_count(a) - 1)
    }
}

// Surface session `n`, CREATING it when the number names the one past the last — which is the
// most term_slot can hand back, so one session is always enough. term_focus alone clamps into
// the sessions that exist, which is how a launch aimed at t4 with three open lands in t3.
term_surface :: proc(a: ^App, n: int) {
    if term_count(a) < n {
        term_new(a)
    }
    term_focus(a, n)
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
