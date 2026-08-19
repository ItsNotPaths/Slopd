package main

import "core:strings"
import "core:unicode/utf8"

// The one popup in the program: a right-press opens a list of buttons naming verbs the chords
// already do. Not a filetree feature — the model is a `kind` plus a list of items, so a second
// caller supplies its own and gets the placement, paint order, capture and keyboard for free.
// contextmenu_ui.odin is the declaration.
//
// The menu is discoverability, never capability: every item is a Ctrl chord you can type, and
// the hint column says which. Nothing may ever be reachable only from here.

// Who interprets a chosen action. `.None` IS the closed state, so there is no second `open`
// bool to keep in step.
Menu_Kind :: enum {
    None,
    FileOps,
}

// One flat enum rather than a proc pointer per item, so the item list stays plain data a test
// can build.
Menu_Action :: enum {
    None, // a separator: drawn as a rule, never hit, never selected
    Open,
    Cut,
    Copy,
    Paste,
    Mark,
    Delete,
    CopyPath,
    OpenInEditor,
    Discard,
    Properties,
    AddPlace,
    RemovePlace,
    SetWorkspace,
    Reload,
}

// `label` and `hint` are STATIC literals: the menu holds them past the frame that opened it, so
// a temp-allocated label would dangle. A disabled item is drawn muted and refuses the press
// rather than being left out — a paste that vanishes teaches less than one you can see.
Menu_Item :: struct {
    label:   string,
    hint:    string,
    action:  Menu_Action,
    enabled: bool,
}

// What the menu was opened on. The kind picks the item table and decides which verbs act on
// THIS path rather than the listing's selection — a path-bar press names a directory the
// listing does not contain.
Menu_Target_Kind :: enum {
    Dir, // the browsed directory: the press hit the contents' background or a bar button
    Entry, // a row of the listing; the right press has already selected it
    Path, // a directory named by chrome: a path-bar segment or a places row
}

Menu_Target :: struct {
    path: string,
    kind: Menu_Target_Kind,
}

ContextMenu :: struct {
    kind:  Menu_Kind,
    items: [dynamic]Menu_Item,

    // Where the press landed, and where the menu was PLACED for it (ctxmenu_place may have
    // flipped it off a window edge). The rect is written by the declaration and read by the
    // dismissal test.
    x, y:  i32,
    rect:  Rect,

    // Kept apart as every pane keeps them apart: the arrows move one, the pointer the other.
    sel:   int,
    hover: int,

    // `path` is OWNED: the listing, the places and the segments are all freed and re-read by
    // half the actions here.
    target: Menu_Target,
}

ctxmenu_shown :: proc(a: ^App) -> bool {
    return a.ctxmenu.kind != .None
}

// The items are copied (the caller builds them in the frame's temp arena) and the target
// cloned. The keyboard lands on the first item that can actually be chosen.
ctxmenu_open :: proc(a: ^App, kind: Menu_Kind, items: []Menu_Item, x, y: i32, target: Menu_Target) {
    ctxmenu_close(a)
    m := &a.ctxmenu
    m.kind = kind
    for it in items {
        append(&m.items, it)
    }
    m.x, m.y = x, y
    m.hover = -1
    m.target = {strings.clone(target.path), target.kind}
    m.sel = ctxmenu_next_selectable(m, -1, 1)
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

// Walking `dir` from `from`; -1 starts before the list. Returns -1 when nothing is selectable,
// which a menu of entirely disabled rows can be.
ctxmenu_next_selectable :: proc(m: ^ContextMenu, from, dir: int) -> int {
    i := from + dir
    for i >= 0 && i < len(m.items) {
        if m.items[i].action != .None && m.items[i].enabled {
            return i
        }
        i += dir
    }
    return from >= 0 && from < len(m.items) && m.items[from].enabled ? from : -1
}

ctxmenu_move :: proc(a: ^App, dir: int) {
    m := &a.ctxmenu
    if next := ctxmenu_next_selectable(m, m.sel, dir); next >= 0 {
        m.sel = next
    }
}

// Pure, so the four cases are assertable without a window. The menu hangs down and to the right
// of the pointer; against an edge it FLIPS to the other side of the press rather than sliding
// along it, so the pointer ends on a corner and never inside. A menu larger than the window
// clamps.
ctxmenu_place :: proc(ax, ay, w, h, win_w, win_h: i32) -> Rect {
    x := ax
    if x + w > win_w {
        x = ax - w // flip left of the press
    }
    y := ay
    if y + h > win_h {
        y = ay - h // flip above it
    }
    x = clamp(x, 0, max(0, win_w - w))
    y = clamp(y, 0, max(0, win_h - h))
    return Rect{x, y, w, h}
}

// A press outside the menu dismisses it and is SPENT doing so: closing a popup must not also
// select a row underneath. Runs before the panes declare, so none can claim it first.
ctxmenu_dismiss_click :: proc(a: ^App) {
    if !ctxmenu_shown(a) || !a.mouse_on || !a.mouse.click {
        return
    }
    if rect_hit(a.ctxmenu.rect, a.mouse.x, a.mouse.y) {
        return // inside: ctxmenu_click owns it
    }
    mouse_take_click(a)
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
    on := Menu_Target{strings.clone(m.target.path, context.temp_allocator), m.target.kind}
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
ctxmenu_file_action :: proc(a: ^App, action: Menu_Action, on: Menu_Target) {
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
    on: Menu_Target,
    in_places: bool,
    alloc := context.temp_allocator,
) -> []Menu_Item {
    ft := &a.tree
    e := filetree_selected(ft)
    row := on.kind == .Entry && e != nil
    marked := row && filetree_marked(ft, e.path)
    // The shortcut acts on a directory: a file cannot be a place.
    place_path := row ? (e.is_dir ? e.path : "") : on.path
    is_place := place_path != "" && filebrowser_place_index(&a.filebrowser, place_path) >= 0

    out := make([dynamic]Menu_Item, 0, 12, alloc)
    switch on.kind {
    case .Entry:
        // A runnable entry says what Enter will DO, and carries the route back to the editor.
        runnable := row && !e.is_dir && run_command(e.path, e.exec, context.temp_allocator) != ""
        append(&out, Menu_Item{runnable ? "Run" : "Open", "Enter", .Open, row})
        if runnable {
            append(&out, Menu_Item{"Open in editor", "^o", .OpenInEditor, true})
        }
        append(&out, Menu_Item{action = .None})
        append(&out, Menu_Item{"Cut", "^x", .Cut, row || len(ft.marks) > 0})
        append(&out, Menu_Item{"Copy", "^c", .Copy, row || len(ft.marks) > 0})
        append(&out, Menu_Item{"Paste", "^v", .Paste, len(ft.clip) > 0})
        append(&out, Menu_Item{action = .None})
        append(&out, Menu_Item{marked ? "Unmark" : "Mark", "^y", .Mark, row})
        append(&out, Menu_Item{"Delete", "^d", .Delete, row || len(ft.marks) > 0})
        append(&out, Menu_Item{"Copy path", "^w", .CopyPath, row})
        append(&out, Menu_Item{"Properties", "^i", .Properties, row})
        // Left out rather than disabled: a file with nothing unsaved has no edits to discard.
        if row && ring_contains(a, e.path) {
            append(&out, Menu_Item{"Discard changes", "^k", .Discard, true})
        }
    case .Path:
        // A chrome-named directory can be gone to, staged for a paste and quoted, and that is
        // the whole of what a segment or a places row is. No hints: ^c and ^w are the same verbs
        // on the SELECTION, so naming them would name a chord that acts elsewhere.
        append(&out, Menu_Item{"Open", "", .Open, on.path != ""})
        append(&out, Menu_Item{action = .None})
        append(&out, Menu_Item{"Copy", "", .Copy, on.path != ""})
        append(&out, Menu_Item{"Copy path", "", .CopyPath, on.path != ""})
        append(&out, Menu_Item{"Properties", "", .Properties, on.path != ""})
    case .Dir:
        // The verbs that act on WHERE YOU ARE. Paste earns the gesture, and "Set workspace
        // here" is `:cd` + `:tu` with the folder pointed at.
        append(&out, Menu_Item{"Paste", "^v", .Paste, len(ft.clip) > 0})
        append(&out, Menu_Item{"Set workspace here", "^h", .SetWorkspace, on.path != ""})
        append(&out, Menu_Item{"Copy path", "^W", .CopyPath, on.path != ""})
        append(&out, Menu_Item{"Properties", "^I", .Properties, on.path != ""})
    }
    if in_places && place_path != "" {
        append(&out, Menu_Item{action = .None})
        if is_place {
            append(&out, Menu_Item{"Remove from places", "", .RemovePlace, true})
        } else {
            append(&out, Menu_Item{"Add to places", "", .AddPlace, true})
        }
    }
    append(&out, Menu_Item{"Reload", "^r", .Reload, true})
    return out[:]
}

// label + gap + hint. Rule 5 does not reach here: Clay would grow the popup to fit, but the
// PLACEMENT needs its width before it is declared, so this is the one place chrome measures a
// string itself. Runes, like clay_measure_dims.
ctxmenu_width_cells :: proc(m: ^ContextMenu) -> int {
    w := 0
    for it in m.items {
        if it.action == .None {
            continue
        }
        n := utf8.rune_count_in_string(it.label)
        if it.hint != "" {
            n += CM_HINT_GAP + utf8.rune_count_in_string(it.hint)
        }
        w = max(w, n)
    }
    return w
}
