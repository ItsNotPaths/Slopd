package tests

import app "../slopd"
import "core:strings"
import "core:testing"
import "../gfx"
import "../ui"
import "../edit"

// Where a popup goes for a press, which rows the keyboard may land on, and what a press outside
// one does. The placement is the interesting half, and being pure is what lets all four cases be
// asserted without a window.

@(private = "file")
ITEMS := [?]ui.Menu_Item {
    {"Open", "Enter", .Open, true},
    {action = .None}, // a separator
    {"Cut", "^x", .Cut, true},
    {"Paste", "^v", .Paste, false}, // nothing on the clipboard
}

// A menu hangs down and to the right of the press and FLIPS against an edge rather than sliding
// along it, so the pointer ends on a corner and never inside — which stops the item under the
// cursor being chosen by the gesture that opened the menu.
@(test)
test_ctxmenu_place :: proc(t: ^testing.T) {
    // Room for it: the press is the top-left corner.
    testing.expect_value(t, ui.ctxmenu_place(100, 100, 120, 80, 800, 600), gfx.Rect{100, 100, 120, 80})

    // Against the right edge: flipped left, not slid back along the edge.
    testing.expect_value(t, ui.ctxmenu_place(750, 100, 120, 80, 800, 600), gfx.Rect{630, 100, 120, 80})

    // Against the bottom: flipped above it.
    testing.expect_value(t, ui.ctxmenu_place(100, 560, 120, 80, 800, 600), gfx.Rect{100, 480, 120, 80})

    // The corner does both at once.
    testing.expect_value(t, ui.ctxmenu_place(750, 560, 120, 80, 800, 600), gfx.Rect{630, 480, 120, 80})

    // Exactly touching the edge is not an overflow: a flip would be a jump for one pixel.
    testing.expect_value(t, ui.ctxmenu_place(680, 520, 120, 80, 800, 600), gfx.Rect{680, 520, 120, 80})

    // A press near the left edge with no room either side clamps into the window rather than
    // resolving to a negative origin.
    testing.expect_value(t, ui.ctxmenu_place(10, 10, 120, 80, 100, 60), gfx.Rect{0, 0, 120, 80})
}

// Separators and disabled rows are skipped both ways, and an open menu lands on something
// choosable rather than whatever is first.
@(test)
test_ctxmenu_selection_skips_chrome :: proc(t: ^testing.T) {
    a: app.App
    defer app.ctxmenu_destroy(&a)

    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, {"/tmp", .Dir})
    testing.expect(t, app.ctxmenu_shown(&a))
    testing.expect_value(t, a.ctxmenu.sel, 0)
    testing.expect_value(t, a.ctxmenu.target.path, "/tmp")

    // Down from Open steps over the separator to Cut and stops: Paste is disabled.
    app.ctxmenu_move(&a, 1)
    testing.expect_value(t, a.ctxmenu.sel, 2)
    app.ctxmenu_move(&a, 1)
    testing.expect_value(t, a.ctxmenu.sel, 2)

    app.ctxmenu_move(&a, -1)
    testing.expect_value(t, a.ctxmenu.sel, 0)
    app.ctxmenu_move(&a, -1)
    testing.expect_value(t, a.ctxmenu.sel, 0)

    // Closing releases the items and the target; `kind` IS the closed state.
    app.ctxmenu_close(&a)
    testing.expect(t, !app.ctxmenu_shown(&a))
    testing.expect_value(t, len(a.ctxmenu.items), 0)
    testing.expect_value(t, a.ctxmenu.target.path, "")
}

// A press outside dismisses the menu and is SPENT doing so, or the press that closes the popup
// also lands on whatever is underneath.
@(test)
test_ctxmenu_dismiss_consumes_the_press :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    defer app.ctxmenu_destroy(&a)

    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, {"/tmp", .Dir})
    a.ctxmenu.rect = gfx.Rect{10, 10, 100, 60} // as the declaration would have left it

    // Inside: the menu keeps it, for its own item click to claim.
    a.mouse.click = true
    a.mouse.x, a.mouse.y = 50, 30
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, app.ctxmenu_shown(&a), "a press inside the menu must not dismiss it")
    testing.expect(t, a.mouse.click, "a press inside the menu is the menu's to claim, not the dismissal's")

    a.mouse.x, a.mouse.y = 400, 300
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, !app.ctxmenu_shown(&a))
    testing.expect(t, !a.mouse.click, "the dismissing press must be spent")

    // With the pointer off, nothing happens: the menu is only ever a second route to a chord.
    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, {"/tmp", .Dir})
    a.ctxmenu.rect = gfx.Rect{10, 10, 100, 60}
    a.mouse_on = false
    a.mouse.click = true
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, app.ctxmenu_shown(&a))
}

// Discard is on a row only while that file has unsaved edits. A clean file has nothing to throw
// away, so the verb is LEFT OUT rather than sitting greyed on every menu there ever is.
@(test)
test_ctxmenu_discard_only_for_unsaved :: proc(t: ^testing.T) {
    a: app.App
    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "f.txt", path = "/tmp/ft/f.txt"})
    edit.editor_init(&a.editor)
    defer {
        delete(a.tree.entries)
        edit.editor_destroy(&a.editor)
    }

    // The menu the right press on f.txt would build, and whether it carries the discard.
    discard_row :: proc(a: ^app.App) -> (ui.Menu_Item, bool) {
        items := app.ctxmenu_file_items(a, {"/tmp/ft/f.txt", .Entry}, false, context.temp_allocator)
        for it in items {
            if it.action == .Discard {
                return it, true
            }
        }
        return {}, false
    }

    _, on_clean := discard_row(&a)
    testing.expect(t, !on_clean, "a file with nothing unsaved must not carry a dead Discard")

    b := edit.editor_current(&a.editor)
    b.path = strings.clone("/tmp/ft/f.txt")
    b.dirty = true
    it, on_dirty := discard_row(&a)
    testing.expect(t, on_dirty, "an unsaved file's menu must offer the discard")
    testing.expect(t, it.enabled)
    testing.expect_value(t, it.hint, "^k") // the chord it stands for, never a verb of its own

    // The '*' in the listing and the menu row are one question asked twice.
    testing.expect(t, edit.ring_contains(&a.editor, "/tmp/ft/f.txt"))
}

// Cut to what the TARGET can have, and only then greyed for what it cannot do yet: a verb
// missing from a menu could never work there, and one still on it is held back by state alone.
@(test)
test_ctxmenu_file_items_enablement :: proc(t: ^testing.T) {
    a: app.App
    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "f.txt", path = "/tmp/ft/f.txt"})
    // Not filetree_destroy: the entries are literals, so only the two sets it OWNS are torn
    // down, each emptied before its backing array goes.
    defer {
        delete(a.tree.entries)
        app.filetree_marks_reset(&a.tree)
        delete(a.tree.marks)
        app.filetree_clip_clear(&a.tree)
        delete(a.tree.clip)
    }

    find :: proc(items: []ui.Menu_Item, action: ui.Menu_Action) -> ui.Menu_Item {
        for it in items {
            if it.action == action {
                return it
            }
        }
        return {}
    }
    has :: proc(items: []ui.Menu_Item, action: ui.Menu_Action) -> bool {
        for it in items {
            if it.action == action {
                return true
            }
        }
        return false
    }

    // On a row with an empty clipboard: everything about the row is live, paste is not.
    on_row := app.ctxmenu_file_items(&a, {"/tmp/ft/f.txt", .Entry}, true, context.temp_allocator)
    testing.expect(t, find(on_row, .Open).enabled)
    testing.expect(t, find(on_row, .Copy).enabled)
    testing.expect(t, !find(on_row, .Paste).enabled, "paste with an empty clipboard must be disabled")
    testing.expect_value(t, find(on_row, .Mark).label, "Mark")

    // On the background the per-entry verbs are GONE rather than greyed, since there is no row
    // for them to act on; the two that act on the directory are live.
    app.filetree_clip_take(&a.tree, .Copy)
    off_row := app.ctxmenu_file_items(&a, {"/tmp/ft", .Dir}, true, context.temp_allocator)
    testing.expect(t, !has(off_row, .Open), "a menu on no row must not carry a dead Open")
    testing.expect(t, !has(off_row, .Cut) && !has(off_row, .Mark) && !has(off_row, .Delete))
    testing.expect(t, find(off_row, .CopyPath).enabled, "copy path acts on the browsed directory")
    testing.expect(t, find(off_row, .Paste).enabled)
    testing.expect(t, find(off_row, .AddPlace).enabled) // the directory you are in can be one
    testing.expect(t, find(off_row, .Reload).enabled) // reload is always available

    // On a segment or a places row: a named directory, which can be gone to, staged for a paste
    // and quoted, and nothing else.
    seg := app.ctxmenu_file_items(&a, {"/tmp", .Path}, true, context.temp_allocator)
    testing.expect(t, find(seg, .Open).enabled)
    testing.expect(t, find(seg, .Copy).enabled, "a folder named in the path bar can be copied")
    testing.expect(t, find(seg, .CopyPath).enabled)
    testing.expect(t, find(seg, .AddPlace).enabled)
    testing.expect(t, !has(seg, .Delete) && !has(seg, .Mark) && !has(seg, .Paste))

    // "Set workspace here" is the background's verb, and on no other menu: on a row or a
    // segment, "here" would name something else.
    testing.expect(t, find(off_row, .SetWorkspace).enabled)
    testing.expect_value(t, find(off_row, .SetWorkspace).hint, "^h")
    testing.expect(t, !has(on_row, .SetWorkspace) && !has(seg, .SetWorkspace))

    // Properties is on all three, because all three name something `stat` can describe.
    testing.expect(t, find(on_row, .Properties).enabled)
    testing.expect(t, find(off_row, .Properties).enabled)
    testing.expect(t, find(seg, .Properties).enabled)

    // The hint names the chord that does THIS: the directory's properties are ^I, the entry's
    // ^i, and a segment's have no chord.
    testing.expect_value(t, find(on_row, .Properties).hint, "^i")
    testing.expect_value(t, find(off_row, .Properties).hint, "^I")
    testing.expect_value(t, find(seg, .Properties).hint, "")

    // A runnable entry says what Enter will do and carries the way back to the editor: "Open"
    // on a binary would be a lie, and without the second row a +x script has no route in.
    append(&a.tree.entries, app.FileEntry{name = "tool", path = "/tmp/ft/tool", exec = true})
    a.tree.selected = len(a.tree.entries) - 1
    prog := app.ctxmenu_file_items(&a, {"/tmp/ft/tool", .Entry}, true, context.temp_allocator)
    testing.expect_value(t, find(prog, .Open).label, "Run")
    testing.expect(t, find(prog, .OpenInEditor).enabled)
    testing.expect_value(t, find(prog, .OpenInEditor).hint, "^o")

    // An ordinary file is opened, not run, and carries no second row.
    a.tree.selected = 0
    doc := app.ctxmenu_file_items(&a, {"/tmp/ft/f.txt", .Entry}, true, context.temp_allocator)
    testing.expect_value(t, find(doc, .Open).label, "Open")
    testing.expect(t, !has(doc, .OpenInEditor))

    // A marked entry offers to unmark, and the sidebar item only where there IS a sidebar.
    app.filetree_mark_toggle(&a.tree)
    marked := app.ctxmenu_file_items(&a, {"/tmp/ft/f.txt", .Entry}, false, context.temp_allocator)
    testing.expect_value(t, find(marked, .Mark).label, "Unmark")
    testing.expect(t, !has(marked, .AddPlace))

    // A file cannot be a place, so the shortcut row is left out rather than offered dead.
    file_menu := app.ctxmenu_file_items(&a, {"/tmp/ft/f.txt", .Entry}, true, context.temp_allocator)
    testing.expect(t, !has(file_menu, .AddPlace))
}

// Every menu ends up with something the keyboard can land on: a shape whose first live row is
// the third must still open on it.
@(test)
test_ctxmenu_every_target_is_navigable :: proc(t: ^testing.T) {
    a: app.App
    a.tree.dir = "/tmp/ft"
    defer app.ctxmenu_destroy(&a)

    for kind in ui.Menu_Target_Kind {
        on := ui.Menu_Target{"/tmp/ft", kind}
        items := app.ctxmenu_file_items(&a, on, true, context.temp_allocator)
        app.ctxmenu_open(&a, .FileOps, items, 10, 10, on)
        testing.expectf(t, a.ctxmenu.sel >= 0, "%v opened with nothing selectable", kind)
        testing.expect(t, items[a.ctxmenu.sel].enabled && items[a.ctxmenu.sel].action != .None)
        app.ctxmenu_close(&a)
    }
}
