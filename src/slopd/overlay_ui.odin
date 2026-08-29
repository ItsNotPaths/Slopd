package main

import "core:fmt"
import "core:unicode/utf8"
import clay "../../bindings/clay"
import "../gfx"
import "../ui"
import "../pty"

// The terminal switcher (a numbered column while plain Alt is held) and the filetree chord bar
// (the Ctrl-held cheat-sheet along the pane's bottom).
//
// Within one scissor group quads paint UNDER glyphs, so an element covering a pane's text needs
// its own group. `floating.clipTo = .AttachedParent` gives the placement, the clipping and that
// group at once: a floating root with a clip emits a ScissorStart/End pair around its subtree
// using the ATTACHED PARENT's box. A `clip` on the overlay would clip to its own box — wrong
// for a bar that can outgrow a short pane — and open a second scissor.
//
// Capture only reaches the panes that ASK THE TREE: `.Capture` stops Clay walking roots, so
// filetree_hit goes quiet under the chord bar. The terminal uses rect_hit, so the switcher's
// capture buys it nothing — what covers that is terminal_click refusing an Alt press.

// Above every pane and the strip. Redundant within a pane, but it is what outranks the strip
// declared after it.
OVERLAY_Z :: 1

// Pinned to one corner of the pane it is declared in, out of the flow, clipped to that pane,
// swallowing the pointer over its own box. `attachTo = .Parent` is what makes
// `clipTo = .AttachedParent` available.
clay_overlay_float :: proc(at: clay.FloatingAttachPointType) -> clay.FloatingElementConfig {
    return {
        attachTo           = .Parent,
        attachment         = {element = at, parent = at},
        clipTo             = .AttachedParent,
        pointerCaptureMode = .Capture,
        zIndex             = OVERLAY_Z,
    }
}

// ---------------------------------------------------------------------------------------
// The terminal switcher
// ---------------------------------------------------------------------------------------

// A cell either side of the number. The width follows the DIGITS in use: ten sessions is rare,
// and reserving its second column always leaves every one-digit number sitting in a gap.
SWITCHER_PAD_CELLS :: 1

// Cells across: the widest session number plus the padding either side.
switcher_cells :: proc(n: int) -> i32 {
    return i32(num_digits(max(1, n))) + 2 * SWITCHER_PAD_CELLS
}

// Plain Alt only: Alt+Ctrl and Alt+Shift drive the terminal's copy cursor. One proc, so
// app_next_wake's fade clause and the declaration cannot disagree.
switcher_shown :: proc(a: ^App) -> bool {
    return a.aux_mode == .Terminal && a.alt_held && !a.ctrl_held && !a.shift_held
}

// The number's own width plus padding, never wider than the pane. The one source every phase
// sizes itself from.
switcher_geom :: proc(area: gfx.Rect, line_h, cell_w: f32, n: int) -> (colw, row_h: i32, rows: int) {
    colw = gfx.cells(cell_w, min(switcher_cells(n), gfx.cells_fit(area.w, cell_w)))
    row_h = gfx.row(line_h)
    if area.h <= 0 || row_h <= 0 {
        return colw, row_h, 0
    }
    rows = max(1, int(area.h / row_h))
    return
}

// The active session centred, clamped at the ends. A derivation, not a state update: the
// switcher has no viewport of its own to write.
switcher_window :: proc(n, active, rows: int) -> (first, visible: int) {
    first = clamp(active - rows / 2, 0, max(0, n - rows))
    visible = min(n - first, rows)
    return
}

// Declare the switcher into the terminal pane. Reads App, writes only Clay.
//
//   sw_col      the column, floating at the pane's top-left, its own scissor group
//     sw_row/i  one per visible session, keyed by SESSION index; the active one takes an
//               accent fill, a locked one's number greys
//
// Every colour tweens out of th.bg as Alt goes down — an opaque lerp, since alpha is a
// visibility bit here, not a blend factor.
switcher_declare :: proc(u: ui.UI_Ctx, terms: []^pty.Terminal, active: int, fade_anim: ^ui.Anim, face: gfx.Face, area: gfx.Rect, now: f64) {
    th := u.theme
    colw, row_h, rows := switcher_geom(area, face.line_height, face.cell_w, len(terms))
    first, visible := switcher_window(len(terms), active, rows)
    if colw <= 0 || visible <= 0 {
        return
    }
    fade := clamp(ui.anim_value(fade_anim, now), 0, 1)
    col_active := ui.clay_rgb(ui.lerp3(th.bg, th.accent, fade))
    col_fg := ui.lerp3(th.bg, th.fg, fade)
    col_lock := ui.lerp3(th.bg, th.muted, fade) // Alt+L
    lh := i32(face.line_height)

    if clay.UI(clay.ID("sw_col"))(
        {
            layout = {
                sizing          = {clay.SizingFixed(f32(colw)), clay.SizingFixed(f32(visible * int(row_h)))},
                layoutDirection = .TopToBottom,
            },
            floating        = clay_overlay_float(.LeftTop),
            backgroundColor = ui.clay_rgb(ui.lerp3(th.bg, th.border_dark, fade)),
        },
    ) {
        for k in 0 ..< visible {
            i := first + k
            bg: clay.Color
            if i == active {
                bg = col_active
            }
            // Right-aligned in whole CELLS, so the numbers line up under each other and the
            // padding stays a cell. Capped, too — a session number wider than the column would
            // grow it, SizingGrow meaning "at least fit your content".
            label := fmt.tprintf("%d", i + 1) // temp: Clay's command list points at it
            lead := gfx.cells(face.cell_w, max(0, switcher_cells(len(terms)) - SWITCHER_PAD_CELLS - i32(len(label))))
            if clay.UI(clay.ID("sw_row", u32(i)))(
                {
                    layout = {
                        sizing  = {clay.SizingGrow({max = f32(colw)}), clay.SizingFixed(f32(row_h))},
                        padding = {left = u16(lead)},
                    },
                    backgroundColor = bg,
                },
            ) {
                clay.Text(label, ui.clay_text_config(terms[i].locked ? col_lock : col_fg, lh))
            }
        }
    }
}

// The test-facing wrapper (see filetree_layout). The stand-in pane box is not optional: an
// overlay attached to `.Parent` inherits its clip from that pane.
switcher_layout :: proc(
    a: ^App,
    face: gfx.Face,
    area: gfx.Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        if clay.UI(clay.ID("term_pane"))(ui.clay_pane_box(area)) {
            switcher_declare(ctx_of(a), a.terminals[:], a.term_active, &a.switcher_anim, face, area, now)
        }
    }
    return clay.EndLayout(0)
}

// ---------------------------------------------------------------------------------------
// The filetree chord bar
// ---------------------------------------------------------------------------------------

// The margin either end and the gap between packed items, both in CELLS — the packing counts
// columns.
CHORD_PAD_CELLS :: 1
CHORD_GAP :: 2

// Each key carries a "^" so the bar reads as the Ctrl menu. Package-level so the packing and
// the declaration agree on the count; `@(rodata)` because the packing indexes it.
//
// The file ops come first and are the same in both presentations; the rest are the browser's,
// and chord_hints drops them for the dired listing.
@(rodata)
CHORD_HINTS := [19][2]string {
    {"^y", "mark"},
    {"^u", "unmark"},
    {"^c", "copy"},
    {"^x", "cut"},
    {"^v", "paste"},
    {"^d", "del"},
    {"^D", "del-set"},
    {"^w", "path"},
    {"^W", "dir"},
    {"^o", "edit"},
    {"^i", "props"},
    {"^I", "dir-props"},
    {"^h", "workspace"},
    {"^k", "discard"},
    {"^←", "back"},
    {"^→", "fwd"},
    {"^r", "reload"},
    {"^g", "grid"},
    {"^1-9", "place"},
}

// The hints that apply to the dired listing: the file ops, no navigation.
CHORD_OPS :: 14

chord_hints :: proc(a: ^App) -> [][2]string {
    return a.file_pane == .Browser ? CHORD_HINTS[:] : CHORD_HINTS[:CHORD_OPS]
}

// The filetree pane, Ctrl down, holding the arrows. Inside the pane rather than the status
// strip, so the command line is never co-opted by a cheat-sheet. Not over the workspace prompt:
// with a line being typed into, every chord below is a Text bind and none of the ops resolve.
chord_shown :: proc(a: ^App) -> bool {
    return a.aux_mode == .FileTree && a.ctrl_held && a.focus == .Aux && !a.wsfind.open
}

// A key and its label, or with key == "" the state readout, at a row and a start column in
// cells.
Chord_Item :: struct {
    key:   string,
    label: string,
    row:   int,
    col:   int,
}

// Row height, margin in Clay's units, and how many CELLS wide the packing may run. The one
// call the packing and the declaration both size themselves from.
chord_geom :: proc(area: gfx.Rect, line_h, cell_w: f32) -> (row_h: i32, pad: u16, maxw: int) {
    row_h = gfx.row(line_h)
    pad = u16(gfx.cells(cell_w, CHORD_PAD_CELLS))
    maxw = max(1, int(gfx.cells_fit(area.w, cell_w)) - 2 * CHORD_PAD_CELLS)
    return
}

// Into rows `maxw` cells wide, left-flowing with CHORD_GAP between items. Clay has no
// flow-wrap, so the wrap is arithmetic. Widths in RUNES, as clay_measure_dims counts them.
chord_pack :: proc(
    hints: [][2]string,
    state: string,
    maxw: int,
    alloc := context.temp_allocator,
) -> (
    items: []Chord_Item,
    nrows: int,
) {
    items = make([]Chord_Item, len(hints) + 1, alloc)
    cur_row, cur_x := 0, 0
    for i in 0 ..< len(items) {
        it: Chord_Item
        w: int
        if i < len(hints) {
            h := hints[i]
            it = Chord_Item{key = h[0], label = h[1]}
            w = utf8.rune_count_in_string(h[0]) + 1 + utf8.rune_count_in_string(h[1])
        } else {
            it = Chord_Item{label = state}
            w = utf8.rune_count_in_string(state)
        }
        if cur_x > 0 && cur_x + w > maxw {
            cur_row += 1
            cur_x = 0
        }
        it.row, it.col = cur_row, cur_x
        items[i] = it
        cur_x += w + CHORD_GAP
    }
    return items, cur_row + 1
}

// Declare the chord bar into the filetree pane. Reads App, writes only Clay.
//
//   ch_bar        the bar, floating at the pane's bottom-left, its own scissor group
//     ch_row/r    one per packed row; margin from padding, inter-item gap from childGap, in
//                 cells, so the columns land where the packing said (rule 5)
//       ch_item/i "^y mark": the key in accent, its label muted
//       ch_state  the paste mode and marked count, last in the flow so it wraps too
chord_declare :: proc(u: ui.UI_Ctx, ft: ^FileTree, hints: [][2]string, fade_anim: ^ui.Anim, face: gfx.Face, area: gfx.Rect, now: f64) {
    th := u.theme
    row_h, pad, maxw := chord_geom(area, face.line_height, face.cell_w)
    if area.w <= 0 || row_h <= 0 {
        return
    }
    // The clipboard half appears only when there is one: "[2 marked]" until you copy.
    state := len(ft.clip) == 0 \
        ? fmt.tprintf("[%d marked]", len(ft.marks)) \
        : fmt.tprintf("[%d marked · %s %d]", len(ft.marks), ft.clip_mode == .Cut ? "cut" : "copy", len(ft.clip))
    items, nrows := chord_pack(hints, state, maxw)

    // Opaque lerp out of the pane bg as Ctrl is held — the switcher's fade, one pane along.
    fade := clamp(ui.anim_value(fade_anim, now), 0, 1)
    key_col := ui.lerp3(th.bg, th.accent, fade)
    lbl_col := ui.lerp3(th.bg, th.muted, fade)
    cw := face.cell_w
    lh := i32(face.line_height)

    if clay.UI(clay.ID("ch_bar"))(
        {
            layout = {
                sizing          = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(nrows * int(row_h)))},
                padding         = {left = pad, right = pad},
                layoutDirection = .TopToBottom,
            },
            floating        = clay_overlay_float(.LeftBottom),
            backgroundColor = ui.clay_rgb(ui.lerp3(th.bg, th.border_dark, fade)),
        },
    ) {
        for r in 0 ..< nrows {
            if clay.UI(clay.ID("ch_row", u32(r)))(
                {
                    layout = {
                        sizing = {
                            clay.SizingGrow({max = f32(area.w) - 2 * f32(pad)}), // rule 8
                            clay.SizingFixed(f32(row_h)),
                        },
                        childGap       = u16(CHORD_GAP * cw),
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                for it, i in items {
                    if it.row != r {
                        continue
                    }
                    if it.key == "" {
                        if clay.UI(clay.ID("ch_state"))({}) {
                            clay.Text(it.label, ui.clay_text_config(lbl_col, lh))
                        }
                        continue
                    }
                    if clay.UI(clay.ID("ch_item", u32(i)))({layout = {childGap = u16(cw)}}) {
                        clay.Text(it.key, ui.clay_text_config(key_col, lh))
                        clay.Text(it.label, ui.clay_text_config(lbl_col, lh))
                    }
                }
            }
        }
    }
}

// See switcher_layout for why the pane box is declared around it.
chord_layout :: proc(
    a: ^App,
    face: gfx.Face,
    area: gfx.Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        if clay.UI(clay.ID("ft_pane"))(ui.clay_pane_box(area)) {
            chord_declare(ctx_of(a), &a.tree, chord_hints(a), &a.chord_anim, face, area, now)
        }
    }
    return clay.EndLayout(0)
}
