package main

import "core:slice"

// Piece_Table — the byte storage under Doc. A document is an ordered list of Pieces, each
// naming a span of one immutable byte Block; reading walks the pieces, editing splices the
// list. Nothing is copied on an edit and nothing already written is ever moved, which is what
// buys the two properties the editor needs:
//
//   parsing needs no flat copy — tree-sitter's Input read callback is handed a piece's span
//   directly (see pt_span), so a keystroke never rebuilds the whole buffer as a string;
//
//   a snapshot is cheap — the blocks are append-only and shared by reference, so a worker
//   thread reads a document by cloning only `pieces` and `lines` (both small).
//
// Block 0 is the file as loaded. Every later block is an append chunk holding the bytes typed
// or pasted since. Blocks are only ever discarded together, by pt_compact.
//
// Invariants, held by every op:
//   - pieces are in document order, none empty, and `doc_off` is the running byte total
//   - `lines` holds the byte offset of every line start, is ascending, and lines[0] == 0
//   - a document always has at least one line (an empty one), so `lines` is never empty
//   - `size` is the sum of the piece lengths
Piece_Table :: struct {
    blocks:    [dynamic][]u8, // owned; block 0 is the loaded file, the rest are append chunks
    pieces:    [dynamic]Piece,
    lines:     [dynamic]int, // byte offset of each line start; len == line count
    size:      int, // total document bytes
    tail:      int, // the block appends go into, -1 before the first one
    tail_used: int, // bytes of that block already written
}

// One run of bytes: [off, off+len) of blocks[block], sitting at [doc_off, doc_off+len) of the
// document. `doc_off` is derived — it is what makes an offset resolvable by binary search
// instead of by walking — and every op that changes a piece's length repairs the pieces after it.
Piece :: struct {
    block:   int,
    off:     int,
    len:     int,
    doc_off: int,
}

// Size of a fresh append chunk. Big enough that ordinary typing allocates about once a session,
// small enough that an abandoned tail wastes nothing worth counting. A single append larger than
// this gets a block of its own, so one append is always one piece.
PT_CHUNK :: 64 * 1024

// Piece count that makes compaction worth doing. Reached only by scattered editing — typing runs
// coalesce into one piece (see pt_splice) — and pt_compact is NOT called from the edit path, so
// crossing it costs nothing until a save or a worker gets round to it.
PT_COMPACT_PIECES :: 2048

// --- lifecycle ---

pt_init :: proc(pt: ^Piece_Table) {
    pt.tail = -1
    append(&pt.lines, 0) // the empty document is one empty line
}

pt_destroy :: proc(pt: ^Piece_Table) {
    for b in pt.blocks {
        delete(b)
    }
    delete(pt.blocks)
    delete(pt.pieces)
    delete(pt.lines)
    pt^ = {}
}

// Replaces the whole document with `src` (a file load). The bytes are cloned into block 0 and
// every earlier block is dropped, so a load leaves the table as compact as it can be.
pt_load :: proc(pt: ^Piece_Table, src: []u8) {
    for b in pt.blocks {
        delete(b)
    }
    clear(&pt.blocks)
    clear(&pt.pieces)
    clear(&pt.lines)
    pt.tail, pt.tail_used, pt.size = -1, 0, len(src)

    append(&pt.blocks, slice.clone(src))
    if len(src) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(src), doc_off = 0})
    }
    append(&pt.lines, 0)
    for c, i in src {
        if c == '\n' {
            append(&pt.lines, i + 1)
        }
    }
}

// --- reading ---

pt_line_count :: proc(pt: ^Piece_Table) -> int {
    return len(pt.lines)
}

// The byte range of `line`, EXCLUDING its terminating newline — the line's text and nothing
// else, so a caller never has to remember to trim one. Assumes a real line index.
pt_line_range :: proc(pt: ^Piece_Table, line: int) -> (lo, hi: int) {
    lo = pt.lines[line]
    if line + 1 < len(pt.lines) {
        return lo, pt.lines[line + 1] - 1 // one back off the next start: the '\n' itself
    }
    return lo, pt.size
}

pt_line_len :: proc(pt: ^Piece_Table, line: int) -> int {
    lo, hi := pt_line_range(pt, line)
    return hi - lo
}

// The line containing `off` — the largest line whose start is at or before it. Clamped, so an
// offset past the end answers the last line rather than reading off the index.
pt_line_at_off :: proc(pt: ^Piece_Table, off: int) -> int {
    lo, hi := 0, len(pt.lines)
    for lo < hi {
        mid := (lo + hi) / 2
        if pt.lines[mid] <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return max(0, lo - 1)
}

// The CONTIGUOUS run of bytes beginning at `off` — as much of the document as lives in one
// piece, which is all tree-sitter's read callback wants and is usually a whole line. Empty at
// or past the end of the document. Borrowed: valid until the next edit.
pt_span :: proc(pt: ^Piece_Table, off: int) -> []u8 {
    i := piece_at(pt.pieces[:], off)
    if i < 0 {
        return nil
    }
    p := pt.pieces[i]
    return pt.blocks[p.block][p.off + off - p.doc_off:p.off + p.len]
}

// The bytes in [lo, hi), copied. `alloc` owns the result — the only read that costs a copy, so
// prefer pt_span or pt_line where a borrow will do.
pt_read :: proc(pt: ^Piece_Table, lo, hi: int, alloc := context.allocator) -> []u8 {
    a := clamp(lo, 0, pt.size)
    b := clamp(hi, a, pt.size)
    out := make([]u8, b - a, alloc)
    n := 0
    for n < len(out) {
        src := pt_span(pt, a + n)
        if len(src) == 0 {
            break // defensive: a truncated span would otherwise spin
        }
        n += copy(out[n:], src)
    }
    return out
}

// One line's bytes. Borrowed straight out of the block when the line sits inside a single piece
// — the common case, and free — and copied into `alloc` only when an edit has left it split.
// Either way it is READ ONLY and dead after the next edit.
pt_line :: proc(pt: ^Piece_Table, line: int, alloc := context.allocator) -> []u8 {
    lo, hi := pt_line_range(pt, line)
    if hi <= lo {
        return nil
    }
    if s := pt_span(pt, lo); len(s) >= hi - lo {
        return s[:hi - lo]
    }
    return pt_read(pt, lo, hi, alloc)
}

// --- editing ---

// Replace the bytes in [lo, hi) with `text` — the one mutator, and what a Patch lowers to.
// Returns the byte delta, which is what the callers' own indices (cursors, folds) shift by.
//
// The fast path is typing: an insert at the very end of the newest piece, when that piece runs
// to the end of the append tail, simply extends it. Without that a piece would be pushed per
// keystroke and the list would grow into the thing the binary search exists to avoid.
pt_splice :: proc(pt: ^Piece_Table, lo, hi: int, text: []u8) -> (delta: int) {
    a := clamp(lo, 0, pt.size)
    b := clamp(hi, a, pt.size)
    if a == b && len(text) == 0 {
        return 0
    }
    delta = len(text) - (b - a)

    pt_splice_lines(pt, a, b, text, delta)

    if a == b && pt_extend_tail(pt, a, text) {
        pt.size += delta
        return
    }

    // Cut the list at both ends so the replaced region is whole pieces, drop them, and put the
    // new text in their place. `at` is where the removed run began.
    at := pt_split_at(pt, a)
    end := pt_split_at(pt, b)
    remove_range(&pt.pieces, at, end)
    if len(text) > 0 {
        block, off := pt_append(pt, text)
        inject_at(&pt.pieces, at, Piece{block = block, off = off, len = len(text), doc_off = a})
        at += 1
    }
    pt.size += delta
    for i in at ..< len(pt.pieces) {
        pt.pieces[i].doc_off += delta
    }
    return
}

// Whether the table has fragmented enough to be worth flattening. Asked by the save path and by
// the derivation worker; deliberately never asked by an edit.
pt_should_compact :: proc(pt: ^Piece_Table) -> bool {
    return len(pt.pieces) > PT_COMPACT_PIECES
}

// Flatten to a single block holding the document as it now reads, discarding every old block.
// Byte-identical by construction, and the line index is untouched — compaction moves bytes
// between blocks, never within the document.
pt_compact :: proc(pt: ^Piece_Table) {
    flat := pt_read(pt, 0, pt.size)
    for b in pt.blocks {
        delete(b)
    }
    clear(&pt.blocks)
    clear(&pt.pieces)
    append(&pt.blocks, flat)
    if len(flat) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(flat), doc_off = 0})
    }
    pt.tail, pt.tail_used = -1, 0
}

// --- internals ---

// The piece holding `off`, or -1 at/past the end. Binary search on doc_off, which is why every
// op that resizes a piece repairs the ones after it.
@(private = "file")
piece_at :: proc(pieces: []Piece, off: int) -> int {
    lo, hi := 0, len(pieces)
    for lo < hi {
        mid := (lo + hi) / 2
        if pieces[mid].doc_off + pieces[mid].len <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo < len(pieces) ? lo : -1
}

// Make `off` a piece boundary and return the index of the piece starting there (len(pieces) at
// the end of the document). Splits the piece that straddles it; a no-op when one already ends
// there, so the two calls a splice makes cost nothing on an aligned edit.
@(private = "file")
pt_split_at :: proc(pt: ^Piece_Table, off: int) -> int {
    i := piece_at(pt.pieces[:], off)
    if i < 0 {
        return len(pt.pieces)
    }
    p := pt.pieces[i]
    if p.doc_off == off {
        return i
    }
    cut := off - p.doc_off
    pt.pieces[i].len = cut
    inject_at(
        &pt.pieces,
        i + 1,
        Piece{block = p.block, off = p.off + cut, len = p.len - cut, doc_off = off},
    )
    return i + 1
}

// The typing fast path: `text` inserted at `at` extends the piece ENDING there, when that
// piece's block bytes also end exactly at the append cursor. Both halves matter — the first says
// the insert continues a run this piece already holds, the second that nothing else has been
// written into the chunk since, so the bytes can simply follow on.
//
// It is the piece ending at `at`, not the last piece in the list, and that is the whole point:
// typing mid-file splits once on the first keystroke, and every keystroke after it lands on the
// end of the piece that split made. Without that, a piece would be pushed per keystroke.
@(private = "file")
pt_extend_tail :: proc(pt: ^Piece_Table, at: int, text: []u8) -> bool {
    if at == 0 || pt.tail < 0 {
        return false
    }
    i := piece_at(pt.pieces[:], at - 1)
    if i < 0 {
        return false
    }
    p := &pt.pieces[i]
    if p.doc_off + p.len != at || p.block != pt.tail || p.off + p.len != pt.tail_used {
        return false
    }
    if pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        return false // the chunk is full; take the ordinary path and start a new one
    }
    copy(pt.blocks[pt.tail][pt.tail_used:], text)
    pt.tail_used += len(text)
    p.len += len(text)
    for k in i + 1 ..< len(pt.pieces) {
        pt.pieces[k].doc_off += len(text)
    }
    return true
}

// Write `text` into the append pool, returning where it landed. A chunk is never grown or moved
// once written — a worker may be reading it — so text that will not fit in the current one opens
// a fresh chunk, sized to the text when the text is the larger. One append is therefore always
// one contiguous span, and no piece straddles a block.
@(private = "file")
pt_append :: proc(pt: ^Piece_Table, text: []u8) -> (block, off: int) {
    if pt.tail < 0 || pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        append(&pt.blocks, make([]u8, max(PT_CHUNK, len(text))))
        pt.tail, pt.tail_used = len(pt.blocks) - 1, 0
    }
    off = pt.tail_used
    copy(pt.blocks[pt.tail][off:], text)
    pt.tail_used += len(text)
    return pt.tail, off
}

// Splice the line index for a replacement of [a, b) by `text`. The lines the replacement
// straddles are the only ones rebuilt — one scan of `text` for its newlines — and every start
// after them just shifts by the byte delta. Called BEFORE the pieces move, while a, b and the
// old index still describe the same document.
@(private = "file")
pt_splice_lines :: proc(pt: ^Piece_Table, a, b: int, text: []u8, delta: int) {
    first := pt_line_at_off(pt, a)
    last := pt_line_at_off(pt, b)

    starts := make([dynamic]int, 0, 8, context.temp_allocator)
    for c, i in text {
        if c == '\n' {
            append(&starts, a + i + 1)
        }
    }

    for i in last + 1 ..< len(pt.lines) {
        pt.lines[i] += delta
    }
    remove_range(&pt.lines, first + 1, last + 1)
    inject_at(&pt.lines, first + 1, ..starts[:])
}
