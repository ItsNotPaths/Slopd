package main

import "base:runtime"
import "core:sync"
import "core:thread"
import ts "../vendor/odin-tree-sitter"
import "wake"

// The parse worker — one thread that keeps a buffer's syntax tree up to date while the main
// thread keeps typing into it.
//
// **The case is opening, not typing.** A full parse of a large file is tens of milliseconds
// (93ms at 716KB), and on the main thread that is a hitch before anything is on screen. Here
// the file appears immediately and its colours land a moment later. The keystroke case is the
// same trade at a smaller scale: an incremental reparse costs microseconds on ordinary files
// and milliseconds on huge ones, and neither should be spent between a keystroke and its glyph.
//
// The shape is one job, replaced rather than queued: only the newest snapshot is worth parsing,
// so holding Enter cannot build a backlog. The worker publishes a tree, posts a wake, and the
// next frame picks it up.
//
// **Nothing here touches a Doc.** A job carries its own flat COPY of the text. Sharing the piece
// table's blocks would be cheaper — they are append-only, so a snapshot could be the piece list
// and nothing else — but it would make pt_load, pt_compact and pt_destroy unsafe to call while a
// parse is out, and that is a use-after-free held off by an ordering rule in three places. One
// memcpy (~70us at 700KB, against a parse measured in milliseconds) buys a job that owns
// everything it points at, and it hands tree-sitter the whole file in a single read.

// A parse request: everything the worker needs, owned by it once handed over.
//
// `text` and `changes` are allocated by the submitter and freed HERE, on the other thread, so
// they are taken from the process heap explicitly rather than from whichever context each side
// happens to be running under — the test runner gives every test its own tracking allocator, and
// freeing one thread's tracking allocation from another is an invalid pointer, not a leak.
Hl_Job :: struct {
    text:    []u8, // the document at `version`, copied
    changes: []Doc_Change, // to fold into `base` before reparsing; empty means parse from scratch
    base:    ts.Tree, // the tree to edit and reuse, or nil for a full parse
    lang:    ts.Language,
    buf:     rawptr, // the Buffer this is for, for identity only — never dereferenced here
    version: u64,
}

// What the worker has finished. Read by the main thread under `lock`.
Hl_Done :: struct {
    tree:    ts.Tree,
    buf:     rawptr,
    version: u64,
}

Hl_Worker :: struct {
    thread:  ^thread.Thread,
    lock:    sync.Mutex,
    cv:      sync.Cond,
    pending: Hl_Job, // the one queued job; `pending.lang != nil` means there is one
    has_job: bool,
    busy:    bool, // a job is being parsed right now
    done:    Hl_Done, // the newest finished tree, waiting to be taken
    has_done: bool,
    quit:    bool,
    parser:  ts.Parser, // the worker's OWN parser: a ts.Parser is not shareable
}

hl_worker_start :: proc(w: ^Hl_Worker) {
    w.thread = thread.create(hl_worker_proc)
    w.thread.data = w
    thread.start(w.thread)
}

// Stop the thread and free everything it holds. Safe to call on a worker that never started.
hl_worker_stop :: proc(w: ^Hl_Worker) {
    if w.thread == nil {
        if w.parser != nil {
            ts.parser_delete(w.parser)
            w.parser = nil
        }
        if w.has_done && w.done.tree != nil {
            ts.tree_delete(w.done.tree)
            w.has_done = false
        }
        return
    }
    sync.mutex_lock(&w.lock)
    w.quit = true
    sync.cond_broadcast(&w.cv)
    sync.mutex_unlock(&w.lock)
    thread.join(w.thread)
    thread.destroy(w.thread)
    w.thread = nil

    // Whatever was still in flight is ours to free now that nothing is running.
    if w.has_job {
        job_destroy(&w.pending)
        w.has_job = false
    }
    if w.has_done && w.done.tree != nil {
        ts.tree_delete(w.done.tree)
        w.has_done = false
    }
}

// Hand over a parse. `base` is adopted — the worker deletes it once the new tree is built — and
// so are `snap` and `changes`, which must be freshly allocated for this call. A job already
// waiting is dropped: it describes an older version of the same buffer and nothing wants it.
hl_worker_submit :: proc(w: ^Hl_Worker, job: Hl_Job) {
    sync.mutex_lock(&w.lock)
    defer sync.mutex_unlock(&w.lock)
    if w.has_job {
        job_destroy(&w.pending)
    }
    // No thread: parse right here. The worker is an optimisation, not a requirement.
    if w.thread == nil {
        j := job
        if w.parser == nil {
            w.parser = ts.parser_new()
        }
        t := hl_worker_parse(w, &j)
        if w.has_done && w.done.tree != nil {
            ts.tree_delete(w.done.tree)
        }
        w.done = Hl_Done{tree = t, buf = j.buf, version = j.version}
        w.has_done = t != nil
        job_destroy(&j)
        return
    }
    w.pending = job
    w.has_job = true
    // BROADCAST, not signal: hl_worker_idle waits on this same variable, and a signal that woke
    // the idler instead of the worker would leave the job sitting there with both asleep.
    sync.cond_broadcast(&w.cv)
}

// Take the newest finished tree, if there is one. Ownership passes to the caller.
hl_worker_take :: proc(w: ^Hl_Worker) -> (Hl_Done, bool) {
    sync.mutex_lock(&w.lock)
    defer sync.mutex_unlock(&w.lock)
    if !w.has_done {
        return {}, false
    }
    w.has_done = false
    return w.done, true
}

// Block until the worker has nothing queued and nothing in flight. The gate in front of anything
// that frees a block a snapshot points at, and what the two synchronous tree queries wait on
// rather than answer from a stale tree.
hl_worker_idle :: proc(w: ^Hl_Worker) {
    if w.thread == nil {
        return
    }
    sync.mutex_lock(&w.lock)
    for w.has_job || w.busy {
        sync.cond_wait(&w.cv, &w.lock)
    }
    sync.mutex_unlock(&w.lock)
}

// --- the thread ---

@(private = "file")
hl_worker_proc :: proc(th: ^thread.Thread) {
    w := (^Hl_Worker)(th.data)
    w.parser = ts.parser_new() // created HERE, on the thread that will use it
    defer ts.parser_delete(w.parser)
    for {
        sync.mutex_lock(&w.lock)
        for !w.has_job && !w.quit {
            sync.cond_wait(&w.cv, &w.lock)
        }
        if w.quit {
            sync.mutex_unlock(&w.lock)
            return
        }
        job := w.pending
        w.has_job = false
        w.busy = true
        sync.mutex_unlock(&w.lock)

        tree := hl_worker_parse(w, &job)

        sync.mutex_lock(&w.lock)
        // A tree nobody took is superseded by this one; only the newest is worth keeping.
        if w.has_done && w.done.tree != nil {
            ts.tree_delete(w.done.tree)
        }
        w.done = Hl_Done{tree = tree, buf = job.buf, version = job.version}
        w.has_done = tree != nil
        w.busy = false
        sync.cond_broadcast(&w.cv) // hl_worker_idle may be waiting on exactly this
        sync.mutex_unlock(&w.lock)

        job_destroy(&job)
        if tree != nil {
            wake.post() // the frame that paints it has to be asked for
        }
    }
}

// Fold the changes into the base tree and reparse. Reads the snapshot and nothing else, so the
// main thread may be editing the live document throughout.
@(private = "file")
hl_worker_parse :: proc(w: ^Hl_Worker, job: ^Hl_Job) -> ts.Tree {
    if !ts.parser_set_language(w.parser, job.lang) {
        return nil
    }
    for c in job.changes {
        edit := hl_input_edit(c)
        ts.tree_edit(job.base, &edit)
    }
    input := ts.Input{payload = rawptr(&job.text), read = hl_snapshot_read, encoding = .UTF8}
    tree, ok := ts.parser_parse(w.parser, job.base, input).?
    if !ok {
        return nil
    }
    return tree
}

// The allocator a job's memory comes from and goes back to: the process heap, named on both
// sides so neither can pick up a thread-local one by accident.
hl_job_allocator :: proc() -> runtime.Allocator {
    return runtime.heap_allocator()
}

// tree-sitter's read, over the job's own copy: one span, so the whole file arrives in a single
// call. A zero length is how the API is told this is the end.
@(private = "file")
hl_snapshot_read :: proc "c" (payload: rawptr, byte_index: u32, position: ts.Point, bytes_read: ^u32) -> cstring {
    context = runtime.default_context()
    text := (^[]u8)(payload)^
    if int(byte_index) >= len(text) {
        bytes_read^ = 0
        return nil
    }
    span := text[byte_index:]
    bytes_read^ = u32(len(span))
    // NOT nul-terminated, and it does not need to be: tree-sitter reads exactly bytes_read.
    return cstring(raw_data(span))
}

@(private = "file")
job_destroy :: proc(j: ^Hl_Job) {
    delete(j.text, hl_job_allocator())
    delete(j.changes, hl_job_allocator())
    if j.base != nil {
        ts.tree_delete(j.base)
    }
    j^ = {}
}
