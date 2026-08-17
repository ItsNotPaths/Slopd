package main

import "core:fmt"
import clay "../bindings/clay"

// The grep results pane's UI half — the first pane whose rows are not one-per-item. It follows
// filetree_ui.odin's template, with one hit being a BLOCK of several display rows (a
// "path:line" title, its context lines, a spacer), so:
//   - the viewport counts DISPLAY ROWS, and the policy frames the selected block's title row;
//   - a click resolves row -> `GrepRow.hit` -> block, so clicking any line selects the block;
//   - the flattening happens once per frame and survives the click, since GrepRow carries no
//     selection state.

// Logical pixels, airier than FT_ROW_PAD so the stacked context blocks do not read as a wall.
GREP_ROW_PAD :: 5

// filetree_geom's twin: content area, row height, and display rows under the header.
grep_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(GREP_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int((area.h - row_h) / row_h)) // the query header takes the first row
    return
}

// `anchor` and `total` are in display rows: a block spans several, so tracking hits would leave
// a title scrolled off above its own context.
grep_scroll_apply :: proc(g: ^GrepPane, anchor, rows, total: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&g.scroll, &g.scroll_detached, anchor, rows, total, center, last_input_at)
}

// Walks display rows and returns the block each belongs to; a spacer carries hit == -1, so the
// gap between blocks is dead space. Resolves against the LAST frame's tree.
grep_hit :: proc(rows: []GrepRow, first, max_rows: int) -> int {
    lo := clamp(first, 0, max(0, len(rows)))
    n := max(0, min(len(rows) - lo, max_rows))
    for k in 0 ..< n {
        i := lo + k
        if rows[i].hit >= 0 && clay.PointerOver(clay.ID("gp_row", u32(i))) {
            return rows[i].hit
        }
    }
    return -1
}

// -1 means the pointer hit no block. Single selects, double jumps — Up/Down and Enter's twin,
// both ending in grep_open_selected. Claimed only on a real hit.
grep_click :: proc(a: ^App, hit: int) {
    if hit < 0 {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    g := &a.grep
    if hit >= len(g.hits) {
        return
    }
    g.selected = hit
    if count >= 2 {
        grep_open_selected(a) // opens the file and puts the caret on the match
    }
}

// Reads App and the flattened rows, writes only Clay. `rows` is passed in rather than rebuilt,
// so the frame flattens exactly once.
//
//   gp_pane   the content area inside the focus ring, floating and clipping its own content
//     gp_head   the query and hit count
//     gp_body   the clip group
//       gp_empty            the "(no matches)" placeholder
//       gp_row/i            one per visible DISPLAY row, keyed by row index
//         gp_gut/i            the right-aligned line-number gutter (context rows only)
grep_declare :: proc(a: ^App, f: ^Font, pane: Rect, rows: []GrepRow) {
    g := &a.grep
    th := &a.theme
    area, row_h, max_rows := grep_geom(pane, a.scale, f.line_height)
    cw := f.cell_w
    lh := i32(f.line_height)
    rail := u16(2 * a.scale)
    gutw := grep_gutter_w(rows)

    first := clamp(g.scroll, 0, max(0, len(rows)))
    visible := max(0, min(len(rows) - first, max_rows))

    // No backgroundColor: panel() filled the pane, so every fill below means something.
    if clay.UI(clay.ID("gp_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("gp_head"))(
            {
                layout = {
                    sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                    padding        = {left = u16(cw)}, // the one-cell left margin
                    childAlignment = {y = .Center},
                },
            },
        ) {
            head := g.query == "" ? "grep" : fmt.tprintf("grep: %s   (%d)", g.query, len(g.hits))
            clay.Text(head, clay_text_config(focus_fg(a, .Aux), lh))
        }

        if clay.UI(clay.ID("gp_body"))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingGrow()},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true},
            },
        ) {
            if len(g.hits) == 0 {
                if clay.UI(clay.ID("gp_empty"))(
                    {
                        layout = {
                            sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                            padding        = {left = u16(2 * cw)}, // indented past the header
                            childAlignment = {y = .Center},
                        },
                    },
                ) {
                    clay.Text("(no matches)", clay_text_config(th.muted, lh))
                }
            }

            for k in 0 ..< visible {
                i := first + k
                r := rows[i]
                sel := r.hit >= 0 && r.hit == g.selected

                // A faint band on the selected block, an accent rail on its match line. The
                // rail is a left BORDER because Clay draws those inside the box but outside
                // its padding.
                bg: clay.Color
                if sel {
                    bg = clay_rgb(th.line_highlight)
                } else if hover_shown(a) && r.hit >= 0 && r.hit == g.hover {
                    // The whole block lights, not the row: that is what a click selects.
                    bg = clay_rgb(hover_bg(th))
                }
                border: clay.BorderElementConfig
                if sel && r.match {
                    border = {color = clay_rgb(th.accent), width = {left = rail}}
                }

                if clay.UI(clay.ID("gp_row", u32(i)))(
                    {
                        layout = {
                            sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                            padding        = {left = u16(cw)},
                            childGap       = u16(cw), // gutter, one cell, then the line
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = bg,
                        border          = border,
                    },
                ) {
                    // A spacer declares no children: it exists to take a row of height, and
                    // grep_hit refuses to resolve a click to it. Nested rather than
                    // `continue`, since clay.UI closes its element with a defer.
                    if r.hit >= 0 {
                        // Derived, not stored: a title is lit when its block is selected, a
                        // context line when it is the match.
                        lit := r.header ? sel : r.match
                        col := lit ? th.fg : th.muted
                        if r.header {
                            clay.Text(r.text, clay_text_config(col, lh)) // flush-left
                        } else {
                            if r.gutter != "" {
                                // A fixed column with its text pushed right, rather than an
                                // x-offset computed per row.
                                if clay.UI(clay.ID("gp_gut", u32(i)))(
                                    {
                                        layout = {
                                            sizing         = {width = clay.SizingFixed(f32(gutw) * cw)},
                                            childAlignment = {x = .Right},
                                        },
                                    },
                                ) {
                                    clay.Text(r.gutter, clay_text_config(th.muted, lh))
                                }
                            }
                            clay.Text(r.text, clay_text_config(col, lh))
                        }
                    }
                }
            }
        }
    }
}

// A header naming the query and hit count, then each hit as a context block: a
// project-relative "path:line" title over the lines around the match, blocks parted by a
// blank row.
grep_frame :: proc(t: ^Text, a: ^App, pane: Rect) {
    area, _, max_rows := grep_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    g := &a.grep
    // Once for the whole frame: the hit test, the scroll policy and the declaration read these
    // same rows, and none depends on the selection the click below may change.
    rows := grep_rows(g, a.project_root, context.temp_allocator)

    hit := grep_hit(rows, g.scroll, max_rows)
    g.hover = hit // against the same (last) frame the click is
    grep_click(a, hit)
    grep_scroll_apply(g, grep_anchor(rows, g.selected), max_rows, len(rows), a.scroll_mode == .Middle, pane_input_at(a))

    grep_declare(a, &t.font, pane, rows)
}

// Test-facing wrapper; see filetree_layout.
grep_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    rows: []GrepRow,
    win_w, win_h: i32,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        grep_declare(a, f, pane, rows)
    }
    return clay.EndLayout(0)
}
