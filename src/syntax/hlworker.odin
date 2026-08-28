package syntax

import "base:runtime"
import "core:sync"
import "core:thread"
import ts "../../vendor/odin-tree-sitter"
import "../wake"
import "../txt"

// One thread keeping a buffer's syntax tree up to date while the main thread types into it.
//
// The case is OPENING, not typing: a full parse of a large file is tens of milliseconds (93ms at
// 716KB), which on the main thread is a hitch before anything is on screen. The keystroke case
// is the same trade at a smaller scale.
//
// One job, replaced rather than queued: only the newest snapshot is worth parsing, so holding
// Enter cannot build a backlog. The worker publishes a tree, posts a wake, and the next frame
// picks it up.
//
// Nothing here touches a Doc — a job carries its own flat COPY of the text. Sharing the piece
// table's blocks would be cheaper, but would make pt_load, pt_compact and pt_destroy unsafe
// while a parse is out. One memcpy (~70us at 700KB) buys a job that owns what it points at.

// Everything the worker needs, owned by it once handed over. `text` and `changes` are allocated
// by the submitter and freed HERE, on the other thread, so they come from the process heap
// explicitly: the test runner gives every test its own tracking allocator, and freeing one
// thread's tracking allocation from another is an invalid pointer, not a leak.
Hl_Job :: struct {
    text:    []u8, // the document at `version`, copied
    changes: []txt.Doc_Change, // folded into `base` first; empty means parse from scratch
    base:    ts.Tree, // the tree to edit and reuse, or nil for a full parse
    lang:    ts.Language,
    buf:     rawptr, // identity only; never dereferenced here
    version: u64,
}

// Read by the main thread under `lock`.
Hl_Done :: struct {
    tree:    ts.Tree,
    buf:     rawptr,
    version: u64,
}

Hl_Worker :: struct {
    thread:  ^thread.Thread,
    lock:    sync.Mutex,
    cv:      sync.Cond,
    pending: Hl_Job, // `pending.lang != nil` means there is one
    has_job: bool,
    busy:    bool, // a job is being parsed right now
    done:    Hl_Done, // the newest finished tree, waiting to be taken
    has_done: bool,
    quit:    bool,
    parser:  ts.Parser, // its own: a ts.Parser is not shareable
}

hl_worker_start :: proc(w: ^Hl_Worker) {
    w.thread = thread.create(hl_worker_proc)
    w.thread.data = w
    thread.start(w.thread)
}

// Safe on a worker that never started.
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

    // Whatever was in flight is ours to free now that nothing is running.
    if w.has_job {
        job_destroy(&w.pending)
        w.has_job = false
    }
    if w.has_done && w.done.tree != nil {
        ts.tree_delete(w.done.tree)
        w.has_done = false
    }
}

// `base`, `snap` and `changes` are all adopted, and the last two must be freshly allocated for
// this call. A job already waiting is dropped: it describes an older version.
hl_worker_submit :: proc(w: ^Hl_Worker, job: Hl_Job) {
    sync.mutex_lock(&w.lock)
    defer sync.mutex_unlock(&w.lock)
    if w.has_job {
        job_destroy(&w.pending)
    }
    // No thread: parse here. The worker is an optimisation, not a requirement.
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
    // Broadcast, not signal: hl_worker_idle waits on the same variable, and waking the idler
    // instead of the worker would leave the job sitting there with both asleep.
    sync.cond_broadcast(&w.cv)
}

// Ownership passes to the caller.
hl_worker_take :: proc(w: ^Hl_Worker) -> (Hl_Done, bool) {
    sync.mutex_lock(&w.lock)
    defer sync.mutex_unlock(&w.lock)
    if !w.has_done {
        return {}, false
    }
    w.has_done = false
    return w.done, true
}

// The gate in front of anything that frees a block a snapshot points at, and what the two
// synchronous tree queries wait on rather than answer stale.
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
    w.parser = ts.parser_new() // on the thread that will use it
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
        // A tree nobody took is superseded; only the newest is worth keeping.
        if w.has_done && w.done.tree != nil {
            ts.tree_delete(w.done.tree)
        }
        w.done = Hl_Done{tree = tree, buf = job.buf, version = job.version}
        w.has_done = tree != nil
        w.busy = false
        sync.cond_broadcast(&w.cv) // hl_worker_idle may be waiting on this
        sync.mutex_unlock(&w.lock)

        job_destroy(&job)
        if tree != nil {
            wake.post() // the frame that paints it has to be asked for
        }
    }
}

// Reads the snapshot and nothing else, so the main thread may edit the live document
// throughout.
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

// The process heap, named on both sides so neither picks up a thread-local one by accident.
hl_job_allocator :: proc() -> runtime.Allocator {
    return runtime.heap_allocator()
}

// Over the job's own copy: one span, so the whole file arrives in a single call. A zero length
// is how the API is told this is the end.
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
    // Not nul-terminated, and it need not be: tree-sitter reads exactly bytes_read.
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

// The worker below replays the same changes onto the same tree.
hl_input_edit :: proc(c: txt.Doc_Change) -> ts.Input_Edit {
    return ts.Input_Edit {
        start_byte = u32(c.start),
        old_end_byte = u32(c.old_end),
        new_end_byte = u32(c.new_end),
        start_point = ts.Point{u32(c.start_pt.line), u32(c.start_pt.col)},
        old_end_point = ts.Point{u32(c.old_end_pt.line), u32(c.old_end_pt.col)},
        new_end_point = ts.Point{u32(c.new_end_pt.line), u32(c.new_end_pt.col)},
    }
}
