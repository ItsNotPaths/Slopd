package main

import "core:fmt"
import "core:strings"

// What Slopd says about itself: the build version, and the two documents baked into the
// binary. Both docs are #load-ed rather than shipped beside the executable, because the
// release is meant to BE the binary — see release.sh. The licence in particular has to
// travel with the program (GPL-3 s4/s6, and the bundled MIT/OFL notices, all require a
// COPY to accompany it, not a link), and an embedded copy the `license` builtin opens is
// that copy.

// Stamped by the build (`-define:SLOPD_VERSION=v1.2.3`); "dev" for a plain `odin build`.
SLOPD_VERSION :: #config(SLOPD_VERSION, "dev")

LICENSE_SRC := string(#load("../LICENSE"))
README_SRC := string(#load("../README.md"))

// The embedded documents, by the builtin that opens them. The name is what the status
// strip shows and what the buffer is keyed on — a display name, not a path (see Buffer).
Embedded_Doc :: enum {
    Readme,
    License,
}

embedded_doc_name :: proc(k: Embedded_Doc) -> string {
    switch k {
    case .Readme:  return "README.md"
    case .License: return "LICENSE"
    }
    return ""
}

embedded_doc_source :: proc(k: Embedded_Doc) -> string {
    switch k {
    case .Readme:  return README_SRC
    case .License: return LICENSE_SRC
    }
    return ""
}

// Opens an embedded document in the editor ring. Re-running the builtin re-activates the
// buffer it already made rather than stacking duplicates; edits are allowed (it is an
// ordinary buffer) but can never be written back, since `embedded` fails buffer_on_disk.
open_embedded_doc :: proc(a: ^App, k: Embedded_Doc) {
    defer set_focus(a, .Editor)
    a.main = .Text // like open_file: flip the main pane back to the editor
    name := embedded_doc_name(k)
    e := &a.editor
    for &b, i in e.buffers {
        if b.embedded && b.path == name {
            e.active = i
            return
        }
    }
    b: Buffer
    doc_init(&b.doc)
    buffer_set_text(&b, embedded_doc_source(k))
    b.path = strings.clone(name)
    b.embedded = true
    b.final_newline = true
    append(&e.buffers, b)
    e.active = len(e.buffers) - 1
}

// `slopd --version` / `-v`. Handled before the window opens (like the grammar CLI), so it
// answers even when the GUI cannot start — which is exactly when you want to ask.
about_cli :: proc(args: []string) -> (handled: bool) {
    for arg in args {
        if arg == "--version" || arg == "-v" {
            fmt.printfln("Slopd %s", SLOPD_VERSION)
            return true
        }
    }
    return false
}
