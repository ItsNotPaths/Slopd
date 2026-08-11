package main

import clay "../bindings/clay"

// The filetree pane's UI half, and the template the other list panes follow. filetree.odin
// is the host-independent listing (it reads directories and formats rows, with no App and no
// GL); everything here is the part that knows about Slopd: the theme, the unsaved ring, the
// pointer, and the pane rect it all has to fit inside. The pane's geometry exists ONCE, as a
// declared tree Clay resolves into boxes that paint AND answer "what is under the pointer".
//
// The frame order in filetree_frame is the load-bearing part:
//
//   1. Resolve the pending click FIRST, against the boxes Clay still holds from the LAST
//      frame — the pointer is over the pane that was painted, and SetPointerState (fed at the
//      top of render) resolves against exactly that tree.
//   2. THEN move the viewport, so a click that changed the selection scrolls in the same frame.
//   3. THEN declare, so the frame paints the post-click state. Consuming the click after the
//      declaration would paint the pre-click list and leave the selection invisible until the
//      next unrelated event woke the loop.

// Extra vertical padding per row, in logical pixels — the twin of GREP_ROW_PAD. Rows are whole
// pixels tall so the list stays on the cell grid: Clay solves in floats, and chrome that is not
// a whole multiple of the row height lands the solver's output between pixels.
FT_ROW_PAD :: 2

// The pane's fixed geometry: the content area inside the focus ring, the row height, and how
// many entry rows fit under the header. Pure, and shared by every phase of the frame, which is
// what makes them incapable of disagreeing. `rows` is at least 1 even in a too-short pane.
filetree_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(FT_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int((area.h - row_h) / row_h)) // the header takes the first row
    return
}

// Move the viewport to follow the selection, under the shared `scroll_mode` policy — the same
// one the editor tracks its caret with (list_scroll_target, scroll.odin). A normal state
// update, GL-free and called before anything is declared, so a headless test can exercise it.
filetree_scroll_apply :: proc(ft: ^FileTree, rows: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&ft.scroll, &ft.scroll_detached, ft.selected, rows, len(ft.entries), center, last_input_at)
}

// Which entry the pointer is over, or -1. Clay answers from the tree the LAST frame declared,
// so this runs before this frame's and over the window that was PAINTED — `top`, the animated
// position, not `ft.scroll`, the target. Mid-scroll those differ by up to a screenful, and
// probing the target would ask about rows the last frame never declared. A stale id reports
// false: a resize costs a missed click, never a wrong row.
filetree_hit :: proc(ft: ^FileTree, top, visible: int) -> int {
    first := clamp(top, 0, max(0, len(ft.entries)))
    n := max(0, min(len(ft.entries) - first, visible))
    for k in 0 ..< n {
        i := first + k
        if clay.PointerOver(clay.ID("ft_row", u32(i))) {
            return i
        }
    }
    return -1
}

// Apply a pending click on `row` (-1 = the pointer hit no row). Single click selects, double
// click activates — the mouse twin of Down/Up and Enter, so neither path can grow behaviour the
// other lacks. Claimed only on a real hit; focus is NOT taken here (see window_ui.odin).
filetree_click :: proc(a: ^App, row: int) {
    if row < 0 {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    ft := &a.tree
    if len(ft.entries) == 0 {
        return
    }
    ft.selected = clamp(row, 0, len(ft.entries) - 1)
    if count < 2 {
        return
    }
    // Double click is Enter, through the same proc: descend into a directory (which reloads the
    // listing, so the row index we just set no longer refers to anything), run the file if it is
    // something we can run, or open it here in Slopd's own editor.
    filetree_activate_selected(a)
}

// A right press: select what is under it, then open the file-ops menu there. The SAME menu the
// browser opens, minus the places item — there is no sidebar here to add a shortcut to — which
// is the reuse the popup was built for rather than a second implementation of one.
filetree_rclick :: proc(a: ^App, row: int) {
    if !rect_hit(a.lay.aux, a.mouse.rclick_x, a.mouse.rclick_y) {
        return // not our pane; whoever owns that region may claim it
    }
    if !mouse_take_rclick(a) {
        return
    }
    ft := &a.tree
    on := Menu_Target{ft.dir, .Dir}
    if row >= 0 && row < len(ft.entries) {
        ft.selected = row
        if e := filetree_selected(ft); e != nil {
            on = {e.path, .Entry}
        }
    }
    items := ctxmenu_file_items(a, on, false, context.temp_allocator)
    ctxmenu_open(a, .FileOps, items, a.mouse.rclick_x, a.mouse.rclick_y, on)
}

// Declare the pane into the window's tree. Reads App, writes only Clay — no mutation,
// no GL — which is what lets tests/filetree_ui_test.odin assert the resolved boxes for a
// known listing and viewport without a window.
//
// The tree is:
//   ft_pane   the content area inside the focus ring, floating at the pane's own rect and
//             clipping its own content (painted by panel(), not here)
//     ft_head  the dired-style header: the current directory, muted
//     ft_body  the clip group — rows past the bottom edge are cut here
//       ft_row/i   one per visible entry, keyed by ENTRY index so a hit names an entry
//         ft_pre/i   the two-cell prefix column, so names start on a fixed cell
//
//     ch_bar     the Ctrl-held chord cheat-sheet (overlay_ui.odin), when it is up: a
//                floating child of the pane, so it inherits the pane's clip and covers the
//                rows rather than being laid out under them
//
// Row indices are the entry's own, not the visible row's: that is what makes filetree_hit
// return something meaningful without a second mapping to maintain.
filetree_declare :: proc(a: ^App, f: ^Font, pane: Rect, top: int, off: i32, now: f64 = 0) {
    ft := &a.tree
    th := &a.theme
    area, row_h, rows := filetree_geom(pane, a.scale, f.line_height)
    cw := f.cell_w
    lh := i32(f.line_height)

    // The window is the TWEEN's top and the remainder is the clip's childOffset — never a term
    // in each row's y, which would put the rows off the cell grid and leave the clip cutting
    // the wrong pixels.
    //
    // The COUNT is the rows the body touches (list_visible_rows), not the whole rows that fit:
    // the partial row at the bottom edge is on screen and has to be declared, whether the
    // remainder comes from the body's height or from a scroll in progress.
    first := clamp(top, 0, max(0, len(ft.entries)))
    visible := max(0, min(len(ft.entries) - first, list_visible_rows(area.h - row_h, off, row_h)))

    // No backgroundColor: panel() already filled the pane, so the fills that do appear mean
    // something — a marked row, the selection.
    if clay.UI(clay.ID("ft_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("ft_head"))(
            {
                layout = {
                    sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                    padding        = {left = u16(cw)}, // the one-cell left margin, as before
                    childAlignment = {y = .Center},
                },
            },
        ) {
            clay.Text(ft.dir, clay_text_config(th.muted, lh))
        }

        if clay.UI(clay.ID("ft_body"))(
            {
                layout = {
                    // FIXED height, not Grow: `SizingGrow` means "at least fit your content", so
                    // the row scrolling into view would stretch the clip group past the pane and
                    // take its scissor with it (rule 8, from the animation's side).
                    sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(max(0, area.h - row_h)))},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true, childOffset = {0, -f32(off)}},
            },
        ) {
            for k in 0 ..< visible {
                i := first + k
                e := &ft.entries[i]
                marked := filetree_marked(ft, e.path)
                ringed := ring_contains(a, e.path)

                // One background per element, so the precedence is stated rather than
                // implied by draw order.
                bg: clay.Color
                if i == ft.selected {
                    bg = clay_rgb(th.separator)
                } else if marked {
                    bg = clay_rgb(th.line_highlight)
                } else if hover_shown(a) && i == ft.hover {
                    bg = clay_rgb(hover_bg(th)) // last, so it never masks a mark
                }

                if clay.UI(clay.ID("ft_row", u32(i)))(
                    {
                        layout = {
                            sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                            padding        = {left = u16(cw)},
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = bg,
                    },
                ) {
                    // A marked entry takes the prefix slot (accent '+'); else the
                    // unsaved-ring star or a dash.
                    prefix := marked ? "+" : ringed ? "*" : "-"
                    pcol := marked ? th.accent : ringed ? th.urgent : th.muted

                    // A fixed TWO-cell column, not a gap: the prefix is one cell and the
                    // name starts on the next but one. Sized in cells (a float, cell_w is
                    // exact) rather than as padding, which Clay takes as whole pixels.
                    if clay.UI(clay.ID("ft_pre", u32(i)))(
                        {layout = {sizing = {width = clay.SizingFixed(2 * cw)}}},
                    ) {
                        clay.Text(prefix, clay_text_config(pcol, lh))
                    }
                    clay.Text(e.display, clay_text_config(e.is_dir ? th.code_return_type : th.fg, lh))
                }
            }
        }

        // The chord bar goes LAST and inside the pane, which is what makes it an overlay:
        // `attachTo = .Parent` takes ft_pane off the open clip stack, so the bar gets a scissor
        // group of its own — without which its backdrop would paint BEHIND the names it covers.
        if chord_shown(a) {
            chord_declare(a, f, area, now)
        }
    }
}

// The pane alone in a window, as a command list — the test-facing half of the declaration
// above. The app never calls it; tests/filetree_ui_test.odin does, because a pane's boxes are
// the same whether or not another pane is declared beside it.
filetree_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    _, row_h, _ := filetree_geom(pane, a.scale, f.line_height)
    top, off := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, row_h)
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        filetree_declare(a, f, pane, top, off, now)
    }
    return clay.EndLayout(0)
}

// The filetree listing: a dired-style header (current dir) then rows, each prefixed '+' (marked
// marked), '*' (in the unsaved ring) or '-'. The selection is highlighted and tracked under
// the shared `scroll_mode` policy. The phases and their order ARE the pane template.
filetree_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    area, row_h, rows := filetree_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    // The window the LAST frame painted is what the pointer is over, so the click resolves
    // against the ANIMATED top rather than the target — the editor's shape, and the reason the
    // view is built twice here too. smooth_scroll re-aims the tween, which is what makes
    // anim_active true and what app_next_wake schedules the next frame off.
    top, off0 := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, row_h)
    hit := filetree_hit(&a.tree, top, list_visible_rows(area.h - row_h, off0, row_h))
    a.tree.hover = hit // resolved against the same (last) frame the click is
    filetree_click(a, hit)
    filetree_rclick(a, hit)
    filetree_scroll_apply(&a.tree, rows, a.scroll_mode == .Middle, pane_input_at(a))

    // Then re-read it over the moved target, so a click that scrolled the list starts easing
    // in the frame it was made rather than a frame later.
    off: i32
    top, off = smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, row_h)
    filetree_declare(a, &t.font, pane, top, off, now)
}
