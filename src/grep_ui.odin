package main

import "core:fmt"
import clay "../bindings/clay"

// The grep results pane's UI half — the first pane whose rows are not one-per-item.
// filetree_ui.odin is the template this follows: a geometry proc every phase sizes itself
// from, a scroll apply that runs before anything is declared, a hit test against the tree
// Clay is still holding, a click verb, a declaration. The frame order in grep_frame is the
// same and load-bearing for the same reason.
//
// What is NEW here is the indirection a real list needs: one hit is a BLOCK of several
// display rows (a "path:line" title, its context lines, a spacer), so
//
//   - the viewport counts DISPLAY ROWS, and the scroll policy frames the selected block's
//     title row (grep_anchor) the way the editor frames its caret line;
//   - a click resolves row -> `GrepRow.hit` -> block, so clicking any line of a block
//     selects that block, which is what the keyboard's Up/Down already mean;
//   - the flattening happens ONCE per frame and stays valid across the click, because
//     GrepRow carries no selection state (see grep.odin).

// Extra vertical padding per row, in logical pixels — a touch airier than the editor and
// the filetree (FT_ROW_PAD) so the stacked context blocks don't read as one packed wall of
// text.
GREP_ROW_PAD :: 5

// The pane's fixed geometry: content area inside the focus ring, row height, and how many
// display rows fit under the header. The twin of filetree_geom, and shared by every phase
// of the frame for the same reason — one call, so they cannot disagree.
grep_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(GREP_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int((area.h - row_h) / row_h)) // the query header takes the first row
    return
}

// Move the viewport to follow the selected BLOCK, under the shared `scroll_mode` policy.
// `anchor` and `total` are both in display rows (grep_anchor, len(rows)) — a block spans
// several, so tracking hits would leave a block's title scrolled off above its own context.
grep_scroll_apply :: proc(g: ^GrepPane, anchor, rows, total: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&g.scroll, &g.scroll_detached, anchor, rows, total, center, last_input_at)
}

// Which HIT the pointer is over, or -1. Walks display rows (what Clay was handed) and returns
// the block each belongs to; spacer rows carry hit == -1 and are skipped, so the gap between
// blocks is dead space. Resolves against the LAST frame's tree, hence `first` = g.scroll then.
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

// Apply a pending click on block `hit` (-1 = the pointer hit no block). Single click selects,
// double click jumps to the match — the mouse twin of Up/Down and Enter, both ending in the
// same `grep_open_selected`. Claimed only on a real hit; see mouse_take_click.
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
        grep_open_selected(a) // jump_to: opens the file and places the caret on the match
    }
}

// Declare the pane into the window's tree. Reads App and the flattened rows, writes
// only Clay — no mutation, no GL. `rows` is passed in rather than rebuilt so the frame
// flattens exactly once (see the header).
//
// The tree is:
//   gp_pane   the content area inside the focus ring, floating at the pane's own rect and
//             clipping its own content
//     gp_head   the query + hit count
//     gp_body   the clip group
//       gp_empty            the "(no matches)" placeholder, when there are no hits
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

    // No backgroundColor: panel() already filled the pane, so every fill below means something.
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

                // The selected block gets a faint band, its match line an accent rail at
                // the very left edge. The rail is a left BORDER because Clay draws borders
                // inside the element box but OUTSIDE its padding, the only way in there.
                bg: clay.Color
                if sel {
                    bg = clay_rgb(th.line_highlight)
                } else if hover_shown(a) && r.hit >= 0 && r.hit == g.hover {
                    // The whole block lights, not the row: that is what a click here
                    // selects, so it is what the pointer should promise.
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
                    // A spacer declares no children at all: it exists to take up a row of
                    // height, and grep_hit already refuses to resolve a click to it. Nesting
                    // rather than `continue` — clay.UI closes its element with a defer.
                    if r.hit >= 0 {
                        // Colour is derived, not stored: a block title is lit when its
                        // block is selected, a context line when it is the match.
                        lit := r.header ? sel : r.match
                        col := lit ? th.fg : th.muted
                        if r.header {
                            clay.Text(r.text, clay_text_config(col, lh)) // flush-left
                        } else {
                            if r.gutter != "" {
                                // A fixed gutw-cell column with its text pushed right,
                                // rather than an x-offset computed per row.
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

// The grep results pane (the FIND aux mode): a header naming the query + hit count, then each
// hit as a `grep -rn`-style CONTEXT BLOCK — a project-relative "path:line" title over the lines
// around the match, blocks parted by a blank row. Up/Down select, Enter jumps (grep_key).
grep_frame :: proc(t: ^Text, a: ^App, pane: Rect) {
    area, _, max_rows := grep_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    g := &a.grep
    // Flattened once, for the whole frame: the hit test, the scroll policy and the
    // declaration all read these same rows, and none of them depends on the selection,
    // which the click below may change out from under them.
    rows := grep_rows(g, a.project_root, context.temp_allocator)

    hit := grep_hit(rows, g.scroll, max_rows)
    g.hover = hit // resolved against the same (last) frame the click is
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
