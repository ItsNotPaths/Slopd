package main

import clay "../bindings/clay"

// The context menu's UI half. It follows the pane template (geom → hit → click → declare) with
// one difference that runs through all four: **the menu is not in a pane.** It is a floating
// child of the WINDOW root, placed at an arbitrary rect, so it is the one surface whose geometry
// is a function of the pointer rather than of a pane it was handed.
//
// Three properties it borrows from the overlays (overlay_ui.odin), and one it does not:
//   - `floating` is what buys the paint order: a floating element is its own layout root, so its
//     backdrop is not stuck under the glyphs of the pane it covers.
//   - `pointerCaptureMode = .Capture` is what silences the panes underneath — and it only
//     reaches the panes that ask the TREE, which the two list presentations of the filetree do.
//   - `zIndex` above the overlays AND above the strip, both of which declare after the panes.
//   - **It clips to ITSELF, not to a parent.** An overlay wants the pane's box (a chord bar may
//     outgrow a short pane); a popup is sized to its own contents and must not be cut by the
//     pane it was opened over, which is the whole point of it being a window-level surface.

// The menu's z: above OVERLAY_Z, so a right-press over the filetree with the chord bar up puts
// the menu on top of it rather than behind it.
CM_Z :: 2

// Row padding, the left/right margin, and the height of a separator band — logical pixels, DPI
// scaled at use. The cell gap between an item's label and its chord hint is in CELLS, since it
// is a column position rather than a margin.
CM_ROW_PAD :: 4
CM_PAD :: 8
CM_SEP_H :: 5
CM_HINT_GAP :: 3

// The menu's box for a given pointer position: its content size, then ctxmenu_place's flip. Pure,
// and the single geometry source — the frame stores the result for the dismissal test and the
// declaration re-derives it here, so the box that is painted, the box that swallows presses and
// the box a press is measured against are one number.
ctxmenu_geom :: proc(
    m: ^ContextMenu,
    scale, line_h, cell_w: f32,
    win_w, win_h: i32,
) -> (
    rect: Rect,
    row_h, sep_h: i32,
    pad: u16,
) {
    row_h = i32(line_h) + i32(CM_ROW_PAD * scale)
    sep_h = max(1, i32(CM_SEP_H * scale))
    p := i32(max(0.0, CM_PAD * scale))
    pad = u16(p)

    h: i32 = 0
    for it in m.items {
        h += it.action == .None ? sep_h : row_h
    }
    w := i32(f32(ctxmenu_width_cells(m)) * cell_w) + 2 * p
    return ctxmenu_place(m.x, m.y, w, h, win_w, win_h), row_h, sep_h, pad
}

// Which item the pointer is over, or -1. Separators are not declared as items, so they cannot be
// hit — the same "chrome rows are dead space" rule the config pane's `item == -1` states.
ctxmenu_hit :: proc(m: ^ContextMenu) -> int {
    for it, i in m.items {
        if it.action == .None {
            continue
        }
        if clay.PointerOver(clay.ID("cm_item", u32(i))) {
            return i
        }
    }
    return -1
}

// Apply a press on item `i` (-1 = the pointer was inside the menu but on no item). **A single
// click activates**, because a context menu is already the second half of a gesture — the right
// press was the first (rule 7, as for a dropdown option).
//
// The press is claimed either way once the pointer is inside the box: a press on a separator or
// a disabled row must be SWALLOWED, not passed down to the pane the menu is covering.
ctxmenu_click :: proc(a: ^App, i: int) {
    m := &a.ctxmenu
    if !rect_hit(m.rect, a.mouse.x, a.mouse.y) {
        return // outside: ctxmenu_dismiss_click already had it (window_pointer)
    }
    if _, ok := mouse_take_click(a); !ok {
        return
    }
    if i < 0 || i >= len(m.items) || m.items[i].action == .None || !m.items[i].enabled {
        return
    }
    m.sel = i
    ctxmenu_choose(a)
}

// Declare the menu into the window's tree. Reads App, writes only Clay.
//
//   cm_pane      the popup: floating at its placed rect, its own clip group, capturing the
//                pointer, above every overlay, with a background and a one-pixel border — the
//                only surface in the program that draws its own frame, because it is the only
//                one not sitting inside a panel()
//     cm_item/i  a verb: its label, then its chord hint pushed to the right edge by the solver
//     cm_sep/i   a separator band, a single top border rather than a filled bar
ctxmenu_declare :: proc(a: ^App, f: ^Font, win_w, win_h: i32) {
    m := &a.ctxmenu
    th := &a.theme
    if m.kind == .None || len(m.items) == 0 {
        return
    }
    rect, row_h, sep_h, pad := ctxmenu_geom(m, a.scale, f.line_height, f.cell_w, win_w, win_h)
    if rect.w <= 0 || rect.h <= 0 {
        return
    }
    lh := i32(f.line_height)
    bw := u16(max(i32(1), i32(a.scale)))

    box := clay_pane_box(rect)
    box.floating.zIndex = CM_Z
    box.floating.pointerCaptureMode = .Capture
    box.backgroundColor = clay_rgb(th.border_light)
    box.border = {
        color = clay_rgb(th.border_dark),
        width = {left = bw, right = bw, top = bw, bottom = bw},
    }

    if clay.UI(clay.ID("cm_pane"))(box) {
        for it, i in m.items {
            if it.action == .None {
                if clay.UI(clay.ID("cm_sep", u32(i)))(
                    {
                        layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(f32(sep_h))}},
                        border = {color = clay_rgb(th.separator), width = {top = 1}},
                    },
                ) {}
                continue
            }

            // The selection bar is the keyboard's place; hover is the pointer's, and it never
            // outranks it — the same precedence every list pane declares.
            bg: clay.Color
            if i == m.sel {
                bg = clay_rgb(th.separator)
            } else if hover_shown(a) && i == m.hover {
                bg = clay_rgb(hover_bg(th))
            }
            col := it.enabled ? (i == m.sel ? th.fg : th.muted) : th.border_light
            hint_col := it.enabled ? th.accent : th.border_light

            if clay.UI(clay.ID("cm_item", u32(i)))(
                {
                    layout = {
                        sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                        padding        = {left = pad, right = pad},
                        childAlignment = {y = .Center},
                    },
                    backgroundColor = bg,
                },
            ) {
                clay.Text(it.label, clay_text_config(col, lh))
                // The hint is pushed to the right edge by the solver rather than by padding the
                // label out to a column: the widest label decides the menu's width already, so
                // asking for alignment says what is meant (rule 5).
                if it.hint != "" {
                    if clay.UI(clay.ID("cm_hint", u32(i)))(
                        {
                            layout = {
                                sizing         = {clay.SizingGrow(), clay.SizingGrow()},
                                childAlignment = {x = .Right, y = .Center},
                            },
                        },
                    ) {
                        clay.Text(it.hint, clay_text_config(hint_col, lh))
                    }
                }
            }
        }
    }
}

// Test-facing wrapper; see filetree_layout.
ctxmenu_layout :: proc(a: ^App, f: ^Font, win_w, win_h: i32) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        ctxmenu_declare(a, f, win_w, win_h)
    }
    return clay.EndLayout(0)
}

// The menu's per-frame entry point, declared LAST in the window so nothing can paint over it.
// The stored rect is this frame's, written before the click is claimed: the press being resolved
// was made against the menu the LAST frame painted, and the two are the same box unless the
// window resized under it — in which case the press is refused rather than mis-aimed.
ctxmenu_frame :: proc(t: ^Text, a: ^App, win_w, win_h: i32) {
    m := &a.ctxmenu
    if m.kind == .None {
        return
    }
    hit := ctxmenu_hit(m)
    m.hover = hit
    ctxmenu_click(a, hit)
    if m.kind == .None {
        return // the click chose something, and the chosen item closed the menu
    }
    m.rect, _, _, _ = ctxmenu_geom(m, a.scale, t.font.line_height, t.font.cell_w, win_w, win_h)
    ctxmenu_declare(a, &t.font, win_w, win_h)
}
