package main

import "core:fmt"
import "core:unicode/utf8"
import clay "../bindings/clay"

// The two overlays — C8c, and the checkpoint that finally spends the mechanism C5b went
// looking for and did not find.
//
// Slopd has exactly two surfaces that COVER another one: the terminal switcher (a slim
// i3-style numbered column, shown while plain Alt is held) and the filetree chord bar (the
// Ctrl-held cheat-sheet along the bottom of the pane). The config dropdown turned out to
// splice rows inline rather than float over them, and procmon's signal panel REPLACES the
// graph band, so those two were never occlusion cases at all — which left the question C1
// property 1 raises unanswered for five checkpoints:
//
//     within one scissor group quads paint UNDER glyphs, so how does an element that must
//     paint OVER a pane's text get a group of its own?
//
// **The answer is one field, and it is not the one the plan predicted.** The plan said
// three concerns on one element — `floating` to place it, `clip` to give it paint order,
// `pointerCaptureMode` to stop what it covers answering the pointer. It is two:
// `floating.clipTo = .AttachedParent` does the placement AND the group AND the clipping,
// because a floating root with a clip element emits a ScissorStart/End pair around its whole
// subtree (clay.h:2781, :3186) — using the ATTACHED PARENT's box, not its own. That is
// exactly what the hand-drawn painters ended with (`flush_pane(t, area, …)`, the pane's
// content area), and a `clip` on the overlay itself would have been wrong twice over: it
// clips to the overlay's own box, which is not what a bar that can outgrow a short pane
// wants, and it emits a second scissor for a group the float already opened.
//
// So the shape of an overlay here is:
//
//   floating  = clay_overlay_float(corner)   placement, paint order, clip, capture
//   sizing    = fixed, from its own geom     it is a bar / a column, not a laid-out child
//   declared  INSIDE the pane it covers      which is where `.AttachedParent` comes from
//
// **Declared inside the pane, and that is the load-bearing part.** `attachTo = .Parent`
// takes the clip element off the open clip stack, so the overlay inherits the pane's box as
// its clip without either side naming a rect. It also means the pane's own `<p>_declare` is
// the only place that has to know an overlay exists, and the pane's test drives it — which
// is where the occlusion question actually lives, since the thing being covered is the
// filetree's rows.
//
// **Capture only reaches the panes that ASK THE TREE.** `pointerCaptureMode = .Capture`
// makes Clay stop walking roots the moment a capturing one is hit (clay.h:4158), so
// `filetree_hit`'s `PointerOver` goes quiet for every row under the chord bar — no hit, no
// hover tint, no click. The terminal keeps `rect_hit` (C8a: one box, no tree lookup), so the
// switcher's capture buys it nothing at all; what covers that hole is that the switcher is
// only up while Alt is held and `terminal_click` already refuses an Alt press outright. That
// asymmetry is a property of the hit tests, not of the overlays, and it is written down
// rather than papered over.

// The z the overlays sit at, above every pane and the strip. Today this is belt and braces:
// an overlay is declared inside the pane it covers, and Clay appends floating roots in
// declaration order, so it already outranks everything that pane drew. What zIndex buys is
// the panes and the strip declared AFTER it — window_frame declares the aux pane before the
// strip, so without this a chord bar in a very short pane could be painted over by a strip it
// overlapped. It is the one line that says "an overlay is on top of the window", not "on top
// of its own pane".
OVERLAY_Z :: 1

// An overlay's placement: pinned to one corner of the pane it is declared in, out of the
// flow, clipped to that pane, and swallowing the pointer over its own box.
//
// `clipTo = .AttachedParent` is doing three jobs and none of them are obvious — see the
// header. `attachTo = .Parent` is what makes it available: the clip element comes off the
// open clip stack at declaration time, which is the pane box every `<p>_declare` opens with.
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

// The column's width around two digits, and the extra height per row, both in logical
// pixels — the values draw_term_overlay always used.
SWITCHER_COL_PAD :: 12
SWITCHER_ROW_PAD :: 6

// Whether the switcher is up. Plain Alt only: Alt+Ctrl and Alt+Shift drive the terminal's
// copy cursor, so the switcher hides while either is down.
//
// Pulled out for C8b's reason (a decision with a precedence in it, buried in a GL proc, is a
// decision nothing can assert) and immediately paid for itself: app_next_wake's fade clause
// asked only `alt_held && aux_mode == .Terminal`, so the loop kept waking to animate an
// overlay render was refusing to draw. One proc, two callers, no way to drift.
switcher_shown :: proc(a: ^App) -> bool {
    return a.aux_mode == .Terminal && a.alt_held && !a.ctrl_held && !a.shift_held
}

// The column's fixed geometry inside a pane's content area: two digits wide plus padding
// (never wider than the pane), a row height, and how many rows fit. Pure, and the single
// source every phase sizes itself from, exactly as a pane's `<p>_geom` is.
switcher_geom :: proc(area: Rect, scale, line_h, cell_w: f32) -> (colw, row_h: i32, rows: int) {
    colw = min(i32(cell_w * 2) + i32(SWITCHER_COL_PAD * scale), area.w)
    row_h = i32(line_h) + i32(SWITCHER_ROW_PAD * scale)
    if area.h <= 0 || row_h <= 0 {
        return colw, row_h, 0
    }
    rows = max(1, int(area.h / row_h))
    return
}

// The visible window: scroll so the active session stays centred, clamped at the list ends.
// The twin of a list pane's scroll policy, except that there is no stored `.scroll` to write
// — the switcher has no viewport of its own, so this is a derivation rather than a state
// update, and it is pure for that reason rather than by discipline.
switcher_window :: proc(n, active, rows: int) -> (first, visible: int) {
    first = clamp(active - rows / 2, 0, max(0, n - rows))
    visible = min(n - first, rows)
    return
}

// Declare the switcher into the terminal pane. Reads App, writes only Clay.
//
//   sw_col      the column, floating at the pane's top-left, its own scissor group, and the
//               one background here (the fade's `border_dark` end)
//     sw_row/i  one per visible session, keyed by SESSION index so the id names a session;
//               the active one takes an accent fill, a locked one's number greys
//
// Every colour tweens out of th.bg as Alt goes down (an opaque lerp — alpha is a visibility
// bit in this renderer, not a blend factor), so at f == 0 the whole column is the pane
// background and the fade is a real fade rather than a pop.
switcher_declare :: proc(a: ^App, f: ^Font, area: Rect, now: f64) {
    th := &a.theme
    colw, row_h, rows := switcher_geom(area, a.scale, f.line_height, f.cell_w)
    first, visible := switcher_window(term_count(a), a.term_active, rows)
    if colw <= 0 || visible <= 0 {
        return
    }
    fade := clamp(anim_value(&a.switcher_anim, now), 0, 1)
    col_active := clay_rgb(lerp3(th.bg, th.accent, fade))
    col_fg := lerp3(th.bg, th.fg, fade)
    col_lock := lerp3(th.bg, th.muted, fade) // a locked session's number is greyed (Alt+L)
    lh := i32(f.line_height)

    if clay.UI(clay.ID("sw_col"))(
        {
            layout = {
                sizing          = {clay.SizingFixed(f32(colw)), clay.SizingFixed(f32(visible * int(row_h)))},
                layoutDirection = .TopToBottom,
            },
            floating        = clay_overlay_float(.LeftTop),
            backgroundColor = clay_rgb(lerp3(th.bg, th.border_dark, fade)),
        },
    ) {
        for k in 0 ..< visible {
            i := first + k
            bg: clay.Color
            if i == a.term_active {
                bg = col_active
            }
            // Capped for rule 8's reason rather than its symptom: a four-digit session
            // number is wider than the column, and `SizingGrow` means "at least fit your
            // content", so the row would resolve wider than the thing it is inside.
            if clay.UI(clay.ID("sw_row", u32(i)))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow({max = f32(colw)}), clay.SizingFixed(f32(row_h))},
                        childAlignment = {x = .Center, y = .Center},
                    },
                    backgroundColor = bg,
                },
            ) {
                // Centred by the solver, not by `(colw - cw * len) / 2` (rule 5). The
                // string is temp-allocated, like every other formatted label in the
                // chrome: Clay's command list points at it and the frame's arena outlives
                // EndLayout.
                clay.Text(
                    fmt.tprintf("%d", i + 1),
                    clay_text_config(a.terminals[i].locked ? col_lock : col_fg, lh),
                )
            }
        }
    }
}

// The switcher alone in a window, as a command list: the test-facing wrapper every declared
// surface keeps (see filetree_layout). It declares a stand-in pane box around it, because an
// overlay attached to `.Parent` with `clipTo = .AttachedParent` is not the same element
// without one — the clip it inherits IS the pane.
switcher_layout :: proc(
    a: ^App,
    f: ^Font,
    area: Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        if clay.UI(clay.ID("term_pane"))(clay_pane_box(area)) {
            switcher_declare(a, f, area, now)
        }
    }
    return clay.EndLayout(0)
}

// ---------------------------------------------------------------------------------------
// The filetree chord bar
// ---------------------------------------------------------------------------------------

// The bar's left/right margin, the extra height per row, and the gap between packed items
// (in CELLS, not pixels — the packing counts columns) — draw_filetree_overlay's own values.
CHORD_PAD :: 8
CHORD_ROW_PAD :: 6
CHORD_GAP :: 2

// The chords the bar advertises. Each key carries a "^" so the bar reads as the Ctrl menu.
// Package-level rather than a local table, because the packing and the declaration are two
// procs now and a cheat-sheet that disagreed with itself about how many items there are
// would wrap in one and paint in the other. `@(rodata)` rather than a constant because the
// packing indexes it with a loop variable, which a constant array cannot be.
@(rodata)
CHORD_HINTS := [9][2]string {
    {"^y", "yank"},
    {"^u", "reset"},
    {"^c", "copy"},
    {"^x", "cut"},
    {"^p", "paste"},
    {"^d", "del"},
    {"^D", "del-set"},
    {"^w", "path"},
    {"^W", "dir"},
}

// Whether the chord bar is up: the filetree, with Ctrl down, holding the arrows. It sits
// INSIDE the pane rather than in the status strip, so the command line is never co-opted by
// a cheat-sheet.
chord_shown :: proc(a: ^App) -> bool {
    return a.aux_mode == .FileTree && a.ctrl_held && a.focus == .Aux
}

// One packed item: a key and its label, or (key == "") the state readout, at a row and a
// start COLUMN in cells.
Chord_Item :: struct {
    key:   string,
    label: string,
    row:   int,
    col:   int,
}

// The bar's geometry: the row height, the margin in the units Clay wants it, and how many
// CELLS wide the packing may run. Pure, and the one call the packing and the declaration
// both size themselves from.
chord_geom :: proc(area: Rect, scale, line_h, cell_w: f32) -> (row_h: i32, pad: u16, maxw: int) {
    row_h = i32(line_h) + i32(CHORD_ROW_PAD * scale)
    p := i32(max(0.0, CHORD_PAD * scale))
    pad = u16(p)
    maxw = 1
    if cell_w > 0 {
        maxw = max(1, int(f32(area.w - 2 * p) / cell_w))
    }
    return
}

// Pack the chords plus the state readout into rows `maxw` cells wide, left-flowing with
// CHORD_GAP cells between items. Clay has no flow-wrap, so this stays arithmetic — but it is
// arithmetic OUT of the painter now, which is the point: the wrap is the only interesting
// thing the bar does and it was previously unreachable from a test.
//
// **Widths are counted in RUNES, and the old code counted bytes.** That was written off as
// "close enough" — the only non-ASCII character in the bar is the state readout's "·", which
// spends two bytes on one cell — and it stops being close enough the moment Clay lays the
// row out, because clay_measure_dims measures runes. A packing that thought an item was two
// cells wider than the solver does would wrap a narrow pane one row early, with the two
// disagreeing about a bar they are supposed to be describing together.
chord_pack :: proc(state: string, maxw: int, alloc := context.temp_allocator) -> (items: []Chord_Item, nrows: int) {
    items = make([]Chord_Item, len(CHORD_HINTS) + 1, alloc)
    cur_row, cur_x := 0, 0
    for i in 0 ..< len(items) {
        it: Chord_Item
        w: int
        if i < len(CHORD_HINTS) {
            h := CHORD_HINTS[i]
            it = Chord_Item{key = h[0], label = h[1]}
            w = utf8.rune_count_in_string(h[0]) + 1 + utf8.rune_count_in_string(h[1]) // key + space + label
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
//   ch_bar        the bar, floating at the pane's BOTTOM-left, its own scissor group, and
//                 the one background here
//     ch_row/r    one per packed row, the margin coming from the bar's padding and the
//                 inter-item gap from childGap — cells, so the columns land where the
//                 packing said they would (rule 5: the solver does the arithmetic)
//       ch_item/i "^y yank": the key in accent, its label muted, one cell between them
//       ch_state  the paste mode + marked count, the last item in the flow so it wraps with
//                 everything else
chord_declare :: proc(a: ^App, f: ^Font, area: Rect, now: f64) {
    th := &a.theme
    row_h, pad, maxw := chord_geom(area, a.scale, f.line_height, f.cell_w)
    if area.w <= 0 || row_h <= 0 {
        return
    }
    mode := a.tree.yank_mode == .Cut ? "cut" : "copy"
    items, nrows := chord_pack(fmt.tprintf("[%s · %d marked]", mode, len(a.tree.yanked)), maxw)

    // Opaque lerp out of the pane bg (so no alpha is needed) as Ctrl is held — the Ctrl-hold
    // twin of the switcher's fade, and the same reason it is a lerp rather than an alpha.
    fade := clamp(anim_value(&a.chord_anim, now), 0, 1)
    key_col := lerp3(th.bg, th.accent, fade)
    lbl_col := lerp3(th.bg, th.muted, fade)
    cw := f.cell_w
    lh := i32(f.line_height)

    if clay.UI(clay.ID("ch_bar"))(
        {
            layout = {
                sizing          = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(nrows * int(row_h)))},
                padding         = {left = pad, right = pad},
                layoutDirection = .TopToBottom,
            },
            floating        = clay_overlay_float(.LeftBottom),
            backgroundColor = clay_rgb(lerp3(th.bg, th.border_dark, fade)),
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
                            clay.Text(it.label, clay_text_config(lbl_col, lh))
                        }
                        continue
                    }
                    if clay.UI(clay.ID("ch_item", u32(i)))({layout = {childGap = u16(cw)}}) {
                        clay.Text(it.key, clay_text_config(key_col, lh))
                        clay.Text(it.label, clay_text_config(lbl_col, lh))
                    }
                }
            }
        }
    }
}

// The chord bar alone in a window, as a command list — see switcher_layout for why the pane
// box is declared around it rather than skipped.
chord_layout :: proc(
    a: ^App,
    f: ^Font,
    area: Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        if clay.UI(clay.ID("ft_pane"))(clay_pane_box(area)) {
            chord_declare(a, f, area, now)
        }
    }
    return clay.EndLayout(0)
}
