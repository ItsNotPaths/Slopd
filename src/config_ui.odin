package main

import clay "../bindings/clay"

// The config / syntax pane's UI half — rows that are neither one-per-item nor uniformly
// clickable. filetree_ui.odin is the template and grep_ui.odin the row -> item indirection; the
// frame order in config_frame is the same, and load-bearing for the same reason. Three things
// are new here:
//   1. Chrome rows. Section rules and titles have no navigable item (`item == -1`) and the hit
//      test refuses them — dead space, as grep's spacers are.
//   2. Two coordinates per row. A click resolves to a row AND, inside an open dropdown, to a
//      choice, so config_hit returns the DISPLAY row index and config_click reads item/opt off it.
//   3. Text fields. The shared one-line `Field` (field_ui.odin), which the file browser's path
//      line is the other instance of. A setting is a field only while HIGHLIGHTED, decided in
//      config_declare rather than in the flattening (see ConfigRow).
//
// **The dropdown is NOT an overlay.** Its options are spliced INTO the row list as indented rows,
// so nothing needs `floating`, a second clip group, or an overlay-first hit test.

// Extra vertical padding per row, in logical pixels. Tighter than the filetree's (FT_ROW_PAD):
// this pane is a dense form rather than a list you scan.
CONFIG_ROW_PAD :: 2

// The pane's fixed geometry: content area inside the focus ring, row height, how many display rows
// fit, and the content width in whole cells. Pure, and shared by every phase of the frame so they
// cannot disagree. No row is reserved for a header — the first row is already a section rule.
config_geom :: proc(
    pane: Rect,
    scale, line_h, cell_w: f32,
) -> (
    area: Rect,
    row_h: i32,
    rows: int,
    cols: int,
) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(CONFIG_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 || cell_w <= 0 {
        return area, row_h, 0, 0
    }
    return area, row_h, max(1, int(area.h / row_h)), int(f32(area.w) / cell_w)
}

// How many cells the key column spans: the widest setting key plus ": ". Every value and inline
// editor starts here, so the value column runs straight down the pane whatever the key length.
config_val_off :: proc() -> f32 {
    keycol := 0
    for si in 0 ..< SETTING_COUNT {
        keycol = max(keycol, len(setting_key(Setting(si))))
    }
    return f32(keycol + 2)
}

// Move the viewport to follow the selected row under the shared `scroll_mode` policy. `anchor` and
// `total` are DISPLAY rows: an open dropdown splices options in, so the row space shifts under the
// stored top and Follow simply re-frames next frame. GL-free, and never a side effect of painting.
config_scroll_apply :: proc(cp: ^ConfigPane, anchor, rows, total: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&cp.scroll, &cp.scroll_detached, anchor, rows, total, center, last_input_at)
}

// Which DISPLAY row the pointer is over, or -1 — a row index, not an item, since an option row
// needs the choice too. Chrome rows (item == -1) are dead space. **Resolves against the tree the
// LAST frame declared**, so it runs first and `first` is cp.scroll as those rows were painted.
config_hit :: proc(rows: []ConfigRow, first, max_rows: int) -> int {
    lo := clamp(first, 0, max(0, len(rows)))
    n := max(0, min(len(rows) - lo, max_rows))
    for k in 0 ..< n {
        i := lo + k
        if rows[i].item >= 0 && clay.PointerOver(clay.ID("cf_row", u32(i))) {
            return i
        }
    }
    return -1
}

// Apply a pending click on display row `row` (-1 = hit nothing), claimed only on a real hit. A nav
// row selects on one click and opens its dropdown on two; an OPTION row chooses on one, being
// already the second half of a gesture, and its double click is swallowed rather than run twice.
config_click :: proc(a: ^App, rows: []ConfigRow, row: int) {
    if row < 0 || row >= len(rows) {
        return
    }
    r := rows[row]
    if r.item < 0 {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    cp := &a.config_pane

    if r.kind == .Option {
        if count >= 2 {
            return // the choice already fired on the first press
        }
        cp.opt_sel = r.opt
        config_choose(a)
        return
    }

    if cp.sel != r.item {
        cp.open = .None // a dropdown belongs to the row it was opened on
    }
    cp.sel = clamp(r.item, 0, max(0, config_pane_rows(cp) - 1))
    if count < 2 {
        return
    }
    #partial switch r.kind {
    case .Setting:
        if s, sok := config_pane_setting(cp.sel); sok {
            config_pane_open_setting(a, s)
        }
    case .Lang:
        if cp.open == .Lang && cp.opt_sel == -1 {
            cp.open = .None // re-Enter on an open root minimises, as the keyboard does
        } else {
            config_pane_open_lang(a)
        }
    case .Search, .Text:
    // Neither text row has a double-click verb: selecting one already makes it the editor.
    // The filter is live as you type; a setting commits on Enter or on leaving the row.
    }
}

// A row's text colour, derived rather than stored — the flattening carries no palette, for the
// same reason it carries no selection (see ConfigRow). Language rows are tinted by INSTALL STATE
// rather than selectedness: the ✓/✗ mark and the colour say the same thing twice, on purpose.
config_row_color :: proc(th: ^Theme, r: ConfigRow, sel: bool) -> [3]f32 {
    switch r.kind {
    case .Rule:
        return th.border_light
    case .Header:
        return th.accent
    case .Lang:
        return r.present ? th.code_return_type : th.fg
    case .Setting, .Text, .Search, .Option:
        return sel ? th.fg : th.muted
    }
    return th.fg
}

// Declare the pane into the window's tree: reads App and the flattened rows, writes only Clay.
// `rows` is passed in rather than rebuilt so the hit test, the click and this cannot disagree.
//   cf_pane   the content area inside the focus ring, floating at the pane's own rect and
//             clipping its own content
//     cf_body   the clip group
//       cf_row/i    one per visible DISPLAY row, keyed by row index
//         cf_key/i    the fixed key column, so every value starts on the same cell
//         cf_edit/i   a text field's Custom (the search row; a highlighted text setting)
config_declare :: proc(a: ^App, f: ^Font, pane: Rect, rows: []ConfigRow, now: f64 = 0) {
    cp := &a.config_pane
    th := &a.theme
    area, row_h, max_rows, _ := config_geom(pane, a.scale, f.line_height, f.cell_w)
    cw := f.cell_w
    lh := i32(f.line_height)
    val_off := config_val_off()

    first := clamp(cp.scroll, 0, max(0, len(rows)))
    visible := max(0, min(len(rows) - first, max_rows))

    // No backgroundColor: panel() already filled the pane, so every fill below means something.
    if clay.UI(clay.ID("cf_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("cf_body"))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingGrow()},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true},
            },
        ) {
            for k in 0 ..< visible {
                i := first + k
                r := rows[i]
                sel := config_row_selected(cp, r)
                col := config_row_color(th, r, sel)
                flush := r.kind == .Rule || r.kind == .Header

                // The selection bar, and under the pointer a fainter one. Hover never
                // competes with the selection: the selected row keeps its own bar.
                bg: clay.Color
                if sel {
                    bg = clay_rgb(th.separator)
                } else if hover_shown(a) && i == cp.hover && r.item >= 0 {
                    bg = clay_rgb(hover_bg(th))
                }

                // The one-cell left margin plus the row's own indent, as whole cells.
                // cell_w is rounded at bake time, so this is exact in u16 pixels.
                if clay.UI(clay.ID("cf_row", u32(i)))(
                    {
                        layout = {
                            sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                            padding        = {left = u16(cw * f32(1 + r.indent))},
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = bg,
                    },
                ) {
                    if flush {
                        // A rule or a section title spans from the margin with no value
                        // column, which is what made these "flush" rows in draw_config.
                        clay.Text(r.text, clay_text_config(col, lh))
                    } else {
                        if clay.UI(clay.ID("cf_key", u32(i)))(
                            {layout = {sizing = {width = clay.SizingFixed(val_off * cw)}}},
                        ) {
                            clay.Text(r.text, clay_text_config(col, lh))
                        }
                        // A live text field: the shared one-line Field (field_ui.odin), which is
                        // a Custom because carets are over-quads (see the header). A free-text
                        // setting is one only while highlighted, decided HERE where selectedness
                        // is derived rather than in the flattening.
                        if r.kind == .Search || (r.kind == .Text && sel) {
                            d := r.kind == .Search ? &cp.search : &cp.edit
                            field_declare(
                                clay.ID("cf_edit", u32(i)),
                                {doc = d, now = now, caret = sel && config_caret_live(a)},
                            )
                        } else if r.value != "" {
                            clay.Text(r.value, clay_text_config(th.fg, lh))
                        }
                    }
                }
            }
        }
    }
}

// The config / syntax pane: a "settings" block of key: value rows (dropdowns, bar the free-text
// one) then a "syntax" block listing each language's grammar status (✓/✗) with its install-options
// dropdown nested under an opened row. The search row filters that list live as you type.
config_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    area, _, max_rows, cols := config_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cp := &a.config_pane
    // One flattening serves the hit test AND the click, since no row carries selection state.
    // This pane needs a SECOND one grep does not: choosing an option splices rows out and can
    // rewrite a value, so the list the click acted on is not the one this frame should paint.
    rows := config_rows(cp, a, cols, context.temp_allocator)

    hit := config_hit(rows, cp.scroll, max_rows)
    // Written before the click for the same reason it is hit-tested there: both resolve against
    // the tree Clay still holds. A click that reshapes the list leaves this a row or two off for
    // exactly one frame, which the next frame's hit test corrects.
    cp.hover = hit
    config_click(a, rows, hit)
    // A click is the one thing that can move the selection off a text row without the keyboard,
    // so the reconcile sits between the click and the re-flatten: the row left commits, the row
    // entered seeds, and the rows this frame paints already show the result.
    config_edit_sync(a)

    rows = config_rows(cp, a, cols, context.temp_allocator)
    config_scroll_apply(cp, config_anchor(cp, rows), max_rows, len(rows), a.scroll_mode == .Middle, pane_input_at(a))

    config_declare(a, &t.font, pane, rows, now)
}

// Test-facing wrapper; see filetree_layout.
config_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    rows: []ConfigRow,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        config_declare(a, f, pane, rows, now)
    }
    return clay.EndLayout(0)
}
