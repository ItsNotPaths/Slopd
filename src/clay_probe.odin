package main

import "core:fmt"
import clay "../bindings/clay"

// THROWAWAY — C1 acceptance only. `slopd --clay-probe` replaces the aux pane with a
// pane declared entirely in Clay, so the bridge in clay_render.odin can be seen doing
// the four things C1 claims: a filled + bordered pane frame, a header row with text,
// alternating row backgrounds under their labels, and a clip group that cuts the
// overflowing rows off at the pane edge rather than painting over the status strip.
// It exists because "the command list is right" (tests/clay_test.odin) and "the pixels
// are right" are different claims and only one of them is testable headlessly.
//
// The whole file is deleted at the end of C1 — that is why it is a file and not a proc
// in clay_render.odin. Deleting it means `rm src/clay_probe.odin` plus the two lines it
// is wired into (the flag in main.odin, the branch in render.odin).

// How many rows past the bottom of the viewport to declare. Fixed counts do not work:
// 40 rows fit outright in a tall window, and a probe whose clip is never exercised proves
// nothing. The count is derived from the pane instead, so the overflow exists at every
// window size.
@(private = "file")
PROBE_OVERFLOW :: 8

// Argument order matches the draw_* procs it stands in for (render.odin).
clay_probe :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    if pane.w <= 0 || pane.h <= 0 {
        return
    }
    th := &a.theme
    lh := t.font.line_height
    row_h := i32(lh) + i32(2 * a.scale)
    pad := u16(8 * a.scale)
    ring := u16(2 * a.scale)

    // The focus ring follows panel()'s rule (render.odin) rather than being always-on:
    // the ring exists to disambiguate WHICH of two panes is active, so it is wrong for a
    // pane to keep it after focus has left. A probe that never releases it is just a probe
    // reporting the wrong thing about the pane it stands in for. Read through
    // panes_visible, NOT by re-running compute_layout: that one re-aims the split
    // animation off the `now` it is handed, and a second call per frame would fight the
    // one render() already made.
    vis := panes_visible(a)
    ringed := vis.editor && vis.aux && a.focus == .Aux

    // How many rows the clipped body can show, computed the way Clay will lay it out:
    // pane height, less the ring top and bottom, less the header row. Rows beyond this
    // must be cut by the scissor. The +1 is slack against an off-by-one in this estimate,
    // so a single row sitting exactly on the edge never raises a false alarm — the signal
    // that matters is a RED row, and PROBE_OVERFLOW guarantees several if the clip fails.
    fits := max(1, int((pane.h - 2 * i32(ring) - row_h) / row_h))
    hidden_from := fits + 1

    clay_resize(win_w, win_h)
    clay.BeginLayout()

    // Clay lays out from (0,0) at the framebuffer size, so a pane at an arbitrary rect is
    // a full-window root padded by the pane's origin holding a fixed-size child. Panes
    // will be declared as siblings of a real split once C3 owns the frame; this is the
    // cheapest way to put one pane where render() already decided it goes.
    if clay.UI(clay.ID("probe_root"))(
        {
            layout = {
                sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))},
                padding = {left = u16(max(0, pane.x)), top = u16(max(0, pane.y))},
            },
        },
    ) {
        if clay.UI(clay.ID("probe_pane"))(
            {
                layout = {
                    sizing = {clay.SizingFixed(f32(pane.w)), clay.SizingFixed(f32(pane.h))},
                    layoutDirection = .TopToBottom,
                    padding = clay.PaddingAll(ring),
                },
                backgroundColor = clay_rgb(th.bg),
                border = {
                    color = clay_rgb(ringed ? th.accent : th.bg),
                    width = clay.BorderOutside(ring),
                },
            },
        ) {
            if clay.UI(clay.ID("probe_head"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                        padding = {left = pad, right = pad},
                        childAlignment = {y = .Center},
                    },
                    backgroundColor = clay_rgb(th.border_light),
                },
            ) {
                clay.Text(
                    fmt.tprintf("clay probe — no red row may be visible (rows %d+)", hidden_from),
                    clay_text_config(th.fg, i32(lh)),
                )
            }

            // The clip group: Clay brackets this subtree with ScissorStart/ScissorEnd, which
            // the bridge maps onto a flush_pane pair. Rows past the bottom edge are cut here
            // — if they spill onto the status strip, the scissor mapping is wrong.
            if clay.UI(clay.ID("probe_body"))(
                {
                    layout = {
                        sizing = {clay.SizingGrow(), clay.SizingGrow()},
                        layoutDirection = .TopToBottom,
                    },
                    clip = {horizontal = true, vertical = true},
                },
            ) {
                for i in 0 ..< fits + PROBE_OVERFLOW {
                    // Alternating backgrounds double as a grid check: with row_h a whole
                    // number of pixels, the bands must be equal height with no seams.
                    // Past the viewport the rows go loud: a visible red row anywhere — in
                    // the pane, over the status strip, past the window edge — means the
                    // ScissorStart/End pair did not become a flush_pane group.
                    over := i >= hidden_from
                    bg := over ? th.urgent : (i % 2 == 0 ? th.bg : th.separator)
                    fg := over ? th.bg : (i % 5 == 0 ? th.accent : th.fg)
                    if clay.UI(clay.ID("probe_row", u32(i)))(
                        {
                            layout = {
                                sizing = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                                padding = {left = pad, right = pad},
                                childAlignment = {y = .Center},
                            },
                            backgroundColor = clay_rgb(bg),
                        },
                    ) {
                        msg :=
                            over \
                            ? fmt.tprintf("row %2d — CLIPPED: this must not be visible", i) \
                            : fmt.tprintf("row %2d — ünïcøde width is rune-counted", i)
                        clay.Text(msg, clay_text_config(fg, i32(lh)))
                    }
                }
            }
        }
    }

    cmds := clay.EndLayout(0)
    clay_paint(t, a, &cmds, pane, win_w, win_h)
}
