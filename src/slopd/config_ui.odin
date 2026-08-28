package main

import clay "../../bindings/clay"
import "../txt"
import "../gfx"
import "../paths"
import "../ui"

// The config / syntax pane's UI half. The rows are drawn by pane_ui.odin, shared with the binds
// pane; what lives here is this pane's own:
//   1. Chrome rows — section rules and titles, with no navigable item, refused by the hit test.
//   2. Two coordinates per row: a click resolves to a row and, inside an open dropdown, to a
//      choice, so config_click reads item/opt off the DISPLAY row.
//   3. Text fields — the shared one-line `Field`, which a setting becomes only while highlighted.
//
// The dropdown is not an overlay: its options are spliced INTO the row list as indented rows, so
// nothing needs `floating`, a second clip group, or an overlay-first hit test.

// Tighter than FT_ROW_PAD: this pane is a dense form rather than a list you scan.
CONFIG_ROW_PAD :: 2

// Content area, row height, display rows, and the content width in whole cells. No row is
// reserved for a header: the first row is already a section rule.
config_geom :: proc(
    pane: gfx.Rect,
    line_h, cell_w: f32,
) -> (
    area: gfx.Rect,
    row_h: i32,
    rows, cols: int,
) {
    return ui.list_geom(pane, line_h, cell_w)
}

// The widest setting key plus ": ". Every value and inline editor starts here, so the value
// column runs straight down the pane.
config_val_off :: proc() -> f32 {
    keycol := 0
    for si in 0 ..< SETTING_COUNT {
        keycol = max(keycol, len(setting_key(Setting(si))))
    }
    return f32(keycol + 2)
}

// `anchor` and `total` are DISPLAY rows: an open dropdown splices options in, so the row space
// shifts under the stored top and Follow re-frames next frame.
config_scroll_apply :: proc(
    cp: ^ConfigPane,
    anchor, rows, total: int,
    center: bool,
    last_input_at: f64 = 0,
) {
    ui.list_scroll_apply(&cp.scroll, &cp.scroll_detached, anchor, rows, total, center, last_input_at)
}


// -1 means it hit nothing; claimed only on a real hit. A nav row selects on one click and opens
// its dropdown on two; an option row chooses on one, being already the second half of a gesture,
// and its double click is swallowed rather than run twice.
config_click :: proc(a: ^App, rows: []ConfigRow, row: int) {
    if row < 0 || row >= len(rows) {
        return
    }
    r := rows[row]
    if r.item < 0 {
        return
    }
    count, ok := ui.mouse_take_click(ctx_of(a))
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
            cp.open = .None // re-Enter minimises, as the keyboard does
        } else {
            config_pane_open_install(a)
        }
    case .Setting:
        if s, sok := config_pane_setting(cp.sel); sok {
            config_pane_open_setting(a, s)
        }
    case .Lang:
        if cp.open == .Lang && cp.opt_sel == -1 {
            cp.open = .None // re-Enter on the root minimises, as the keyboard does
        } else {
            config_pane_open_lang(a)
        }
    case .Binds:
        set_aux(a, .Binds)
    case .Macros:
        config_open_macros(a)
    case .Search, .Text:
    // Neither text row has a double-click verb: selecting one makes it the editor.
    }
}

// Derived rather than stored: the flattening carries no palette, for the reason it carries no
// selection. Language rows are tinted by install state, so the mark and the colour agree.
config_row_color :: proc(th: ^gfx.Theme, r: ConfigRow, sel: bool) -> [3]f32 {
    switch r.kind {
    case .Rule:
        return th.border_light
    case .Header:
        return th.accent
    case .Lang:
        return r.present ? th.code_return_type : th.fg
    case .Install:
        // Read-only is a problem rather than a choice, so it takes a colour of its own.
        switch paths.install_mode() {
        case .ReadOnly:  return th.code_keyword
        case .Installed: return th.code_return_type
        case .Portable:  return sel ? th.fg : th.muted
        }
        return th.fg
    case .Binds, .Macros:
        return r.value[0] == '!' ? th.urgent : sel ? th.fg : th.muted
    case .Setting, .Text, .Search, .Option:
        return sel ? th.fg : th.muted
    }
    return th.fg
}

// Selectedness, colour and the one live editor, derived here so the rows the hit test ran
// against carry none of it.
config_draw_rows :: proc(
    a: ^App,
    rows: []ConfigRow,
    alloc := context.allocator,
) -> []ui.Pane_Row {
    cp := &a.config_pane
    th := &a.theme
    out := make([]ui.Pane_Row, len(rows), alloc)
    for r, i in rows {
        sel := config_row_selected(cp, r)
        // A free-text setting is an editor only while highlighted; the filter always is.
        field: ^txt.Doc
        if r.kind == .Search {
            field = &cp.search
        } else if r.kind == .Text && sel {
            field = &cp.edit
        }
        out[i] = ui.Pane_Row {
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

config_declare :: proc(u: ui.UI_Ctx, cp: ^ConfigPane, face: gfx.Face, pane: gfx.Rect, rows: []ui.Pane_Row, now: f64 = 0) {
    area, row_h, max_rows, _ := config_geom(pane, face.line_height, face.cell_w)
    ui.pane_declare(
        u,
        face,
        {
            ids = ui.CONFIG_IDS,
            area = area,
            row_h = row_h,
            max_rows = max_rows,
            val_off = config_val_off(),
            scroll = cp.scroll,
            hover = cp.hover,
            now = now,
        },
        rows,
    )
}

// A "settings" block of key: value rows, then a "syntax" block listing each language's grammar
// status with its install-options dropdown nested under an opened row. The search row filters
// that list live.
config_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect, now: f64) {
    u := ctx_of(a)
    area, _, max_rows, cols := config_geom(pane, gfx.face(t).line_height, gfx.face(t).cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cp := &a.config_pane
    // One flattening serves the hit test and the click, since no row carries selection state.
    // A SECOND is needed here where grep needs none: choosing an option splices rows out and can
    // rewrite a value, so the list the click acted on is not the one to paint.
    rows := config_rows(cp, a, cols, context.temp_allocator)

    drawn := config_draw_rows(a, rows, context.temp_allocator)
    hit := ui.pane_hit(ui.CONFIG_IDS, drawn, cp.scroll, max_rows)

    // Before the click, for the reason it is hit-tested there: both resolve against the tree
    // Clay still holds. A click that reshapes the list leaves it a row off for one frame.
    cp.hover = hit
    config_click(a, rows, hit)
    // A click can move the selection off a text row without the keyboard, so the reconcile sits
    // between the click and the re-flatten: the row left commits, the row entered seeds.
    config_edit_sync(a)

    rows = config_rows(cp, a, cols, context.temp_allocator)
    drawn = config_draw_rows(a, rows, context.temp_allocator)
    center := u.scroll_mode == .Middle
    config_scroll_apply(cp, ui.pane_anchor(drawn), max_rows, len(drawn), center, ui.pane_input_at(u))
    config_declare(u, cp, gfx.face(t), pane, drawn, now)
}

// Test-facing wrapper; see filetree_layout.
config_layout :: proc(
    a: ^App,
    face: gfx.Face,
    pane: gfx.Rect,
    rows: []ConfigRow,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        drawn := config_draw_rows(a, rows, context.temp_allocator)
        config_declare(ctx_of(a), &a.config_pane, face, pane, drawn, now)
    }
    return clay.EndLayout(0)
}
