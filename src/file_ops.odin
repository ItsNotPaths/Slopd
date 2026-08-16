package main

import "core:fmt"
import "core:strings"

// File operations — what activating, opening, deleting or describing an entry MEANS. One proc
// per verb, because three gestures reach each of them: the chord (action.odin), the double click
// (filetree_ui / filebrowser_ui) and the context menu. A verb only one of the three could reach
// would be a hole in the pointer/keyboard parity the panes promise.
//
// The destructive ones STAGE a real shell command in the command line rather than acting behind
// a modal prompt: you read the line, edit it, and press Enter. The CL is the confirm, and the
// command lands in its history like anything else you typed.

// Alt+Enter on a selected folder: set the project root via a `:cd <path>` command — staged in
// the command line for review, or run at once, per the `folder_cd` config. No-op unless a
// directory is selected.
filetree_cd_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && e.is_dir {
        cl_dispatch(a, fmt.tprintf(":cd %s", e.path), a.folder_cd_run)
    }
}

// What Enter (and its double-click twin) does with a FILE in either presentation: run it when it
// is something we could run, open it otherwise. **A program is not a document** — loading a
// binary into the text ring shows you its bytes, which is never what activating it meant.
//
// It runs in the `run_term` session, surfaced, so its output is in front of you. The trailing
// space run_command leaves for typing arguments is trimmed off: that space is Shift+Enter's,
// which STAGES the same line instead — the two halves of "run it" and "run it with flags".
open_or_run :: proc(a: ^App, path: string, exec: bool) {
    if cmd := run_command(path, exec, context.temp_allocator); cmd != "" {
        run_in_term(a, strings.trim_space(cmd), a.run_term)
        return
    }
    open_file(a, path)
}

// Enter in the dired listing: descend into the folder, or open/run the file.
filetree_activate_selected :: proc(a: ^App) {
    ft := &a.tree
    e := filetree_selected(ft)
    exec := e != nil && e.exec
    // filetree_activate reloads when it DESCENDS, which frees the listing `path` came from —
    // but it only returns a path on the file branch, where nothing was reloaded.
    if path, is_file := filetree_activate(ft); is_file {
        open_or_run(a, path, exec)
    }
}

// Ctrl+O: open the entry in the EDITOR whatever it is — the way back to a script that Enter now
// runs. Everything else in the pane has a chord, and "edit my +x build script" needed one too.
filetree_edit_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && !e.is_dir && e.name != ".." {
        open_file(a, e.path)
    }
}

// Shift+Enter: open the entry the way the DESKTOP would, via xdg-open. The exception is anything
// we could RUN — a binary or script STAGES its run command in the CL instead, since running WITH
// ARGUMENTS is a decision worth reading first. Plain Enter runs it outright.
filetree_open_selected :: proc(a: ^App) {
    e := filetree_selected(&a.tree)
    if e == nil || e.name == ".." {
        return
    }
    if !e.is_dir {
        if cmd := run_command(e.path, e.exec, context.temp_allocator); cmd != "" {
            cl_inject(a, cmd)
            return
        }
    }
    desktop_open(e.path)
}

// Ctrl+D / Ctrl+Shift+D: stage `rm -rf <paths> && :ls` in the command line. The delete is a real
// shell command you read, edit and run with Enter — no modal confirm. No-op with nothing
// selected or marked.
filetree_rm_selected :: proc(a: ^App, marked: bool) {
    paths := filetree_targets(&a.tree, marked, context.temp_allocator)
    if cmd := rm_command(paths, context.temp_allocator); cmd != "" {
        cl_inject(a, cmd)
    }
}

// Ctrl+I / Ctrl+Shift+I: print `path`'s properties in t1. It RUNS rather than staging (unlike the
// delete above) because `stat` only reads — there is nothing here to review before it happens —
// and it surfaces the terminal, since properties you cannot see were not sent anywhere. Alt+F
// comes back to the browser with the listing where you left it.
filetree_props :: proc(a: ^App, path: string) {
    if cmd := properties_command(path, context.temp_allocator); cmd != "" {
        run_in_t1(a, cmd)
    }
}
