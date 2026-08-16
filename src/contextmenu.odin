package main

import "core:strings"
import "core:unicode/utf8"

// ContextMenu — the floating click-menu, and the one popup in the program: a right-press opens a list
// of BUTTONS naming the verbs the chords already do, at the pointer, over whatever is under it.
// Not a filetree feature: the model is a `kind` plus a list of items, so a second caller supplies
// its own items and gets the placement, the paint order, the capture and the keyboard for free.
// contextmenu_ui.odin is the declaration; the panes that open one are filebrowser_ui.odin and
// filetree_ui.odin.
//
// **The menu is discoverability, never capability.** Every item here is a Ctrl chord you can also
// type, and its hint column says which — the same bargain the chord cheat-sheet bar strikes, in
// the shape a pointer can press. Nothing may ever be reachable ONLY from here.

// Which surface opened the menu, and therefore who interprets a chosen action. `.None` IS the
// closed state — a menu with no owner has nothing to dispatch to, so there is no second `open`
// bool to keep in step with it.
Menu_Kind :: enum {
    None,
    FileOps,
}

// The verbs a menu item can carry. One flat enum rather than a proc pointer per item: an action
// is a name the dispatch switches on, which keeps the item list plain data that a test can build.
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
    Properties,
    AddPlace,
    RemovePlace,
    SetWorkspace,
    Reload,
}

// One row. `label` and `hint` are STATIC literals from the tables in the panes — the menu holds
// them past the frame that opened it, so a temp-allocated label would dangle on the second frame.
// A disabled item is drawn muted and refuses the press, rather than being left out: a paste that
// vanishes when the clipboard is empty teaches you less than one you can see is unavailable.
Menu_Item :: struct {
    label:   string,
    hint:    string,
    action:  Menu_Action,
    enabled: bool,
}

// What the menu was opened ON, and what sort of thing that path is. The kind picks the item table
// (a segment has no marks to toggle and nothing to unmark), and it decides which verbs act on
// THIS path rather than on the listing's selection — a press on the path bar names a directory
// the listing does not contain, so "act on the selection" would act on the wrong thing entirely.
Menu_Target_Kind :: enum {
    Dir, // the directory being browsed: the press hit the contents' background or a bar button
    Entry, // a row of the listing; the right press has already moved the selection onto it
    Path, // a directory named by chrome: a path-bar segment or a places row
}

Menu_Target :: struct {
    path: string,
    kind: Menu_Target_Kind,
}

ContextMenu :: struct {
    kind:  Menu_Kind,
    items: [dynamic]Menu_Item,

    // Where the press landed, and where the menu was actually PLACED for it (ctxmenu_place, which
    // may have flipped it off the window edge). The rect is written by the declaration and read
    // by the dismissal test — a press outside it closes the menu instead of reaching a pane.
    x, y:  i32,
    rect:  Rect,

    // The keyboard highlight and the pointer's, kept apart for the reason every pane keeps them
    // apart: the arrows move one, the pointer moves the other, and a menu where the mouse drags
    // the keyboard's place around is a menu you lose your position in.
    sel:   int,
    hover: int,

    // What the menu was opened ON — its `path` is OWNED. The listing, the places and the path
    // bar's segments are all freed and re-read by half the actions here, so this cannot be a
    // borrow of any of them.
    target: Menu_Target,
}

ctxmenu_shown :: proc(a: ^App) -> bool {
    return a.ctxmenu.kind != .None
}

// Open `items` at the press position. The items are COPIED (the caller builds them in the frame's
// temp arena), the target is cloned, and the keyboard lands on the first item that can actually
// be chosen — never on a separator, and never on a disabled row.
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

// The next item the keyboard may land on, walking `dir` from `from`; `from` = -1 starts before
// the list. Returns -1 when there is nothing selectable at all, which a menu built entirely of
// disabled rows can genuinely be.
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

// Where a menu of `w` x `h` goes for a press at (ax, ay). **This is the whole of "spatially
// aware", and it is a pure function so the four cases are assertable without a window.** The
// menu prefers to hang down and to the right of the pointer, like every desktop's; against an
// edge it FLIPS to the other side of the press rather than sliding along the edge, so the
// pointer always ends up on a corner of it and never inside it. A menu larger than the window
// clamps — there is no third option, and a negative origin would paint off the top-left.
ctxmenu_place :: proc(ax, ay, w, h, win_w, win_h: i32) -> Rect {
    x := ax
    if x + w > win_w {
        x = ax - w // flip to the left of the press
    }
    y := ay
    if y + h > win_h {
        y = ay - h // flip above it
    }
    x = clamp(x, 0, max(0, win_w - w))
    y = clamp(y, 0, max(0, win_h - h))
    return Rect{x, y, w, h}
}

// A press that landed outside the menu dismisses it and is SPENT doing so — the press that
// closes a popup must not also select a row underneath, which is what every desktop does and
// what stops a stray right-click-then-left-click editing a file you were not looking at.
// Runs before the panes declare (window_pointer), so no pane can claim it first.
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

// Run the highlighted item. Both callers — Enter and a click — come through here, so a verb
// cannot grow on one path and not the other.
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
    // Cloned into the frame's arena because the close below frees the menu's copy, and the
    // dispatch reads the path after it.
    on := Menu_Target{strings.clone(m.target.path, context.temp_allocator), m.target.kind}
    ctxmenu_close(a) // close FIRST: the actions below reload listings and stage command lines
    switch kind {
    case .None:
    case .FileOps:
        ctxmenu_file_action(a, it.action, on)
    }
}

// The file-ops dispatch. Every branch is the SAME call the chord makes (input.odin's
// action.odin), which is the property that keeps the menu discoverability rather than a second
// implementation — a verb that behaved differently here would be a bug with two sources.
@(private = "file")
ctxmenu_file_action :: proc(a: ^App, action: Menu_Action, on: Menu_Target) {
    ft := &a.tree
    named := on.kind == .Path // chrome named a directory the selection is not on
    switch action {
    case .None:
    case .Open:
        // Each presentation's own Enter verb: the browser's descends THROUGH THE HISTORY (a
        // menu that pushed history the `ls` pane cannot show would leave [◀] pointing at
        // somewhere you never went), the listing's is the plain activate.
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
        // Always the target: for an entry it IS the selection's path (the right press moved the
        // selection there), and for the other two kinds the selection is the wrong thing.
        if on.path != "" {
            clipboard_set(a, strings.clone(on.path), nil)
        }
    case .OpenInEditor:
        filetree_edit_selected(a) // the entry the right press selected, bytes and all
    case .Properties:
        filetree_props(a, on.path) // the target's, for all three kinds — t1 prints it
    case .AddPlace:
        filebrowser_place_add(&a.filebrowser, on.path)
    case .RemovePlace:
        filebrowser_place_remove(&a.filebrowser, filebrowser_place_index(&a.filebrowser, on.path))
    case .SetWorkspace:
        cl_workspace(a, on.path) // the project root moves here, and every unlocked terminal cds
    case .Reload:
        filetree_reload(ft)
    }
}

// The file-ops menu's items for a press on `on`. Built by the pane that opened the menu and
// copied into it, which is why the allocator defaults to the frame's temp arena — and why every
// label here is a LITERAL, since the menu outlives the arena.
//
// **A verb the target cannot have is left out; a verb it has but cannot do right now is
// disabled.** Mark on a path-bar segment is the first — there is no row to mark, and a greyed
// row that could never light up is furniture you read past. Paste with an empty clipboard is the
// second: it stays, greyed, because a clipboard is a thing you can go and fill.
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
    // The sidebar shortcut acts on a DIRECTORY: the entry when the press was on one, and the
    // named path otherwise — a file cannot be a place.
    place_path := row ? (e.is_dir ? e.path : "") : on.path
    is_place := place_path != "" && filebrowser_place_index(&a.filebrowser, place_path) >= 0

    out := make([dynamic]Menu_Item, 0, 12, alloc)
    switch on.kind {
    case .Entry:
        // A runnable entry says what Enter will DO with it, and carries the way back to the
        // editor beside it — Enter running a script is exactly when you need that route.
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
    case .Path:
        // A directory the chrome named: it can be gone to, staged for a paste and quoted, and
        // that is the whole of what a segment or a places row IS. **No hints here** — ^c and ^w
        // are the same verbs but on the SELECTION, and a column that named them would be naming
        // a chord that acts somewhere else. The keyboard's route to these is to go there first.
        append(&out, Menu_Item{"Open", "", .Open, on.path != ""})
        append(&out, Menu_Item{action = .None})
        append(&out, Menu_Item{"Copy", "", .Copy, on.path != ""})
        append(&out, Menu_Item{"Copy path", "", .CopyPath, on.path != ""})
        append(&out, Menu_Item{"Properties", "", .Properties, on.path != ""})
    case .Dir:
        // The background of the listing: the verbs that act on WHERE YOU ARE. Paste is the one
        // that earns the gesture, and it is the reason this menu exists at all. "Set workspace
        // here" is the other: it is `cd` + `tu`, and pointing at the folder is how you mean it.
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

// The widest item, in cells: label + a gap + hint. The menu is sized to its contents (rule 5 does
// not reach here — Clay would grow the popup to fit, but the popup's PLACEMENT needs its width
// before it is declared), so this is the one place chrome measures a string itself. Runes, like
// clay_measure_dims.
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
