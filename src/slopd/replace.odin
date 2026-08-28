package main

import "core:fmt"
import "core:strings"
import "../txt"
import "../search"
import "../edit"

// Workspace-wide find and replace: `:rep <old> <new>`.
//
// grep finds the FILES, but never writes them. sed is not wrapped, and the reasons are the
// reasons this file exists:
//   - sed cannot find files, so the pipeline needs a shell, and the pattern would have to be
//     quoted into it — the hazard grep_run avoids by execing grep directly;
//   - view_refresh re-reads only the FOCUSED buffer, so a pass on disk leaves every other open
//     buffer stale, and its next save undoes the replace;
//   - file_write_atomic saves through a symlink and keeps the file's mode bits; `sed -i` renames
//     over the link and takes a fresh file's defaults;
//   - a pass on disk cannot be undone, and every buffer here has an undo journal;
//   - sed has no literal mode, so `&`, backreferences and the delimiter would need escaping on
//     both sides. grep has `-F` and this file uses it.
//
// So the edit lands in BUFFERS: each touched file is loaded into the ring and left unsaved. Undo
// works per file, the unsaved ring is the review list (Alt+P with nothing typed lists exactly
// it), `:wa` is the commit and `:discard <file>` backs one out.
//
// Literal and case-sensitive, unlike `:f`'s smart case: replacing `foo` must not rewrite `Foo`.

// A replace you cannot read is a replace you cannot check. Past this the count is reported and
// nothing is touched.
REP_FILE_MAX :: 100

// `:rep <old> <new>` — two arguments, each a bare word or a quoted string, so a phrase and an
// empty replacement both have a spelling (`:rep "old text" ""`). Trailing junk is rejected
// rather than guessed at: this one writes to files.
rep_parse :: proc(args: string) -> (old, new: string, ok: bool) {
    s := strings.trim_left_space(args)
    raw1, v1 := first_arg(s)
    if raw1 == "" {
        return "", "", false
    }
    s = strings.trim_left_space(s[len(raw1):])
    raw2, v2 := first_arg(s)
    if raw2 == "" || strings.trim_space(s[len(raw2):]) != "" {
        return "", "", false
    }
    return v1, v2, v1 != ""
}

// `:rep <old> <new>` on plain Enter: leave the listing up, the way `:grep` does. It never jumps
// into a lone hit — the pane IS what it is asking you to read. Shift+Enter is what writes.
cl_rep :: proc(a: ^App, args: string) {
    old, new, ok := rep_parse(args)
    if !ok {
        cl_echo(a, "rep: :rep <old> <new> — quote anything with spaces")
        return
    }
    grep_async(a, old, .List, new, true)
}

// Shift+Enter over a `:rep` preview. The search is re-run here rather than read off the pane,
// for the reason `:grep`'s Enter re-runs it: the preview may be a keystroke behind, or still out
// with the worker, and this one WRITES.
rep_apply :: proc(a: ^App, args: string) {
    old, new, ok := rep_parse(args)
    if !ok {
        return
    }
    targets := rep_targets(a, old)
    if len(targets) > REP_FILE_MAX {
        cl_echo(a, fmt.tprintf("rep: %d files, over the %d limit — narrow the pattern", len(targets), REP_FILE_MAX))
        return
    }
    files, hits := 0, 0
    for path in targets {
        b := rep_buffer_for(a, path)
        if b == nil {
            continue
        }
        if n := rep_buffer_replace(b, old, new); n > 0 {
            files += 1
            hits += n
        }
    }
    if files == 0 {
        cl_echo(a, fmt.tprintf("rep: %s not found", old))
        return
    }
    cl_echo(a, fmt.tprintf("rep: %d in %d file%s, unsaved — :wa writes them", hits, files, files == 1 ? "" : "s"))
}

// Every file to look in, each once and in scan order. grep speaks for the disk; a dirty buffer
// holds text the disk has not seen, so it is added on its own account.
@(private = "file")
rep_targets :: proc(a: ^App, old: string) -> []string {
    seen := make(map[string]bool, 32, context.temp_allocator)
    out := make([dynamic]string, 0, 32, context.temp_allocator)
    for h in grep_project(a, old, false, true) {
        if !seen[h.path] {
            seen[h.path] = true
            append(&out, h.path)
        }
    }
    for &b in a.editor.buffers {
        if !b.dirty || !edit.buffer_on_disk(&b) || !strings.has_prefix(b.path, a.project_root) {
            continue
        }
        if !seen[b.path] {
            seen[b.path] = true
            append(&out, b.path)
        }
    }
    return out[:]
}

// The ring's buffer for `path`, loading the file into a new one when none holds it. Nil when it
// cannot be read. The ACTIVE buffer is left alone, unlike open_file: a replace touches many
// files and must not walk the view through them.
@(private = "file")
rep_buffer_for :: proc(a: ^App, path: string) -> ^edit.Buffer {
    e := &a.editor
    for &b, i in e.buffers {
        if b.path == path && !b.embedded {
            return &e.buffers[i]
        }
    }
    b: edit.Buffer
    if !edit.buffer_load(&b, path) {
        edit.buffer_destroy(&b)
        return nil
    }
    append(&e.buffers, b)
    return &e.buffers[len(e.buffers) - 1]
}

// One file, as ONE undo step: doc_commit journals the whole batch, so a single undo in that file
// backs all of it out. The cursors land on the replacements, as they do after `:f` + Shift+Enter.
rep_buffer_replace :: proc(b: ^edit.Buffer, old, new: string) -> int {
    offs := rep_offsets(txt.doc_string(&b.doc, context.temp_allocator), old)
    if len(offs) == 0 {
        return 0
    }
    edits := make([dynamic]txt.Edit, 0, len(offs), context.temp_allocator)
    for off in offs {
        append(&edits, txt.Edit{off, off + len(old), new, 0})
    }
    if !txt.doc_commit(&b.doc, edits[:]) {
        return 0
    }
    b.dirty = true
    return len(offs)
}

// Byte offsets of every literal, non-overlapping occurrence, which is what Edit wants. Scanned
// over the DOCUMENT and not read off the grep hits: a hit carries only the first match on its
// line, so trusting it would leave the second one behind.
rep_offsets :: proc(text, pat: string, alloc := context.temp_allocator) -> []int {
    out := make([dynamic]int, 0, 16, alloc)
    if pat == "" {
        return out[:]
    }
    for at := 0; at <= len(text) - len(pat); {
        i := strings.index(text[at:], pat)
        if i < 0 {
            break
        }
        append(&out, at + i)
        at += i + len(pat)
    }
    return out[:]
}

// `(12 in 4 files · Shift+Enter)` — the count you read before you commit, which is the whole
// point of the preview. Keyed on the preview's kind, like cl_grep_hint.
cl_rep_hint :: proc(a: ^App, args: string) -> string {
    old, _, ok := rep_parse(args)
    if !ok {
        return "(<old> <new>)"
    }
    // The preview declines a pattern this short, since it walks the project at every pause. The
    // commit still takes it, so the line has to say why it has gone quiet rather than look ready.
    if len(old) < CL_GREP_MIN {
        return "(too short to preview)"
    }
    if a.cl_preview.kind != .Replace {
        return ""
    }
    if grep_searching(a) {
        return "(searching…)"
    }
    if n := len(a.grep.hits); n > 0 {
        f := search.grep_file_count(&a.grep)
        return fmt.tprintf("(%d in %d file%s · Shift+Enter)", n, f, f == 1 ? "" : "s")
    }
    return "(no matches)"
}
