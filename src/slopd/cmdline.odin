package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "vendor:glfw"
import "../txt"
import "../pty"
import "../edit"

// The master command line: a one-line Doc (so every motion/edit op is reused from the buffer;
// Enter submits instead of splitting) plus a history ring and an executor. Output never lands
// here: builtins mutate app state, shell commands go to a terminal. Driven by input.odin.
//
// A line is SHELL unless it starts with the `:` sigil — `grep foo` is the real grep, `:grep foo`
// is our Grep pane. Alt+C opens empty, Alt+; opens with the sigil typed.
CommandLine :: struct {
    using doc:  txt.Doc,
    history:  [dynamic]string,
    hist_idx: int, // index into history; == len(history) means the live edit
    // A UI gesture pre-filled the line; it renders in the alert colour until touched. Version
    // tracked so any edit clears the alert with no per-edit hook.
    injected:   bool,
    inject_ver: u64,
}

cl_init :: proc(cl: ^CommandLine) {
    txt.doc_init(&cl.doc)
}

cl_destroy :: proc(a: ^App) {
    for s in a.cl.history {
        delete(s)
    }
    delete(a.cl.history)
    txt.doc_destroy(&a.cl.doc)
}

// Open the line, optionally with `prefix` already typed (Alt+; passes the `:` sigil). Not an
// injection: the prefix is a keystroke saved, not a command staged, so no alert.
cl_open :: proc(a: ^App, prefix := "") {
    a.cl_active = true
    txt.doc_clear(&a.cl.doc)
    a.cl.hist_idx = len(a.cl.history)
    a.cl.injected = false
    if prefix != "" {
        cl_recall(a, prefix)
    }
}

// Stage a command for the user to review and run with Enter (e.g. the filetree folder cd).
cl_inject :: proc(a: ^App, text: string) {
    cl_open(a)
    cl_recall(a, text)
    a.cl.injected = true
    a.cl.inject_ver = a.cl.doc.version
}

// A gesture producing a FULL line either stages it (default) or runs it, per config. Gestures
// pre-filling an INCOMPLETE command (e.g. Alt+W's "j ") call cl_inject directly.
cl_dispatch :: proc(a: ^App, text: string, run: bool) {
    if run {
        cl_exec(a, text)
    } else {
        cl_inject(a, text)
    }
}

cl_cancel :: proc(a: ^App) {
    cl_preview_restore(a)
    a.cl_active = false
    txt.doc_clear(&a.cl.doc)
}

cl_submit :: proc(a: ^App) {
    if input := cl_close_kept(a); input != "" {
        cl_exec(a, input)
    }
}

// Shift+Enter over a `:f` line: every hit takes a cursor and the line closes WITHOUT running
// — the search already did the work, and re-running it would collapse the set back to one.
// False when the line does not answer it, and plain Enter stands.
cl_submit_all :: proc(a: ^App) -> bool {
    // The TYPED LINE decides, not the preview's kind, so the gesture still works with
    // `cl_preview` turned off.
    name, args, ok := cl_builtin_call(txt.doc_string(&a.cl.doc, context.temp_allocator))
    if !ok {
        return false
    }
    switch name {
    case "rep":
        // A `:rep` line commits rather than selecting: its hits are in files this page does not
        // hold, so there is no cursor set to land them on.
        if _, _, valid := rep_parse(args); !valid {
            return false
        }
        rep_apply(a, args) // before the close: it reads the typed line
    case "f", "find":
        if a.cl_preview.kind != .Find {
            cl_find(a, args) // no preview ran the search, so it is owed here
        }
        if !cl_find_select_all(a) {
            return false
        }
    case:
        return false
    }
    cl_close_kept(a)
    return true
}

// One selected cursor per hit, the head at its end. The primary stays on the hit the caret is
// on, so the view does not jump. False when there is nothing to take.
@(private = "file")
cl_find_select_all :: proc(a: ^App) -> bool {
    b := main_text_buffer(a)
    if b == nil || len(a.find.matches) == 0 {
        return false
    }
    clear(&b.cursors)
    for m in a.find.matches {
        head := txt.doc_clamp_pos(&b.doc, txt.Pos{m.line, m.col + m.n})
        append(&b.cursors, txt.Cursor{
            anchor = txt.doc_clamp_pos(&b.doc, txt.Pos{m.line, m.col}),
            head   = head,
            goal   = txt.doc_cell_col(&b.doc, head),
        })
    }
    b.primary = clamp(a.find.cur, 0, len(b.cursors) - 1)
    return true
}

// Both Enter paths share this: the preview's landing stays, the line closes, and what you typed
// goes to history. Returns it, or "" for an empty line.
@(private = "file")
cl_close_kept :: proc(a: ^App) -> string {
    input := strings.trim_space(txt.doc_string(&a.cl.doc, context.temp_allocator))
    cl_preview_commit(a) // keep what the preview landed on
    a.cl_active = false
    txt.doc_clear(&a.cl.doc)
    if input != "" {
        append(&a.cl.history, strings.clone(input))
    }
    return input
}

// The way back from a jump (link.odin), left newest in the ring so Alt+C then Up is the return
// trip. A jump inside one file needs no path; a buffer with no file cannot be named by a `:j`
// line at all, so it leaves nothing. Quoted only when a space would split the path in two.
cl_history_jump :: proc(a: ^App, from_path, to_path: string, line: int) {
    cmd: string
    switch {
    case from_path == to_path:
        cmd = fmt.tprintf(":j %d", line + 1)
    case from_path == "":
        return
    case:
        arg := from_path
        if strings.contains(arg, " ") {
            arg = sh_quote(arg, context.temp_allocator)
        }
        cmd = fmt.tprintf(":j %s %d", arg, line + 1)
    }
    append(&a.cl.history, strings.clone(cmd))
}

cl_history_prev :: proc(a: ^App) {
    if a.cl.hist_idx > 0 {
        a.cl.hist_idx -= 1
        cl_recall(a, a.cl.history[a.cl.hist_idx])
    }
}

cl_history_next :: proc(a: ^App) {
    if a.cl.hist_idx < len(a.cl.history) {
        a.cl.hist_idx += 1
        if a.cl.hist_idx == len(a.cl.history) {
            txt.doc_clear(&a.cl.doc)
        } else {
            cl_recall(a, a.cl.history[a.cl.hist_idx])
        }
    }
}

@(private = "file")
cl_recall :: proc(a: ^App, text: string) {
    txt.doc_set_text(&a.cl.doc, text)
    txt.doc_cursor_to_end(&a.cl.doc)
}

// A submitted line is a chain of `&&` segments, each a builtin (`:name`) or a shell command. A
// step runs only once the preceding shell step exits 0, reported asynchronously via the OSC
// sentinel, so the chain pumps a frame at a time. Adjacent shell segments coalesce and keep their
// `&&` for the shell. `text` is stored sigil-free.
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
    wait_term: ^pty.Terminal,
}

// The private OSC tag must match src/pty's OSC_EXIT_TAG.
@(private = "file")
EXIT_OSC :: 697

// A new line abandons any half-finished chain.
cl_exec :: proc(a: ^App, input: string) {
    cl_parse(a, input)
    cl_chain_pump(a)
}

// Chain-building without execution, split out so parsing is unit-testable.
cl_parse :: proc(a: ^App, input: string) {
    cl_chain_clear(a)
    ch := &a.cl_chain
    ch.target = cl_term(a)

    rest := strings.trim_space(input)

    // A leading `:tN` sets the target terminal for the chain's shell parts; alone it is a goto.
    // Stripped before segmenting, so `:t2 make` throws a raw `make` at session 2.
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
                continue // a bare `:` names no builtin
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

// Split into `&&` segments the way the shell would: an `&&` separates only where the shell sees
// an operator, not inside quotes, after a backslash, or inside `...`, $(...) or a subshell. So
// `rm -rf 'a && b.txt' && :ls` is two steps. Never expands or unquotes — segments go on verbatim.
// An unclosed quote or paren swallows the rest, as the shell would.
//
// Returns temp-allocated slices of `s`. Only `&&` is an operator here; `;`, `|` and `||` ride
// along inside a segment.
@(private = "file")
cl_split_chain :: proc(s: string, alloc := context.temp_allocator) -> []string {
    out := make([dynamic]string, 0, 4, alloc)
    depth: int // unquoted ( ) / $( ) nesting
    tick: bool // inside `...`
    start, i := 0, 0
    for i < len(s) {
        c := s[i]
        switch {
        case c == '\'' || c == '"':
            // quoted_span knows where a quote ends; an unclosed one swallows the rest.
            _, n, ok := quoted_span(s[i:])
            i += ok ? n : len(s) - i
            continue
        case c == '\\':
            i += 1 // escapes anything, `&` included
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

// Advance the chain as far as it can this frame: resolve a pending exit code (short-circuiting
// on failure), run builtins inline, inject the next shell step and wait unless it is the last.
cl_chain_pump :: proc(a: ^App) {
    ch := &a.cl_chain
    if !ch.waiting && len(ch.steps) == 0 {
        return // nothing running
    }
    if ch.waiting {
        t := ch.wait_term
        if t == nil || !pty.terminal_alive(t) {
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

// The final step runs plain; a non-final one is wrapped so the shell reports its exit code.
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
        pty.terminal_write(t, transmute([]u8)strings.concatenate({cmd, "\n"}, context.temp_allocator))
        return
    }
    id := a.cl_wait_seq
    a.cl_wait_seq += 1
    t.exit_ready = false // discard any stale report
    // Pager neutralised: git's `less` would block on a keypress and stall the chain. The trailing
    // `;printf` always runs, reporting the group's exit code via the private OSC.
    line := fmt.tprintf(
        "(export GIT_PAGER=cat PAGER=cat; %s) ;printf '\\033]%d;%d;%%d\\007' \"$?\"\n",
        cmd,
        EXIT_OSC,
        id,
    )
    pty.terminal_write(t, transmute([]u8)line)
    ch.waiting = true
    ch.wait_id = id
    ch.wait_term = t
}

// `text` is the segment with its `:` stripped. Fails only on an unknown name — the sigil
// promised a builtin, so a typo says so in the CL's session and stops the chain. This is the whole
// registry; a new builtin is a case here and a row in the README's table.
@(private = "file")
cl_run_builtin :: proc(a: ^App, text: string) -> bool {
    name := first_field(text)
    args := strings.trim_space(text[len(name):])
    switch name {
    case "ls":
        set_aux(a, .FileTree)
        filetree_reload(&a.tree) // also the refresh gesture, and the tail of a staged rm
    case "gs":
        git_tool_open(a)
    case "cf":
        set_aux(a, .Config)
        config_pane_refresh(&a.config_pane)
    case "bind", "binds":
        set_aux(a, .Binds)
    case "rebind":
        cl_rebind(a, args)
    case "macro":
        cl_macro(a, args)
    case "macros":
        config_open_macros(a) // the block itself: its values are command lines, so the editor
    case "readme", "README":
        open_embedded_doc(a, .Readme)
    case "license", "LICENSE":
        open_embedded_doc(a, .License)
    case "zen", "zm":
        view_toggle_zen(a)
    case "full", "face":
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
    case "rep":
        cl_rep(a, args)
    case "cd":
        cl_cd(a, args)
    case "reload":
        cl_reload(a, args)
    case "saved":
        cl_saved(a)
    case "crlf":
        cl_crlf(a)
    case "discard":
        cl_discard(a, args)
    case "tu":
        cl_tu(a)
    case "color", "colour", "colors", "colours":
        cl_color(a)
    case "return", "return!":
        cl_return(a, name == "return!", args)
    case "w", "w!", "wa", "q", "q!", "wq", "wqa", "waq":
        cl_quit(a, name, args)
    case:
        cl_echo(a, fmt.tprintf("%s: not a builtin (drop the : to run it in the shell)", name))
        return false
    }
    return true
}

// --- saving --- Every save gesture goes through cl_save (Ctrl+S, `:w`) so the two agree about
// locked files. `:wa` stays on plain buffer_save: a write-all hitting three unwritable files has
// no one line to stage.

// Save, and on a permission denial stage the line that gets there anyway.
cl_save :: proc(a: ^App, b: ^edit.Buffer) -> edit.Save_Result {
    res := edit.buffer_save(b)
    // A staged line is the report; only a denial that cannot stage has to speak.
    if res == .Denied && !save_stage_sudo(a, b) {
        cl_echo(a, "save: permission denied, and no private folder to stage a sudo copy in")
    }
    return res
}

// Write the bytes to a private copy and prefill the `sudo cp` line that carries them over. The
// shell half of the CL is the one place a password prompt can be typed.
//
// False when there is nowhere private to put the copy, or the copy fails.
save_stage_sudo :: proc(a: ^App, b: ^edit.Buffer) -> bool {
    dir := save_tmp_dir()
    if dir == "" || !edit.buffer_on_disk(b) {
        return false
    }
    // pid + counter: a staged line can sit in history while another buffer is saved, and a copy
    // named for the file alone would hand the older line the newer file's bytes.
    a.save_seq += 1
    name := fmt.tprintf("slopd-%d-%d-%s", os.get_pid(), a.save_seq, filepath.base(b.path))
    tmp := filepath.join({dir, name}, context.temp_allocator) or_else ""
    if tmp == "" {
        return false
    }
    edit.buffer_drop_save_tmp(b) // one staged copy per buffer
    if os.write_entire_file(tmp, transmute([]u8)edit.buffer_bytes(b), {.Read_User, .Write_User}) != nil {
        return false
    }
    b.save_tmp = strings.clone(tmp)
    line := sudo_save_command(tmp, b.path, context.temp_allocator)
    cl_inject(a, line)
    return true
}

// --- opening --- A file we may not READ is the other half of the sudo save: one gesture that
// cannot get through, and one line that can. Staged by open_file, so every gesture that opens
// (the filetree, `:j`, the fuzzy finder, a link) reports it the same way.

// Stage the line that unlocks `path` and opens it again. False when the open failed for any
// other reason, which is not ours to answer.
open_stage_sudo :: proc(a: ^App, path: string) -> bool {
    if !edit.path_read_denied(path) {
        return false
    }
    cl_inject(a, sudo_open_command(path, context.temp_allocator))
    return true
}

// $XDG_RUNTIME_DIR, else ~/.cache, else "" and nothing is staged.
//
// /tmp is excluded deliberately: root is about to read this file, and a shared /tmp lets another
// local user own the path first and swap the contents between our write and root's copy.
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

// `:saved`: drop the dirty flag because the disk already holds these bytes. Safe as a plain
// builtin because it verifies rather than trusts — it is a no-op when the disk disagrees.
// Every unsaved buffer, not just the one on screen: the staged line carries no name to say
// which it was for, and a buffer whose bytes equal its own file is saved either way.
@(private = "file")
cl_saved :: proc(a: ^App) {
    if edit.ring_mark_saved_matching(&a.editor) == 0 {
        cl_echo(a, ":saved: no unsaved buffer holds what its file holds — nothing changed")
    }
}

// Flip this buffer's line endings. The load detects them and the save restores them, so this is
// only for converting a file, or for saying what a new one gets. Dirty either way: the disk
// still holds the other ending until a `:w`.
@(private = "file")
cl_crlf :: proc(a: ^App) {
    b := main_text_buffer(a)
    if b == nil {
        return
    }
    b.crlf = !b.crlf
    b.dirty = true
    cl_echo(a, fmt.tprintf(":crlf: line endings are %s now — `:w` writes them", b.crlf ? "CRLF" : "LF"))
}

// The only way to close Slopd (Esc never quits), guarded by the unsaved ring. Refusals echo into
// the CL's session naming the sigilled line that would work.
@(private = "file")
cl_quit :: proc(a: ^App, cmd: string, args: string) {
    switch cmd {
    case "w", "w!":
        if strings.trim_space(args) != "" {
            cl_write_copy(a, edit.editor_current(&a.editor), args, cmd == "w!")
            return
        }
        // A denial stages its own `sudo cp` line, which is the message.
        switch cl_save(a, edit.editor_current(&a.editor)) {
        case .No_Path: cl_echo(a, ":w: no filename — `:w <path>` names it")
        case .Failed:  cl_echo(a, ":w: could not write the file")
        case .Ok, .Denied:
        }
    case "wa":
        cl_write_all(a)
    case "q!":
        a.quit = true
    case "q":
        if n := edit.ring_dirty_count(&a.editor); n > 0 {
            cl_echo(a, fmt.tprintf(":q: %d unsaved buffer(s) — :wqa saves+quits, :q! drops", n))
        } else {
            a.quit = true
        }
    case "wq":
        edit.buffer_save(edit.editor_current(&a.editor))
        if n := edit.ring_dirty_count(&a.editor); n > 0 {
            cl_echo(a, fmt.tprintf(":wq: %d other unsaved buffer(s) — :wqa or :q!", n))
        } else {
            a.quit = true
        }
    case "wqa", "waq":
        cl_write_all(a)
        if n := edit.ring_dirty_count(&a.editor); n > 0 {
            cl_echo(a, fmt.tprintf(":wqa: %d buffer(s) could not be saved — :q! to discard", n))
        } else {
            a.quit = true
        }
    }
}

// `:w <path>`: write these bytes THERE and stay on this file, as vim does — a copy, not a
// save-as, so the buffer keeps its name and its unsaved mark. `:w! <path>` overwrites an
// existing file; plain `:w` refuses one, since a mistyped name must not eat what is already
// there. Silent on success, like every other write.
@(private = "file")
cl_write_copy :: proc(a: ^App, b: ^edit.Buffer, args: string, force: bool) {
    path := cl_resolve_path(a, unquote_arg(strings.trim_space(args)))
    defer delete(path)
    if why := cl_write_refusal(path, force); why != "" {
        cl_echo(a, why)
        return
    }
    if edit.file_write_atomic(path, edit.buffer_bytes(b)) != .Ok {
        cl_echo(a, fmt.tprintf(":w: could not write %s", path))
        return
    }
    // A buffer with no file was not COPIED anywhere — it was named. It takes the path, so the
    // next `^S` writes it, the modeline says where, and the extension picks up a grammar.
    if b.path == "" && !b.embedded {
        delete(b.path)
        b.path = strings.clone(path)
        edit.buffer_mark_saved(b)
    }
}

// Why `path` may not be written, or "" when it may. Split from the write and pure, so what the
// bang is FOR is assertable without a terminal to echo into. Temp-allocated.
cl_write_refusal :: proc(path: string, force: bool) -> string {
    dir := filepath.dir(path) // slices into path; not owned
    switch {
    case path == "" || os.is_dir(path):
        return ":w: that is a directory, not a file"
    case !os.is_dir(dir):
        return fmt.tprintf(":w: no such folder: %s", dir)
    case !force && os.exists(path):
        return fmt.tprintf(":w: %s exists — `:w! <path>` overwrites it", path)
    }
    return ""
}

// `:discard [file]`: throw a buffer's unsaved edits away and take the disk version back, so the
// file leaves the unsaved ring. Bare, the current buffer; with a path, whichever buffer holds
// that file — which is how the file panes' gesture reaches a buffer you are not looking at.
//
// A file with nothing unsaved is a no-op that says so, so a line left staged past a save cannot
// undo it.
@(private = "file")
cl_discard :: proc(a: ^App, args: string) {
    arg := unquote_arg(strings.trim_space(args))
    b := main_text_buffer(a)
    if arg != "" {
        path := cl_resolve_path(a, arg)
        defer delete(path)
        b = edit.ring_dirty_buffer(&a.editor, path)
        if b == nil {
            cl_echo(a, fmt.tprintf(":discard: %s has no unsaved changes", arg))
            return
        }
    }
    if b == nil || !edit.buffer_discard(b) {
        cl_echo(a, ":discard: nothing to take back — this buffer has no file on disk")
    }
}

// Returns how many of the ring's buffers are still unsaved; one with no file is not in it.
@(private = "file")
cl_write_all :: proc(a: ^App) -> int {
    for &b in a.editor.buffers {
        if b.dirty {
            edit.buffer_save(&b)
        }
    }
    return edit.ring_dirty_count(&a.editor)
}

// Feedback lands in a real terminal (spawning it) rather than the status strip. sh_quote means
// a message carrying the user's own text can hold anything.
cl_echo :: proc(a: ^App, msg: string) {
    run_in_cl_term(a, fmt.tprintf("echo %s", sh_quote(msg, context.temp_allocator)))
}

// `:cd [dir]`: set the project root, never a shell's cwd (an unsigilled `cd` is the shell's).
// Only an existing directory is accepted. New terminals spawn here; `:tu` syncs the unlocked.
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

// `~`, `~/x`, project-root-relative or absolute -> absolute cleaned path, owned by the caller.
// Existence is the caller's check.
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

// `:tu`: push `cd <project root>` into every unlocked live terminal. Locked sessions (Alt+L)
// keep their cwd. Changes no focus.
@(private = "file")
cl_tu :: proc(a: ^App) {
    if a.project_root == "" {
        return
    }
    line := cd_command(a.project_root, context.temp_allocator)
    for t in a.terminals {
        if pty.terminal_alive(t) && !t.locked {
            pty.terminal_write(t, transmute([]u8)line)
        }
    }
}

// "Set workspace here": `:cd <dir>` then `:tu`. Reached by the `^h` chord and the file panes'
// context menu.
cl_workspace :: proc(a: ^App, dir: string) {
    if dir == "" {
        return
    }
    cl_cd(a, dir)
    cl_tu(a)
}

// `slopd --<path>`: applied once at startup, before the first frame. A directory becomes the
// workspace; a file opens in the editor with its folder as the workspace. The file panes are
// pointed at it too, since at launch there is no browsed dir to take it from.
//
// False for a path that does not exist — main says so on stderr rather than ignoring it.
cl_launch_path :: proc(a: ^App, arg: string) -> bool {
    if arg == "" { // unlike a bare `:cd`, this is not "home"
        return false
    }
    path := cl_resolve_path(a, arg)
    defer delete(path)
    if path == "" || !os.exists(path) {
        return false
    }
    file := !os.is_dir(path)
    dir := file ? filepath.dir(path) : path // slices into path; not owned
    if !os.is_dir(dir) {
        return false
    }
    cl_workspace(a, dir)
    filetree_load(&a.tree, dir)
    if file {
        open_file(a, path)
    }
    return true
}

// `:reload [y|n]`: settle a pending disk-change conflict, which auto-stages this line.
//   :reload y   re-read, discarding unsaved edits
//   :reload n   keep the edits, and stop asking until the file changes again
// The third way out is `:w`, which writes my version over the conflict. A bare `:reload` while
// conflicted is a no-op so an accidental Enter cannot discard edits; with no conflict it is a
// manual refresh (vim's :e!).
@(private = "file")
cl_reload :: proc(a: ^App, args: string) {
    if a.main != .Text || len(a.editor.buffers) == 0 {
        return
    }
    b := edit.editor_current(&a.editor)
    arg := strings.to_lower(strings.trim_space(args), context.temp_allocator)
    if b.conflict {
        switch arg { // needs an explicit answer; bare `reload` waits
        case "y", "yes": edit.buffer_conflict_resolve(b, true)
        case "n", "no":  edit.buffer_conflict_resolve(b, false)
        }
        return
    }
    switch arg { // no conflict: a manual refresh
    case "", "y", "yes": edit.buffer_reload_keep_view(b)
    }
}

// `:j [file] [line]` / `:jump ...`: reveal a location through jump_to.
//   :j N            line in the current buffer (1-based, matching the gutter)
//   :j +N / :j -N   relative to the current line
//   :j <file>       open it (name-first under the project root, or an absolute path)
//   :j <file> N     open it at line N (+N/-N here is relative to the file's top)
// Out-of-range lines clamp. A name with spaces is quoted (`:j "my notes.md" 12`).
@(private = "file")
cl_jump :: proc(a: ^App, args: string) {
    s := strings.trim_space(args)
    if s == "" {
        return
    }
    b := edit.editor_current(&a.editor)

    if pos, ok := cl_jump_line(b, s); ok {
        jump_to(a, "", pos.line, txt.doc_cell_col(&b.doc, pos))
        return
    }
    raw, first := first_arg(s)
    rest := strings.trim_space(s[len(raw):])
    path, found := jump_resolve_path(a, first)
    if !found {
        return
    }
    line := 0
    if rest != "" {
        line, _ = parse_line_spec(rest, 0) // relative to the file's top
    }
    jump_to(a, path, max(line, 0), 0)
}

// Where a bare-line `:j` argument lands, clamped into the buffer. ok=false when the argument
// names a file. Shared with the live preview so the two cannot disagree.
cl_jump_line :: proc(b: ^edit.Buffer, args: string) -> (txt.Pos, bool) {
    s := strings.trim_space(args)
    raw, first := first_arg(s)
    if strings.trim_space(s[len(raw):]) != "" {
        return {}, false // a second field means the first was a file name
    }
    cur := b.cursors[b.primary].head
    line, ok := parse_line_spec(first, cur.line)
    if !ok {
        return {}, false
    }
    line = clamp(line, 0, txt.doc_line_count(&b.doc) - 1)
    // Keep the column by CELL, as a vertical motion does; a byte offset would land elsewhere.
    return txt.Pos{line, txt.doc_byte_col(&b.doc, line, txt.doc_cell_col(&b.doc, cur))}, true
}

// `:f <text>` / `:find <text>`: put the caret on a match in the open buffer.
//
// No hand-off from the preview needed: it leaves the caret on the match it cycled to, and "first
// match at or after the caret" is then that same match. The marks go down — Enter is an answer.
cl_find :: proc(a: ^App, args: string) {
    b := main_text_buffer(a)
    if b == nil {
        return
    }
    find_set(&a.find, b, strings.trim_space(args), b.cursors[b.primary].head)
    a.find.show = false
    if p, ok := find_pos(&a.find); ok {
        txt.doc_reset_cursor(&b.doc, p)
        set_focus(a, .Editor)
    }
}

// `:grep [flags] <pattern>`: project-wide search into the Grep pane. The live preview runs the
// same search as you type; Enter re-runs it over what the files hold now, and only then may a
// lone hit skip the pane.
@(private = "file")
cl_grep :: proc(a: ^App, args: string) {
    query := cl_grep_query(args)
    if query == "" {
        return
    }
    grep_async(a, query, .Open) // the pane fills when the worker answers
}

// Leading `-flags` are discarded (grep_run forces its own); the rest is kept whole as a regex.
// So a pattern beginning with '-' cannot be expressed here — use plain `grep` for that. Shared
// with the live preview.
cl_grep_query :: proc(args: string) -> string {
    query := strings.trim_space(args)
    for query != "" && query[0] == '-' {
        query = strings.trim_space(query[len(first_field(query)):])
    }
    return query
}

// `:put [text]`: type the text then the editor's selection into the target terminal, with no
// trailing newline, so it composes a command at the prompt.
@(private = "file")
cl_put :: proc(a: ^App, args: string) {
    sel := editor_selection_text(a, context.temp_allocator)
    parts := args != "" && sel != "" ? []string{args, " ", sel} : []string{args, sel}
    text := strings.concatenate(parts, context.temp_allocator)
    term_focus(a, a.cl_chain.target)
    if t := term_current(a); t != nil {
        pty.terminal_write(t, transmute([]u8)text)
    }
}

// --- shell command builders --- UI gestures stage a real shell line rather than hiding the work
// behind a modal: you read it, edit it, Enter, and it lands in history. Pure, so they test
// without an App.

// Single-quote s. An embedded quote closes, escapes and reopens ('\'') — safe in every POSIX
// shell.
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

// The line `:tu` types into a terminal. Single-quoted, because a project root is a directory
// NAME: a shell expands `$( )`, a backtick and a `$var` inside DOUBLE quotes, so a folder called
// `$(id)` would run it. "" when there is no root.
cd_command :: proc(root: string, alloc := context.allocator) -> string {
    if root == "" {
        return ""
    }
    return strings.concatenate({"cd ", sh_quote(root, context.temp_allocator), "\n"}, alloc)
}

// `rm -rf '<path>' ... && :ls` — once the rm exits 0 the chain re-reads the listing. "" when
// nothing is selected.
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

// `sudo cp '<tmp>' '<path>' && :saved`.
//
// cp, not mv: cp writes through to the destination inode, keeping owner, mode, ACLs, hardlinks
// and following symlinks. mv across a filesystem is copy-then-unlink, leaving a new root-owned
// 0600 inode — /etc/nginx.conf would silently stop being readable by nginx.
//
// The `&& :saved` waits on the exit code, so a wrong password leaves the buffer dirty.
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

// `sudo chmod a+r '<path>' && :j '<path>'`.
//
// a+r, not u+r: the file is someone else's (root's, usually), so the owner's bits are not the
// ones locking us out. It is a lasting change to the file, which is why it is STAGED — the line
// is there to be read and edited before Enter.
//
// The `&& :j` waits on the exit code, so a wrong password opens nothing.
sudo_open_command :: proc(path: string, alloc := context.allocator) -> string {
    if path == "" {
        return ""
    }
    return strings.concatenate(
        {
            "sudo chmod a+r ",
            sh_quote(path, context.temp_allocator),
            " && :j ",
            cl_quote_arg(path, context.temp_allocator),
        },
        alloc,
    )
}

// One `stat` cut to mode, size, owner and the two timestamps. --printf, not -c: only the former
// interprets the `\n`s.
PROPS_FORMAT :: `stat --printf '%n\n  %A  %s bytes  %U:%G\n  modified %y\n  created  %w\n' -- `

// "" when there is nothing to describe. A directory reports its own entry, not a recursive size.
properties_command :: proc(path: string, alloc := context.allocator) -> string {
    if path == "" {
        return ""
    }
    return strings.concatenate({PROPS_FORMAT, sh_quote(path, context.temp_allocator)}, alloc)
}

// The line that runs a file, or "" when it isn't ours to run (the caller hands those to
// desktop_open). A non-executable shell script still runs under `bash`, since chmod +x is the
// step people skip. The trailing space is so args type straight on.
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

// Steps left, or a shell step whose exit code has not come back. The disk poll asks, so a chain
// rewriting the open file (the sudo save) is not interrupted by a prompt about its own change.
cl_chain_busy :: proc(a: ^App) -> bool {
    return a.cl_chain.waiting || len(a.cl_chain.steps) > 0
}

cl_chain_clear :: proc(a: ^App) {
    ch := &a.cl_chain
    for step in ch.steps {
        delete(step.text)
    }
    delete(ch.steps) // commands are rare; no need to pool
    ch.steps = nil
    ch.idx = 0
    ch.waiting = false
    ch.wait_term = nil
}

// Surface the command line's own session and run — no chaining.
run_in_cl_term :: proc(a: ^App, cmd: string) {
    run_in_term(a, cmd, cl_term(a))
}

// The session the command line works in: its shell steps, its messages, and the file pane's
// runs. `:tN` overrides it for one line. Clamped, since a bare App has no config loaded.
cl_term :: proc(a: ^App) -> int {
    return max(1, a.run_term)
}

// The same in session `n` — the open ones plus the next, so `run_term: 8` with three open opens
// the fourth rather than landing in the third (term_slot).
run_in_term :: proc(a: ^App, cmd: string, n: int) {
    term_surface(a, term_slot(term_count(a), n))
    if t := term_current(a); t != nil {
        pty.terminal_write(t, transmute([]u8)strings.concatenate({cmd, "\n"}, context.temp_allocator))
    }
}

@(private = "file")
editor_selection_text :: proc(a: ^App, alloc := context.temp_allocator) -> string {
    b := edit.editor_current(&a.editor)
    for c in b.cursors {
        if txt.cursor_has_selection(c) {
            joined, _ := txt.doc_copy(&b.doc, alloc)
            return joined
        }
    }
    return ""
}

// Where a quoted span ends, and nothing else -- the ONE reading of a quote in this file, so the
// chain splitter and the argument parsers cannot drift apart about where one ends. `n` covers
// both quotes and `inner` is the text between them, raw. ok=false when `s` does not open with a
// quote or the quote never closes, which the shell lets swallow the rest of the line.
@(private = "file")
quoted_span :: proc(s: string) -> (inner: string, n: int, ok: bool) {
    if len(s) == 0 || (s[0] != '\'' && s[0] != '"') {
        return "", 0, false
    }
    for i := 1; i < len(s); i += 1 {
        if s[0] == '"' && s[i] == '\\' && i + 1 < len(s) {
            i += 1 // an escaped quote is content, not the partner
            continue
        }
        if s[i] == s[0] {
            return s[1:i], i + 1, true
        }
    }
    return "", 0, false
}

// The same span read as an ARGUMENT: cl_quote_arg's escaping comes back off. Only double quotes
// escape, because only they have to -- a single-quoted span has no partner to hide.
@(private = "file")
quoted_value :: proc(s: string) -> (value: string, n: int, ok: bool) {
    inner, span, found := quoted_span(s)
    if !found {
        return "", 0, false
    }
    return s[0] == '"' ? arg_unescape(inner) : inner, span, true
}

first_field :: proc(s: string) -> string {
    i := 0
    for i < len(s) && s[i] != ' ' && s[i] != '\t' {
        i += 1
    }
    return s[:i]
}

// first_field, except a leading quote runs to its partner so a path with spaces works
// (`:j "my file" 40`). Returns the span to skip and the value inside. An unclosed quote falls
// back to the plain field.
first_arg :: proc(s: string) -> (raw, value: string) {
    if v, n, ok := quoted_value(s); ok {
        return s[:n], v
    }
    f := first_field(s)
    return f, f
}

// The inverse of quoted_value. A staged argument must be quoted for the CHAIN rather than for
// looks, because cl_split_chain re-reads the line before any builtin sees it: a file named
// `notes && rm -rf ~` would otherwise stage as two steps.
cl_quote_arg :: proc(s: string, alloc := context.allocator) -> string {
    plain := len(s) > 0
    for i in 0 ..< len(s) {
        if !arg_plain_byte(s[i]) {
            plain = false
            break
        }
    }
    if plain {
        return s // borrowed: nothing to escape
    }
    b := strings.builder_make(alloc)
    strings.write_byte(&b, '"')
    for i in 0 ..< len(s) {
        if s[i] == '"' || s[i] == '\\' {
            strings.write_byte(&b, '\\')
        }
        strings.write_byte(&b, s[i])
    }
    strings.write_byte(&b, '"')
    return strings.to_string(b)
}

// A whitelist, because `&&` is not the only thing that reparses a line -- the quote states, the
// backslash and the subshell parens do too. Bytes over 0x7f are UTF-8 text.
@(private = "file")
arg_plain_byte :: proc(c: u8) -> bool {
    switch c {
    case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
        return true
    case '/', '.', '-', '_', '~', '+', ',', '=', '@', ':', 0x80 ..= 0xff:
        return true
    }
    return false
}

// Undo cl_quote_arg's escaping. Temp-allocated only when there is an escape to strip, so the
// common path still borrows.
@(private = "file")
arg_unescape :: proc(s: string) -> string {
    if !strings.contains(s, "\\") {
        return s
    }
    b := strings.builder_make(context.temp_allocator)
    for i := 0; i < len(s); i += 1 {
        if s[i] == '\\' && i + 1 < len(s) {
            i += 1
        }
        strings.write_byte(&b, s[i])
    }
    return strings.to_string(b)
}

// Strip one matched pair of quotes from an argument that is the whole rest of the line
// (`:cd "my dir"`). Those builtins never needed them, but honouring the habit beats failing.
unquote_arg :: proc(s: string) -> string {
    if v, n, ok := quoted_value(s); ok && n == len(s) {
        return v
    }
    return s
}

// `:tN` — a line prefix, not a step: it says where the chain's shell parts land, so it is read
// and stripped before segmenting.
@(private = "file")
is_term_token :: proc(s: string) -> bool {
    return len(s) >= 3 && s[0] == ':' && s[1] == 't' && all_digits(s[2:])
}

// The builtin a typed line calls, split into name and rest. ok=false when unsigilled or the
// sigil stands alone. Shared by the ghost hint and the live preview.
cl_builtin_call :: proc(line: string) -> (name, args: string, ok: bool) {
    s := strings.trim_space(line)
    if !strings.has_prefix(s, ":") {
        return "", "", false
    }
    body := strings.trim_left_space(s[1:])
    name = first_field(body)
    return name, strings.trim_space(body[len(name):]), name != ""
}

// A faint note drawn past the typed text once a builtin is recognised; add a case to give one a
// hint. Two kinds: a PROMPT names the answers it takes and drops once one is typed (`:reload`),
// a REPORT counts what the live preview found (`:f`). Each case decides for itself, so `args`
// is not tested up here. Takes the App because a hint reads live state.
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
    case "grep":
        return cl_grep_hint(a)
    case "rep":
        return cl_rep_hint(a, args)
    }
    return ""
}

// `(3/17)` — how many matches and which one Up/Down landed on. Read off the search state, not
// the typed line, so it is silent exactly when there is no preview.
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

// Keyed on the preview's kind, not on the pane holding hits, so it stays silent for results from
// elsewhere (an Alt+Enter lookup, a submitted search).
@(private = "file")
cl_grep_hint :: proc(a: ^App) -> string {
    if a.cl_preview.kind != .Grep {
        return ""
    }
    if grep_searching(a) {
        return "(searching…)"
    }
    if n := len(a.grep.hits); n > 0 {
        return fmt.tprintf("(%d match%s)", n, n == 1 ? "" : "es")
    }
    return "(no matches)"
}

// Opens the picker on the colour under the caret and edits it in place. With none there it opens
// on the last one — red the first time — and writes into no buffer.
cl_color :: proc(a: ^App) {
    if color_open_at_caret(a) {
        return
    }
    rgba := a.color.rgba
    if rgba == {} {
        rgba = {1, 0, 0, 1}
    }
    color_open(a, rgba)
}

// Guarded for the bare App the tests build (no buffers at all).
cl_conflict_pending :: proc(a: ^App) -> bool {
    return a.main == .Text && len(a.editor.buffers) > 0 && edit.editor_current(&a.editor).conflict
}

// Switch to session n (1-based), surfacing the pane. Shared by `:tN` and Alt+1..9; clamps n
// into the existing range.
term_focus :: proc(a: ^App, n: int) {
    a.aux_mode = .Terminal
    set_focus(a, .Aux)
    term_ensure(a) // spawns t1 if none exists
    if term_count(a) > 0 {
        a.term_active = clamp(n - 1, 0, term_count(a) - 1)
    }
}

// Surface session `n`, creating it when the number names the one past the last — the most
// term_slot hands back, so one is always enough. term_focus alone only clamps.
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
