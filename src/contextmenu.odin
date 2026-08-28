package main

import "core:unicode/utf8"
import "gfx"

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
    rect:  gfx.Rect,

    // Kept apart as every pane keeps them apart: the arrows move one, the pointer the other.
    sel:   int,
    hover: int,

    // `path` is OWNED: the listing, the places and the segments are all freed and re-read by
    // half the actions here.
    target: Menu_Target,
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


// Pure, so the four cases are assertable without a window. The menu hangs down and to the right
// of the pointer; against an edge it FLIPS to the other side of the press rather than sliding
// along it, so the pointer ends on a corner and never inside. A menu larger than the window
// clamps.
ctxmenu_place :: proc(ax, ay, w, h, win_w, win_h: i32) -> gfx.Rect {
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
    return gfx.Rect{x, y, w, h}
}





CM_HINT_GAP :: 3

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
