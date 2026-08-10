package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// C5c: the process monitor declared in Clay. The three panes before it proved a flat list
// (filetree), one item spanning several rows (grep) and rows that select nothing (config).
// What is new here — and therefore what these assertions are about — is:
//
//   - a list that ANIMATES, so the viewport is the tween's floored top plus a sub-row pixel
//     offset, expressed as the body clip's childOffset rather than as a term in every row;
//   - a Custom that is NOT a text grid (the graph plot), which is the last cheap place to
//     find the ClayCustom contract under-specified before C7 hands it the editor;
//   - three hit zones in one pane (rows, category tabs, signal cells), mutually exclusive
//     because the selector REPLACES the band rather than covering it.
//
// The pane used throughout is {100, 50, 700, 400} at scale 1 with the synthetic 10x16 font:
// a content area of {102, 52, 696, 396} and an 18px row (16px line + 2px PM_ROW_PAD). It is
// deliberately wide, because the process table's six columns span 52 cells and a narrow
// pane would clip the assertions rather than test them.
//
// Derived by hand, and every box below is checked against these:
//   band  7 rows = 126px at y=52       column header at y=178
//   list  from y=196, 252px tall -> 14 rows

@(private = "file")
PANE :: app.Rect{100, 50, 700, 400}
@(private = "file")
AREA :: app.Rect{102, 52, 696, 396}
@(private = "file")
ROW_H :: 18
@(private = "file")
BAND_H :: 126
@(private = "file")
LIST_Y :: AREA.y + BAND_H + ROW_H // 196
@(private = "file")
MAX_ROWS :: 14

// The six column x positions, in framebuffer pixels: a one-cell margin then the cumulative
// PM_COL_CELLS widths {7, 9, 8, 10, 18}. Pinned here because the header row and every
// process row are asserted against the SAME numbers — which is the whole claim of moving
// the columns into one declaration.
@(private = "file")
X_CPU :: AREA.x + 10
@(private = "file")
X_MEM :: X_CPU + 70
@(private = "file")
X_PID :: X_MEM + 90
@(private = "file")
X_USER :: X_PID + 80
@(private = "file")
X_NAME :: X_USER + 100
@(private = "file")
X_CMD :: X_NAME + 180

// A pane with `n` synthetic processes, in view order. The strings are LITERALS and the
// snapshot is torn down with plain `delete` — never procmon_snapshot_free, which frees
// every owned string and would be freeing static storage here. procmon_init is likewise
// avoided on purpose: it starts the /proc sampler thread, and none of this needs a machine.
@(private = "file")
fixture :: proc(a: ^app.App, n: int) {
    a.scale = 1
    a.theme = app.default_theme() // a zero App's palette is all black, which hides colour bugs
    pm := &a.procmon
    app.doc_init(&pm.filter)
    names := [?]string{"alpha", "beta", "gamma", "delta", "epsilon"}
    for i in 0 ..< n {
        append(
            &pm.cur.procs,
            app.ProcRow {
                pid     = 100 + i,
                name    = names[i % len(names)],
                cmd     = "/usr/bin/thing --flag",
                user    = "paths",
                rss_kb  = 2048,
                cpu_pct = f32(i),
            },
        )
        append(&pm.view, i)
    }
    pm.cur.cpu.avail = true
    pm.cur.cpu.label = "12%"
    pm.cur.cpu.hist.n = 2
    pm.cur.cpu.hist.head = 1
    pm.cur.cpu.hist.vals[0] = 0.5
    pm.cur.cpu.hist.vals[1] = 1.0
}

@(private = "file")
teardown :: proc(a: ^app.App) {
    app.doc_destroy(&a.procmon.filter)
    delete(a.procmon.cur.procs)
    delete(a.procmon.view)
}

// The geometry every phase of the frame sizes itself from. The band's height is a MIN of
// two terms and the second one is the interesting half: a short pane gives the band what it
// can spare rather than what it asked for, so a couple of process rows always survive.
@(test)
test_procmon_geom :: proc(t: ^testing.T) {
    area, row_h, band, list, rows := app.procmon_geom(PANE, 1, 16, false, false)
    testing.expect_value(t, area, AREA)
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, band, app.Rect{AREA.x, AREA.y, AREA.w, BAND_H})
    testing.expect_value(t, list, app.Rect{AREA.x, LIST_Y, AREA.w, 252})
    testing.expect_value(t, rows, MAX_ROWS)

    // The signal selector needs two more rows than the graphs: 31 signals four abreast is
    // eight grid rows under its header, where a graph is one tab row plus the plot.
    _, _, sband, slist, srows := app.procmon_geom(PANE, 1, 16, true, false)
    testing.expect_value(t, sband.h, i32(9 * ROW_H))
    testing.expect_value(t, slist, app.Rect{AREA.x, AREA.y + 9 * ROW_H + ROW_H, AREA.w, 216})
    testing.expect_value(t, srows, 12)

    // The filter bar claims the bottom row, and the list gets exactly one fewer.
    _, _, _, flist, frows := app.procmon_geom(PANE, 1, 16, false, true)
    testing.expect_value(t, flist.h, i32(252 - ROW_H))
    testing.expect_value(t, frows, MAX_ROWS - 1)

    // A pane too short for a 7-row band: the band shrinks to what is left over three list
    // rows, rather than the list vanishing under it.
    _, _, tband, _, trows := app.procmon_geom(app.Rect{100, 50, 700, 150}, 1, 16, false, false)
    testing.expect_value(t, tband.h, i32(146 - 3 * ROW_H)) // 92, not 126
    testing.expect(t, trows >= 1, "a short pane must still show a list row")

    _, _, _, _, none := app.procmon_geom(app.Rect{}, 1, 16, false, false)
    testing.expect_value(t, none, 0)
}

// The end-to-end claim: the declared tree resolves to the columns the hand-drawn pane used.
// The header and the rows are asserted against the same six constants, which is what makes
// "the header cannot drift from the rows" a fact rather than a comment.
@(test)
test_procmon_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 3)
    defer teardown(&a)
    a.focus = .Aux
    a.procmon.focus = .List
    a.procmon.sel = 1

    cmds := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)

    hdr: [6]i32 = {-1, -1, -1, -1, -1, -1}
    cell: [6]i32 = {-1, -1, -1, -1, -1, -1}
    row_y: [3]i32 = {-1, -1, -1}
    sel_box: app.Rect
    rects, scissors := 0, 0
    body: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .ScissorStart:
            scissors += 1
            if c.id == clay.ID("pm_body").id {
                body = r
            }
        case .Rectangle:
            rects += 1
            if c.id == clay.ID("pm_row", 1).id {
                sel_box = r
            }
        case .Text:
            d := c.renderData.text
            s := string(d.stringContents.chars[:d.stringContents.length])
            switch s {
            case "CPU%":
                hdr[0] = r.x
            case "MEM":
                hdr[1] = r.x
            case "PID":
                hdr[2] = r.x
            case "USER":
                hdr[3] = r.x
            case "NAME":
                hdr[4] = r.x
            case "COMMAND":
                hdr[5] = r.x
            case "000.0":
                cell[0] = r.x;row_y[0] = r.y
            case "2 MB":
                cell[1] = r.x
            case "100":
                cell[2] = r.x
            case "paths":
                cell[3] = r.x
            case "alpha":
                cell[4] = r.x
            case "/usr/bin/thing --flag":
                cell[5] = r.x
            case "001.0":
                row_y[1] = r.y
            case "002.0":
                row_y[2] = r.y
            }
        }
    }

    testing.expect_value(t, hdr, [6]i32{X_CPU, X_MEM, X_PID, X_USER, X_NAME, X_CMD})
    testing.expect_value(t, cell, [6]i32{X_CPU, X_MEM, X_PID, X_USER, X_NAME, X_CMD})

    // Two clip groups: the pane's own (C8a) and the list body, which starts under the
    // column header. `body` is captured by id, so the count is the only thing that changed.
    testing.expect_value(t, scissors, 2)
    testing.expect_value(t, body, app.Rect{AREA.x, LIST_Y, AREA.w, 252})

    // Rows stack on the grid from the top of the body, and the text is centred in each.
    testing.expect_value(t, row_y[0], i32(LIST_Y + 1)) // (18 - 16) / 2
    testing.expect_value(t, row_y[1], i32(LIST_Y + ROW_H + 1))
    testing.expect_value(t, row_y[2], i32(LIST_Y + 2 * ROW_H + 1))

    // Exactly one band: the selected row. Nothing else in the tree fills, because panel()
    // has already painted the pane and Clay's transparent default emits no Rectangle — the
    // graph band's focus tint is off here (the LIST holds focus).
    testing.expect_value(t, rects, 1)
    testing.expect_value(t, sel_box, app.Rect{AREA.x, LIST_Y + ROW_H, AREA.w, ROW_H})
}

// The graph band: tabs on the grid, the readout right-aligned by the solver rather than by
// `band.x + band.w - cw - cw * len(label)`, and the plot as a Custom below them.
@(test)
test_procmon_graph_band :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 2)
    defer teardown(&a)

    cmds := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)

    tabs: [4]i32 = {-1, -1, -1, -1}
    label_x, tab_y: i32 = -1, -1
    customs := 0
    plot: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            plot = r
        case .Text:
            d := c.renderData.text
            switch string(d.stringContents.chars[:d.stringContents.length]) {
            case "cpu":
                tabs[0] = r.x;tab_y = r.y
            case "mem":
                tabs[1] = r.x
            case "disk":
                tabs[2] = r.x
            case "gpu":
                tabs[3] = r.x
            case "12%":
                label_x = r.x
            }
        }
    }

    // Each tab is its label plus PM_TAB_PAD cells EITHER SIDE, with the label centred by the
    // solver — so the boxes tile from the margin at 70/70/80/70 px and each label sits two
    // cells in. That symmetry is the whole point: the box is what the hover highlight fills,
    // and a label jammed against its leading edge reads as "cpu    " rather than "  cpu  ".
    testing.expect_value(t, tabs, [4]i32{AREA.x + 30, AREA.x + 100, AREA.x + 170, AREA.x + 250})
    testing.expect_value(t, tab_y, i32(AREA.y + 1))

    // The readout ends one cell short of the pane's right edge: 3 runes at 10px, so it
    // starts 40px back from 798.
    testing.expect_value(t, label_x, i32(AREA.x + AREA.w - 10 - 30))

    // The plot is a Custom filling the band under the tab row. This is the first Custom in
    // the refactor that is not a text grid, and the box it gets is the whole contract.
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, plot, app.Rect{AREA.x, AREA.y + ROW_H, AREA.w, BAND_H - ROW_H})
}

// A metric this machine cannot report is a NOTICE, not an empty plot — and a notice is
// chrome, so it stays declared rather than being drawn by the painter. That split is the
// point of the escape hatch: it is for pixels no widget tree wants to describe.
@(test)
test_procmon_unavailable_is_not_a_custom :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 1)
    defer teardown(&a)
    a.procmon.cat = .GPU // the fixture leaves gpu unavailable, as a machine without one does

    cmds := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)

    customs, notices := 0, 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
        case .Text:
            d := c.renderData.text
            if string(d.stringContents.chars[:d.stringContents.length]) == "unavailable" {
                notices += 1
            }
        }
    }
    testing.expect_value(t, customs, 0)
    testing.expect_value(t, notices, 1)
}

// The tween's sub-row remainder is the body clip's childOffset — ONE number on ONE element,
// where the hand-drawn pane subtracted `off` from every row's y. This is the assertion that
// the two are the same thing: rows shift up by exactly `off`, and the clip does not.
@(test)
test_procmon_smooth_scroll_offset :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 40)
    defer teardown(&a)

    row_y :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), id: u32) -> i32 {
        for i in 0 ..< cmds.length {
            c := clay.RenderCommandArray_Get(cmds, i)
            if c.commandType == .Rectangle && c.id == clay.ID("pm_row", id).id {
                return app.clay_rect(c.boundingBox).y
            }
        }
        return -1
    }

    a.procmon.sel = 5 // give row 5 a band, so it is findable as a Rectangle
    settled := app.procmon_layout(&a, &f, PANE, 5, 0, 900, 500)
    testing.expect_value(t, row_y(&settled, 5), i32(LIST_Y))

    // Mid-tween: seven pixels into the row, everything rides up by seven.
    moving := app.procmon_layout(&a, &f, PANE, 5, 7, 900, 500)
    testing.expect_value(t, row_y(&moving, 5), i32(LIST_Y - 7))

    // The clip is NOT offset — only its children are. A body that moved with them would
    // let the partial row paint over the column header. Matched by id since C8a: the pane
    // declares a clip of its own, and it starts at the top of the pane, not at the list.
    for i in 0 ..< moving.length {
        c := clay.RenderCommandArray_Get(&moving, i)
        if c.commandType == .ScissorStart && c.id == clay.ID("pm_body").id {
            testing.expect_value(t, app.clay_rect(c.boundingBox).y, i32(LIST_Y))
        }
    }

    // One row more than fits is declared, so the tween has a partial row to slide in at the
    // bottom edge rather than a gap. Counted by the user column, which every process row has
    // and nothing else in the pane does — the band's "cpu" tab and the header's "CPU%" both
    // sit at the first column's x, so an x test would count chrome as rows.
    n := 0
    for i in 0 ..< moving.length {
        c := clay.RenderCommandArray_Get(&moving, i)
        if c.commandType != .Text {
            continue
        }
        d := c.renderData.text
        if string(d.stringContents.chars[:d.stringContents.length]) == "paths" {
            n += 1
        }
    }
    testing.expect_value(t, n, MAX_ROWS + 1)
}

// A hit resolves to a VIEW index, WITH THE LIST SCROLLED — the case that separates a real
// index from a visible-row index, which agree only at the top and so hide the bug.
@(test)
test_procmon_hit_with_scroll :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 40)
    defer teardown(&a)
    pm := &a.procmon

    hit_at :: proc(a: ^app.App, f: ^app.Font, top: int, visible_row: int) -> app.ProcHit {
        _ = app.procmon_layout(a, f, PANE, top, 0, 900, 500) // frame 1: give Clay boxes
        clay.SetPointerState({f32(X_NAME), f32(LIST_Y + i32(visible_row) * ROW_H + 4)}, false)
        _ = app.procmon_layout(a, f, PANE, top, 0, 900, 500)
        return app.procmon_hit(&a.procmon, top, MAX_ROWS)
    }

    // Scrolled to row 8: the third visible row is process 10, not process 2.
    testing.expect_value(t, hit_at(&a, &f, 8, 2), app.ProcHit{.Row, 10})
    testing.expect_value(t, hit_at(&a, &f, 8, 0), app.ProcHit{.Row, 8})

    // The column header is above the body, and below the last row is nothing.
    _ = app.procmon_layout(&a, &f, PANE, 8, 0, 900, 500)
    clay.SetPointerState({f32(X_NAME), f32(AREA.y + BAND_H + 4)}, false)
    _ = app.procmon_layout(&a, &f, PANE, 8, 0, 900, 500)
    testing.expect_value(t, app.procmon_hit(pm, 8, MAX_ROWS).kind, app.Proc_Hit_Kind.None)

    clay.SetPointerState({f32(X_NAME), f32(AREA.y + AREA.h + 30)}, false)
    _ = app.procmon_layout(&a, &f, PANE, 8, 0, 900, 500)
    testing.expect_value(t, app.procmon_hit(pm, 8, MAX_ROWS).kind, app.Proc_Hit_Kind.None)
}

// Three hit zones in one pane, and they are mutually exclusive by construction: the signal
// selector REPLACES the graph band, so there is no occlusion to arbitrate and no overlay to
// probe first. While it is open — or a kill is armed — the list beneath is captured exactly
// as it is for the keyboard.
@(test)
test_procmon_hit_zones :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 20)
    defer teardown(&a)
    pm := &a.procmon

    probe :: proc(a: ^app.App, f: ^app.Font, x, y: f32) -> app.ProcHit {
        _ = app.procmon_layout(a, f, PANE, 0, 0, 900, 500)
        clay.SetPointerState({x, y}, false)
        _ = app.procmon_layout(a, f, PANE, 0, 0, 900, 500)
        return app.procmon_hit(&a.procmon, 0, MAX_ROWS)
    }

    // A category tab, by its own id. The boxes tile 70/70/80/70 from the one-cell margin,
    // so "disk" owns [x+150, x+230) — and the PADDING is part of the target, which is the
    // point of probing 10px inside the box rather than on the label.
    testing.expect_value(
        t,
        probe(&a, &f, f32(AREA.x + 160), f32(AREA.y + 8)),
        app.ProcHit{.Tab, int(app.GraphCat.Disk)},
    )
    testing.expect_value(
        t,
        probe(&a, &f, f32(AREA.x + 115), f32(AREA.y + 8)),
        app.ProcHit{.Tab, int(app.GraphCat.Memory)},
    )
    // The plot under the tabs is not a target: a graph has nothing to point at.
    testing.expect_value(t, probe(&a, &f, f32(AREA.x + 115), f32(AREA.y + 60)).kind, app.Proc_Hit_Kind.None)

    // With the selector open, the band is a 1..31 grid. Signal 6 is row 1, column 1:
    // x = 102 + 5 + 130, y = 52 + 18 + 18.
    pm.sig_open = true
    testing.expect_value(t, probe(&a, &f, f32(AREA.x + 140), f32(AREA.y + 40)), app.ProcHit{.Signal, 6})
    testing.expect_value(t, probe(&a, &f, f32(AREA.x + 20), f32(AREA.y + 22)), app.ProcHit{.Signal, 1})

    // ...and the list underneath it is not clickable while it is up.
    testing.expect_value(
        t,
        probe(&a, &f, f32(X_NAME), f32(AREA.y + 9 * ROW_H + ROW_H + 4)).kind,
        app.Proc_Hit_Kind.None,
    )
    pm.sig_open = false

    // An armed kill owns the pane the same way: the prompt is answered with Enter/y, and a
    // click on the row you were already pointing at is not a confirmation of anything.
    pm.kill_armed = true
    pm.kill_pid = 100
    testing.expect_value(t, probe(&a, &f, f32(X_NAME), f32(LIST_Y + 3 * ROW_H + 4)).kind, app.Proc_Hit_Kind.None)
}

// The verb half. Every one of these is a proc the keyboard also reaches, and the claim
// rules are the filetree's: a press is taken only when it hit something of this pane's.
@(test)
test_procmon_click :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 20)
    defer teardown(&a)
    a.mouse_on = true
    pm := &a.procmon

    // A row: single click selects it and focuses the list. The pid comes with it, which is
    // what keeps the selection on the same process across a re-sort.
    pm.focus = .Graphs
    a.mouse.click, a.mouse.click_count = true, 1
    app.procmon_click(&a, app.ProcHit{.Row, 4})
    testing.expect_value(t, pm.sel, 4)
    testing.expect_value(t, pm.sel_pid, 104)
    testing.expect_value(t, pm.focus, app.ProcFocus.List)
    testing.expect(t, !a.mouse.click, "a click that hit a row must be claimed")

    // A press that hit nothing is left for whoever else is drawing — the one-noun rule.
    a.mouse.click = true
    app.procmon_click(&a, app.ProcHit{})
    testing.expect_value(t, pm.sel, 4)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // A tab PICKS a category, where the keyboard steps through them, and focus follows.
    a.mouse.click, a.mouse.click_count = true, 1
    app.procmon_click(&a, app.ProcHit{.Tab, int(app.GraphCat.Disk)})
    testing.expect_value(t, pm.cat, app.GraphCat.Disk)
    testing.expect_value(t, pm.focus, app.ProcFocus.Graphs)

    // A signal cell ARMS on a single click. This is the pane's one destructive control, so
    // it stays a two-step gesture — nothing has been sent here.
    pm.sig_open = true
    a.mouse.click, a.mouse.click_count = true, 1
    app.procmon_click(&a, app.ProcHit{.Signal, 15})
    testing.expect_value(t, pm.sig_sel, 15)
    testing.expect(t, pm.sig_open, "a single click on a signal must not send it")

    // With the mouse configured off, nothing is claimed and nothing moves.
    a.mouse_on = false
    a.mouse.click = true
    app.procmon_click(&a, app.ProcHit{.Row, 9})
    testing.expect_value(t, pm.sel, 4)
}

// Typing a signal number. The leading-zero case is the one that was broken and it is the
// dangerous kind of broken: "0" armed signal 1 and started a multi-digit run, so "09" —
// which every user means as 9, SIGKILL — computed 1*10+9 and armed 19, SIGSTOP. Asking for
// a kill and getting a stop is a wrong signal sent to a real process.
@(test)
test_procmon_sig_digit :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 2)
    defer teardown(&a)
    pm := &a.procmon

    // Typed as one run: each digit a tenth of a second after the last, well inside
    // PROC_SIG_RUN_S. The timeout gets its own test below.
    type_in :: proc(pm: ^app.ProcmonPane, digits: ..int) -> int {
        pm.sig_sel, pm.sig_multi, pm.sig_typed_at = 9, false, 0 // as procmon_key leaves it on `s`
        for d, i in digits {
            app.procmon_sig_digit(pm, d, f64(i) * 0.1)
        }
        return pm.sig_sel
    }

    // The bug, as reported: a leading zero must not count, so these are 9 and 5.
    testing.expect_value(t, type_in(pm, 0, 9), 9)
    testing.expect_value(t, type_in(pm, 0, 5), 5)
    // ...and a lone "0" arms nothing at all, rather than silently becoming signal 1.
    testing.expect_value(t, type_in(pm, 0), 9)
    testing.expect(t, !pm.sig_multi, "a leading zero must not start a run")

    // Everything that already worked still does.
    testing.expect_value(t, type_in(pm, 1, 5), 15)
    testing.expect_value(t, type_in(pm, 1, 0), 10) // a zero INSIDE a run is a real digit
    testing.expect_value(t, type_in(pm, 3, 0), 30)
    testing.expect_value(t, type_in(pm, 3, 1), 31)
    testing.expect_value(t, type_in(pm, 7), 7)

    // A run that would overshoot restarts from the digit just typed: "3" then "5" is 35,
    // which is not a signal, so it arms 5 rather than clamping to 31.
    testing.expect_value(t, type_in(pm, 3, 5), 5)

    // An arrow ends the run, so the next digit starts a fresh number instead of extending.
    pm.sig_sel, pm.sig_multi = 1, true
    app.procmon_sig_move(pm, 0)
    app.procmon_sig_digit(pm, 5, 0)
    testing.expect_value(t, pm.sig_sel, 5)
}

// A multi-digit run EXPIRES. Without it the run only ever ended on an arrow key, so a "1"
// typed and forgotten about turned the next "5" into 15 — the same class of wrong signal as
// the leading-zero bug, just reached by walking away instead of by typing a zero.
@(test)
test_procmon_sig_digit_run_expires :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 2)
    defer teardown(&a)
    pm := &a.procmon

    // Inside the window, the two digits are one number.
    pm.sig_sel, pm.sig_multi, pm.sig_typed_at = 9, false, 0
    app.procmon_sig_digit(pm, 1, 100)
    app.procmon_sig_digit(pm, 5, 100 + app.PROC_SIG_RUN_S - 0.5)
    testing.expect_value(t, pm.sig_sel, 15)

    // Past it, the second digit is a number of its own.
    pm.sig_sel, pm.sig_multi, pm.sig_typed_at = 9, false, 0
    app.procmon_sig_digit(pm, 1, 100)
    app.procmon_sig_digit(pm, 5, 100 + app.PROC_SIG_RUN_S + 0.5)
    testing.expect_value(t, pm.sig_sel, 5)

    // And an expired run makes a following zero a LEADING zero again, so it is ignored
    // rather than extending a number that timed out three seconds ago.
    pm.sig_sel, pm.sig_multi, pm.sig_typed_at = 9, false, 0
    app.procmon_sig_digit(pm, 3, 100)
    testing.expect_value(t, pm.sig_sel, 3)
    app.procmon_sig_digit(pm, 0, 100 + app.PROC_SIG_RUN_S + 0.5)
    testing.expect_value(t, pm.sig_sel, 3) // not 30
    testing.expect(t, !pm.sig_multi, "an ignored leading zero must not re-arm the run")
}

// The armed signal walks a CLOSED choice: clamped at both ends rather than stepping out of
// the grid, which is the distinction config's two dropdown kinds draw. One proc serves the
// selector's arrows and a wheel notch over it, which is what let wheel_apply stop refusing.
@(test)
test_procmon_sig_move :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 2)
    defer teardown(&a)
    pm := &a.procmon

    pm.sig_sel = 9
    pm.sig_multi = true
    app.procmon_sig_move(pm, 4)
    testing.expect_value(t, pm.sig_sel, 13)
    testing.expect(t, !pm.sig_multi, "a move must end a multi-digit run")

    app.procmon_sig_move(pm, 99)
    testing.expect_value(t, pm.sig_sel, 31)
    app.procmon_sig_move(pm, -99)
    testing.expect_value(t, pm.sig_sel, 1)
}

// A notch means different things in the two halves of this pane, and which half it landed
// in is answered by the tree Clay is holding rather than by a second copy of the geometry.
@(test)
test_procmon_wheel_by_region :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 20)
    defer teardown(&a)
    a.mouse_on = true
    a.aux_mode = .Procmon // wheel_apply's .List branch dispatches on which list is showing
    pm := &a.procmon

    point_at :: proc(a: ^app.App, f: ^app.Font, x, y: f32) {
        _ = app.procmon_layout(a, f, PANE, 0, 0, 900, 500)
        clay.SetPointerState({x, y}, false)
        _ = app.procmon_layout(a, f, PANE, 0, 0, 900, 500)
    }

    // Over the list: the notch scrolls the VIEW and leaves the selection alone.
    pm.sel = 5
    point_at(&a, &f, f32(X_NAME), f32(LIST_Y + 4 * ROW_H))
    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, pm.scroll, app.WHEEL_LINES)
    testing.expect_value(t, pm.sel, 5) // the cursor did not move

    // Over the graph band: nothing. A graph is a picture, not a viewport — scrolling the
    // list from up there would move something the pointer is nowhere near.
    point_at(&a, &f, f32(AREA.x + 200), f32(AREA.y + 60))
    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, pm.scroll, app.WHEEL_LINES)

    // With the selector open, a notch over the band walks the signal grid...
    pm.sig_open = true
    pm.sig_sel = 9
    point_at(&a, &f, f32(AREA.x + 200), f32(AREA.y + 60))
    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, pm.sig_sel, 9 + app.WHEEL_LINES)
    testing.expect_value(t, pm.scroll, app.WHEEL_LINES) // and the list stayed put

    // ...while one over the list still scrolls it. The selector captures the KEYBOARD,
    // because its keys would otherwise arm and send; a view scroll can do neither, so
    // there is nothing here for a capture to protect.
    point_at(&a, &f, f32(X_NAME), f32(AREA.y + 9 * ROW_H + ROW_H + 4))
    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, pm.scroll, 2 * app.WHEEL_LINES)
    testing.expect_value(t, pm.sig_sel, 9 + app.WHEEL_LINES)
}

// The detach in the round: a notch moves the view, the policy leaves it alone while
// detached, and the pane's own next keystroke puts it back on the selection.
@(test)
test_procmon_scroll_detach_roundtrip :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 40)
    defer teardown(&a)
    pm := &a.procmon
    pm.sel = 0

    app.list_scroll_by(&pm.scroll, &pm.scroll_detached, 12, 100)
    testing.expect_value(t, pm.scroll, 12)

    // Attached, the FOLLOW policy would have pulled the top back to the selection at row 0.
    // Detached, it does not run at all — and MIDDLE does not either, which is the whole
    // reason the detach exists rather than a "move the view" branch inside the policy.
    app.procmon_scroll_apply(pm, MAX_ROWS, false, 0)
    testing.expect_value(t, pm.scroll, 12)
    app.procmon_scroll_apply(pm, MAX_ROWS, true, 0)
    testing.expect_value(t, pm.scroll, 12)

    // A keystroke that POSTDATES the gesture re-attaches, and the policy resumes.
    app.procmon_scroll_apply(pm, MAX_ROWS, false, 101)
    testing.expect_value(t, pm.scroll, 0)
    testing.expect_value(t, pm.scroll_detached, f64(0))
}

// The filter bar is a Custom for the same reason the config pane's search field is: a caret
// is an OVER-quad (text.odin), and everything in a scissor group paints under the glyphs.
// It claims the bottom row and starts past the "filter " label.
@(test)
test_procmon_filter_bar :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 3)
    defer teardown(&a)
    a.procmon.filtering = true

    cmds := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)

    customs := 0
    box: app.Rect
    label_x: i32 = -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .Custom:
            if c.id == clay.ID("pm_fedit").id {
                customs += 1
                box = r
            }
        case .Text:
            d := c.renderData.text
            if string(d.stringContents.chars[:d.stringContents.length]) == "filter " {
                label_x = r.x
            }
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, label_x, i32(AREA.x + 10))
    // Seven cells past the label, on the pane's last row, running to the right edge.
    testing.expect_value(
        t,
        box,
        app.Rect{AREA.x + 80, AREA.y + AREA.h - ROW_H, AREA.w - 80, ROW_H},
    )
}

// Hover is the C5b toggle, read here by all three of this pane's zones. It never competes
// with the selection, and the armed-kill prompt does not light: you cannot click it.
@(test)
test_procmon_hover_is_toggleable :: proc(t: ^testing.T) {
    raw := clay_test_context(900, 500)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a, 20)
    defer teardown(&a)
    pm := &a.procmon
    pm.sel = 0

    count_rects :: proc(cmds: ^clay.ClayArray(clay.RenderCommand)) -> int {
        n := 0
        for i in 0 ..< cmds.length {
            if clay.RenderCommandArray_Get(cmds, i).commandType == .Rectangle {
                n += 1
            }
        }
        return n
    }

    pm.hover = {.Row, 6}
    a.hover_on = false
    off := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)
    testing.expect_value(t, count_rects(&off), 1) // the selection, and nothing else

    a.hover_on = true
    on := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)
    testing.expect_value(t, count_rects(&on), 2)

    // The selected row does not take a second band on top of its own.
    pm.hover = {.Row, 0}
    same := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)
    testing.expect_value(t, count_rects(&same), 1)

    // The ACTIVE tab does not light either — it is already lit, and a hover that repeats
    // the current state says nothing.
    pm.hover = {.Tab, int(app.GraphCat.CPU)}
    active := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)
    testing.expect_value(t, count_rects(&active), 1)

    pm.hover = {.Tab, int(app.GraphCat.Disk)}
    tab := app.procmon_layout(&a, &f, PANE, 0, 0, 900, 500)
    testing.expect_value(t, count_rects(&tab), 2)
}

// The scroll policy is the shared one, driven by the SELECTION — so the pane behaves the
// same in both scroll_modes and there is nothing to detach, exactly as C2 settled for the
// other list panes.
@(test)
test_procmon_scroll_apply :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a, 40)
    defer teardown(&a)
    pm := &a.procmon

    // FOLLOW holds still while the selection is in view, then moves the minimum.
    pm.sel, pm.scroll = 3, 0
    app.procmon_scroll_apply(pm, MAX_ROWS, false)
    testing.expect_value(t, pm.scroll, 0)
    pm.sel = 20
    app.procmon_scroll_apply(pm, MAX_ROWS, false)
    testing.expect_value(t, pm.scroll, 20 - MAX_ROWS + 1)

    // MIDDLE pins the selection to the middle row instead.
    app.procmon_scroll_apply(pm, MAX_ROWS, true)
    testing.expect_value(t, pm.scroll, 20 - MAX_ROWS / 2)

    // And the tween chases the target rather than jumping: mid-flight the top is between
    // the two, so the window the declaration uses is NOT pm.scroll.
    pm.scroll_anim = app.Anim{}
    top, off := app.procmon_window(pm, 0, ROW_H)
    testing.expect_value(t, top, 0)
    testing.expect_value(t, off, i32(0))
}
