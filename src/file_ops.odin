package main

import "core:fmt"
import "core:strings"

// What activating, opening, deleting or describing an entry MEANS. One proc per verb, because
// three gestures reach each: the chord, the double click and the context menu.
//
// The destructive ones STAGE a shell command in the CL rather than acting behind a modal prompt.
// You read the line, edit it and press Enter: the CL is the confirm.

// Set the project root, staged for review or run at once per the `folder_cd` config.
filetree_cd_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && e.is_dir {
        cl_dispatch(a, fmt.tprintf(":cd %s", e.path), a.folder_cd_run)
    }
}

// A PROGRAM IS NOT A DOCUMENT: run what we could run, open the rest. It runs in `run_term`,
// surfaced. The trailing space run_command leaves is Shift+Enter's, which stages instead.
open_or_run :: proc(a: ^App, path: string, exec: bool) {
    if cmd := run_command(path, exec, context.temp_allocator); cmd != "" {
        run_in_term(a, strings.trim_space(cmd), a.run_term)
        return
    }
    open_file(a, path)
}

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

// The way back to a script that Enter now runs.
filetree_edit_selected :: proc(a: ^App) {
    if e := filetree_selected(&a.tree); e != nil && !e.is_dir && e.name != ".." {
        open_file(a, e.path)
    }
}

// Throw away a file's unsaved edits: it leaves the unsaved ring and its buffer holds the disk
// again. Staged for review or run at once per the `discard` config, like the folder cd — the
// staged line IS the confirm, as it is for the delete.
//
// A file with nothing unsaved has nothing to discard, so this is a no-op on one.
filetree_discard_selected :: proc(a: ^App) {
    e := filetree_selected(&a.tree)
    if e == nil || e.is_dir || !ring_contains(a, e.path) {
        return
    }
    cl_dispatch(a, fmt.tprintf(":discard %s", cl_quote_arg(e.path, context.temp_allocator)), a.discard_run)
}

// xdg-open, except for anything RUNNABLE: that stages its command instead, since running with
// arguments is a decision worth reading first.
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

// Stages `rm -rf <paths> && :ls`. No-op with nothing selected or marked.
filetree_rm_selected :: proc(a: ^App, marked: bool) {
    paths := filetree_targets(&a.tree, marked, context.temp_allocator)
    if cmd := rm_command(paths, context.temp_allocator); cmd != "" {
        cl_inject(a, cmd)
    }
}

// Runs rather than staging, unlike the delete: `stat` only reads, so there is nothing to review.
filetree_props :: proc(a: ^App, path: string) {
    if cmd := properties_command(path, context.temp_allocator); cmd != "" {
        run_in_t1(a, cmd)
    }
}
