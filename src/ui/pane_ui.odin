package ui

import clay "../../bindings/clay"
import "../txt"
import "../gfx"

// The shape the Config and Binds panes share: a scrolled list of rows, each a key column and a
// value on one shared column, with rules and titles spanning from the margin.
//
// Each pane flattens to its OWN row type first, because the hit test and the click need what
// only it knows and must carry no selection, which a click changes mid-frame. Once the selection
// has settled they convert to Pane_Row, the drawable view.

// What every phase of a pane's frame sizes itself from.
list_geom :: proc(
    pane: gfx.Rect,
    line_h, cell_w: f32,
) -> (
    area: gfx.Rect,
    row_h: i32,
    rows, cols: int,
) {
    area = gfx.grid_snap(inset(pane, gfx.edge(line_h)), cell_w, line_h)
    row_h = gfx.row(line_h)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 || cell_w <= 0 {
        return area, row_h, 0, 0
    }
    return area, row_h, max(1, int(area.h / row_h)), int(f32(area.w) / cell_w)
}

// A run of the value column with its own colour: how the binds pane lights the one chord
// Left/Right landed on.
Pane_Span :: struct {
    text:  string,
    color: [3]f32,
}

Pane_Row :: struct {
    text:   string,
    value:  string, // at the shared value column, unless `spans` or `field` replaces it
    spans:  []Pane_Span, // coloured runs instead of `value`, when one needs picking out
    item:   int, // the navigable row this selects, or -1 for chrome
    indent: i32,
    flush:  bool, // from the margin, with no value column: a rule or a title
    sel:    bool,
    color:  [3]f32,
    vcolor: [3]f32, // the value's, which a lit row does not always share
    field:  ^txt.Doc, // a live one-line editor in place of `value`
    caret:  bool,
}

// Clay keys on the string, so element ids are written down rather than built per frame.
Pane_Ids :: struct {
    pane, body, row, key, edit: string,
}

CONFIG_IDS :: Pane_Ids{"cf_pane", "cf_body", "cf_row", "cf_key", "cf_edit"}
BINDS_IDS :: Pane_Ids{"bk_pane", "bk_body", "bk_row", "bk_key", "bk_edit"}

// What a pane hands the shared declaration besides its rows.
Pane_Draw :: struct {
    ids:      Pane_Ids,
    area:     gfx.Rect,
    row_h:    i32,
    max_rows: int,
    val_off:  f32, // the key column, in cells
    scroll:   int,
    hover:    int, // display row under the pointer, or -1
    now:      f64,
}

// -1 when over none; chrome is dead space. Resolves against the tree the LAST frame declared,
// so it runs before anything this frame is built.
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

// The lit one.
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
// No backgroundColor: panel() filled the pane, so every fill here means something.
pane_declare :: proc(u: UI_Ctx, face: gfx.Face, d: Pane_Draw, rows: []Pane_Row) {
    th := u.theme
    cw := face.cell_w
    lh := i32(face.line_height)
    first := clamp(d.scroll, 0, max(0, len(rows)))
    visible := max(0, min(len(rows) - first, d.max_rows))

    if clay.UI(clay.ID(d.ids.pane))(clay_pane_box(d.area)) {
        if clay.UI(clay.ID(d.ids.body))(
            {
                layout = {
                    // Capped at the pane (rule 8): a row wider than the pane is a row the clip
                    // has to cut, and a growing clip group would widen to fit it instead.
                    sizing          = {clay.SizingGrow({max = f32(d.area.w)}), clay.SizingGrow()},
                    layoutDirection = .TopToBottom,
                },
                clip = {horizontal = true, vertical = true},
            },
        ) {
            for k in 0 ..< visible {
                i := first + k
                r := rows[i]

                // Hover never competes with the selection: the lit row keeps its own bar.
                bg: clay.Color
                if r.sel {
                    bg = clay_rgb(th.separator)
                } else if hover_shown(u) && i == d.hover && r.item >= 0 {
                    bg = clay_rgb(hover_bg(th))
                }

                // The one-cell margin plus the row's indent. cell_w is rounded at bake time,
                // so this is exact in u16 pixels.
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
                    // A Custom, because carets are over-quads.
                    switch {
                    case r.field != nil:
                        field_declare(
                            clay.ID(d.ids.edit, u32(i)),
                            u,
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
