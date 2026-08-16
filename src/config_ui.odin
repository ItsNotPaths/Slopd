package main

import clay "../bindings/clay"

// The config / syntax pane's UI half. The rows are drawn by pane_ui.odin, which the binds pane
// shares; what lives here is everything that is this pane's own:
//   1. Chrome rows — section rules and titles, with no navigable item, refused by the hit test.
//   2. Two coordinates per row: a click resolves to a row AND, inside an open dropdown, to a
//      choice, so config_click reads item/opt off the DISPLAY row.
//   3. Text fields — the shared one-line `Field`, which a setting becomes only while HIGHLIGHTED.
//      config_draw_rows decides that, where selectedness is derived rather than stored.
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
    rows, cols: int,
) {
    return list_geom(pane, scale, line_h, cell_w, CONFIG_ROW_PAD)
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
config_scroll_apply :: proc(
    cp: ^ConfigPane,
    anchor, rows, total: int,
    center: bool,
    last_input_at: f64 = 0,
) {
    list_scroll_apply(&cp.scroll, &cp.scroll_detached, anchor, rows, total, center, last_input_at)
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
    case .Install:
        if cp.open == .Install {
            cp.open = .None // re-Enter on an open row minimises, as the keyboard does
        } else {
            config_pane_open_install(a)
        }
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
    case .Binds:
        set_aux(a, .Binds)
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
    case .Install:
        // Read-only is the one state that is a PROBLEM rather than a choice, so it is the one
        // that takes a colour of its own; installed reads like an installed grammar.
        switch install_mode() {
        case .ReadOnly:  return th.code_keyword
        case .Installed: return th.code_return_type
        case .Portable:  return sel ? th.fg : th.muted
        }
        return th.fg
    case .Binds:
        return r.value[0] == '!' ? th.urgent : sel ? th.fg : th.muted
    case .Setting, .Text, .Search, .Option:
        return sel ? th.fg : th.muted
    }
    return th.fg
}

// The drawable view of the flattening: selectedness, colour and the one live editor, derived
// here rather than stored, so the rows the hit test ran against carry none of it.
config_draw_rows :: proc(
    a: ^App,
    rows: []ConfigRow,
    alloc := context.allocator,
) -> []Pane_Row {
    cp := &a.config_pane
    th := &a.theme
    out := make([]Pane_Row, len(rows), alloc)
    for r, i in rows {
        sel := config_row_selected(cp, r)
        // A free-text setting is an editor only while HIGHLIGHTED; the filter always is.
        field: ^Doc
        if r.kind == .Search {
            field = &cp.search
        } else if r.kind == .Text && sel {
            field = &cp.edit
        }
        out[i] = Pane_Row {
            text   = r.text,
            value  = r.value,
            item   = r.item,
            indent = r.indent,
            flush  = r.kind == .Rule || r.kind == .Header,
            sel    = sel,
            color  = config_row_color(th, r, sel),
            vcolor = th.fg,
            field  = field,
            caret  = sel && config_caret_live(a),
        }
    }
    return out
}

config_declare :: proc(a: ^App, f: ^Font, pane: Rect, ui: []Pane_Row, now: f64 = 0) {
    cp := &a.config_pane
    area, row_h, max_rows, _ := config_geom(pane, a.scale, f.line_height, f.cell_w)
    pane_declare(
        a,
        f,
        {
            ids = CONFIG_IDS,
            area = area,
            row_h = row_h,
            max_rows = max_rows,
            val_off = config_val_off(),
            scroll = cp.scroll,
            hover = cp.hover,
            now = now,
        },
        ui,
    )
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

    ui := config_draw_rows(a, rows, context.temp_allocator)
    hit := pane_hit(CONFIG_IDS, ui, cp.scroll, max_rows)

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
    ui = config_draw_rows(a, rows, context.temp_allocator)
    center := a.scroll_mode == .Middle
    config_scroll_apply(cp, pane_anchor(ui), max_rows, len(ui), center, pane_input_at(a))
    config_declare(a, &t.font, pane, ui, now)
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
        ui := config_draw_rows(a, rows, context.temp_allocator)
        config_declare(a, f, pane, ui, now)
    }
    return clay.EndLayout(0)
}
