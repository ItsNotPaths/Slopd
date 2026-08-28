package main

import "core:strings"
import "../gfx"
import "../ui"
import "../edit"

// Opening the menu and running what it chose. The menu MODEL — its rows, its geometry, and
// which row a key moves to — is the other half, and knows none of this.

ctxmenu_shown :: proc(a: ^App) -> bool {
    return a.ctxmenu.kind != .None
}

// The items are copied (the caller builds them in the frame's temp arena) and the target
// cloned. The keyboard lands on the first item that can actually be chosen.
ctxmenu_open :: proc(a: ^App, kind: ui.Menu_Kind, items: []ui.Menu_Item, x, y: i32, target: ui.Menu_Target) {
    ctxmenu_close(a)
    m := &a.ctxmenu
    m.kind = kind
    for it in items {
        append(&m.items, it)
    }
    m.x, m.y = x, y
    m.hover = -1
    m.target = {strings.clone(target.path), target.kind}
    m.sel = ui.ctxmenu_next_selectable(m, -1, 1)
}

ctxmenu_close :: proc(a: ^App) {
    m := &a.ctxmenu
    m.kind = .None
    clear(&m.items)
    delete(m.target.path)
    m.target = {}
    m.rect = {}
    m.sel, m.hover = -1, -1
}

ctxmenu_destroy :: proc(a: ^App) {
    delete(a.ctxmenu.items)
    delete(a.ctxmenu.target.path)
}

ctxmenu_move :: proc(a: ^App, dir: int) {
    m := &a.ctxmenu
    if next := ui.ctxmenu_next_selectable(m, m.sel, dir); next >= 0 {
        m.sel = next
    }
}

// A press outside the menu dismisses it and is SPENT doing so: closing a popup must not also
// select a row underneath. Runs before the panes declare, so none can claim it first.
ctxmenu_dismiss_click :: proc(a: ^App) {
    if !ctxmenu_shown(a) || !a.mouse_on || !a.mouse.click {
        return
    }
    if gfx.rect_hit(a.ctxmenu.rect, a.mouse.x, a.mouse.y) {
        return // inside: ctxmenu_click owns it
    }
    ui.mouse_take_click(ctx_of(a))
    ctxmenu_close(a)
}

// Enter and a click both come through here, so a verb cannot grow on one path only.
ctxmenu_choose :: proc(a: ^App) {
    m := &a.ctxmenu
    if m.sel < 0 || m.sel >= len(m.items) {
        return
    }
    it := m.items[m.sel]
    if it.action == .None || !it.enabled {
        return
    }
    kind := m.kind
    // Cloned: the close below frees the menu's copy, and the dispatch reads the path after.
    on := ui.Menu_Target{strings.clone(m.target.path, context.temp_allocator), m.target.kind}
    ctxmenu_close(a) // first: the actions below reload listings and stage command lines
    switch kind {
    case .None:
    case .FileOps:
        ctxmenu_file_action(a, it.action, on)
    }
}

// Every branch is the same call the chord makes (action.odin), which is what keeps the menu
// discoverability rather than a second implementation.
@(private = "file")
ctxmenu_file_action :: proc(a: ^App, action: ui.Menu_Action, on: ui.Menu_Target) {
    ft := &a.tree
    named := on.kind == .Path // chrome named a directory the selection is not on
    switch action {
    case .None:
    case .Open:
        // Each presentation's own Enter verb: the browser's descends through the history, the
        // listing's is the plain activate.
        if named {
            filebrowser_navigate(&a.filebrowser, ft, on.path)
        } else if a.file_pane == .Browser {
            filebrowser_activate(a)
        } else {
            filetree_activate_selected(a)
        }
    case .Cut:
        filetree_clip_take(ft, .Cut)
    case .Copy:
        if named {
            filetree_clip_one(ft, on.path, .Copy)
        } else {
            filetree_clip_take(ft, .Copy)
        }
    case .Paste:
        filetree_paste(ft)
    case .Mark:
        filetree_mark_toggle(ft)
    case .Delete:
        filetree_rm_selected(a, len(ft.marks) > 0)
    case .CopyPath:
        // Always the target: for an entry that IS the selection's path, and for the other two
        // kinds the selection is the wrong thing.
        if on.path != "" {
            clipboard_set(a, strings.clone(on.path), nil)
        }
    case .OpenInEditor:
        filetree_edit_selected(a) // the entry the right press selected
    case .Discard:
        filetree_discard_selected(a)
    case .Properties:
        filetree_props(a, on.path) // the target's, for all three kinds; the CL's session prints it
    case .AddPlace:
        filebrowser_place_add(&a.filebrowser, on.path)
    case .RemovePlace:
        filebrowser_place_remove(&a.filebrowser, filebrowser_place_index(&a.filebrowser, on.path))
    case .SetWorkspace:
        cl_workspace(a, on.path) // the root moves here, and every unlocked terminal cds
    case .Reload:
        filetree_reload(ft)
    }
}

// Built by the pane that opened the menu and copied into it, hence the temp arena — and hence
// every label being a literal, since the menu outlives that arena.
//
// A verb the target cannot have is left out; a verb it has but cannot do now is disabled. Mark
// on a path-bar segment is the first, paste with an empty clipboard the second.
ctxmenu_file_items :: proc(
    a: ^App,
    on: ui.Menu_Target,
    in_places: bool,
    alloc := context.temp_allocator,
) -> []ui.Menu_Item {
    ft := &a.tree
    e := filetree_selected(ft)
    row := on.kind == .Entry && e != nil
    marked := row && filetree_marked(ft, e.path)
    // The shortcut acts on a directory: a file cannot be a place.
    place_path := row ? (e.is_dir ? e.path : "") : on.path
    is_place := place_path != "" && filebrowser_place_index(&a.filebrowser, place_path) >= 0

    out := make([dynamic]ui.Menu_Item, 0, 12, alloc)
    switch on.kind {
    case .Entry:
        // A runnable entry says what Enter will DO, and carries the route back to the editor.
        runnable := row && !e.is_dir && run_command(e.path, e.exec, context.temp_allocator) != ""
        append(&out, ui.Menu_Item{runnable ? "Run" : "Open", "Enter", .Open, row})
        if runnable {
            append(&out, ui.Menu_Item{"Open in editor", "^o", .OpenInEditor, true})
        }
        append(&out, ui.Menu_Item{action = .None})
        append(&out, ui.Menu_Item{"Cut", "^x", .Cut, row || len(ft.marks) > 0})
        append(&out, ui.Menu_Item{"Copy", "^c", .Copy, row || len(ft.marks) > 0})
        append(&out, ui.Menu_Item{"Paste", "^v", .Paste, len(ft.clip) > 0})
        append(&out, ui.Menu_Item{action = .None})
        append(&out, ui.Menu_Item{marked ? "Unmark" : "Mark", "^y", .Mark, row})
        append(&out, ui.Menu_Item{"Delete", "^d", .Delete, row || len(ft.marks) > 0})
        append(&out, ui.Menu_Item{"Copy path", "^w", .CopyPath, row})
        append(&out, ui.Menu_Item{"Properties", "^i", .Properties, row})
        // Left out rather than disabled: a file with nothing unsaved has no edits to discard.
        if row && edit.ring_contains(&a.editor, e.path) {
            append(&out, ui.Menu_Item{"Discard changes", "^k", .Discard, true})
        }
    case .Path:
        // A chrome-named directory can be gone to, staged for a paste and quoted, and that is
        // the whole of what a segment or a places row is. No hints: ^c and ^w are the same verbs
        // on the SELECTION, so naming them would name a chord that acts elsewhere.
        append(&out, ui.Menu_Item{"Open", "", .Open, on.path != ""})
        append(&out, ui.Menu_Item{action = .None})
        append(&out, ui.Menu_Item{"Copy", "", .Copy, on.path != ""})
        append(&out, ui.Menu_Item{"Copy path", "", .CopyPath, on.path != ""})
        append(&out, ui.Menu_Item{"Properties", "", .Properties, on.path != ""})
    case .Dir:
        // The verbs that act on WHERE YOU ARE. Paste earns the gesture, and "Set workspace
        // here" is `:cd` + `:tu` with the folder pointed at.
        append(&out, ui.Menu_Item{"Paste", "^v", .Paste, len(ft.clip) > 0})
        append(&out, ui.Menu_Item{"Set workspace here", "^h", .SetWorkspace, on.path != ""})
        append(&out, ui.Menu_Item{"Copy path", "^W", .CopyPath, on.path != ""})
        append(&out, ui.Menu_Item{"Properties", "^I", .Properties, on.path != ""})
    }
    if in_places && place_path != "" {
        append(&out, ui.Menu_Item{action = .None})
        if is_place {
            append(&out, ui.Menu_Item{"Remove from places", "", .RemovePlace, true})
        } else {
            append(&out, ui.Menu_Item{"Add to places", "", .AddPlace, true})
        }
    }
    append(&out, ui.Menu_Item{"Reload", "^r", .Reload, true})
    return out[:]
}
