package tests

import app ".."
import "core:testing"

// The context menu's model: where a popup goes for a press, which rows the keyboard may land
// on, and what a press outside one does. The placement is the interesting half — it is the
// "spatially aware" requirement, and being a pure function is what lets all four cases be
// asserted without a window.

@(private = "file")
ITEMS := [?]app.Menu_Item {
    {"Open", "Enter", .Open, true},
    {action = .None}, // a separator
    {"Cut", "^x", .Cut, true},
    {"Paste", "^v", .Paste, false}, // nothing on the clipboard
}

// A menu hangs down and to the right of the press, and FLIPS to the other side against an
// edge rather than sliding along it — so the pointer ends up on a corner of the menu and never
// inside it, which is what stops the item under the cursor being chosen by the same gesture
// that opened the menu.
@(test)
test_ctxmenu_place :: proc(t: ^testing.T) {
    // Room for it: the press is the top-left corner.
    testing.expect_value(t, app.ctxmenu_place(100, 100, 120, 80, 800, 600), app.Rect{100, 100, 120, 80})

    // Against the right edge: flipped left of the press, not slid back along the edge.
    testing.expect_value(t, app.ctxmenu_place(750, 100, 120, 80, 800, 600), app.Rect{630, 100, 120, 80})

    // Against the bottom: flipped above it.
    testing.expect_value(t, app.ctxmenu_place(100, 560, 120, 80, 800, 600), app.Rect{100, 480, 120, 80})

    // The corner does both at once.
    testing.expect_value(t, app.ctxmenu_place(750, 560, 120, 80, 800, 600), app.Rect{630, 480, 120, 80})

    // Exactly touching the edge is not an overflow — a flip here would be a jump for one pixel.
    testing.expect_value(t, app.ctxmenu_place(680, 520, 120, 80, 800, 600), app.Rect{680, 520, 120, 80})

    // A press near the LEFT edge with no room on either side clamps into the window rather than
    // resolving to a negative origin, which would paint off the top-left corner.
    testing.expect_value(t, app.ctxmenu_place(10, 10, 120, 80, 100, 60), app.Rect{0, 0, 120, 80})
}

// The keyboard skips separators and disabled rows, in both directions, and an open menu lands
// on something choosable rather than on whatever happens to be first.
@(test)
test_ctxmenu_selection_skips_chrome :: proc(t: ^testing.T) {
    a: app.App
    defer app.ctxmenu_destroy(&a)

    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, "/tmp")
    testing.expect(t, app.ctxmenu_shown(&a))
    testing.expect_value(t, a.ctxmenu.sel, 0)
    testing.expect_value(t, a.ctxmenu.target, "/tmp")

    // Down from Open steps OVER the separator to Cut, and stops there: Paste is disabled, and
    // there is nothing after it.
    app.ctxmenu_move(&a, 1)
    testing.expect_value(t, a.ctxmenu.sel, 2)
    app.ctxmenu_move(&a, 1)
    testing.expect_value(t, a.ctxmenu.sel, 2)

    app.ctxmenu_move(&a, -1)
    testing.expect_value(t, a.ctxmenu.sel, 0)
    app.ctxmenu_move(&a, -1)
    testing.expect_value(t, a.ctxmenu.sel, 0)

    // Closing releases the items and the target; `kind` IS the closed state, so there is no
    // second flag that could disagree with it.
    app.ctxmenu_close(&a)
    testing.expect(t, !app.ctxmenu_shown(&a))
    testing.expect_value(t, len(a.ctxmenu.items), 0)
    testing.expect_value(t, a.ctxmenu.target, "")
}

// A press outside an open menu dismisses it and is SPENT doing so. Without that, the press
// that closes the popup also lands on whatever is underneath — a row selected, or worse, in
// the pane the user was only trying to get back to.
@(test)
test_ctxmenu_dismiss_consumes_the_press :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    defer app.ctxmenu_destroy(&a)

    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, "/tmp")
    a.ctxmenu.rect = app.Rect{10, 10, 100, 60} // as the declaration would have left it

    // Inside: the menu keeps it, for its own item click to claim.
    a.mouse.click = true
    a.mouse.x, a.mouse.y = 50, 30
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, app.ctxmenu_shown(&a), "a press inside the menu must not dismiss it")
    testing.expect(t, a.mouse.click, "a press inside the menu is the menu's to claim, not the dismissal's")

    // Outside: closed, and the press is gone.
    a.mouse.x, a.mouse.y = 400, 300
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, !app.ctxmenu_shown(&a))
    testing.expect(t, !a.mouse.click, "the dismissing press must be spent")

    // With the pointer off, nothing happens at all — `mouse: off` costs convenience, never
    // capability, and the menu is only ever a second route to a chord.
    app.ctxmenu_open(&a, .FileOps, ITEMS[:], 10, 10, "/tmp")
    a.ctxmenu.rect = app.Rect{10, 10, 100, 60}
    a.mouse_on = false
    a.mouse.click = true
    app.ctxmenu_dismiss_click(&a)
    testing.expect(t, app.ctxmenu_shown(&a))
}

// The item table reports state rather than hiding it: a verb with nothing to act on is present
// and disabled, so the menu is the same shape every time and reading it teaches the chords.
@(test)
test_ctxmenu_file_items_enablement :: proc(t: ^testing.T) {
    a: app.App
    a.tree.dir = "/tmp/ft"
    append(&a.tree.entries, app.FileEntry{name = "f.txt", path = "/tmp/ft/f.txt"})
    // Not filetree_destroy: the entries here are literals, so only the two sets it OWNS are
    // torn down, and each is emptied before its backing array goes (one block, since defers
    // run in reverse and a pair of them would free the array out from under the walk).
    defer {
        delete(a.tree.entries)
        app.filetree_marks_reset(&a.tree)
        delete(a.tree.marks)
        app.filetree_clip_clear(&a.tree)
        delete(a.tree.clip)
    }

    find :: proc(items: []app.Menu_Item, action: app.Menu_Action) -> app.Menu_Item {
        for it in items {
            if it.action == action {
                return it
            }
        }
        return {}
    }

    // On a row, with an empty clipboard: everything about the row is live, paste is not.
    on_row := app.ctxmenu_file_items(&a, true, true, context.temp_allocator)
    testing.expect(t, find(on_row, .Open).enabled)
    testing.expect(t, find(on_row, .Copy).enabled)
    testing.expect(t, !find(on_row, .Paste).enabled, "paste with an empty clipboard must be disabled")
    testing.expect_value(t, find(on_row, .Mark).label, "Mark")

    // On the background: nothing is selected, so the per-entry verbs go quiet — but paste
    // lights up once the clipboard has something in it, since it acts on the DIRECTORY.
    app.filetree_clip_take(&a.tree, .Copy)
    off_row := app.ctxmenu_file_items(&a, false, true, context.temp_allocator)
    testing.expect(t, !find(off_row, .Open).enabled)
    testing.expect(t, !find(off_row, .CopyPath).enabled)
    testing.expect(t, find(off_row, .Paste).enabled)
    testing.expect(t, find(off_row, .Reload).enabled) // reload is always available

    // A marked entry offers to unmark, and the sidebar item is offered only where there IS a
    // sidebar — the dired listing has none, so it does not carry the row.
    app.filetree_mark_toggle(&a.tree)
    marked := app.ctxmenu_file_items(&a, true, false, context.temp_allocator)
    testing.expect_value(t, find(marked, .Mark).label, "Unmark")
    testing.expect_value(t, find(marked, .AddPlace).action, app.Menu_Action.None)

    // A FILE cannot be a place, so the browser's own menu offers it disabled rather than
    // adding a shortcut that opens nothing.
    file_menu := app.ctxmenu_file_items(&a, true, true, context.temp_allocator)
    testing.expect(t, !find(file_menu, .AddPlace).enabled)
}
