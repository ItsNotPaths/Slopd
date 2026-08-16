package main

import clay "../bindings/clay"

// The key:value pane — the shape the Config and Binds panes share: a scrolled list of rows, each
// a key column and a value on one shared column, with rules and titles spanning from the margin.
//
// Each pane flattens to its OWN row type first, because the hit test and the click need what only
// it knows (a dropdown's choice, an error's line) and must carry no selection — a click changes
// that mid-frame. Once the selection has settled they convert to Pane_Row, which is the drawable
// view: derived colour, derived selectedness, and a live editor where one belongs.

// The geometry every phase of a pane's frame sizes itself from, so they cannot disagree.
list_geom :: proc(
    pane: Rect,
    scale, line_h, cell_w, pad: f32,
) -> (
    area: Rect,
    row_h: i32,
    rows, cols: int,
) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(pad * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 || cell_w <= 0 {
        return area, row_h, 0, 0
    }
    return area, row_h, max(1, int(area.h / row_h)), int(f32(area.w) / cell_w)
}

// A run of the value column with its own colour, for a value made of several small words —
// which is how the binds pane lights the one chord Left/Right has landed on.
Pane_Span :: struct {
    text:  string,
    color: [3]f32,
}

Pane_Row :: struct {
    text:   string,
    value:  string, // drawn at the shared value column, unless `spans` or `field` replaces it
    spans:  []Pane_Span, // several coloured runs instead of `value`, when one needs picking out
    item:   int, // the navigable row this selects, or -1 for chrome
    indent: i32,
    flush:  bool, // spans from the margin with no value column: a rule or a title
    sel:    bool,
    color:  [3]f32,
    vcolor: [3]f32, // the value's, which a lit row does not always share
    field:  ^Doc, // a live one-line editor in place of `value`
    caret:  bool,
}

// Clay keys on the string, so a pane's element ids are written down rather than built per frame.
Pane_Ids :: struct {
    pane, body, row, key, edit: string,
}

CONFIG_IDS :: Pane_Ids{"cf_pane", "cf_body", "cf_row", "cf_key", "cf_edit"}
BINDS_IDS :: Pane_Ids{"bk_pane", "bk_body", "bk_row", "bk_key", "bk_edit"}

// What a pane hands the shared declaration besides its rows.
Pane_Draw :: struct {
    ids:      Pane_Ids,
    area:     Rect,
    row_h:    i32,
    max_rows: int,
    val_off:  f32, // the key column, in cells
    scroll:   int,
    hover:    int, // display row under the pointer, or -1
    now:      f64,
}

// The display row under the pointer, or -1. Chrome is dead space. Resolves against the tree the
// LAST frame declared, so it runs before anything this frame is built.
pane_hit :: proc(ids: Pane_Ids, rows: []Pane_Row, first, max_rows: int) -> int {
    lo := clamp(first, 0, max(0, len(rows)))
    n := max(0, min(len(rows) - lo, max_rows))
    for k in 0 ..< n {
        i := lo + k
        if rows[i].item >= 0 && clay.PointerOver(clay.ID(ids.row, u32(i))) {
            return i
        }
    }
    return -1
}

// The display row the scroll policy frames: the lit one.
pane_anchor :: proc(rows: []Pane_Row) -> int {
    for r, i in rows {
        if r.sel {
            return i
        }
    }
    return 0
}

//   <p>_pane   the content area, floating at the pane's rect and clipping its own content
//     <p>_body   the clip group
//       <p>_row/i    one per visible DISPLAY row, keyed by row index
//         <p>_key/i    the fixed key column, so every value starts on the same cell
//         <p>_edit/i   a text field's Custom, where the row carries one
//
// No backgroundColor on the pane: panel() already filled it, so every fill here means something.
pane_declare :: proc(a: ^App, f: ^Font, d: Pane_Draw, rows: []Pane_Row) {
    th := &a.theme
    cw := f.cell_w
    lh := i32(f.line_height)
    first := clamp(d.scroll, 0, max(0, len(rows)))
    visible := max(0, min(len(rows) - first, d.max_rows))

    if clay.UI(clay.ID(d.ids.pane))(clay_pane_box(d.area)) {
        if clay.UI(clay.ID(d.ids.body))(
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

                // The selection bar, and under the pointer a fainter one. Hover never competes
                // with the selection: the lit row keeps its own bar.
                bg: clay.Color
                if r.sel {
                    bg = clay_rgb(th.separator)
                } else if hover_shown(a) && i == d.hover && r.item >= 0 {
                    bg = clay_rgb(hover_bg(th))
                }

                // The one-cell margin plus the row's own indent, in whole cells. cell_w is
                // rounded at bake time, so this is exact in u16 pixels.
                if clay.UI(clay.ID(d.ids.row, u32(i)))(
                    {
                        layout = {
                            sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(d.row_h))},
                            padding        = {left = u16(cw * f32(1 + r.indent))},
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = bg,
                    },
                ) {
                    if r.flush {
                        clay.Text(r.text, clay_text_config(r.color, lh))
                        continue
                    }
                    if clay.UI(clay.ID(d.ids.key, u32(i)))(
                        {layout = {sizing = {width = clay.SizingFixed(d.val_off * cw)}}},
                    ) {
                        clay.Text(r.text, clay_text_config(r.color, lh))
                    }
                    // A Custom, because carets are over-quads (field_ui.odin).
                    switch {
                    case r.field != nil:
                        field_declare(
                            clay.ID(d.ids.edit, u32(i)),
                            {doc = r.field, now = d.now, caret = r.caret},
                        )
                    case len(r.spans) > 0:
                        for s in r.spans {
                            clay.Text(s.text, clay_text_config(s.color, lh))
                        }
                    case r.value != "":
                        clay.Text(r.value, clay_text_config(r.vcolor, lh))
                    }
                }
            }
        }
    }
}
