package main

import clay "../bindings/clay"

// The filetree pane's UI half, and the template the other list panes follow. filetree.odin is
// the host-independent listing; this is the part that knows about Slopd — the theme, the
// unsaved ring, the pointer, the pane rect. The geometry exists once, as a declared tree Clay
// resolves into boxes that paint AND answer what is under the pointer.
//
// The frame order in filetree_frame is load-bearing:
//   1. Resolve the pending click first, against the boxes Clay holds from the LAST frame —
//      the pointer is over the pane that was painted.
//   2. Then move the viewport, so a click that changed the selection scrolls in the same frame.
//   3. Then declare, so the frame paints the post-click state.

// Logical pixels; the twin of GREP_ROW_PAD. Rows are whole pixels tall so the list stays on
// the cell grid — Clay solves in floats.
FT_ROW_PAD :: 2

// The content area inside the focus ring, the row height, and how many rows fit under the
// header. Shared by every phase of the frame. `rows` is at least 1 even in a too-short pane.
filetree_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(FT_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int((area.h - row_h) / row_h)) // the header takes the first row
    return
}

// The shared `scroll_mode` policy (list_scroll_target). GL-free and called before anything is
// declared, so a headless test can exercise it.
filetree_scroll_apply :: proc(ft: ^FileTree, rows: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&ft.scroll, &ft.scroll_detached, ft.selected, rows, len(ft.entries), center, last_input_at)
}

// -1 when over none. Clay answers from the tree the LAST frame declared, so probe the painted
// window — `top`, the animated position, not the target, which mid-scroll can be a screenful
// away. A stale id reports false, so a resize costs a missed click, never a wrong row.
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

// -1 means the pointer hit no row. Single selects, double activates — the twin of Up/Down and
// Enter. Claimed only on a real hit; focus is not taken here (window_ui.odin).
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
    // Enter, through the same proc. Descending reloads the listing, so the row index just set
    // no longer refers to anything.
    filetree_activate_selected(a)
}

// Select what is under it, then open the file-ops menu. The same menu the browser opens, minus
// the places item, since there is no sidebar here.
filetree_rclick :: proc(a: ^App, row: int) {
    if !rect_hit(a.lay.aux, a.mouse.rclick_x, a.mouse.rclick_y) {
        return
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

// Declare the pane into the window's tree. Reads App, writes only Clay — no mutation, no GL —
// so tests can assert the resolved boxes without a window.
//
//   ft_pane   the content area inside the focus ring, floating and clipping its own content
//     ft_head  the dired-style header: the current directory, muted
//     ft_body  the clip group — rows past the bottom edge are cut here
//       ft_row/i   one per visible entry, keyed by ENTRY index so a hit names an entry
//         ft_pre/i   the two-cell prefix column, so names start on a fixed cell
//     ch_bar   the Ctrl-held chord cheat-sheet, a floating child so it inherits the pane's
//              clip and covers the rows rather than being laid out under them
filetree_declare :: proc(a: ^App, f: ^Font, pane: Rect, top: int, off: i32, now: f64 = 0) {
    ft := &a.tree
    th := &a.theme
    area, row_h, _ := filetree_geom(pane, a.scale, f.line_height)
    cw := f.cell_w
    lh := i32(f.line_height)

    // No backgroundColor: panel() filled the pane, so the fills that appear mean something.
    if clay.UI(clay.ID("ft_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("ft_head"))(
            {
                layout = {
                    sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                    padding        = {left = u16(cw)}, // the one-cell left margin
                    childAlignment = {y = .Center},
                },
            },
        ) {
            // The pane's one line of chrome, so the workspace prompt takes it.
            if wsfind_shown(a) {
                wsfind_declare_bar(a, lh, now)
            } else {
                clay.Text(ft.dir, clay_text_config(th.muted, lh))
            }
        }

        // One or the other: the prompt covers the listing rather than sitting beside it.
        body := filetree_body_rect(area, row_h)
        if wsfind_shown(a) {
            wsfind_declare_body(a, body, row_h, lh, cw, now)
        } else {
            filetree_declare_rows(a, body, top, off, row_h, lh, cw)
        }

        // Last and inside the pane: `attachTo = .Parent` takes ft_pane off the open clip
        // stack, so the bar gets its own scissor group and its backdrop covers the names.
        if chord_shown(a) {
            chord_declare(a, f, area, now)
        }
    }
}

// What the rows scroll inside, whosever rows they are.
filetree_body_rect :: proc(area: Rect, row_h: i32) -> Rect {
    return Rect{area.x, area.y + row_h, area.w, max(0, area.h - row_h)}
}

// The window is the tween's top and the remainder is the clip's childOffset, never a term in
// each row's y — that would put the rows off the cell grid. The count is the rows the body
// TOUCHES, so the partial row at the bottom edge is declared.
@(private = "file")
filetree_declare_rows :: proc(a: ^App, body: Rect, top: int, off, row_h, lh: i32, cw: f32) {
    ft := &a.tree
    th := &a.theme
    first := clamp(top, 0, max(0, len(ft.entries)))
    visible := max(0, min(len(ft.entries) - first, list_visible_rows(body.h, off, row_h)))

    if clay.UI(clay.ID("ft_body"))(
        {
            layout = {
                // Fixed, not Grow: `SizingGrow` means "at least fit your content", so the row
                // scrolling into view would stretch the clip group past the pane.
                sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(body.h))},
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

            // One background per element, so precedence is stated, not implied by draw order.
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
                prefix := marked ? "+" : ringed ? "*" : "-"
                pcol := marked ? th.accent : ringed ? th.urgent : th.muted

                // A fixed two-cell column, not a gap, sized in cells rather than padding,
                // which Clay takes as whole pixels.
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

// The pane alone in a window, as a command list. The app never calls it; the tests do, because
// a pane's boxes are the same whether or not another is declared beside it.
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

// A dired-style header then rows, each prefixed '+' (marked), '*' (in the unsaved ring) or '-'.
// The phases and their order ARE the pane template.
filetree_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    area, row_h, rows := filetree_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    wsfind_sync(a)
    top, off := a.tree.scroll, i32(0) // the listing's window; the prompt's is its own

    if wsfind_shown(a) {
        // The prompt takes the whole pane's input: offering the press to the listing would act
        // on rows the last frame stopped declaring.
        a.tree.hover = -1
        // The header's box past its one-cell margin, where the prompt was declared.
        head := Rect{area.x + i32(cw), area.y, max(0, area.w - i32(cw)), row_h}
        body := filetree_body_rect(area, row_h)
        wsfind_frame(a, wsfind_field_rect(head, cw), body, row_h, cw, now)
    } else {
        // The pointer is over what the LAST frame painted, so the click resolves against the
        // animated top rather than the target — hence the view being read twice.
        top0, off0 := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, row_h)
        hit := filetree_hit(&a.tree, top0, list_visible_rows(area.h - row_h, off0, row_h))
        a.tree.hover = hit // against the same (last) frame the click is
        filetree_click(a, hit)
        filetree_rclick(a, hit)
        filetree_scroll_apply(&a.tree, rows, a.scroll_mode == .Middle, pane_input_at(a))

        // Re-read over the moved target, so a click that scrolled starts easing in its own
        // frame.
        top, off = smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, row_h)
    }
    filetree_declare(a, &t.font, pane, top, off, now)
}
