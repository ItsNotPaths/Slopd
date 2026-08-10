package main

import "core:fmt"
import clay "../bindings/clay"

// The process monitor's UI half — C5c, the fourth pane declared in Clay and the last of
// the "simple" three. procmon.odin keeps the model (the sampler thread, the snapshot, the
// filtered view) and learns nothing about Clay, the theme or the pointer; everything here
// is the part that knows where the pane is and what is under the cursor.
//
// filetree_ui.odin is the template and its header explains the frame order, which is the
// same here and load-bearing for the same reason. Three things are new.
//
//   1. **The first ANIMATED list.** The filetree, grep and config panes jump a row at a
//      time; this one tweens, and the sub-row pixel offset used to be applied by hand to
//      every row's y. In Clay it is the body clip's `childOffset`, which is what that
//      field is for — one number on one element instead of a term in each row's
//      arithmetic. The window is therefore the ANIMATED top, not pm.scroll, and is
//      computed either side of the click (see draw_procmon).
//   2. **The first Custom that is not a text grid.** The graph band is a plot: bars rising
//      from a baseline, one per history sample, at sub-cell widths. It is not chrome and
//      declaring 120 elements for it would be absurd, so it takes the escape hatch the
//      boundary reserves — and it is what made the ClayCustom contract's missing clip
//      parameter worth fixing first (see clay_render.odin).
//   3. **Three hit zones, not one.** A press can land on a process row, a category tab or
//      a signal cell, so procmon_hit returns a tagged ProcHit rather than an index. The
//      zones are mutually exclusive by construction: the signal selector REPLACES the
//      graph band rather than floating over it, exactly as C5b found the config dropdown
//      splices rather than covers, so there is still no occlusion anywhere in this pane.
//
// What deliberately has NO click verb: the kill-arm prompt. It is a confirm gate, and a
// gate you can pass by clicking the thing you were already pointing at is not a gate. It
// stays Enter/y — the keyboard is not the poorer path here, it is the only sensible one.

// Extra vertical padding per row, in logical pixels — the value draw_procmon has always
// used, matching the filetree's density rather than grep's airier blocks. This pane is a
// table, and a table wants its rows close enough to scan down a column.
PM_ROW_PAD :: 2

// The process table's columns, in whole cells, left to right: cpu%, mem, pid, user, name.
// The command takes whatever is left. These were six `x0 + cw * n` locals in draw_procmon
// that the header row and every process row each spelled out separately; as widths they
// are stated once and the header cannot drift from the rows beneath it.
PM_COL_CELLS :: [5]f32{7, 9, 8, 10, 18}

// How many rows the top band claims. The signal selector needs two more than the graphs:
// 31 signals four abreast is eight rows under its header, where a graph is one tab row
// plus the plot.
PM_BAND_ROWS :: 7
PM_SIG_BAND_ROWS :: 9

// Cells of padding either side of a category tab's label, so a tab reads "  cpu  " rather
// than "cpu    ". It has to be a constant rather than a childGap because the padding is
// part of the tab — it is what the hover highlight fills — and a gap is the space between
// two tabs, which belongs to neither and must not light.
PM_TAB_PAD :: 2

// What a press landed on. A tagged union rather than an index because this pane has three
// clickable surfaces and they mean categorically different things — the alternative is a
// sentinel scheme where -1 is "nothing", -2 is "a tab", and every reader has to remember.
Proc_Hit_Kind :: enum {
    None,
    Row, // a process row; `idx` indexes pm.view
    Tab, // a graph category tab; `idx` is the GraphCat
    Signal, // a cell of the signal selector; `idx` is the signal number, 1..31
}

ProcHit :: struct {
    kind: Proc_Hit_Kind,
    idx:  int,
}

// The pane's fixed geometry, and the single source every phase of the frame sizes itself
// from. Pure: no App, no Clay, no GL, so the numbers below are a unit test rather than
// something you confirm by looking.
//
// The band takes a fixed number of rows but never more than the pane can spare — the
// `max(row_h * 2, ...)` floor is what keeps a couple of process rows visible in a short
// pane, and it is why band height is a min of two terms rather than a multiplication.
// The filter bar, when open, claims the bottom row and the list gets one fewer.
//
procmon_geom :: proc(
    pane: Rect,
    scale, line_h: f32,
    sig_open, filtering: bool,
) -> (
    area: Rect,
    row_h: i32,
    band: Rect,
    list: Rect,
    rows: int,
) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(PM_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, {}, {}, 0
    }
    band_rows := i32(sig_open ? PM_SIG_BAND_ROWS : PM_BAND_ROWS)
    band_h := min(row_h * band_rows, max(row_h * 2, area.h - row_h * 3))
    band = Rect{area.x, area.y, area.w, band_h}

    // The column header sits between the band and the list and belongs to neither.
    list_top := area.y + band_h + row_h
    filter_h := filtering ? row_h : 0
    list = Rect{area.x, list_top, area.w, max(0, area.y + area.h - filter_h - list_top)}
    return area, row_h, band, list, max(1, int(list.h / row_h))
}

// Move the viewport to follow the selection, under the shared `scroll_mode` policy. This
// is the write that used to sit in the middle of draw_procmon (`pm.scroll = ...`), which
// meant the pane's scroll position was a side effect of painting.
//
// Note it writes the TARGET only; the animation that chases it is smooth_scroll's, and
// the two are separate on purpose — this is a policy decision (which row should be on top)
// and that is a tween (where is it right now).
procmon_scroll_apply :: proc(pm: ^ProcmonPane, rows: int, center: bool, last_input_at: f64 = 0) {
    list_scroll_apply(&pm.scroll, &pm.scroll_detached, pm.sel, rows, len(pm.view), center, last_input_at)
}

// The visible row window: the animated top row and the sub-row pixel offset the body clip
// shifts its children by. A thin wrapper, but a named one, because every caller has to
// remember that the list's viewport is NOT pm.scroll — that is only where it is heading.
//
// `top` is never negative here: list_scroll_target clamps at zero in both modes and the
// tween runs between two of its outputs, so unlike the diff's centred edge hunks this list
// has no over-scroll and the declaration needs no leading blank slots.
procmon_window :: proc(pm: ^ProcmonPane, now: f64, row_h: i32) -> (top: int, off: i32) {
    return smooth_scroll(&pm.scroll_anim, pm.scroll, now, row_h)
}

// What the pointer is over. Resolves against the tree Clay is still holding — the one the
// LAST frame declared — which is why this runs before this frame's declaration.
//
// The probed window is this frame's, which for an animating list is up to one frame of
// tween away from the one that was painted. That costs a missed click during a fast scroll
// and can never cost a WRONG one: PointerOver answers from last frame's box, so an id that
// resolves is an element the user really was pointing at, and an id that was not declared
// simply reports false.
//
// Only one zone is live at a time, by construction: the signal selector replaces the graph
// band, and while it is open (or a kill is armed) the list beneath it is not clickable —
// the same capture the keyboard applies, so neither path can act on a pane the other has
// locked.
procmon_hit :: proc(pm: ^ProcmonPane, top, rows: int) -> ProcHit {
    if pm.sig_open {
        for s in 1 ..= 31 {
            if clay.PointerOver(clay.ID("pm_sig", u32(s))) {
                return {.Signal, s}
            }
        }
        return {}
    }
    for c in 0 ..< len(GraphCat) {
        if clay.PointerOver(clay.ID("pm_cat", u32(c))) {
            return {.Tab, c}
        }
    }
    if pm.kill_armed {
        return {} // the confirm prompt owns the pane until it is answered
    }
    lo := clamp(top, 0, max(0, len(pm.view)))
    n := max(0, min(len(pm.view) - lo, rows + 1)) // +1: the partial row at the bottom edge
    for k in 0 ..< n {
        i := lo + k
        if clay.PointerOver(clay.ID("pm_row", u32(i))) {
            return {.Row, i}
        }
    }
    return {}
}

// Apply a pending click. Claimed only on a real hit, so a press aimed elsewhere is not
// eaten — see mouse_take_click. Every verb below is one the keyboard already has, reached
// through the same proc, so neither path can grow behaviour the other lacks:
//
//   - a process row: single click selects it (Up/Down) and focuses the list. There is no
//     double-click verb, because the pane has no Enter: `k` and `s` are the row's actions
//     and neither is something to put one impatient double click away.
//   - a category tab: a single click PICKS that graph (Tab / Left / Right, which step).
//     Picking is not selecting, so there is nothing for a second click to activate.
//   - a signal cell: single click arms it (the arrows), double click SENDS it (Enter).
//     This is the pane's one destructive click, and it is deliberately the two-step one.
//
// Intra-pane focus does move here, unlike the wheel: a click on a tab or a row says which
// half of the pane you are working in, and leaving the arrows pointed at the other half
// after you just clicked would be its own surprise. Pane focus (App.focus) is untouched —
// focus-follows-click is C8 and belongs to every pane at once.
procmon_click :: proc(a: ^App, hit: ProcHit) {
    if hit.kind == .None {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    pm := &a.procmon
    switch hit.kind {
    case .None:
    case .Tab:
        procmon_pick_cat(pm, GraphCat(clamp(hit.idx, 0, len(GraphCat) - 1)))
    case .Signal:
        pm.sig_sel = clamp(hit.idx, 1, 31)
        pm.sig_multi = false
        if count >= 2 {
            procmon_sig_send(pm)
        }
    case .Row:
        procmon_select(pm, hit.idx)
        pm.focus = .List
    }
}

// What the graph band's Custom needs. The series is reached through the pane rather than
// copied, so a snapshot swapped in between declaring and painting shows the new bars
// rather than the old ones — both happen inside one frame on the main thread, so there is
// no tear to worry about, only staleness to avoid.
Procmon_Graph :: struct {
    gv: ^GraphView,
}

// The plot: the metric's history as columns rising from the baseline, newest at the right
// edge. The one surface in this pane that is genuinely not chrome — 120 samples at sub-cell
// widths, where a Clay element each would be 120 elements to say "a bar chart".
//
// Everything ELSE in the band is declared: the tabs, the readout, the "unavailable" notice.
// That split is the point of the Custom escape hatch — it is for the pixels no widget tree
// wants to describe, not for a region that happens to look busy.
procmon_paint_graph :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    g := (^Procmon_Graph)(user)
    if g == nil || g.gv == nil || r.h <= 0 || r.w <= 0 {
        return
    }
    bar_col := lerp3(a.theme.bg, a.theme.accent, 0.55)
    colw := f32(r.w) / f32(PROC_HIST)
    right := r.x + r.w
    floor := r.y + r.h
    for age in 0 ..< g.gv.hist.n {
        v := g.gv.hist.vals[(g.gv.hist.head - age + PROC_HIST) % PROC_HIST]
        bh := i32(v * f32(r.h))
        x := right - i32(f32(age + 1) * colw)
        fill(t, Rect{x, floor - bh, max(i32(colw) + 1, 1), bh}, bar_col)
    }
    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, which is the whole reason it is a
    // parameter: a band squeezed by a short pane has a box taller than what may show.
    flush_pane(t, clip, win_w, win_h)
}

// What the filter bar's Custom needs. Same shape as the config pane's search field and for
// the same reason — a caret is an OVER-quad (text.odin), so a live text field cannot be a
// Clay Rectangle plus a Text, which the bridge maps to under-quads.
Procmon_Filter :: struct {
    doc: ^Doc,
    now: f64,
}

// The filter bar's editable half: the query's runes and a block caret. Kept separate from
// config_paint_edit rather than shared with it: that one draws selection spans and a thin
// insertion caret at the glyph's height, this one a bar caret nearly the full row, which
// is what the filter bar has always looked like. Two fields that look different are not a
// duplicated geometry — the scar this refactor deletes is one rect computed twice, not two
// rects that happen to both hold text.
procmon_paint_filter :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    e := (^Procmon_Filter)(user)
    if e == nil || e.doc == nil || len(e.doc.lines) == 0 {
        return
    }
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    ex := f32(r.x)
    text_draw_runes(t, e.doc.lines[0].text[:], ex, f32(r.y) + (f32(r.h) - lh) / 2, th.fg)
    if caret_blink_on(a, e.now) {
        col := e.doc.cursors[e.doc.primary].head.col
        pad := i32(2 * a.scale)
        caret(t, Rect{i32(ex + cw * f32(col)), r.y + pad, max(pad, 1), r.h - 2 * pad}, th.fg)
    }
    flush_pane(t, clip, win_w, win_h)
}

// One row of the process table. The six columns are fixed cell widths plus a growing
// command, so the header and every row are laid out by the same call and cannot disagree
// about where a column starts — which is what the six `x0 + cw * n` locals in draw_procmon
// could not promise.
//
// The cells take Clay's auto id: a click resolves to a ROW, never to a column, so a
// per-cell id scheme would exist only to look like the other panes' named children.
@(private = "file")
procmon_cells :: proc(texts: [6]string, cols: [6][3]f32, cw: f32, lh: i32) {
    for w, c in PM_COL_CELLS {
        if clay.UI()({layout = {sizing = {width = clay.SizingFixed(w * cw)}}}) {
            clay.Text(texts[c], clay_text_config(cols[c], lh))
        }
    }
    clay.Text(texts[5], clay_text_config(cols[5], lh)) // the command, clipped by the body
}

// Declare the pane and hand back the frame's command list. Reads App, writes only Clay —
// no mutation, no GL — which is what lets tests/procmon_ui_test.odin assert the resolved
// boxes without a window. `top` and `off` are passed in rather than recomputed so the
// declaration cannot animate to a different place than the frame decided on.
//
// The tree is:
//   pm_root  full-window container, padded to put the pane where render decided it goes
//     pm_pane   the content area inside the focus ring
//       pm_band    the graph band OR the signal selector — one or the other, never both
//         pm_tabs      the category row
//           pm_cat/i     one per GraphCat, and a hit target
//           pm_read      the current readout, right-aligned
//         pm_plot      the bars, as a Custom (or the "unavailable" notice)
//         pm_sighead   the signal selector's target line
//         pm_sigrow/r  its grid rows
//           pm_sig/s     one per signal 1..31, and a hit target
//       pm_hdr     the column header
//       pm_body    the clip group, offset by the tween's sub-row remainder
//         pm_row/i   one per visible process, keyed by VIEW index
//       pm_filter  the live filter bar, when open
//         pm_fedit   its editable half, as a Custom
procmon_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    top: int,
    off: i32,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    pm := &a.procmon
    th := &a.theme
    area, row_h, band, _, max_rows := procmon_geom(pane, a.scale, f.line_height, pm.sig_open, pm.filtering)
    cw := f.cell_w
    lh := i32(f.line_height)
    half := u16(cw * 0.5)

    // Rows are capped at the pane, not merely grown to it. A long command line is 52 cells
    // of fixed columns plus however much text, which a bare SizingGrow would let push the
    // row WIDER than the pane it sits in — invisible, because the body's clip cuts the
    // paint, but not harmless: the row's box is also its hit box, and a row that reaches
    // past the pane is a row you can click from inside the editor. The overflow itself is
    // wanted (that is how long commands have always trailed off the edge); the growth is
    // not, and the cap is the difference.
    row_w := clay.SizingGrow({max = f32(area.w)})

    n := len(pm.view)
    first := clamp(top, 0, max(0, n))
    // One row more than fits: the tween slides a partial row in at the bottom edge, and
    // the body's clip is what stops it painting past the list.
    visible := max(0, min(n - first, max_rows + 1))

    clay_resize(win_w, win_h)
    clay.BeginLayout()

    if clay.UI(clay.ID("pm_root"))(
        {
            layout = {
                sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))},
                padding = {left = u16(max(0, area.x)), top = u16(max(0, area.y))},
            },
        },
    ) {
        // No background anywhere it is not meant: panel() has already filled the pane and
        // drawn its focus ring, and Clay's transparent default emits no Rectangle at all.
        if clay.UI(clay.ID("pm_pane"))(
            {
                layout = {
                    sizing = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
                    layoutDirection = .TopToBottom,
                },
            },
        ) {
            // The band is tinted as a whole: a faint accent wash when the graphs hold the
            // pane's focus, a danger wash while a signal is armed. Both are the element's
            // own background, where they used to be a fill under everything else.
            band_bg: clay.Color
            if pm.sig_open {
                band_bg = clay_rgb(lerp3(th.bg, th.urgent, 0.10))
            } else if pm.focus == .Graphs && a.focus == .Aux {
                band_bg = clay_rgb(lerp3(th.bg, th.accent, 0.08))
            }

            if clay.UI(clay.ID("pm_band"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingFixed(f32(band.h))},
                        layoutDirection = .TopToBottom,
                    },
                    backgroundColor = band_bg,
                },
            ) {
                if pm.sig_open {
                    procmon_declare_signals(a, cw, lh, row_h, half, row_w)
                } else {
                    procmon_declare_graph(a, cw, lh, row_h, row_w)
                }
            }

            if clay.UI(clay.ID("pm_hdr"))(
                {
                    layout = {
                        sizing = {row_w, clay.SizingFixed(f32(row_h))},
                        padding = {left = u16(cw)}, // the one-cell left margin
                        childAlignment = {y = .Center},
                    },
                },
            ) {
                procmon_cells(
                    {"CPU%", "MEM", "PID", "USER", "NAME", "COMMAND"},
                    {th.muted, th.muted, th.muted, th.muted, th.muted, th.muted},
                    cw,
                    lh,
                )
            }

            if clay.UI(clay.ID("pm_body"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingGrow()},
                        layoutDirection = .TopToBottom,
                    },
                    // The tween's sub-row remainder, as ONE number on ONE element. This is
                    // what childOffset is for, and it replaces the `- off` term that used
                    // to appear in every row's y.
                    clip = {horizontal = true, vertical = true, childOffset = {0, -f32(off)}},
                },
            ) {
                list_focus := pm.focus == .List && a.focus == .Aux
                for k in 0 ..< visible {
                    i := first + k
                    r := &pm.cur.procs[pm.view[i]]

                    // The kill confirm REPLACES its row with a one-key prompt rather than
                    // covering it — the same swap the signal selector makes with the band,
                    // and the reason this pane has no occlusion either.
                    if pm.kill_armed && r.pid == pm.kill_pid {
                        if clay.UI(clay.ID("pm_row", u32(i)))(
                            {
                                layout = {
                                    sizing = {row_w, clay.SizingFixed(f32(row_h))},
                                    padding = {left = u16(cw)},
                                    childAlignment = {y = .Center},
                                },
                                backgroundColor = clay_rgb(th.urgent),
                            },
                        ) {
                            prompt := fmt.tprintf(
                                "kill %s (%d)?   enter/y = confirm    esc = cancel",
                                proc_trunc(r.name, 24),
                                r.pid,
                            )
                            clay.Text(prompt, clay_text_config(th.bg, lh))
                        }
                        continue
                    }

                    bg: clay.Color
                    if i == pm.sel {
                        bg = clay_rgb(list_focus ? th.selection : th.line_highlight)
                    } else if a.hover_on && !pm.kill_armed && pm.hover.kind == .Row && pm.hover.idx == i {
                        bg = clay_rgb(hover_bg(th)) // never competes with the selection
                    }

                    if clay.UI(clay.ID("pm_row", u32(i)))(
                        {
                            layout = {
                                sizing = {row_w, clay.SizingFixed(f32(row_h))},
                                padding = {left = u16(cw)},
                                childAlignment = {y = .Center},
                            },
                            backgroundColor = bg,
                        },
                    ) {
                        // Hot processes are tinted: green past 10% of a core, red past 50%.
                        // Derived here rather than stored on the row, for the same reason
                        // GrepRow dropped its colour field — a snapshot carries no palette.
                        cpu_col := r.cpu_pct >= 50 ? th.urgent : (r.cpu_pct >= 10 ? th.code_return_type : th.fg)
                        procmon_cells(
                            {
                                fmt.tprintf("%5.1f", r.cpu_pct),
                                proc_human_kb(r.rss_kb),
                                fmt.tprintf("%d", r.pid),
                                proc_trunc(r.user, 9),
                                proc_trunc(r.name, 17),
                                r.cmd,
                            },
                            {cpu_col, th.fg, th.muted, th.muted, th.fg, th.muted},
                            cw,
                            lh,
                        )
                    }
                }
            }

            if pm.filtering {
                if clay.UI(clay.ID("pm_filter"))(
                    {
                        layout = {
                            sizing = {row_w, clay.SizingFixed(f32(row_h))},
                            padding = {left = u16(cw)},
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = clay_rgb(th.line_highlight),
                    },
                ) {
                    if clay.UI()({layout = {sizing = {width = clay.SizingFixed(7 * cw)}}}) {
                        clay.Text("filter ", clay_text_config(th.accent, lh))
                    }
                    // The live query: a Custom, because a caret is an over-quad. The two
                    // structs outlive EndLayout in the frame's temp arena.
                    cu := new(ClayCustom, context.temp_allocator)
                    fe := new(Procmon_Filter, context.temp_allocator)
                    fe^ = {doc = &pm.filter, now = now}
                    cu^ = {paint = procmon_paint_filter, user = fe}
                    if clay.UI(clay.ID("pm_fedit"))(
                        {
                            layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                            custom = {customData = cu},
                        },
                    ) {}
                }
            }
        }
    }

    return clay.EndLayout(0)
}

@(private = "file")
procmon_declare_graph :: proc(a: ^App, cw: f32, lh, row_h: i32, row_w: clay.SizingAxis) {
    pm := &a.procmon
    th := &a.theme
    gv := procmon_graphview(pm)
    cats := [4]string{"cpu", "mem", "disk", "gpu"}

    if clay.UI(clay.ID("pm_tabs"))(
        {
            layout = {
                sizing = {row_w, clay.SizingFixed(f32(row_h))},
                padding = {left = u16(cw), right = u16(cw)},
                childAlignment = {y = .Center},
            },
        },
    ) {
        for name, i in cats {
            // Each tab is its own element so it can be hit, and its padding is SYMMETRIC:
            // PM_TAB_PAD cells either side of the label, centred by the solver rather than
            // by a start offset. The hand-drawn version advanced by `len + 2` from a flush
            // left edge, which put all of the slack after the word — invisible while a tab
            // was only ever text, and wrong the moment one could light up, because the
            // highlight read as "cpu    " with the label jammed against its leading edge.
            lit := GraphCat(i) == pm.cat
            bg: clay.Color
            if a.hover_on && pm.hover.kind == .Tab && pm.hover.idx == i && !lit {
                bg = clay_rgb(hover_bg(th))
            }
            if clay.UI(clay.ID("pm_cat", u32(i)))(
                {
                    layout = {
                        sizing = {
                            clay.SizingFixed(f32(len(name) + 2 * PM_TAB_PAD) * cw),
                            clay.SizingGrow(),
                        },
                        childAlignment = {x = .Center, y = .Center},
                    },
                    backgroundColor = bg,
                },
            ) {
                clay.Text(name, clay_text_config(lit ? th.fg : th.muted, lh))
            }
        }
        // The readout, right-aligned by the solver rather than by
        // `band.x + band.w - cw - cw * len(label)`.
        if gv.label != "" {
            if clay.UI(clay.ID("pm_read"))(
                {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Right, y = .Center}}},
            ) {
                clay.Text(gv.label, clay_text_config(th.accent, lh))
            }
        }
    }

    if !gv.avail {
        // Not every machine has a GPU to read. A notice is chrome, so it stays declared.
        if clay.UI(clay.ID("pm_plot"))(
            {
                layout = {
                    sizing = {clay.SizingGrow(), clay.SizingGrow()},
                    padding = {left = u16(cw)},
                    childAlignment = {y = .Center},
                },
            },
        ) {
            clay.Text("unavailable", clay_text_config(th.muted, lh))
        }
        return
    }

    cu := new(ClayCustom, context.temp_allocator)
    g := new(Procmon_Graph, context.temp_allocator)
    g^ = {gv = gv}
    cu^ = {paint = procmon_paint_graph, user = g}
    if clay.UI(clay.ID("pm_plot"))(
        {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = {customData = cu}},
    ) {}
}

// The signal selector, which REPLACES the graph band (btop-style) rather than floating
// over it: a header naming the target, then signals 1..31 four abreast with the armed one
// highlighted.
//
// The half-cell offsets are the one piece of arithmetic worth explaining. The hand-drawn
// version put each label at `x0 + col * cellw` and its highlight half a cell to the LEFT of
// that, so the bar has a lip either side of the text. Here the grid row is indented by half
// a cell and each cell pads its label by the other half, which lands the label on exactly
// the same pixel while making the highlight the cell's own background — a property of the
// element rather than a rect drawn near it.
@(private = "file")
procmon_declare_signals :: proc(a: ^App, cw: f32, lh, row_h: i32, half: u16, row_w: clay.SizingAxis) {
    pm := &a.procmon
    th := &a.theme
    cellw := cw * 13

    if clay.UI(clay.ID("pm_sighead"))(
        {
            layout = {
                sizing = {row_w, clay.SizingFixed(f32(row_h))},
                padding = {left = u16(cw)},
                childAlignment = {y = .Center},
            },
        },
    ) {
        name := ""
        if pm.sel >= 0 && pm.sel < len(pm.view) {
            name = pm.cur.procs[pm.view[pm.sel]].name
        }
        head := fmt.tprintf("signal -> %s (%d)   enter=send  q=cancel", name, procmon_sel_pid(pm))
        clay.Text(head, clay_text_config(th.fg, lh))
    }

    rows := (31 + SIG_COLS - 1) / SIG_COLS
    for r in 0 ..< rows {
        if clay.UI(clay.ID("pm_sigrow", u32(r)))(
            {
                layout = {
                    sizing = {row_w, clay.SizingFixed(f32(row_h))},
                    padding = {left = half},
                    childAlignment = {y = .Center},
                },
            },
        ) {
            for c in 0 ..< SIG_COLS {
                s := r * SIG_COLS + c + 1
                if s > 31 {
                    break
                }
                armed := s == pm.sig_sel
                bg: clay.Color
                if armed {
                    bg = clay_rgb(th.accent)
                } else if a.hover_on && pm.hover.kind == .Signal && pm.hover.idx == s {
                    bg = clay_rgb(hover_bg(th))
                }
                if clay.UI(clay.ID("pm_sig", u32(s)))(
                    {
                        layout = {
                            sizing = {clay.SizingFixed(cellw), clay.SizingGrow()},
                            padding = {left = u16(cw) - half},
                            childAlignment = {y = .Center},
                        },
                        backgroundColor = bg,
                    },
                ) {
                    clay.Text(
                        fmt.tprintf("%2d %s", s, SIG_NAMES[s]),
                        clay_text_config(armed ? th.bg : th.fg, lh),
                    )
                }
            }
        }
    }
}

// The procmon (process monitor) aux mode: a GRAPH BAND up top (a tab-enum of CPU / Memory
// / Disk / GPU history graphs, or the signal selector when armed) over a btop-style
// PROCESS LIST (cpu% / mem / pid / user / name / command). Data is the lock-free snapshot
// drained from the sampler thread (procmon.odin); this only reads pm.cur + pm.view.
// Up/Down move the selection, crossing into the band at the top (procmon_key); Space opens
// the bottom filter bar. A click selects a process, picks a graph category, or arms a
// signal — and a double click on a signal sends it.
//
// The window is computed TWICE, either side of the click, and that is not redundancy. The
// first call answers "what did the user press on", against the tween as it stood; the click
// may then move the selection, and procmon_scroll_apply re-aims the viewport at it. The
// second call is what re-aims the ANIMATION — and app_next_wake schedules the next frame
// off that anim being active, so skipping it would leave the list frozen part-scrolled
// until an unrelated event woke the loop. C5b's config pane flattens twice for the same
// class of reason: a click that changes the list has to be bracketed, not followed.
draw_procmon :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    pm := &a.procmon
    area, row_h, _, _, max_rows := procmon_geom(pane, a.scale, t.font.line_height, pm.sig_open, pm.filtering)
    if area.w <= 0 || area.h <= 0 {
        return
    }

    top, _ := procmon_window(pm, now, row_h)
    hit := procmon_hit(pm, top, max_rows)
    pm.hover = hit // resolved against the same (last) frame the click is
    procmon_click(a, hit)

    procmon_scroll_apply(pm, max_rows, a.scroll_mode == .Middle, pane_input_at(a))
    off: i32
    top, off = procmon_window(pm, now, row_h)

    cmds := procmon_layout(a, &t.font, pane, top, off, win_w, win_h, now)
    clay_paint(t, a, &cmds, area, win_w, win_h)
}
