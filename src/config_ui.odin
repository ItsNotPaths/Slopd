package main

import clay "../bindings/clay"

// The config / syntax pane's UI half — C5b, the third pane declared in Clay and the first
// with rows that are neither one-per-item nor uniformly clickable. filetree_ui.odin is the
// template and grep_ui.odin the row -> item indirection; the frame order in draw_config is
// the same and load-bearing for the same reason (see filetree_ui.odin's header).
//
// Three things are new here.
//
//   1. **Chrome rows.** Section rules and titles are display rows with no navigable item, so
//      `ConfigRow.item == -1` and the hit test refuses them. They are dead space, exactly as
//      grep's spacers are.
//   2. **Two coordinates per row.** A click has to resolve to a row AND, inside an open
//      dropdown, to a choice — so config_hit returns the DISPLAY row index and config_click
//      reads `item` / `opt` off it, rather than resolving to an item the way grep_hit does.
//   3. **A Custom for the search field.** The language filter is a live one-line Doc with
//      selection spans and carets, and a caret is an OVER-quad (text.odin) — it must land
//      above the glyphs, which a Clay Rectangle cannot do, since the bridge maps those to
//      `fill` and everything in a scissor group paints under the text. So it takes the
//      escape hatch the boundary reserves for per-glyph surfaces.
//
// The dropdown is NOT an overlay, and this is worth stating because docs/clay-refactor.md
// billed C5b as the refactor's first occlusion case. It is not one: draw_config spliced an
// open dropdown's options INTO the row list as indented rows, pushing the rows below it
// down, and this port keeps that behaviour. Nothing here covers anything, so nothing here
// needs `floating`, a second clip group, or an overlay-first hit test. See the C5b notes in
// the refactor doc for where the occlusion question actually lands.

// Extra vertical padding per row, in logical pixels — the value draw_config has always
// used, and tighter than the filetree's (FT_ROW_PAD) because this pane is a dense form
// rather than a list you scan.
CONFIG_ROW_PAD :: 2

// The pane's fixed geometry: the content area inside the focus ring, the row height, how
// many display rows fit, and the content width in whole cells (which is all the section
// rules need in order to span it). Pure, and shared by every phase of the frame — the one
// call that makes them incapable of disagreeing.
//
// Unlike the filetree and grep, no row is reserved for a header: this pane's first row is
// already a section rule, and the "settings" title is a row like any other.
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

// How many cells the key column spans: the widest setting key plus ": ". Every value and
// every inline editor starts at this offset from its row's text, so the value column is
// straight down the pane regardless of key length.
config_val_off :: proc() -> f32 {
    keycol := 0
    for si in 0 ..< SETTING_COUNT {
        keycol = max(keycol, len(setting_key(Setting(si))))
    }
    return f32(keycol + 2)
}

// Move the viewport to follow the selected row, under the shared `scroll_mode` policy.
// `anchor` and `total` are both in DISPLAY rows: an open dropdown splices its options into
// the list, so the row space shifts under the stored top — Follow simply re-frames from
// wherever it lands on the next frame, which is what draw_config always did.
//
// This is the write that used to be a side effect of painting (`cp.scroll = ...` sat in the
// middle of draw_config). It is a normal state update now: GL-free, before any declaration.
config_scroll_apply :: proc(cp: ^ConfigPane, anchor, rows, total: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&cp.scroll, &cp.scroll_detached, anchor, rows, total, center, last_input_at)
}

// Which DISPLAY row the pointer is over, or -1. A row index rather than an item, because a
// click on an option row needs the choice as well as the row that owns it — see the header.
// Chrome rows carry item == -1 and are skipped, so a press on a rule or a section title is
// dead space rather than a hit on whatever row sits nearest.
//
// As in the other panes this resolves against the tree Clay is still holding — the one the
// LAST frame declared — which is why it runs before this frame's declaration and why
// `first` is cp.scroll as it stood when those rows were painted.
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

// Apply a pending click on display row `row` (-1 = the pointer hit nothing). Claimed only
// on a real hit, so a press aimed elsewhere is not eaten — see mouse_take_click.
//
// The verbs are the keyboard's, reached through the same procs:
//
//   - a nav row: single click selects it (Up/Down), double click opens its dropdown
//     (Right/Enter). Clicking OFF an open dropdown closes it, which is the one thing the
//     keyboard cannot express — its Up/Down are captured by the dropdown while it is open.
//   - an option row: a single click CHOOSES it (config_choose), because an option list is
//     already the second half of a two-step gesture and making it a third would be unlike
//     every dropdown ever built. This is the one deliberate departure from the template's
//     single-selects / double-activates rule.
//
// A double click on an option is therefore swallowed rather than run twice: the first press
// commits and closes the dropdown, and by the time the second is claimed the row underneath
// is something else entirely. The count guard is what stops an impatient user installing a
// grammar and then opening whatever slid up into that spot.
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
    case .Search:
    // The filter box has no Enter verb: it is live as you type (config_pane_filter).
    }
}

// A row's text colour, derived rather than stored — the flattening carries no palette, for
// the same reason it carries no selection (see ConfigRow). Language rows are tinted by
// INSTALL STATE rather than by selectedness, which is deliberate and predates the port: the
// ✓/✗ mark and the colour say the same thing twice, on purpose.
config_row_color :: proc(th: ^Theme, r: ConfigRow, sel: bool) -> [3]f32 {
    switch r.kind {
    case .Rule:
        return th.border_light
    case .Header:
        return th.accent
    case .Lang:
        return r.present ? th.code_return_type : th.fg
    case .Setting, .Search, .Option:
        return sel ? th.fg : th.muted
    }
    return th.fg
}

// What the search row's Custom element needs in order to paint itself. Handed to the bridge
// as `customData`, so it must outlive EndLayout — it lives in the frame's temp arena.
//
// It used to carry the body clip too: this pane found that the bridge handed a painter its
// BOX and a box is not a clip, so a search row half off the bottom of the pane would have
// scissored to its full-height box and drawn outside the body. That was a gap in the
// ClayCustom contract rather than a quirk of this pane, and C5c closed it — `paint` now
// takes the live clip as a parameter, so there is nothing left here but the field's data.
Config_Edit :: struct {
    doc: ^Doc,
    now: f64,
}

// The inline settings editor: the edit buffer's runes at the value column, with per-cursor
// selection spans and carets — the command-line treatment, reused, and unchanged from the
// config_draw_edit that used to live in render.odin beyond taking its box from Clay.
config_paint_edit :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    e := (^Config_Edit)(user)
    if e == nil || e.doc == nil || len(e.doc.lines) == 0 {
        return
    }
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    ex := f32(r.x)
    ty := f32(r.y) + (f32(r.h) - lh) / 2
    y := i32(ty) // selection / caret share the glyph cell's top

    line := &e.doc.lines[0]
    for c in e.doc.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(t, Rect{i32(ex + cw * f32(lo.col)), y, i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
        }
    }
    text_draw_runes(t, line.text[:], ex, ty, th.fg)
    if caret_blink_on(a, e.now) {
        for c in e.doc.cursors {
            caret(t, Rect{i32(ex + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, so this is the whole obligation.
    flush_pane(t, clip, win_w, win_h)
}

// Declare the pane and hand back the frame's command list. Reads App and the flattened
// rows, writes only Clay — no mutation, no GL. `rows` is passed in rather than rebuilt so
// the frame flattens exactly once, and so the hit test, the click and this declaration
// cannot be looking at different lists.
//
// The tree is:
//   cf_root  full-window container, padded to put the pane where render decided it goes
//     cf_pane   the content area inside the focus ring
//       cf_body   the clip group
//         cf_row/i    one per visible DISPLAY row, keyed by row index
//           cf_key/i    the fixed key column, so every value starts on the same cell
//           cf_edit/i   the search field's Custom (that row only)
config_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    rows: []ConfigRow,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    cp := &a.config_pane
    th := &a.theme
    area, row_h, max_rows, _ := config_geom(pane, a.scale, f.line_height, f.cell_w)
    cw := f.cell_w
    lh := i32(f.line_height)
    val_off := config_val_off()

    first := clamp(cp.scroll, 0, max(0, len(rows)))
    visible := max(0, min(len(rows) - first, max_rows))

    clay_resize(win_w, win_h)
    clay.BeginLayout()

    if clay.UI(clay.ID("cf_root"))(
        {
            layout = {
                sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))},
                padding = {left = u16(max(0, area.x)), top = u16(max(0, area.y))},
            },
        },
    ) {
        // Nothing here paints a background: panel() has already filled the pane and drawn
        // its focus ring, and Clay's transparent default emits no Rectangle at all, so every
        // fill below is one that means something.
        if clay.UI(clay.ID("cf_pane"))(
            {
                layout = {
                    sizing = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
                    layoutDirection = .TopToBottom,
                },
            },
        ) {
            if clay.UI(clay.ID("cf_body"))(
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
                    r := rows[i]
                    sel := config_row_selected(cp, r)
                    col := config_row_color(th, r, sel)
                    flush := r.kind == .Rule || r.kind == .Header

                    // The selection bar, and under the pointer a fainter one. Hover never
                    // competes with the selection: the selected row keeps its own bar.
                    bg: clay.Color
                    if sel {
                        bg = clay_rgb(th.separator)
                    } else if a.hover_on && i == cp.hover && r.item >= 0 {
                        bg = clay_rgb(hover_bg(th))
                    }

                    // The one-cell left margin plus the row's own indent, as whole cells.
                    // cell_w is rounded at bake time, so this is exact in u16 pixels.
                    if clay.UI(clay.ID("cf_row", u32(i)))(
                        {
                            layout = {
                                sizing = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                                padding = {left = u16(cw * f32(1 + r.indent))},
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
                            if r.kind == .Search {
                                // The live filter box: a Custom, because carets are
                                // over-quads (see the header). The struct outlives
                                // EndLayout in the frame's temp arena.
                                cu := new(ClayCustom, context.temp_allocator)
                                ed := new(Config_Edit, context.temp_allocator)
                                ed^ = {doc = &cp.search, now = now}
                                cu^ = {paint = config_paint_edit, user = ed}
                                if clay.UI(clay.ID("cf_edit", u32(i)))(
                                    {
                                        layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                                        custom = {customData = cu},
                                    },
                                ) {}
                            } else if r.value != "" {
                                clay.Text(r.value, clay_text_config(th.fg, lh))
                            }
                        }
                    }
                }
            }
        }
    }

    return clay.EndLayout(0)
}

// The config / syntax pane: a "settings" block (key: value rows, each choosing from a
// dropdown) then a "syntax" block listing every known language with its grammar status
// (✓/✗) and, when a row is opened, its install-options dropdown nested under it. Section
// headers are flanked by rules; setting values share one column; the search row filters the
// language list live as you type. One selection highlight, centre-scrolled like the
// filetree. Up/Down move, Right/Enter open a dropdown, Enter chooses; a click selects a row,
// a double click opens its dropdown, and a click on an option chooses it.
draw_config :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    area, _, max_rows, cols := config_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cp := &a.config_pane
    // One flattening serves the hit test AND the click, because no row carries selection
    // state (the C5a rule). But this pane needs a SECOND one that grep did not, and the
    // difference is structural rather than cosmetic: choosing an option splices rows out of
    // the list and can rewrite a value (config_choose -> setting_commit), so the list the
    // click acted on is not the list this frame should paint. Re-flatten between the two,
    // and the anchor, the scroll policy and the declaration all see the post-click pane.
    rows := config_rows(cp, a, cols, context.temp_allocator)

    hit := config_hit(rows, cp.scroll, max_rows)
    // The hovered row is written before the click for the same reason it is hit-tested
    // there: both resolve against the tree Clay is still holding. A click that reshapes the
    // list leaves this index pointing a row or two off for exactly one frame, which the next
    // frame's hit test corrects.
    cp.hover = hit
    config_click(a, rows, hit)

    rows = config_rows(cp, a, cols, context.temp_allocator)
    config_scroll_apply(cp, config_anchor(cp, rows), max_rows, len(rows), a.scroll_mode == .Middle, pane_input_at(a))

    cmds := config_layout(a, &t.font, pane, rows, win_w, win_h, now)
    clay_paint(t, a, &cmds, area, win_w, win_h)
}
