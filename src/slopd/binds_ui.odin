package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import clay "../../bindings/clay"
import "../gfx"
import "../ui"

// The binds pane's UI half — the flattening and the click; pane_ui.odin draws the rows.
//
// A row carries SEVERAL selectable chords, so the highlight has two coordinates here, as an open
// dropdown gives the config pane two.

// How the pane works, said once at the top. Both edit paths end in the same `:rebind` grammar.
@(rodata)
BINDS_BANNER := [?]string {
    "enter edits the highlighted chord · ←/→ pick which · alt+= adds one",
    "backspace (alt+-) deletes · ^s saves · :rebind [+|-|N] <action> [chord]",
}

Binds_Row_Kind :: enum {
    Rule,
    Header, // a section title: the action name's prefix
    Note, // the banner: how to work the pane
    Button, // the mode toggle, open in editor, save
    Error, // a refused config line
    Action, // an action and its chords
}

BindsRow :: struct {
    kind:   Binds_Row_Kind,
    text:   string,
    value:  string, // the chords, or a button's state; drawn at the shared value column
    item:   int, // the navigable row this selects, or -1 for chrome
    indent: i32,
}

binds_geom :: proc(
    pane: gfx.Rect,
    line_h, cell_w: f32,
) -> (
    area: gfx.Rect,
    row_h: i32,
    rows, cols: int,
) {
    return ui.list_geom(pane, line_h, cell_w)
}

// The widest action name plus ": ", so every chord list starts on one column.
binds_val_off :: proc() -> f32 {
    w := 0
    for info in ACTIONS {
        w = max(w, len(info.name))
    }
    return f32(w + 2)
}

// `act`'s chords, space-joined. One string, so the flattening stays free of the palette; the
// highlighted one is picked out in colour by binds_chord_spans at declaration time.
@(private = "file")
binds_chord_text :: proc(bp: ^BindsPane, act: Action, alloc: runtime.Allocator) -> string {
    at := binds_of(bp, act)
    if len(at) == 0 {
        return strings.clone("—", alloc)
    }
    b := strings.builder_make(0, 32, alloc)
    for i in at {
        if strings.builder_len(b) > 0 {
            strings.write_byte(&b, ' ')
        }
        strings.write_string(&b, chord_string(bp.working[i].chord, context.temp_allocator))
    }
    return strings.to_string(b)
}

// The same chords as coloured runs, with the one Left/Right has landed on lit. Only the SELECTED
// row needs them; every other row is one colour and stays a plain string.
@(private = "file")
binds_chord_spans :: proc(
    bp: ^BindsPane,
    act: Action,
    th: ^gfx.Theme,
    alloc: runtime.Allocator,
) -> []ui.Pane_Span {
    at := binds_of(bp, act)
    if len(at) == 0 {
        return nil
    }
    out := make([]ui.Pane_Span, len(at), alloc)
    for i, k in at {
        text := chord_string(bp.working[i].chord, alloc)
        if k > 0 {
            text = strings.concatenate({" ", text}, alloc)
        }
        out[k] = {text, k == bp.chord ? th.accent : th.fg}
    }
    return out
}

// What the pane is waiting for, or what Ctrl+S would do — shown on the save row, so neither a
// live capture nor a blocked write is ever invisible.
@(private = "file")
binds_state_text :: proc(bp: ^BindsPane, alloc: runtime.Allocator) -> string {
    switch bp.capture {
    case .Add, .Rebind:
        return strings.clone("press a chord   (esc cancels)", alloc)
    case .Confirm:
        c := chord_string(bp.pending, context.temp_allocator)
        who := action_name(bp.steal)
        return fmt.aprintf("%s is %s — enter takes it, esc cancels", c, who, allocator = alloc)
    case .Rejected:
        c := chord_string(bp.pending, context.temp_allocator)
        return fmt.aprintf("%s refused: %s", c, bind_fault_text(bp.fault), allocator = alloc)
    case .None:
    }
    switch {
    case len(bp.errs) > 0:
        return strings.clone("blocked: clear the errors above first", alloc)
    case bp.note != "":
        return strings.clone(bp.note, alloc) // what `:rebind` just did, until you move off
    case bp.dirty:
        return strings.clone("unsaved changes", alloc)
    }
    return ""
}

binds_rows :: proc(bp: ^BindsPane, cols: int, alloc := context.allocator) -> []BindsRow {
    rows := make([dynamic]BindsRow, 0, 96, alloc)
    rule := strings.repeat("-", max(1, cols - 1), alloc)
    chrome :: proc(kind: Binds_Row_Kind, text: string) -> BindsRow {
        return BindsRow{kind = kind, text = text, item = -1}
    }
    append(&rows, chrome(.Rule, rule), chrome(.Header, "bindings"), chrome(.Rule, rule))
    for l in BINDS_BANNER {
        append(&rows, chrome(.Note, l))
    }
    append(&rows, chrome(.Rule, rule))
    append(
        &rows,
        BindsRow {
            kind = .Button,
            text = "edit mode:",
            value = bp.mode == .Capture ? "capture a keystroke" : "fill in the command line",
            item = ROW_BINDS_MODE,
            indent = 1,
        },
        BindsRow{kind = .Button, text = "open in editor", item = ROW_BINDS_OPEN, indent = 1},
        BindsRow {
            kind = .Button,
            text = "save  (^s)",
            value = binds_state_text(bp, alloc),
            item = ROW_BINDS_SAVE,
            indent = 1,
        },
    )

    if len(bp.errs) > 0 {
        head := chrome(.Header, "errors in slopd.config")
        append(&rows, chrome(.Rule, rule), head, chrome(.Rule, rule))
        for e, i in bp.errs {
            append(
                &rows,
                BindsRow {
                    kind = .Error,
                    text = fmt.aprintf("line %d:", e.line, allocator = alloc),
                    value = fmt.aprintf(
                        "%s   %s",
                        e.text,
                        bind_fault_text(e.why),
                        allocator = alloc,
                    ),
                    item = ROW_BINDS_ERRS + i,
                    indent = 1,
                },
            )
        }
    }

    group := ""
    for i in 0 ..< len(Action) - 1 {
        act := Action(i + 1)
        name := action_name(act)
        if g := action_group(name); g != group {
            group = g
            append(&rows, chrome(.Rule, rule), chrome(.Header, group), chrome(.Rule, rule))
        }
        nav := ROW_BINDS_ERRS + len(bp.errs) + i
        append(
            &rows,
            BindsRow {
                kind = .Action,
                text = fmt.aprintf("%s:", name, allocator = alloc),
                value = binds_chord_text(bp, act, alloc),
                item = nav,
                indent = 1,
            },
        )
    }
    return rows[:]
}


binds_click :: proc(a: ^App, rows: []BindsRow, row: int) {
    if row < 0 || row >= len(rows) || rows[row].item < 0 {
        return
    }
    count, ok := ui.mouse_take_click(ctx_of(a))
    if !ok {
        return
    }
    bp := &a.binds_pane
    if bp.sel != rows[row].item {
        bp.sel, bp.chord, bp.capture = rows[row].item, 0, .None
    }
    if count >= 2 {
        binds_pane_activate(a)
    }
}

binds_row_color :: proc(th: ^gfx.Theme, r: BindsRow, sel: bool) -> [3]f32 {
    switch r.kind {
    case .Rule:
        return th.border_light
    case .Header:
        return th.accent
    case .Error:
        return th.urgent
    case .Note:
        return th.muted
    case .Button, .Action:
        return sel ? th.fg : th.muted
    }
    return th.fg
}

// The drawable view: an error row is urgent throughout, and only the lit row spells out which of
// its chords Left/Right has landed on.
binds_draw_rows :: proc(u: ui.UI_Ctx, bp: ^BindsPane, rows: []BindsRow, alloc := context.allocator) -> []ui.Pane_Row {
    th := u.theme
    sel_row := bp.sel
    out := make([]ui.Pane_Row, len(rows), alloc)
    for r, i in rows {
        sel := r.item >= 0 && r.item == sel_row
        // Only the lit row splits its chords, since only there is one of them picked out.
        spans: []ui.Pane_Span
        if sel && r.kind == .Action {
            if act, ok := binds_pane_action(bp, r.item); ok {
                spans = binds_chord_spans(bp, act, th, alloc)
            }
        }
        out[i] = ui.Pane_Row {
            text   = r.text,
            value  = r.value,
            spans  = spans,
            item   = r.item,
            indent = r.indent,
            flush  = r.kind == .Rule || r.kind == .Header || r.kind == .Note,
            sel    = sel,
            color  = binds_row_color(th, r, sel),
            vcolor = r.kind == .Error ? th.urgent : th.fg,
        }
    }
    return out
}

binds_declare :: proc(u: ui.UI_Ctx, bp: ^BindsPane, face: gfx.Face, pane: gfx.Rect, rows: []ui.Pane_Row) {
    area, row_h, max_rows, _ := binds_geom(pane, face.line_height, face.cell_w)
    ui.pane_declare(
        u,
        face,
        {
            ids = ui.BINDS_IDS,
            area = area,
            row_h = row_h,
            max_rows = max_rows,
            val_off = binds_val_off(),
            scroll = bp.scroll,
            hover = bp.hover,
        },
        rows,
    )
}

binds_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect) {
    u := ctx_of(a)
    area, _, max_rows, cols := binds_geom(pane, gfx.face(t).line_height, gfx.face(t).cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    bp := &a.binds_pane
    rows := binds_rows(bp, cols, context.temp_allocator)
    drawn := binds_draw_rows(u, bp, rows, context.temp_allocator)
    hit := ui.pane_hit(ui.BINDS_IDS, drawn, bp.scroll, max_rows)
    bp.hover = hit
    binds_click(a, rows, hit)

    rows = binds_rows(bp, cols, context.temp_allocator)
    drawn = binds_draw_rows(u, bp, rows, context.temp_allocator)
    ui.list_scroll_apply(
        &bp.scroll,
        &bp.scroll_detached,
        ui.pane_anchor(drawn),
        max_rows,
        len(drawn),
        u.scroll_mode == .Middle,
        ui.pane_input_at(u),
    )
    binds_declare(u, bp, gfx.face(t), pane, drawn)
}

// Test-facing wrapper; see filetree_layout.
binds_layout :: proc(
    a: ^App,
    face: gfx.Face,
    pane: gfx.Rect,
    rows: []BindsRow,
    win_w, win_h: i32,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        u := ctx_of(a)
        binds_declare(u, &a.binds_pane, face, pane, binds_draw_rows(u, &a.binds_pane, rows, context.temp_allocator))
    }
    return clay.EndLayout(0)
}
