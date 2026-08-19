package main

import "core:unicode/utf8"

// A linear patch journal on the Doc edit funnel. Each edit records a reversible Op; consecutive
// single-character inserts coalesce into one step, broken by whitespace, a caret move or any
// other edit. The op-level granularity is graph-ready: swapping the linear stacks for a tree
// would not touch how edits are recorded.

// Two byte offsets, one per direction, because a batch's edits shift each other. Forward,
// [at, at+len(removed)) in the PRE-batch document became `inserted`; undo replaces
// [inv_at, inv_at+len(inserted)) in the POST-batch one with `removed`. Both strings are owned.
Op :: struct {
    at:                int,
    inv_at:            int,
    removed, inserted: string,
}

// The ops from one doc_apply call (one per surviving cursor).
Batch :: struct {
    ops: [dynamic]Op,
}

// The batches applied while the step was open, plus the cursor sets to restore. Undo replays
// the inverses last-to-first and restores `before`; redo replays forward and restores `after`.
Undo_Step :: struct {
    batches:                       [dynamic]Batch,
    before, after:                 [dynamic]Cursor,
    before_primary, after_primary: int,
}

Undo :: struct {
    steps: [dynamic]Undo_Step,
    redo:  [dynamic]Undo_Step,
}

UNDO_MAX :: 1000 // step cap; oldest steps drop off the bottom

undo_destroy :: proc(d: ^Doc) {
    for &s in d.undo.steps {
        step_destroy(&s)
    }
    for &s in d.undo.redo {
        step_destroy(&s)
    }
    delete(d.undo.steps)
    delete(d.undo.redo)
    d.undo = {}
}

// A single-character insert extends the most recent step while that step's last inserted
// character was not a break char and the caret is where the step left off.
//
// doc_apply leaves one collapsed cursor per edit, which is right for typing and wrong for an
// edit spanning whole lines — the selection has to survive Tab so a second press indents again.
// `after_set` is the caller saying where its edit left the cursors; the step records those, so
// redo lands on them too.
doc_commit :: proc(d: ^Doc, edits: []Edit, after_set: []Cursor = nil) -> bool {
    before := clone_cursors(d.cursors[:])
    before_primary := d.primary
    batch: Batch
    changed := doc_apply(d, edits, &batch)
    if !changed {
        delete(before)
        batch_destroy(&batch)
        return false
    }
    if len(after_set) > 0 {
        set_cursors(d, after_set, before_primary)
    }
    undo_clear_redo(d)
    after := clone_cursors(d.cursors[:])
    u := &d.undo

    if coalesces(u, &batch, before[:]) {
        top := &u.steps[len(u.steps) - 1]
        append(&top.batches, batch)
        delete(top.after)
        top.after = after
        top.after_primary = d.primary
        delete(before)
    } else {
        step := Undo_Step {
            before         = before,
            after          = after,
            before_primary = before_primary,
            after_primary  = d.primary,
        }
        append(&step.batches, batch)
        append(&u.steps, step)
    }
    undo_cap(d)
    return true
}

// Replays each batch's inverse last-to-first, restores the pre-edit cursors, and moves the step
// onto the redo stack.
doc_undo :: proc(d: ^Doc) -> bool {
    u := &d.undo
    if len(u.steps) == 0 {
        return false
    }
    step := pop(&u.steps)
    for i := len(step.batches) - 1; i >= 0; i -= 1 {
        edits := make([dynamic]Edit, 0, len(step.batches[i].ops), context.temp_allocator)
        for op in step.batches[i].ops {
            append(&edits, Edit{op.inv_at, op.inv_at + len(op.inserted), op.removed, 0})
        }
        doc_apply(d, edits[:])
    }
    set_cursors(d, step.before[:], step.before_primary)
    append(&u.redo, step)
    return true
}

// Replays each batch forward, restores the post-edit cursors, and moves the step back.
doc_redo :: proc(d: ^Doc) -> bool {
    u := &d.undo
    if len(u.redo) == 0 {
        return false
    }
    step := pop(&u.redo)
    for batch in step.batches {
        edits := make([dynamic]Edit, 0, len(batch.ops), context.temp_allocator)
        for op in batch.ops {
            append(&edits, Edit{op.at, op.at + len(op.removed), op.inserted, 0})
        }
        doc_apply(d, edits[:])
    }
    set_cursors(d, step.after[:], step.after_primary)
    append(&u.steps, step)
    return true
}

// --- internals ---

// Whitespace, or a bracket/quote delimiter. After one is typed the step is sealed.
@(private = "file")
is_undo_break :: proc(r: rune) -> bool {
    switch r {
    case ' ', '\t', '\n', '(', ')', '[', ']', '{', '}', '"', '\'', '`':
        return true
    }
    return false
}

// A single-character insert landing where that step left off, whose last inserted character was
// not a break char.
@(private = "file")
coalesces :: proc(u: ^Undo, batch: ^Batch, before: []Cursor) -> bool {
    if !batch_is_char_insert(batch) || len(u.steps) == 0 {
        return false
    }
    top := &u.steps[len(u.steps) - 1]
    return cursors_match(top.after[:], before) && step_open(top)
}

// A keystroke fans out to every cursor as one character, so a batch coalesces when ALL its ops
// are single-char inserts.
@(private = "file")
batch_is_char_insert :: proc(b: ^Batch) -> bool {
    if len(b.ops) == 0 {
        return false
    }
    for op in b.ops {
        if op.removed != "" || utf8.rune_count_in_string(op.inserted) != 1 {
            return false
        }
    }
    return true
}

// Still open if its last edit inserted a non-break character.
@(private = "file")
step_open :: proc(s: ^Undo_Step) -> bool {
    if len(s.batches) == 0 {
        return false
    }
    b := &s.batches[len(s.batches) - 1]
    if len(b.ops) == 0 {
        return false
    }
    op := b.ops[len(b.ops) - 1]
    if op.removed != "" || op.inserted == "" {
        return false
    }
    last, _ := utf8.decode_last_rune_in_string(op.inserted)
    return !is_undo_break(last)
}

@(private = "file")
clone_cursors :: proc(src: []Cursor) -> [dynamic]Cursor {
    dst := make([dynamic]Cursor, len(src))
    copy(dst[:], src)
    return dst
}

@(private = "file")
set_cursors :: proc(d: ^Doc, src: []Cursor, primary: int) {
    clear(&d.cursors)
    append(&d.cursors, ..src)
    d.primary = clamp(primary, 0, len(d.cursors) - 1)
}

@(private = "file")
cursors_match :: proc(a, b: []Cursor) -> bool {
    if len(a) != len(b) {
        return false
    }
    for c, i in a {
        if c.head != b[i].head || c.anchor != b[i].anchor {
            return false
        }
    }
    return true
}

@(private = "file")
undo_clear_redo :: proc(d: ^Doc) {
    for &s in d.undo.redo {
        step_destroy(&s)
    }
    clear(&d.undo.redo)
}

@(private = "file")
undo_cap :: proc(d: ^Doc) {
    for len(d.undo.steps) > UNDO_MAX {
        step_destroy(&d.undo.steps[0])
        ordered_remove(&d.undo.steps, 0)
    }
}

@(private = "file")
step_destroy :: proc(s: ^Undo_Step) {
    for &b in s.batches {
        batch_destroy(&b)
    }
    delete(s.batches)
    delete(s.before)
    delete(s.after)
}

@(private = "file")
batch_destroy :: proc(b: ^Batch) {
    for op in b.ops {
        delete(op.removed)
        delete(op.inserted)
    }
    delete(b.ops)
}
