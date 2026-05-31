package main

// The editor buffer and the unsaved-buffer ring are Part 3. For now these are the
// stubs the filetree and command line call into, so their seams are real even
// before the buffer exists.

// open_file loads a path into the editor buffer. Stub: focuses the editor so the
// action is visible; loading the contents comes with the buffer.
open_file :: proc(a: ^App, path: string) {
    a.focus = .Editor
    // TODO(part 3): read `path` into the buffer and track it in the ring.
}

// ring_contains reports whether path currently has unsaved changes (is in the
// ring). Stub: nothing is ringed until the buffer exists.
ring_contains :: proc(a: ^App, path: string) -> bool {
    return false
}
