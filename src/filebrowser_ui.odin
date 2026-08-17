package main

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:unicode/utf8"
import clay "../bindings/clay"

// The file browser pane's UI half — the same six procs every pane has (filetree_ui.odin is the
// short example), plus four kinds of thing to point at: a top-bar button, a path segment, a
// places row or an entry. So the hit test returns a tagged struct rather than an index.
//
// The pane is a fixed frame around one scrolling region:
//
//   ┌──────────────────────────────────────────────┐
//   │ [◀] [▶] [⟳] │ / home paths src        │ [▦] │  fb_bar   — square buttons, path buttons
//   ├─────────────┼──────────────────────────────┬─┤
//   │ Home        │  contents, list or grid      │ │  fb_side  — places, a rail on its right
//   │ Documents   │  scrolled by ft.scroll       │ │  fb_content
//   └─────────────┴──────────────────────────────┴─┘
//
// The model underneath is `FileTree` — entries, selection, marks, clipboard and every file op
// are the aux pane's. This file only decides how they look and what a pointer can reach, which
// makes `file_pane: ls | browser` a presentation switch rather than a second file manager.

// Logical pixels. The bar is taller than a row because its buttons are square — the height is
// also their width.
FB_ROW_PAD :: 2
FB_BAR_PAD :: 5

// Logical pixels. The tile's width is in cells (FB_TILE_CELLS) so it follows the font zoom;
// chrome follows the DPI only.
FB_TILE_PAD :: 4
FB_TILE_GAP :: 6

// In the bundled font subset (download-deps.sh keeps U+2190-21FF, U+25A0-25FF, U+27F0-27FF).
FB_ICON_BACK :: "◀"
FB_ICON_FWD :: "▶"
FB_ICON_RELOAD :: "⟳"
FB_ICON_GRID :: "▦"
FB_ICON_LIST :: "▤"

// `index` means whichever list `kind` names, and is -1 for a button, whose identity is `btn`.
// `PathBar` is the region itself, not a segment button: the whitespace after the last segment
// (and, once the bar is a text line, the whole line).
FB_Hit_Kind :: enum {
    None,
    Button,
    Segment,
    PathBar,
    Place,
    Row,
}

FB_Hit :: struct {
    kind:  FB_Hit_Kind,
    index: int,
    btn:   Browse_Btn,
}

// The content area inside the focus ring, the three regions it splits into, and the row
// metrics. Pure, and the one source every phase sizes itself from.
//
// The sidebar caps at half the pane: at a narrow split a fixed 16-cell sidebar would leave the
// contents narrower than one tile.
filebrowser_geom :: proc(
    pane: Rect,
    scale, line_h, cell_w: f32,
) -> (
    area, bar, side, content: Rect,
    row_h, bar_h: i32,
) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(FB_ROW_PAD * scale)
    bar_h = i32(line_h) + i32(2 * FB_BAR_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, {}, {}, {}, row_h, bar_h
    }
    bar_h = min(bar_h, area.h)
    bar = Rect{area.x, area.y, area.w, bar_h}

    side_w := min(i32(f32(FB_SIDE_CELLS) * cell_w), area.w / 2)
    below := area.h - bar_h
    side = Rect{area.x, area.y + bar_h, side_w, below}
    content = Rect{area.x + side_w, area.y + bar_h, area.w - side_w, below}
    return
}

// The icon band, the caption row, and the padding either side. Both bands round to whole
// pixels, or every grid row lands on a fractional boundary.
//
// Capped at the content width (rule 8): a fixed box that outgrows its parent is still a hit box,
// clickable beyond the pane's edge while the clip group hides the overflow.
filebrowser_tile :: proc(scale, line_h, cell_w: f32, max_w: i32) -> (w, h: f32) {
    w = min(f32(FB_TILE_CELLS) * cell_w, f32(max(0, max_w)))
    icon_h, name_h := filebrowser_tile_bands(line_h)
    h = icon_h + name_h + 2 * math.round(FB_TILE_PAD * scale)
    return
}

filebrowser_tile_bands :: proc(line_h: f32) -> (icon_h, name_h: f32) {
    return math.round(line_h * FB_TILE_ICON_ROWS), math.round(line_h * FB_TILE_NAME_SCALE)
}

// Whole pixels, in one place: the column count, the scroll unit and the declaration must agree
// or the tween lands a few pixels off the row it is easing to.
filebrowser_tile_gap :: proc(scale: f32) -> f32 {
    return math.round(max(0, FB_TILE_GAP * scale))
}

// Runes of a caption across a tile at the caption's reduced size.
filebrowser_tile_name_cells :: proc() -> int {
    return int(math.floor(f32(FB_TILE_CELLS) / f32(FB_TILE_NAME_SCALE))) - 1
}

// Rows that fit, and in Grid the tiles across. One call for both, so a caller never has to pick
// which proc to ask.
filebrowser_rows :: proc(
    content: Rect,
    view: Browse_View,
    row_h: i32,
    scale, line_h, cell_w: f32,
) -> (
    rows, cols: int,
) {
    if content.w <= 0 || content.h <= 0 {
        return 0, 1
    }
    if view == .List {
        return row_h > 0 ? max(0, int(content.h / row_h)) : 0, 1
    }
    tw, th := filebrowser_tile(scale, line_h, cell_w, content.w)
    gap := filebrowser_tile_gap(scale)
    if th <= 0 {
        return 0, 1
    }
    // In pitch, not tile heights: bare tiles would claim room for one row more than there is.
    return max(0, int(f32(content.h) / (th + gap))), filebrowser_grid_cols(content.w, tw, gap)
}

// A list row, or a row of tiles: the unit the viewport and its tween both count in.
filebrowser_row_h :: proc(view: Browse_View, row_h: i32, scale, line_h, cell_w: f32) -> i32 {
    if view == .List {
        return row_h
    }
    // A tile's height does not depend on the width cap, so the cap here is immaterial.
    _, tile_h := filebrowser_tile(scale, line_h, cell_w, max(i32))
    return i32(tile_h + filebrowser_tile_gap(scale)) // pitch: the tile plus the gap under it
}

// Follow the selection under the shared `scroll_mode` policy. The unit is the content row, so
// the anchor and the total go through filebrowser_anchor / filebrowser_grid_rows.
filebrowser_scroll_apply :: proc(a: ^App, rows, cols: int, center: bool) {
    ft := &a.tree
    view := a.filebrowser.view
    total := view == .List ? len(ft.entries) : filebrowser_grid_rows(len(ft.entries), cols)
    anchor := filebrowser_anchor(ft, view, cols)
    list_scroll_apply(&ft.scroll, &ft.scroll_detached, anchor, rows, total, center, pane_input_at(a))
}

// The bar less its four square buttons. For the phases the solver cannot answer — the press
// that puts a caret on the column it landed on.
filebrowser_path_rect :: proc(bar: Rect, bar_h: i32) -> Rect {
    return Rect{bar.x + 3 * bar_h, bar.y, max(0, bar.w - 4 * bar_h), bar_h}
}

// Cells the segments may use, which is also what the line scrolls inside, so both states of the
// bar cut the path at the same character.
filebrowser_path_cells :: proc(bar: Rect, bar_h: i32, cell_w: f32) -> int {
    return field_cells(filebrowser_path_rect(bar, bar_h), cell_w)
}

// Chrome first, contents last, though the boxes do not overlap so the order is documentation.
// Resolves against the tree the last frame declared.
filebrowser_hit :: proc(a: ^App, segs: []Path_Seg, first_seg, top, visible, cols: int) -> FB_Hit {
    for b in Browse_Btn {
        if b != .None && clay.PointerOver(clay.ID("fb_btn", u32(b))) {
            return FB_Hit{kind = .Button, index = -1, btn = b}
        }
    }
    for i in first_seg ..< len(segs) {
        if clay.PointerOver(clay.ID("fb_seg", u32(i))) {
            return FB_Hit{kind = .Segment, index = i}
        }
    }
    // Whitespace after the last segment, and the whole of the line while it is being edited.
    if clay.PointerOver(clay.ID("fb_path")) {
        return FB_Hit{kind = .PathBar, index = -1}
    }
    for i in 0 ..< len(a.filebrowser.places) {
        if clay.PointerOver(clay.ID("fb_place", u32(i))) {
            return FB_Hit{kind = .Place, index = i}
        }
    }
    // Over the painted window (`top`, animated) rather than the target — see filetree_hit.
    ft := &a.tree
    first := clamp(top, 0, max(0, len(ft.entries)))
    lo := a.filebrowser.view == .List ? first : first * max(1, cols)
    n := max(0, min(len(ft.entries) - lo, visible * max(1, cols)))
    for k in 0 ..< n {
        i := lo + k
        if clay.PointerOver(clay.ID("fb_item", u32(i))) {
            return FB_Hit{kind = .Row, index = i}
        }
    }
    return FB_Hit{kind = .None, index = -1}
}

// Chrome activates on a single press, an entry selects on one and opens on two, and a press
// that hit nothing is left for whoever else is drawing. `path` and `cw` are for the one press
// needing a column rather than a box: inside the open text line, the caret goes where it landed.
filebrowser_click :: proc(a: ^App, segs: []Path_Seg, hit: FB_Hit, path: Rect, cw: f32) {
    br := &a.filebrowser
    // A press elsewhere abandons the line without consuming the press.
    if br.path_edit && hit.kind != .PathBar && a.mouse_on && a.mouse.click {
        filebrowser_path_cancel(a)
    }
    if hit.kind == .None {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    switch hit.kind {
    case .None:
    case .Button:
        filebrowser_button(a, hit.btn)
    case .Segment:
        if hit.index >= 0 && hit.index < len(segs) {
            filebrowser_navigate(br, &a.tree, segs[hit.index].path)
        }
    case .PathBar:
        // Empty space after the last segment turns the bar into a line; a press inside an open
        // line is the field's own.
        if br.path_edit {
            field_press(a, filebrowser_path_box(a, path, cw), count)
        } else {
            filebrowser_path_open(a)
        }
    case .Place:
        if hit.index >= 0 && hit.index < len(br.places) {
            filebrowser_navigate(br, &a.tree, br.places[hit.index].path)
        }
    case .Row:
        ft := &a.tree
        if len(ft.entries) == 0 {
            return
        }
        ft.selected = clamp(hit.index, 0, len(ft.entries) - 1)
        if count >= 2 {
            filebrowser_activate(a) // the mouse twin of Enter
        }
    }
}

// Work out what it landed on, select it if it is a row, then open that target's menu. All four
// kinds get one: a segment and a place name a directory, and empty space is the browsed
// directory's menu (paste, add to places, reload).
filebrowser_rclick :: proc(a: ^App, segs: []Path_Seg, hit: FB_Hit) {
    if !rect_hit(a.lay.aux, a.mouse.rclick_x, a.mouse.rclick_y) {
        return
    }
    if !mouse_take_rclick(a) {
        return
    }
    br := &a.filebrowser
    ft := &a.tree
    on := Menu_Target{ft.dir, .Dir} // a button press and a miss both act on where you are
    switch hit.kind {
    case .None, .Button, .PathBar:
    case .Row:
        if hit.index >= 0 && hit.index < len(ft.entries) {
            ft.selected = hit.index
            if e := filetree_selected(ft); e != nil {
                on = {e.path, .Entry}
            }
        }
    case .Segment:
        if hit.index >= 0 && hit.index < len(segs) {
            on = {segs[hit.index].path, .Path}
        }
    case .Place:
        if hit.index >= 0 && hit.index < len(br.places) {
            on = {br.places[hit.index].path, .Path}
        }
    }
    items := ctxmenu_file_items(a, on, true, context.temp_allocator)
    ctxmenu_open(a, .FileOps, items, a.mouse.rclick_x, a.mouse.rclick_y, on)
}

// The top bar's verbs. Package-level because the pointer and the keyboard (`^Left`, `^Right`,
// `^r`, `^g`) both reach every one.
filebrowser_button :: proc(a: ^App, b: Browse_Btn) {
    br := &a.filebrowser
    switch b {
    case .None:
    case .Back:
        filebrowser_back(br, &a.tree)
    case .Forward:
        filebrowser_forward(br, &a.tree)
    case .Reload:
        filetree_reload(&a.tree)
    case .View:
        br.view = br.view == .List ? .Grid : .List
        config_set("file_view", br.view == .Grid ? "grid" : "list")
    }
}

// --- the path bar's two states --- A row of buttons, until you press the whitespace after them:
// then it is a text line on the same path, so you can type a destination. Enter goes there; Esc,
// or a press elsewhere, puts the buttons back.

// Open AND owning the keyboard. One predicate for the char callback, the key routing and the
// blink.
filebrowser_path_live :: proc(a: ^App) -> bool {
    if !a.filebrowser.path_edit || a.focus != .Aux {
        return false
    }
    return a.aux_mode == .FileTree && a.file_pane == .Browser
}

filebrowser_path_open :: proc(a: ^App) {
    br := &a.filebrowser
    br.path_edit = true
    br.path_off = 0
    doc_set_text(&br.path, a.tree.dir)
    doc_cursor_to_end(&br.path)
}

filebrowser_path_cancel :: proc(a: ^App) {
    a.filebrowser.path_edit = false
    a.filebrowser.path_off = 0
}

// Enter: go where the line says. A path that is not a directory keeps the line open with the
// text in it, so the typo stays on screen to fix.
filebrowser_path_commit :: proc(a: ^App) {
    br := &a.filebrowser
    typed := doc_string(&br.path, context.temp_allocator)
    dir := filebrowser_path_resolve(a.tree.dir, typed)
    if !os.is_dir(dir) {
        return
    }
    filebrowser_path_cancel(a)
    filebrowser_navigate(br, &a.tree, dir)
}

// The box the press, the drag and the window resolve against. `path` is the rect the field was
// declared into.
filebrowser_path_box :: proc(a: ^App, path: Rect, cw: f32) -> Field_Box {
    br := &a.filebrowser
    return {doc = &br.path, target = FIELD_PATH, r = path, off = br.path_off, cw = cw}
}

// Descend into a directory through the history (the difference from filetree_activate), or open
// the file in the editor.
filebrowser_activate :: proc(a: ^App) {
    e := filetree_selected(&a.tree)
    if e == nil {
        return
    }
    if e.is_dir {
        filebrowser_navigate(&a.filebrowser, &a.tree, e.path)
        return
    }
    open_or_run(a, e.path, e.exec)
}

// `filepath.dir` slices ft.dir, which the load inside navigate frees — navigate clones first,
// which is why that clone is there.
filebrowser_parent :: proc(a: ^App) {
    ft := &a.tree
    if parent := filepath.dir(ft.dir); parent != ft.dir {
        filebrowser_navigate(&a.filebrowser, ft, parent)
    }
}

// The `^1`..`^9` chords, the sidebar's keyboard twin. One-based, like Alt+1..9.
filebrowser_place_open :: proc(a: ^App, n: int) {
    br := &a.filebrowser
    if n >= 1 && n <= len(br.places) {
        filebrowser_navigate(br, &a.tree, br.places[n - 1].path)
    }
}

// Declare the pane into the window's tree. Reads App, writes only Clay.
//
//   fb_pane        content area inside the focus ring, clipping its own content
//     fb_bar       three square buttons, the path, then the view toggle
//       fb_btn/b     one per Browse_Btn, square (its side is the bar's height)
//       fb_path      the path, clipped; too long and it elides from the LEFT
//         fb_ell       the "…" marking an elision
//         fb_seg/i     one per shown segment, keyed by segment index
//         fb_edit      replaces the two above while the line is open
//     fb_body      the two scrolling regions, side by side
//       fb_side      the places column, single-edge border as the rail
//         fb_place/i one per shortcut; the browsed dir's is in the accent colour
//       fb_content   the clip group the contents scroll inside
//         fb_item/i    List: one row per visible entry, keyed by entry index
//         fb_grow/r    Grid: one row of tiles, holding fb_item/i tiles keyed the same
filebrowser_declare :: proc(a: ^App, f: ^Font, pane: Rect, top: int, off: i32, now: f64 = 0) {
    br := &a.filebrowser
    ft := &a.tree
    th := &a.theme
    area, bar, side, content, row_h, bar_h := filebrowser_geom(pane, a.scale, f.line_height, f.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := f.cell_w
    lh := i32(f.line_height)
    _, cols := filebrowser_rows(content, br.view, row_h, a.scale, f.line_height, cw)
    // Rows the region TOUCHES, one more than fit whenever it does not divide evenly or a scroll
    // is in progress. Whole rows alone leaves the bottom tile row undeclared but on screen.
    unit := filebrowser_row_h(br.view, row_h, a.scale, f.line_height, cw)
    visible := list_visible_rows(content.h, off, unit)

    if clay.UI(clay.ID("fb_pane"))(clay_pane_box(area)) {
        filebrowser_declare_bar(a, bar, bar_h, lh, cw, now)

        if clay.UI(clay.ID("fb_body"))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(max(0, content.h)))},
                    layoutDirection = .LeftToRight,
                },
            },
        ) {
            // Rail as a single-edge border (rule 5); the pane's panel() painted the background.
            if clay.UI(clay.ID("fb_side"))(
                {
                    layout = {
                        sizing          = {clay.SizingFixed(f32(side.w)), clay.SizingFixed(f32(max(0, content.h)))},
                        layoutDirection = .TopToBottom,
                    },
                    border = {
                        color = clay_rgb(th.separator),
                        width = {right = u16(max(i32(1), i32(a.scale)))},
                    },
                    clip   = {horizontal = true, vertical = true},
                },
            ) {
                for p, i in br.places {
                    here := p.path == ft.dir
                    bg: clay.Color
                    if hover_shown(a) && i == br.hover_place {
                        bg = clay_rgb(hover_bg(th))
                    }
                    if clay.UI(clay.ID("fb_place", u32(i)))(
                        {
                            layout = {
                                sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                                padding        = {left = u16(cw)},
                                childAlignment = {y = .Center},
                            },
                            backgroundColor = bg,
                        },
                    ) {
                        clay.Text(p.name, clay_text_config(here ? th.accent : th.muted, lh))
                    }
                }
            }

            // The prompt covers the listing, not the pane: the bar and sidebar stay.
            if wsfind_shown(a) {
                wsfind_declare_body(a, content, row_h, lh, cw, now)
            } else if clay.UI(clay.ID("fb_content"))(
                {
                    layout = {
                        // Fixed, not Grow: the row easing into view must not stretch the clip
                        // group it is inside (rule 8).
                        sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(max(0, content.h)))},
                        layoutDirection = .TopToBottom,
                        // Solver-spaced, which is what makes filebrowser_row_h's pitch real.
                        childGap        = br.view == .Grid ? u16(filebrowser_tile_gap(a.scale)) : 0,
                    },
                    // The tween's remainder rides on the clip, not each row's y (rule 9).
                    clip = {horizontal = true, vertical = true, childOffset = {0, -f32(off)}},
                },
            ) {
                switch br.view {
                case .List:
                    filebrowser_declare_list(a, f, top, visible, row_h, lh, cw)
                case .Grid:
                    filebrowser_declare_grid(a, f, top, visible, cols, lh, cw, content.w)
                }
            }
        }

        // Last and inside the pane — the same overlay the listing face puts up, over the same
        // chords. See filetree_declare.
        if chord_shown(a) {
            chord_declare(a, f, area, now)
        }
    }
}

// Every button is square — `SizingFixed(bar_h)` on both axes — which keeps the icons on a
// common baseline at any zoom.
@(private = "file")
filebrowser_declare_bar :: proc(a: ^App, bar: Rect, bar_h, lh: i32, cw: f32, now: f64) {
    br := &a.filebrowser
    th := &a.theme
    segs := filebrowser_segments(a.tree.dir)
    first := filebrowser_seg_first(segs, filebrowser_path_cells(bar, bar_h, cw))

    if clay.UI(clay.ID("fb_bar"))(
        {
            layout = {
                sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(bar_h))},
                layoutDirection = .LeftToRight,
                childAlignment  = {y = .Center},
            },
            backgroundColor = clay_rgb(th.border_light),
        },
    ) {
        filebrowser_declare_btn(a, .Back, FB_ICON_BACK, filebrowser_can_back(br), bar_h, lh)
        filebrowser_declare_btn(a, .Forward, FB_ICON_FWD, filebrowser_can_forward(br), bar_h, lh)
        filebrowser_declare_btn(a, .Reload, FB_ICON_RELOAD, true, bar_h, lh)

        if clay.UI(clay.ID("fb_path"))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingGrow()},
                    layoutDirection = .LeftToRight,
                    childAlignment  = {y = .Center},
                },
                clip = {horizontal = true},
            },
        ) {
            // The line is the shared one-line Field (field_ui.odin), with a window since a
            // path is read from its end. The workspace prompt takes the same box.
            if wsfind_shown(a) {
                wsfind_declare_bar(a, lh, now)
            } else if br.path_edit {
                field_declare(
                    clay.ID("fb_edit"),
                    {doc = &br.path, off = br.path_off, now = now, caret = filebrowser_path_live(a)},
                )
            } else {
                filebrowser_declare_segs(a, segs, first, lh, cw)
            }
        }

        // The toggle shows the view it would give you, not the one you are in: a button is a
        // verb.
        icon := br.view == .List ? FB_ICON_GRID : FB_ICON_LIST
        filebrowser_declare_btn(a, .View, icon, true, bar_h, lh)
    }
}

// One button per segment from `first` on, behind a '…' when the head is cut.
@(private = "file")
filebrowser_declare_segs :: proc(a: ^App, segs: []Path_Seg, first: int, lh: i32, cw: f32) {
    th := &a.theme
    if first > 0 {
        if clay.UI(clay.ID("fb_ell"))({layout = {padding = {left = u16(cw)}}}) {
            clay.Text("…", clay_text_config(th.muted, lh))
        }
    }
    for i in first ..< len(segs) {
        last := i == len(segs) - 1
        bg: clay.Color
        if hover_shown(a) && i == a.filebrowser.hover_seg {
            bg = clay_rgb(hover_bg(th))
        }
        if clay.UI(clay.ID("fb_seg", u32(i)))(
            {
                layout = {
                    sizing         = {height = clay.SizingGrow()},
                    padding        = {left = u16(cw / 2), right = u16(cw / 2)},
                    childAlignment = {y = .Center},
                },
                backgroundColor = bg,
            },
        ) {
            clay.Text(segs[i].name, clay_text_config(last ? th.fg : th.muted, lh))
        }
    }
}

// A disabled button (no history behind [◀]) draws in the border colour and takes no hover tint,
// but stays in place so the bar does not reflow as you navigate.
@(private = "file")
filebrowser_declare_btn :: proc(a: ^App, b: Browse_Btn, icon: string, enabled: bool, bar_h, lh: i32) {
    th := &a.theme
    bg: clay.Color
    if enabled && hover_shown(a) && a.filebrowser.hover_btn == b {
        bg = clay_rgb(hover_bg(th))
    }
    if clay.UI(clay.ID("fb_btn", u32(b)))(
        {
            layout = {
                sizing         = {clay.SizingFixed(f32(bar_h)), clay.SizingFixed(f32(bar_h))},
                childAlignment = {x = .Center, y = .Center},
            },
            backgroundColor = bg,
        },
    ) {
        clay.Text(icon, clay_text_config(enabled ? th.fg : th.border_dark, lh))
    }
}

// The filetree's row with a type icon in front. The icon is one cell and a glyph like any other
// (font.odin bakes the icon face into the same atlas) — no image, no second texture.
@(private = "file")
filebrowser_declare_list :: proc(a: ^App, f: ^Font, top, visible: int, row_h, lh: i32, cw: f32) {
    ft := &a.tree
    th := &a.theme
    first := clamp(top, 0, max(0, len(ft.entries)))
    shown := max(0, min(len(ft.entries) - first, visible))

    for k in 0 ..< shown {
        i := first + k
        e := &ft.entries[i]
        bg: clay.Color
        if i == ft.selected {
            bg = clay_rgb(th.separator)
        } else if filetree_marked(ft, e.path) {
            bg = clay_rgb(th.line_highlight)
        } else if hover_shown(a) && i == a.filebrowser.hover_row {
            bg = clay_rgb(hover_bg(th))
        }
        if clay.UI(clay.ID("fb_item", u32(i)))(
            {
                layout = {
                    sizing         = {clay.SizingGrow(), clay.SizingFixed(f32(row_h))},
                    padding        = {left = u16(cw)},
                    childAlignment = {y = .Center},
                },
                backgroundColor = bg,
            },
        ) {
            col := filebrowser_entry_color(a, e)
            if icon, ok := filebrowser_icon(a, f, e); ok {
                if clay.UI(clay.ID("fb_ico", u32(i)))(
                    {layout = {sizing = {width = clay.SizingFixed(2 * cw)}}},
                ) {
                    clay.Text(icon, clay_text_config(col, lh))
                }
            }
            clay.Text(e.display, clay_text_config(col, lh))
        }
    }
}

// ok=false when icons are off or no icon face was vendored. Temp-allocated: Clay's command list
// points at it, and the frame's arena outlives EndLayout.
filebrowser_icon :: proc(a: ^App, f: ^Font, e: ^FileEntry) -> (s: string, ok: bool) {
    if !a.file_icons || !f.icons_ok {
        return "", false
    }
    r := file_icon(e.name, e.is_dir)
    return utf8.runes_to_string({r}, context.temp_allocator), true
}

// Handed to the bridge as `customData`, so these live in the frame's temp arena.
FB_Icon :: struct {
    icon:  rune,
    px:    f32,
    color: [3]f32,
}

FB_Name :: struct {
    text:  string,
    px:    f32,
    color: [3]f32,
}

// Baked at the tile's own size. A Custom because a glyph can only be drawn at the size it was
// baked, and Clay's Text command is the atlas's one size.
filebrowser_paint_icon :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    ic := (^FB_Icon)(user)
    if ic != nil {
        icon_draw(t, ic.icon, r, ic.px, ic.color)
    }
    // The ClayCustom contract: the painter ends with its own flush.
    flush_pane(t, clip, win_w, win_h)
}

// A Custom for the icon's reason, from the other side: Clay lays text out at the atlas size and
// this is smaller. Centred from the rune count, which a fixed advance makes exact.
filebrowser_paint_name :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    nm := (^FB_Name)(user)
    if nm != nil && nm.text != "" {
        n := utf8.rune_count_in_string(nm.text)
        w := f32(n) * text_sized_cell(t, nm.px)
        x := f32(r.x) + (f32(r.w) - w) / 2
        y := f32(r.y) + (f32(r.h) - t.font.line_height * FB_TILE_NAME_SCALE) / 2
        text_draw_sized(t, nm.text, x, y, nm.px, nm.color)
    }
    flush_pane(t, clip, win_w, win_h)
}

// Rows of tiles, each a coloured swatch over an elided name. No thumbnails to decode: a filled
// block says "directory / program / file" at any zoom.
@(private = "file")
filebrowser_declare_grid :: proc(a: ^App, f: ^Font, top, visible, cols: int, lh: i32, cw: f32, max_w: i32) {
    ft := &a.tree
    th := &a.theme
    tw, thh := filebrowser_tile(a.scale, f.line_height, cw, max_w)
    first := clamp(top, 0, max(0, filebrowser_grid_rows(len(ft.entries), cols)))
    pad := u16(max(0.0, FB_TILE_PAD * a.scale))

    for r in first ..< min(first + visible, filebrowser_grid_rows(len(ft.entries), cols)) {
        if clay.UI(clay.ID("fb_grow", u32(r)))(
            {
                layout = {
                    sizing          = {clay.SizingGrow(), clay.SizingFixed(thh)},
                    layoutDirection = .LeftToRight,
                    childGap        = u16(filebrowser_tile_gap(a.scale)),
                },
            },
        ) {
            for c in 0 ..< cols {
                i := r * cols + c
                if i >= len(ft.entries) {
                    break
                }
                e := &ft.entries[i]
                bg: clay.Color
                if i == ft.selected {
                    bg = clay_rgb(th.separator)
                } else if filetree_marked(ft, e.path) {
                    bg = clay_rgb(th.line_highlight)
                } else if hover_shown(a) && i == a.filebrowser.hover_row {
                    bg = clay_rgb(hover_bg(th))
                }
                if clay.UI(clay.ID("fb_item", u32(i)))(
                    {
                        layout = {
                            sizing          = {clay.SizingFixed(tw), clay.SizingFixed(thh)},
                            padding         = {top = pad, bottom = pad},
                            layoutDirection = .TopToBottom,
                            childAlignment  = {x = .Center},
                        },
                        backgroundColor = bg,
                    },
                ) {
                    // The type icon where there is an icon face, a plain swatch where there is
                    // not. Same box either way, so the grid does not reflow.
                    icon_h, name_h := filebrowser_tile_bands(f.line_height)
                    icon_w := min(cw * f32(FB_TILE_CELLS - 6), tw)
                    col := filebrowser_entry_color(a, e)
                    if a.file_icons && f.icons_ok {
                        ic := new(FB_Icon, context.temp_allocator)
                        cu := new(ClayCustom, context.temp_allocator)
                        ic^ = {icon = file_icon(e.name, e.is_dir), px = icon_h, color = col}
                        cu^ = {paint = filebrowser_paint_icon, user = ic}
                        if clay.UI(clay.ID("fb_swatch", u32(i)))(
                            {
                                layout = {sizing = {clay.SizingFixed(icon_w), clay.SizingFixed(icon_h)}},
                                custom = {customData = cu},
                            },
                        ) {}
                    } else if clay.UI(clay.ID("fb_swatch", u32(i)))(
                        {
                            layout = {sizing = {clay.SizingFixed(icon_w), clay.SizingFixed(icon_h)}},
                            backgroundColor = clay_rgb(col),
                        },
                    ) {}
                    // At FB_TILE_NAME_SCALE of the text size, so its own Custom.
                    nm := new(FB_Name, context.temp_allocator)
                    ncu := new(ClayCustom, context.temp_allocator)
                    nm^ = {
                        text  = filebrowser_elide(e.name, filebrowser_tile_name_cells()),
                        px    = f.px * FB_TILE_NAME_SCALE,
                        color = i == ft.selected ? th.fg : th.muted,
                    }
                    ncu^ = {paint = filebrowser_paint_name, user = nm}
                    if clay.UI(clay.ID("fb_name", u32(i)))(
                        {
                            layout = {sizing = {clay.SizingFixed(tw), clay.SizingFixed(name_h)}},
                            custom = {customData = ncu},
                        },
                    ) {}
                }
            }
        }
    }
}

// Also the tile swatch's. The execute bit is called out here because a tile has no room for the
// filetree's mode column.
filebrowser_entry_color :: proc(a: ^App, e: ^FileEntry) -> [3]f32 {
    th := &a.theme
    switch {
    case e.is_dir:
        return th.code_return_type
    case ring_contains(a, e.path):
        return th.urgent
    case e.exec:
        return th.accent
    }
    return th.fg
}

// Test-facing wrapper; see filetree_layout.
filebrowser_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    win_w, win_h: i32,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    _, _, _, _, row_h, _ := filebrowser_geom(pane, a.scale, f.line_height, f.cell_w)
    unit := filebrowser_row_h(a.filebrowser.view, row_h, a.scale, f.line_height, f.cell_w)
    top, off := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, unit)
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        filebrowser_declare(a, f, pane, top, off, now)
    }
    return clay.EndLayout(0)
}

// The template's four phases, with the hover written per kind of target from the one hit the
// click consumes. `cols` is published for the keyboard, since only the geometry knows it.
filebrowser_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    br := &a.filebrowser
    area, bar, _, content, row_h, bar_h := filebrowser_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    rows, cols := filebrowser_rows(content, br.view, row_h, a.scale, t.font.line_height, t.font.cell_w)
    br.cols = cols
    wsfind_sync(a)
    cw := t.font.cell_w
    path := filebrowser_path_rect(bar, bar_h)
    top, off := a.tree.scroll, i32(0) // the listing's window; the prompt's is its own

    // The prompt takes the whole pane's input; the chrome stays on screen but inert, for
    // filetree_frame's reason — the listing it acts on is not declared.
    if wsfind_shown(a) {
        br.hover_row, br.hover_place, br.hover_seg, br.hover_btn = -1, -1, -1, .None
        wsfind_frame(a, wsfind_field_rect(path, cw), content, row_h, cw, now)
        filebrowser_declare(a, &t.font, pane, top, off, now)
        return
    }

    // The pointer is over what the LAST frame painted, so the hit resolves against the animated
    // top. Read twice for the editor's reason (editor_frame).
    unit := filebrowser_row_h(br.view, row_h, a.scale, t.font.line_height, cw)
    top0, off0 := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, unit)

    // The line belongs to the pane: losing the keyboard closes it.
    if br.path_edit && !filebrowser_path_live(a) {
        filebrowser_path_cancel(a)
    }

    segs := filebrowser_segments(a.tree.dir)
    first_seg := filebrowser_seg_first(segs, filebrowser_path_cells(bar, bar_h, cw))
    hit := filebrowser_hit(a, segs, first_seg, top0, list_visible_rows(content.h, off0, unit), cols)
    br.hover_row = hit.kind == .Row ? hit.index : -1
    br.hover_place = hit.kind == .Place ? hit.index : -1
    br.hover_seg = hit.kind == .Segment ? hit.index : -1
    br.hover_btn = hit.kind == .Button ? hit.btn : .None

    filebrowser_click(a, segs, hit, path, cw)
    filebrowser_rclick(a, segs, hit)
    filebrowser_scroll_apply(a, rows, cols, a.scroll_mode == .Middle)

    // Beside the click for editor_drag's reason: a drag walking the caret off the end must move
    // the window in the same frame — the next two statements, in order.
    if br.path_edit {
        field_drag(a, filebrowser_path_box(a, path, cw), now)
    }
    // The window follows the caret, as the listing's follows the selection.
    if br.path_edit && doc_line_count(&br.path) > 0 {
        cells := doc_cells(&br.path, 0)
        cur := cells_col(cells, br.path.cursors[br.path.primary].head.col)
        br.path_off = field_scroll(br.path_off, cells_count(cells), cur, field_cells(path, cw))
    }

    top, off = smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, unit)
    filebrowser_declare(a, &t.font, pane, top, off, now)
}
