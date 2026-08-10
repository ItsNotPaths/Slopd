package main

import clay "../bindings/clay"

// The filetree pane's UI half — C3, the first pane declared in Clay. filetree.odin is the
// host-independent listing (it reads directories and formats rows, with no App and no GL);
// everything here is the part that knows about Slopd: the theme, the unsaved ring, the
// pointer, and the pane rect it all has to fit inside.
//
// The point of the port is that the pane's geometry now exists ONCE, as a declared tree.
// draw_filetree used to compute row_h, the list top, the visible window and each row's y
// as locals and throw them away, which is why nothing could hit-test them; Clay resolves
// the same tree into boxes that paint AND answer "what is under the pointer". Nothing
// about the listing itself changed here — same dired-style header, same one-cell margin,
// same prefix column, same colours. The redesign is a separate job.
//
// The frame order in draw_filetree is the load-bearing part, and it reads oddly until you
// know why:
//
//   1. Resolve the pending click FIRST, against the boxes Clay is still holding from the
//      LAST frame. That is not a compromise — it is the only correct choice. The pointer
//      is over the pane the user is looking at, which is the one that was painted, and
//      SetPointerState (fed at the top of render) resolves against exactly that tree.
//   2. THEN move the viewport, so a click that changed the selection scrolls in the same
//      frame it was made.
//   3. THEN declare and paint, so the frame shows the post-click state. Consuming the
//      click after the declaration instead would paint the pre-click list and leave the
//      selection invisible until the next unrelated event woke the loop.

// Extra vertical padding per row, in logical pixels — the twin of GREP_ROW_PAD, and the
// value draw_filetree has always used. Rows are whole pixels tall so the list stays on the
// cell grid: Clay solves in floats, and chrome that is not a whole multiple of the row
// height lands the solver's output between pixels.
FT_ROW_PAD :: 2

// The pane's fixed geometry: the content area inside the focus ring, the row height, and
// how many entry rows fit under the header. Pure, and shared by every phase of the frame —
// the hit test, the scroll policy and the declaration all size themselves from this one
// call, which is what makes them incapable of disagreeing.
//
// `rows` is at least 1 even in a pane too short to hold a row: the old code did the same,
// and the clip group is what keeps an overflowing row inside the pane.
filetree_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(FT_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int((area.h - row_h) / row_h)) // the header takes the first row
    return
}

// Move the viewport to follow the selection, under the shared `scroll_mode` policy — the
// same one the editor tracks its caret with (list_scroll_target, scroll.odin).
//
// This is the write that used to happen INSIDE draw_filetree, which meant the pane's
// scroll position was a side effect of painting: nothing headless could exercise it, and
// a frame that did not draw did not scroll. It is a normal state update now, GL-free and
// called before anything is declared.
filetree_scroll_apply :: proc(ft: ^FileTree, rows: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&ft.scroll, &ft.scroll_detached, ft.selected, rows, len(ft.entries), center, last_input_at)
}

// Which entry the pointer is over, or -1 for none. Clay answers from the tree it is
// holding — i.e. the one the LAST frame declared — which is why this runs before this
// frame's declaration rather than after it.
//
// The loop is over the visible window only, never the whole listing: a directory can hold
// thousands of entries and only the declared ones can possibly be hit. `ft.scroll` is
// deliberately read BEFORE filetree_scroll_apply runs, so the window matches the rows that
// were actually painted. A stale id (the window shrank since) simply reports false, so a
// resize between the press and the frame that claims it costs a missed click, never a hit
// on the wrong row.
filetree_hit :: proc(ft: ^FileTree, rows: int) -> int {
    first := clamp(ft.scroll, 0, max(0, len(ft.entries)))
    n := max(0, min(len(ft.entries) - first, rows))
    for k in 0 ..< n {
        i := first + k
        if clay.PointerOver(clay.ID("ft_row", u32(i))) {
            return i
        }
    }
    return -1
}

// Apply a pending click on `row` (-1 = the pointer hit no row). Single click selects,
// double click activates — the mouse twin of Down/Up and Enter, so both paths end in the
// same two procs and neither can grow behaviour the other lacks.
//
// The click is claimed only when a row was actually hit; a press over the header, the
// margin or another pane is left for whoever else is drawing (nobody, today) and dropped
// at the end of the frame. Focus is NOT taken: focus-follows-click is C8 and belongs to
// every pane at once, since a filetree that grabs focus while the git pane does not is
// worse than one that never does.
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
    // Double click is Enter: descend into a directory (which reloads the listing, so the
    // row index we just set no longer refers to anything — filetree_activate handles that)
    // or open the file here, in Slopd's own editor.
    if path, is_file := filetree_activate(ft); is_file {
        open_file(a, path)
    }
}

// Declare the pane and hand back the frame's command list. Reads App, writes only Clay —
// no mutation, no GL — which is what lets tests/filetree_ui_test.odin assert the resolved
// boxes for a known listing and viewport without a window.
//
// The tree is:
//   ft_root  full-window container, padded to put the pane where render decided it goes
//     ft_pane   the content area inside the focus ring (painted by panel(), not here)
//       ft_head  the dired-style header: the current directory, muted
//       ft_body  the clip group — rows past the bottom edge are cut here
//         ft_row/i   one per visible entry, keyed by ENTRY index so a hit names an entry
//           ft_pre/i   the two-cell prefix column, so names start on a fixed cell
//
// Row indices are the entry's own, not the visible row's: that is what makes filetree_hit
// return something meaningful without a second mapping to maintain.
filetree_layout :: proc(a: ^App, f: ^Font, pane: Rect, win_w, win_h: i32) -> clay.ClayArray(clay.RenderCommand) {
    ft := &a.tree
    th := &a.theme
    area, row_h, rows := filetree_geom(pane, a.scale, f.line_height)
    cw := f.cell_w
    lh := i32(f.line_height)

    first := clamp(ft.scroll, 0, max(0, len(ft.entries)))
    visible := max(0, min(len(ft.entries) - first, rows))

    clay_resize(win_w, win_h)
    clay.BeginLayout()

    // Clay lays out from (0, 0) at the framebuffer size, so a pane at an arbitrary rect is
    // a full-window root padded by the pane's origin holding a fixed-size child. The panes
    // become siblings of a real split when C8 declares the window frame; until then this
    // is the cheapest way to put one pane where compute_layout already decided it goes.
    if clay.UI(clay.ID("ft_root"))(
        {
            layout = {
                sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))},
                padding = {left = u16(max(0, area.x)), top = u16(max(0, area.y))},
            },
        },
    ) {
        // No backgroundColor anywhere in this tree: panel() has already filled the pane and
        // drawn its focus ring, and Clay's default transparent is not painted (clay_color
        // reports it invisible), so the fills that do appear are the ones that mean
        // something — a marked row, the selection.
        if clay.UI(clay.ID("ft_pane"))(
            {
                layout = {
                    sizing = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
                    layoutDirection = .TopToBottom,
                },
            },
        ) {
            if clay.UI(clay.ID("ft_head"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                        padding = {left = u16(cw)}, // the one-cell left margin, as before
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                clay.Text(ft.dir, clay_text_config(th.muted, lh))
            }

            if clay.UI(clay.ID("ft_body"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingGrow()},
                        layoutDirection = .TopToBottom,
                    },
                    clip = {horizontal = true, vertical = true},
                },
            ) {
                for k in 0 ..< visible {
                    i := first + k
                    e := &ft.entries[i]
                    marked := filetree_yanked_contains(ft, e.path)
                    ringed := ring_contains(a, e.path)

                    // One background per element, where the old code laid two fills over
                    // each other: the selection bar covered the mark bar exactly, so the
                    // pixels are the same and the precedence is now stated rather than
                    // implied by draw order.
                    bg: clay.Color
                    if i == ft.selected {
                        bg = clay_rgb(th.separator)
                    } else if marked {
                        bg = clay_rgb(th.line_highlight)
                    } else if hover_shown(a) && i == ft.hover {
                        bg = clay_rgb(hover_bg(th)) // C5b's toggle; last, so it never masks a mark
                    }

                    if clay.UI(clay.ID("ft_row", u32(i)))(
                        {
                            layout = {
                                sizing = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                                padding = {left = u16(cw)},
                                childAlignment = {y = .Center},
                            },
                            backgroundColor = bg,
                        },
                    ) {
                        // Marked-for-yank takes the prefix slot (accent '+'); else the
                        // unsaved-ring star or a dash.
                        prefix := marked ? "+" : ringed ? "*" : "-"
                        pcol := marked ? th.accent : ringed ? th.urgent : th.muted

                        // A fixed TWO-cell column, not a gap: the prefix is one cell and the
                        // name starts on the next but one, which is the column the listing
                        // has always used. Sized in cells (a float, cell_w is exact) rather
                        // than as padding, which Clay takes as whole pixels.
                        if clay.UI(clay.ID("ft_pre", u32(i)))(
                            {layout = {sizing = {width = clay.SizingFixed(2 * cw)}}},
                        ) {
                            clay.Text(prefix, clay_text_config(pcol, lh))
                        }
                        clay.Text(e.display, clay_text_config(e.is_dir ? th.code_return_type : th.fg, lh))
                    }
                }
            }
        }
    }

    return clay.EndLayout(0)
}

// The filetree listing: a dired-style header (current dir) then rows, each prefixed '+'
// (marked for yank), '*' (in the unsaved ring) or '-' (neither). The selection is
// highlighted and the list tracks it under the shared `scroll_mode` policy; directories
// are tinted. Declared in Clay and painted by the bridge — see the header for why the
// three steps happen in this order.
draw_filetree :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    area, _, rows := filetree_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    hit := filetree_hit(&a.tree, rows)
    a.tree.hover = hit // resolved against the same (last) frame the click is
    filetree_click(a, hit)
    filetree_scroll_apply(&a.tree, rows, a.scroll_mode == .Middle, pane_input_at(a))

    cmds := filetree_layout(a, &t.font, pane, win_w, win_h)
    clay_paint(t, a, &cmds, area, win_w, win_h)
}
