package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "wake"

// One thread running the project search, so `:grep` never stalls the frame.
//
// The cost is a fork/exec of grep over the whole tree plus a context block read per hit — tens
// of milliseconds on a real project, and the live preview runs it again at every pause in the
// typing. On the main thread that is a visible hitch on a search you may not even keep.
//
// One job, replaced rather than queued, like the highlight worker: only the newest query is
// worth answering. Every request takes a ticket (App.grep_seq) and an answer to anything but
// the newest is dropped, so a slow search cannot land over a newer one.
//
// The thread is an optimisation, not a requirement: with none started, grep_async searches on
// the spot and applies the answer before returning.

// What the answer is for. The preview only lists; `:grep` may jump straight into a lone hit;
// `:rep` lists and never jumps, since the pane IS what it is asking you to read.
Grep_Want :: enum {
    Preview,
    Open,
    List,
}

// Owned by the worker once handed over, and freed there. Allocated from the process heap
// explicitly, so neither side frees the other thread's allocator.
Grep_Job :: struct {
    root:      string,
    query:     string,
    exclude:   []string,
    want:      Grep_Want,
    seq:       u64,
    // `:rep`, carried through so the answer can restate it: the pane is rebuilt from scratch on
    // arrival, and a search is literal exactly when it is a replace.
    replace:   string,
    replacing: bool,
}

// The finished search, heap-allocated the same way and freed by whoever takes it.
Grep_Answer :: struct {
    query:     string,
    hits:      []GrepHit, // context blocks already filled
    want:      Grep_Want,
    seq:       u64,
    replace:   string,
    replacing: bool,
}

Grep_Worker :: struct {
    thread:   ^thread.Thread,
    lock:     sync.Mutex,
    cv:       sync.Cond,
    pending:  Grep_Job,
    has_job:  bool,
    done:     Grep_Answer,
    has_done: bool,
    quit:     bool,
}

// The process heap, named on both sides so neither picks up a thread-local one by accident.
grep_job_allocator :: proc() -> runtime.Allocator {
    return runtime.heap_allocator()
}

grep_worker_start :: proc(w: ^Grep_Worker) {
    w.thread = thread.create(grep_worker_proc)
    w.thread.data = w
    thread.start(w.thread)
}

// Safe on a worker that never started.
grep_worker_stop :: proc(w: ^Grep_Worker) {
    if w.thread != nil {
        sync.mutex_lock(&w.lock)
        w.quit = true
        sync.cond_broadcast(&w.cv)
        sync.mutex_unlock(&w.lock)
        thread.join(w.thread)
        thread.destroy(w.thread)
        w.thread = nil
    }
    // Whatever was in flight is ours to free now that nothing is running.
    if w.has_job {
        grep_job_destroy(&w.pending)
        w.has_job = false
    }
    if w.has_done {
        grep_answer_destroy(&w.done)
        w.has_done = false
    }
}

// Ask for a search. The ticket is bumped first, which is also how anything already out is
// disowned — a cancelled preview needs no more than this.
grep_async :: proc(a: ^App, query: string, want: Grep_Want, replace := "", replacing := false) {
    a.grep_seq += 1
    w := &a.grep_worker
    if w.thread == nil {
        ans := Grep_Answer {
            query     = query,
            hits      = grep_project(a, query, false, replacing),
            want      = want,
            seq       = a.grep_seq,
            replace   = replace,
            replacing = replacing,
        }
        grep_apply(a, ans)
        return
    }
    alloc := grep_job_allocator()
    job := Grep_Job {
        root      = strings.clone(a.project_root, alloc),
        query     = strings.clone(query, alloc),
        want      = want,
        seq       = a.grep_seq,
        replace   = strings.clone(replace, alloc),
        replacing = replacing,
    }
    pats := exclude_dirs(a)
    job.exclude = make([]string, len(pats), alloc)
    for p, i in pats {
        job.exclude[i] = strings.clone(p, alloc)
    }
    sync.mutex_lock(&w.lock)
    if w.has_job {
        grep_job_destroy(&w.pending) // it describes an older query
    }
    w.pending = job
    w.has_job = true
    sync.cond_broadcast(&w.cv)
    sync.mutex_unlock(&w.lock)
}

// Once a frame (main.odin). One mutex at rest.
grep_poll :: proc(a: ^App) {
    w := &a.grep_worker
    sync.mutex_lock(&w.lock)
    ans, got := w.done, w.has_done
    w.has_done = false
    sync.mutex_unlock(&w.lock)
    if !got {
        return
    }
    grep_apply(a, ans)
    grep_answer_destroy(&ans)
}

// The answer's storage stays the caller's: grep_set deep-clones what it keeps.
@(private = "file")
grep_apply :: proc(a: ^App, ans: Grep_Answer) {
    if ans.seq != a.grep_seq {
        return // a newer query is out; nobody is waiting on this one
    }
    a.grep_seen = ans.seq
    switch ans.want {
    case .Preview:
        if preview_owns_grep(a) { // still up: an Esc took the pane back otherwise
            grep_set(&a.grep, ans.query, ans.hits, ans.replace, ans.replacing)
        }
    case .List:
        grep_set(&a.grep, ans.query, ans.hits, ans.replace, ans.replacing)
        set_aux(a, .Grep)
    case .Open:
        grep_set(&a.grep, ans.query, ans.hits, ans.replace, ans.replacing)
        if len(ans.hits) == 1 && !a.grep_pane_always {
            grep_open_hit(a, ans.hits[0]) // sole match, shortcut enabled
        } else {
            set_aux(a, .Grep)
        }
    }
}

// A request is out and unanswered. The hint reports this rather than the miss it cannot yet
// tell from an empty pane.
grep_searching :: proc(a: ^App) -> bool {
    return a.grep_seen != a.grep_seq
}

// --- the thread ---

@(private = "file")
grep_worker_proc :: proc(th: ^thread.Thread) {
    w := (^Grep_Worker)(th.data)
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
        sync.mutex_unlock(&w.lock)

        alloc := grep_job_allocator()
        hits := grep_run(job.root, job.query, job.exclude, false, job.replacing)
        ans := Grep_Answer {
            query     = strings.clone(job.query, alloc),
            hits      = grep_hits_clone(hits, alloc), // the disk reads, off the main thread too
            want      = job.want,
            seq       = job.seq,
            replace   = strings.clone(job.replace, alloc),
            replacing = job.replacing,
        }

        sync.mutex_lock(&w.lock)
        if w.has_done { // an answer nobody took is superseded
            grep_answer_destroy(&w.done)
        }
        w.done = ans
        w.has_done = true
        sync.mutex_unlock(&w.lock)

        grep_job_destroy(&job)
        free_all(context.temp_allocator) // grep_run and the file reads land here
        wake.post() // the frame that paints it has to be asked for
    }
}

@(private = "file")
grep_job_destroy :: proc(j: ^Grep_Job) {
    alloc := grep_job_allocator()
    delete(j.root, alloc)
    delete(j.query, alloc)
    delete(j.replace, alloc)
    for p in j.exclude {
        delete(p, alloc)
    }
    delete(j.exclude, alloc)
    j^ = {}
}

@(private = "file")
grep_answer_destroy :: proc(ans: ^Grep_Answer) {
    alloc := grep_job_allocator()
    delete(ans.query, alloc)
    delete(ans.replace, alloc)
    grep_hits_destroy(ans.hits, alloc)
    ans^ = {}
}
