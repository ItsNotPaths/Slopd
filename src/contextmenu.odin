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
    AddPlace,
    RemovePlace,
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

    // What the menu was opened ON (owned): the entry's path, or the browsed directory when the
    // press hit no row. The listing is freed and re-read by half the actions here, so this
    // cannot be a borrow of an entry.
    target: string,
}

ctxmenu_shown :: proc(a: ^App) -> bool {
    return a.ctxmenu.kind != .None
}

// Open `items` at the press position. The items are COPIED (the caller builds them in the frame's
// temp arena), the target is cloned, and the keyboard lands on the first item that can actually
// be chosen — never on a separator, and never on a disabled row.
ctxmenu_open :: proc(a: ^App, kind: Menu_Kind, items: []Menu_Item, x, y: i32, target: string) {
    ctxmenu_close(a)
    m := &a.ctxmenu
    m.kind = kind
    for it in items {
        append(&m.items, it)
    }
    m.x, m.y = x, y
    m.hover = -1
    m.target = strings.clone(target)
    m.sel = ctxmenu_next_selectable(m, -1, 1)
}

ctxmenu_close :: proc(a: ^App) {
    m := &a.ctxmenu
    m.kind = .None
    clear(&m.items)
    delete(m.target)
    m.target = ""
    m.rect = {}
    m.sel, m.hover = -1, -1
}

ctxmenu_destroy :: proc(a: ^App) {
    delete(a.ctxmenu.items)
    delete(a.ctxmenu.target)
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
    // Only the two sidebar verbs act on the path the menu was opened over; the rest act on the
    // selection, which the right press already moved. Cloned because the close below frees it.
    on_place := it.action == .AddPlace || it.action == .RemovePlace
    target := strings.clone(on_place ? m.target : "", context.temp_allocator)
    ctxmenu_close(a) // close FIRST: the actions below reload listings and stage command lines
    switch kind {
    case .None:
    case .FileOps:
        ctxmenu_file_action(a, it.action, target)
    }
}

// The file-ops dispatch. Every branch is the SAME call the chord makes (input.odin's
// filetree_key), which is the property that keeps the menu discoverability rather than a second
// implementation — a verb that behaved differently here would be a bug with two sources.
@(private = "file")
ctxmenu_file_action :: proc(a: ^App, action: Menu_Action, target: string) {
    ft := &a.tree
    switch action {
    case .None:
    case .Open:
        // Each presentation's own Enter verb: the browser's descends THROUGH THE HISTORY (a
        // menu that pushed history the `ls` pane cannot show would leave [◀] pointing at
        // somewhere you never went), the listing's is the plain activate.
        if a.file_pane == .Browser {
            filebrowser_activate(a)
        } else if path, is_file := filetree_activate(ft); is_file {
            open_file(a, path)
        }
    case .Cut:
        filetree_clip_take(ft, .Cut)
    case .Copy:
        filetree_clip_take(ft, .Copy)
    case .Paste:
        filetree_paste(ft)
    case .Mark:
        filetree_mark_toggle(ft)
    case .Delete:
        filetree_rm_selected(a, len(ft.marks) > 0)
    case .CopyPath:
        if e := filetree_selected(ft); e != nil {
            clipboard_set(a, strings.clone(e.path), nil)
        }
    case .AddPlace:
        filebrowser_place_add(&a.filebrowser, target)
    case .RemovePlace:
        filebrowser_place_remove(&a.filebrowser, filebrowser_place_index(&a.filebrowser, target))
    case .Reload:
        filetree_reload(ft)
    }
}

// The file-ops menu's items, for a press on an entry (`on_row`) or on the background. Built by
// the pane that opened the menu and copied into it, which is why the allocator defaults to the
// frame's temp arena — and why every label here is a LITERAL, since the menu outlives the arena.
//
// **Nothing is left out, only disabled.** A paste with an empty clipboard, a delete with nothing
// under the pointer: both stay on the menu, greyed, so the menu is the same shape every time you
// open it and reading it teaches you the chords rather than the current state.
ctxmenu_file_items :: proc(
    a: ^App,
    on_row, in_places: bool,
    alloc := context.temp_allocator,
) -> []Menu_Item {
    ft := &a.tree
    e := filetree_selected(ft)
    row := on_row && e != nil
    marked := row && filetree_marked(ft, e.path)
    // The sidebar shortcut acts on the entry when it is a directory, and on the directory being
    // browsed when the press hit its background — a file cannot be a place.
    place_path := row ? (e.is_dir ? e.path : "") : ft.dir
    is_place := place_path != "" && filebrowser_place_index(&a.filebrowser, place_path) >= 0

    out := make([dynamic]Menu_Item, 0, 12, alloc)
    append(&out, Menu_Item{"Open", "Enter", .Open, row})
    append(&out, Menu_Item{action = .None})
    append(&out, Menu_Item{"Cut", "^x", .Cut, row || len(ft.marks) > 0})
    append(&out, Menu_Item{"Copy", "^c", .Copy, row || len(ft.marks) > 0})
    append(&out, Menu_Item{"Paste", "^v", .Paste, len(ft.clip) > 0})
    append(&out, Menu_Item{action = .None})
    append(&out, Menu_Item{marked ? "Unmark" : "Mark", "^y", .Mark, row})
    append(&out, Menu_Item{"Delete", "^d", .Delete, row || len(ft.marks) > 0})
    append(&out, Menu_Item{"Copy path", "^w", .CopyPath, row})
    if in_places {
        append(&out, Menu_Item{action = .None})
        if is_place {
            append(&out, Menu_Item{"Remove from places", "", .RemovePlace, true})
        } else {
            append(&out, Menu_Item{"Add to places", "", .AddPlace, place_path != ""})
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
