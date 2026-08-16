package main

import clay "../bindings/clay"

// The workspace prompt's UI half — ONE bar and ONE list, called by both faces of the file pane.
// The two faces differ only in the box they hand it: the `ls` header row, or the browser's path
// region and the content area right of its sidebar. Everything a row means (what is selected,
// what is unsaved, what a press does) is decided here, once, so the two cannot drift.
//
//   <caller's bar>
//     ws_lbl     "WORKSPACE/", in the accent — the prompt, and the only thing saying you are
//                in one, since the pane under it is unchanged
//     ws_edit    the typed line: the shared one-line Field (field_ui.odin), the path bar's twin
//   ws_body      the clip group the rows scroll inside
//     ws_row/i     one per visible row, keyed by ROW index so a hit names a row
//       ws_pre/i     the two-cell prefix column: '*' for the unsaved ring, else '-'
//     ws_none    instead of the rows when there are none: one muted line saying which nothing
//                this is — an empty ring, or a filter that matched nothing

// The prompt's contents, declared into the box the caller has already opened. Reads App, writes
// only Clay.
wsfind_declare_bar :: proc(a: ^App, lh: i32, now: f64) {
    th := &a.theme
    ws := &a.wsfind
    if clay.UI(clay.ID("ws_lbl"))({layout = {childAlignment = {y = .Center}}}) {
        clay.Text(WS_PROMPT, clay_text_config(th.accent, lh))
    }
    field_declare(
        clay.ID("ws_edit"),
        {doc = &ws.query, off = ws.off, now = now, caret = wsfind_live(a)},
    )
}

// The rows, in a clip group `r` tall. Owns its own viewport tween: the listing underneath keeps
// `tree.scroll` where the user left it, and the two lists scroll independently by construction.
wsfind_declare_body :: proc(a: ^App, r: Rect, row_h, lh: i32, cw: f32, now: f64) {
    ws := &a.wsfind
    th := &a.theme
    top, off := smooth_scroll(&ws.scroll_anim, ws.scroll, now, row_h)
    first := clamp(top, 0, max(0, len(ws.rows)))
    visible := max(0, min(len(ws.rows) - first, list_visible_rows(r.h, off, row_h)))

    if clay.UI(clay.ID("ws_body"))(
        {
            layout = {
                // Fixed, not Grow, as every list pane's clip group is: the row easing into view
                // must not stretch the group it is inside (rule 8).
                sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(max(0, r.h)))},
                layoutDirection = .TopToBottom,
            },
            clip = {horizontal = true, vertical = true, childOffset = {0, -f32(off)}},
        },
    ) {
        if len(ws.rows) == 0 {
            empty := wsfind_typed(ws) ? "no match" : "no unsaved buffers"
            if clay.UI(clay.ID("ws_none"))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                        padding        = {left = u16(cw)},
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                clay.Text(empty, clay_text_config(th.muted, lh))
            }
            return
        }
        for k in 0 ..< visible {
            i := first + k
            row := ws.rows[i]
            bg: clay.Color
            if i == ws.selected {
                bg = clay_rgb(th.separator)
            } else if hover_shown(a) && i == ws.hover {
                bg = clay_rgb(hover_bg(th))
            }
            if clay.UI(clay.ID("ws_row", u32(i)))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                        padding        = {left = u16(cw)},
                        childAlignment = {y = .Center},
                    },
                    backgroundColor = bg,
                },
            ) {
                // The listing's two-cell prefix column, with its two marks: the unsaved star,
                // or a dash for a row that is only a file.
                col := row.dirty ? th.urgent : th.muted
                if clay.UI(clay.ID("ws_pre", u32(i)))(
                    {layout = {sizing = {width = clay.SizingFixed(2 * cw)}}},
                ) {
                    clay.Text(row.dirty ? "*" : "-", clay_text_config(col, lh))
                }
                name := clay_text_config(row.dirty ? th.urgent : th.fg, lh)
                clay.Text(wsfind_rel(ws.root, row.path), name)
            }
        }
    }
}

// Where the typed line was declared, given the bar's CONTENT box (the caller's, since the two
// faces pad their bars differently) — the box the press, the drag and the window resolve
// against. The label takes the first cells; the line takes the rest.
wsfind_field_rect :: proc(inner: Rect, cw: f32) -> Rect {
    w := i32(f32(len(WS_PROMPT)) * cw)
    return Rect{inner.x + w, inner.y, max(0, inner.w - w), inner.h}
}

wsfind_field_box :: proc(a: ^App, field: Rect, cw: f32) -> Field_Box {
    ws := &a.wsfind
    return {doc = &ws.query, target = FIELD_WSFIND, r = field, off = ws.off, cw = cw}
}

// Which row the pointer is over, or -1 — over the window that was PAINTED (`top`, the animated
// position) rather than the target, for filetree_hit's reason.
wsfind_hit :: proc(ws: ^WS_Find, top, visible: int) -> int {
    first := clamp(top, 0, max(0, len(ws.rows)))
    n := max(0, min(len(ws.rows) - first, visible))
    for k in 0 ..< n {
        i := first + k
        if clay.PointerOver(clay.ID("ws_row", u32(i))) {
            return i
        }
    }
    return -1
}

// A press: a row selects on one and opens on two (the listing's rule, so a prompt is not a
// second kind of list), and a press on the typed line is the field's own.
@(private = "file")
wsfind_click :: proc(a: ^App, row: int, field: Rect, cw: f32) {
    if row < 0 {
        if clay.PointerOver(clay.ID("ws_edit")) {
            if count, ok := mouse_take_click(a); ok {
                field_press(a, wsfind_field_box(a, field, cw), count)
            }
        }
        return
    }
    count, ok := mouse_take_click(a)
    if !ok || len(a.wsfind.rows) == 0 {
        return
    }
    a.wsfind.selected = clamp(row, 0, len(a.wsfind.rows) - 1)
    if count >= 2 {
        wsfind_activate(a)
    }
}

// The prompt's frame phases, in the pane template's order — the whole of what the face hosting
// it has to do, since with the prompt up the listing behind it takes no input at all. `field` is
// the typed line's box and `body` the region the rows are in.
wsfind_frame :: proc(a: ^App, field, body: Rect, row_h: i32, cw: f32, now: f64) {
    ws := &a.wsfind
    if row_h <= 0 {
        return
    }
    top, off := smooth_scroll(&ws.scroll_anim, ws.scroll, now, row_h)
    hit := wsfind_hit(ws, top, list_visible_rows(body.h, off, row_h))
    ws.hover = hit
    wsfind_click(a, hit, field, cw)
    list_scroll_apply(
        &ws.scroll,
        &ws.scroll_detached,
        ws.selected,
        int(body.h / row_h),
        len(ws.rows),
        a.scroll_mode == .Middle,
        pane_input_at(a),
    )

    // The line's drag and its window, as the path bar runs them: the gesture that walks the
    // caret off the end must move the window in the frame that moved it.
    field_drag(a, wsfind_field_box(a, field, cw), now)
    if len(ws.query.lines) > 0 {
        n := line_len(&ws.query.lines[0])
        cur := ws.query.cursors[ws.query.primary].head.col
        ws.off = field_scroll(ws.off, n, cur, field_cells(field, cw))
    }
}
