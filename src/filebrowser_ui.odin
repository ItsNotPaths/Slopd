package main

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:unicode/utf8"
import clay "../bindings/clay"

// The file browser pane's UI half — the same six procs every pane has (filetree_ui.odin is the
// short example), grown by the one thing this pane has that the others do not: **four kinds of
// thing to point at.** A press can land on a top-bar button, a path segment, a places row or an
// entry, so the hit test returns a TAGGED STRUCT rather than an index, exactly as the plan's
// rule for a pane with several kinds of target says (and never a sentinel scheme layered on an
// int, which is how the four would eventually disagree about what -2 meant).
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
// **The model underneath is `FileTree`.** The entries, the selection, the marks, the clipboard
// and every file op are the aux pane's, unchanged — this file decides how they LOOK and what a
// pointer can reach. That is what makes `file_pane: ls | browser` a presentation switch rather
// than a second file manager, and what keeps one set of chords true in both.

// The list row's extra height and the top bar's, in logical pixels. The bar is taller than a row
// because its buttons are SQUARE: the height is also their width, so a cramped bar would give
// three cramped buttons.
FB_ROW_PAD :: 2
FB_BAR_PAD :: 5

// A tile's padding and the gap between tiles, in logical pixels. The tile's WIDTH is in cells
// (FB_TILE_CELLS, filebrowser.odin) so it scales with the font zoom; these are chrome, and
// chrome scales with the DPI only.
FB_TILE_PAD :: 4
FB_TILE_GAP :: 6

// The top bar's glyphs. Box-drawing and arrows are in the bundled subset (download-deps.sh keeps
// U+2190-21FF, U+25A0-25FF and U+27F0-27FF), so these are real glyphs rather than ASCII stand-ins.
FB_ICON_BACK :: "◀"
FB_ICON_FWD :: "▶"
FB_ICON_RELOAD :: "⟳"
FB_ICON_GRID :: "▦"
FB_ICON_LIST :: "▤"

// What the pointer is over. `index` means whichever list `kind` names — an ENTRY index for a
// row, a place index, a segment index — and is -1 for a button, whose identity is `btn`.
//
// `PathBar` is the path region itself and NOT one of its segment buttons: the whitespace after
// the last segment, which is the gesture that turns the bar into a text line (and, once it is
// one, the whole line).
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

// The pane's fixed geometry: the content area inside the focus ring, then the three regions it
// splits into, then the row metrics. Pure, and the single source every phase sizes itself from —
// the reason the four hit tests, the scroll and the declaration cannot drift apart.
//
// The sidebar is capped at half the pane: at a narrow split a fixed 16-cell sidebar would leave
// the contents narrower than one tile, and a places list you cannot browse FROM is furniture.
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

// A grid tile's size in pixels: the icon band, the caption row, and the padding either side.
// Both bands are ROUNDED to whole pixels — a fractional tile height would put every row of the
// grid on a fractional boundary, which is the same reason the cell advance is rounded at bake.
//
// **Capped at the content width (rule 8).** At a narrow split 14 cells is wider than the region
// the tiles are in, and a fixed box that outgrows its parent is still a HIT box — it would be
// clickable from beyond the pane's edge while the clip group quietly hid the overflow. Capping
// leaves one usable column at any width instead.
filebrowser_tile :: proc(scale, line_h, cell_w: f32, max_w: i32) -> (w, h: f32) {
    w = min(f32(FB_TILE_CELLS) * cell_w, f32(max(0, max_w)))
    icon_h, name_h := filebrowser_tile_bands(line_h)
    h = icon_h + name_h + 2 * math.round(FB_TILE_PAD * scale)
    return
}

// The two bands inside a tile: the icon's, and the caption's at its reduced size.
filebrowser_tile_bands :: proc(line_h: f32) -> (icon_h, name_h: f32) {
    return math.round(line_h * FB_TILE_ICON_ROWS), math.round(line_h * FB_TILE_NAME_SCALE)
}

// The gap BETWEEN tiles, both ways. Whole pixels, and asked for here rather than inlined at each
// use: the column count, the scroll unit and the declaration all have to space the grid by the
// same number or the tween would land a few pixels off the row it is easing to.
filebrowser_tile_gap :: proc(scale: f32) -> f32 {
    return math.round(max(0, FB_TILE_GAP * scale))
}

// How many runes of a caption fit across a tile at the caption's size. Smaller text means MORE
// characters in the same width, which is the one thing shrinking it buys back.
filebrowser_tile_name_cells :: proc() -> int {
    return int(math.floor(f32(FB_TILE_CELLS) / f32(FB_TILE_NAME_SCALE))) - 1
}

// How many content rows fit and, in Grid, how many tiles fit across. One call answers both
// because the two are the same question asked of the two presentations, and a caller that had to
// pick which proc to ask would be the place the two answers drifted.
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
    // In PITCH, not in tile heights: a row of tiles occupies its own height plus the gap under
    // it, and counting bare tiles would claim room for one more row than the grid has.
    return max(0, int(f32(content.h) / (th + gap))), filebrowser_grid_cols(content.w, tw, gap)
}

// The height of one CONTENT ROW — a list row, or a row of tiles — which is the unit both the
// viewport and its tween count in. One proc so the scroll policy, the animation and the
// declaration cannot disagree about what "a row" is in the presentation that is up.
filebrowser_row_h :: proc(view: Browse_View, row_h: i32, scale, line_h, cell_w: f32) -> i32 {
    if view == .List {
        return row_h
    }
    // A tile's HEIGHT does not depend on the width cap, so the cap passed here is immaterial —
    // the caller's content width is not in scope at every call site, and asking for it would
    // make three procs take a parameter one of them ignores.
    _, tile_h := filebrowser_tile(scale, line_h, cell_w, max(i32))
    return i32(tile_h + filebrowser_tile_gap(scale)) // the PITCH: the tile and the gap under it
}

// Move the viewport to follow the selection, under the shared `scroll_mode` policy. The unit is
// the CONTENT ROW — an entry in List, a row of tiles in Grid — which is why the anchor and the
// total both go through filebrowser_anchor / filebrowser_grid_rows rather than being taken as
// entry counts here.
filebrowser_scroll_apply :: proc(a: ^App, rows, cols: int, center: bool) {
    ft := &a.tree
    view := a.filebrowser.view
    total := view == .List ? len(ft.entries) : filebrowser_grid_rows(len(ft.entries), cols)
    anchor := filebrowser_anchor(ft, view, cols)
    list_scroll_apply(&ft.scroll, &ft.scroll_detached, anchor, rows, total, center, pane_input_at(a))
}

// The path region's box: the bar less its four square buttons. The declaration lays it out by
// the solver, so this is for the phases the solver cannot answer — the press that puts a caret
// on the column it landed on.
filebrowser_path_rect :: proc(bar: Rect, bar_h: i32) -> Rect {
    return Rect{bar.x + 3 * bar_h, bar.y, max(0, bar.w - 4 * bar_h), bar_h}
}

// How many cells the segments may use — the path region's, which is also what the LINE scrolls
// inside (field_cells, on the same rect), so both states of the bar cut the path at the same
// character. Pure, and asked by both the hit test and the declaration.
filebrowser_path_cells :: proc(bar: Rect, bar_h: i32, cell_w: f32) -> int {
    return field_cells(filebrowser_path_rect(bar, bar_h), cell_w)
}

// Which of the four kinds of target the pointer is over. Probed in the order a press should be
// offered them — chrome first, contents last — though the boxes do not overlap, so the order is
// documentation rather than precedence. Resolves against the tree the LAST frame declared.
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
    // The path region minus its buttons: the whitespace AFTER the last segment, and the whole of
    // the line while it is being edited (no segment is declared then, so this is all that is left).
    if clay.PointerOver(clay.ID("fb_path")) {
        return FB_Hit{kind = .PathBar, index = -1}
    }
    for i in 0 ..< len(a.filebrowser.places) {
        if clay.PointerOver(clay.ID("fb_place", u32(i))) {
            return FB_Hit{kind = .Place, index = i}
        }
    }
    // Over the window that was PAINTED (`top`, the animated position) rather than the target,
    // and over as many rows as are ON SCREEN — see filetree_hit and list_visible_rows.
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

// Apply a pending LEFT press. Chrome activates on a single press (a button is not a list row —
// there is nothing to select first), an entry selects on one and opens on two, and a press that
// hit nothing is left for whoever else is drawing.
//
// `path` and `cw` are the path region and the cell width, for the one press that needs a COLUMN
// rather than a box: a press inside the open text line puts the caret where it landed.
filebrowser_click :: proc(a: ^App, segs: []Path_Seg, hit: FB_Hit, path: Rect, cw: f32) {
    br := &a.filebrowser
    // A press anywhere else abandons the line, as every desktop's does — and does NOT consume
    // the press, which still means whatever it landed on.
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
        // The empty space after the last segment TURNS THE BAR INTO A LINE (Dolphin's gesture);
        // a press inside a line that is already open is the field's own — caret, word, value,
        // and the capture a drag-select extends from.
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

// Apply a pending RIGHT press: work out WHAT it landed on, select it if it is a row, then open
// the menu for that. **All four kinds of target get a menu of their own** — a segment's and a
// place's name a directory, and a press on the contents' empty space is not a miss but the
// DIRECTORY's menu (paste, add to places, reload), the gesture every file manager gives you for
// "act on where I am".
filebrowser_rclick :: proc(a: ^App, segs: []Path_Seg, hit: FB_Hit) {
    if !rect_hit(a.lay.aux, a.mouse.rclick_x, a.mouse.rclick_y) {
        return // not our pane; whoever owns that region may claim it
    }
    if !mouse_take_rclick(a) {
        return
    }
    br := &a.filebrowser
    ft := &a.tree
    on := Menu_Target{ft.dir, .Dir} // a button's press, and a miss, both act on where you are
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

// The top bar's verbs. Package-level and switch-shaped because both the pointer and the keyboard
// reach every one of them (`^Left`, `^Right`, `^r`, `^g`), which is the pane's whole keyboard-
// parity obligation in one proc.
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

// --- the path bar's two states ---
// A row of BUTTONS, until you press the whitespace after them: then it is a text line on the same
// path, which is the one gesture that lets you TYPE a destination instead of walking to it. Enter
// goes there; Esc, and a press anywhere else, put the buttons back. Transient, never a mode.

// Whether the line is open AND owns the keyboard. One predicate, so the char callback, the key
// routing and the blink cannot disagree about who is being typed into.
filebrowser_path_live :: proc(a: ^App) -> bool {
    if !a.filebrowser.path_edit || a.focus != .Aux {
        return false
    }
    return a.aux_mode == .FileTree && a.file_pane == .Browser
}

// Open the line on the browsed directory, caret at the end — the end is the part you edit.
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

// Enter: go where the line says. A path that is not a directory KEEPS THE LINE OPEN with the
// text still in it — the typo is on screen and one keystroke from being fixed, where closing
// would throw away what was typed and leave nothing to correct.
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

// The open line as the pointer sees it — the box the press, the drag and the window all resolve
// against. `path` is filebrowser_path_rect's, which is the box the field was declared into.
filebrowser_path_box :: proc(a: ^App, path: Rect, cw: f32) -> Field_Box {
    br := &a.filebrowser
    return {doc = &br.path, target = FIELD_PATH, r = path, off = br.path_off, cw = cw}
}

// Open the selection: descend into a directory THROUGH THE HISTORY (which is the whole
// difference from filetree_activate — a browser that forgets where you came from has no [◀]),
// or open the file in Slopd's own editor.
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

// Up to the parent directory, through the history. `filepath.dir` slices ft.dir, which the load
// inside navigate frees — navigate clones before loading, so this is safe as written and is the
// reason that clone is there.
filebrowser_parent :: proc(a: ^App) {
    ft := &a.tree
    if parent := filepath.dir(ft.dir); parent != ft.dir {
        filebrowser_navigate(&a.filebrowser, ft, parent)
    }
}

// Jump to place N (the `^1`..`^9` chords — the sidebar's keyboard twin). One-based, as the
// terminal's Alt+1..9 is.
filebrowser_place_open :: proc(a: ^App, n: int) {
    br := &a.filebrowser
    if n >= 1 && n <= len(br.places) {
        filebrowser_navigate(br, &a.tree, br.places[n - 1].path)
    }
}

// Declare the pane into the window's tree. Reads App, writes only Clay.
//
//   fb_pane        the content area inside the focus ring, clipping its own content
//     fb_bar       the top bar: three square buttons, the path, then the view toggle
//       fb_btn/b     one per Browse_Btn, square (its side IS the bar's height)
//       fb_path      the path, clipped: longer than the bar and it elides from the LEFT
//         fb_ell       the "…" marking an elision, when there is one
//         fb_seg/i     one per shown segment, keyed by SEGMENT index
//         fb_edit      instead of the two above while the line is open: the text field's Custom
//     fb_body      the two scrolling regions, side by side
//       fb_side      the places column, with a single-edge border as the rail between them
//         fb_place/i one per shortcut, the one matching the browsed dir in the accent colour
//       fb_content   the clip group the contents scroll inside
//         fb_item/i    List: one row per visible entry, keyed by ENTRY index
//         fb_grow/r    Grid: one row of tiles, holding fb_item/i tiles keyed the same way
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
    // The rows the content region TOUCHES, which is one more than fit whenever the region does
    // not divide evenly or a scroll is in progress. Counting the whole rows that fit leaves the
    // bottom row of tiles undeclared with 46px of it on screen (see list_visible_rows).
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
            // The sidebar's rail is a single-edge border rather than a drawn line (rule 5), and
            // the sidebar declares no background: the pane's panel() has already painted it.
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

            if clay.UI(clay.ID("fb_content"))(
                {
                    layout = {
                        // Fixed, not Grow, for the sidebar's reason: the row easing into view
                        // must not stretch the clip group it is inside (rule 8).
                        sizing          = {clay.SizingGrow(), clay.SizingFixed(f32(max(0, content.h)))},
                        layoutDirection = .TopToBottom,
                        // The grid's rows are spaced by the solver, which is what makes the
                        // PITCH filebrowser_row_h reports the real one. A list has no gap.
                        childGap        = br.view == .Grid ? u16(filebrowser_tile_gap(a.scale)) : 0,
                    },
                    // The tween's remainder rides on the clip, not on each row's y (rule 9).
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
    }
}

// The top bar. Every button is SQUARE — `SizingFixed(bar_h)` on both axes — which is what the
// design asks for and also what keeps the three icons on a common baseline whatever the zoom.
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
            // The bar's two states. The line is the shared one-line Field (field_ui.odin), the
            // config pane's text rows being the other instance — with a WINDOW, since a path is
            // read from its end.
            if br.path_edit {
                field_declare(
                    clay.ID("fb_edit"),
                    {doc = &br.path, off = br.path_off, now = now, caret = filebrowser_path_live(a)},
                )
            } else {
                filebrowser_declare_segs(a, segs, first, lh, cw)
            }
        }

        // The view toggle shows the view it would GIVE you, not the one you are in: a button is
        // a verb, and a grid icon that means "you are in grid" is the same pixels meaning the
        // opposite thing.
        icon := br.view == .List ? FB_ICON_GRID : FB_ICON_LIST
        filebrowser_declare_btn(a, .View, icon, true, bar_h, lh)
    }
}

// The path as BUTTONS: one per segment from `first` on, behind a '…' when the head is cut.
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

// One square top-bar button. A disabled one (no history behind [◀]) draws its icon in the border
// colour and takes no hover tint — it is still THERE, so the bar does not reflow as you navigate.
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

// List contents: the filetree's row with a type icon in front of it. The icon is ONE CELL and
// is a glyph like any other (font.odin bakes the icon face into the same atlas), so the row is
// still text on the cell grid — no image, no second texture, nothing to cache.
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

// An entry's icon as a one-rune string, or ok=false when icons are off or no icon face was
// vendored — the pane then draws exactly what it drew before them. Temp-allocated, like every
// other formatted label in the chrome: Clay's command list points at it and the frame's arena
// outlives EndLayout.
filebrowser_icon :: proc(a: ^App, f: ^Font, e: ^FileEntry) -> (s: string, ok: bool) {
    if !a.file_icons || !f.icons_ok {
        return "", false
    }
    r := file_icon(e.name, e.is_dir)
    return utf8.runes_to_string({r}, context.temp_allocator), true
}

// What a tile's painters need. Handed to the bridge as `customData`, so these live in the
// frame's temp arena and outlive EndLayout.
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

// A tile's icon, baked at the tile's own size. A `Custom` because this is the one thing in the
// chrome that is not text at the text size — a glyph can only be drawn at the size it was baked
// (there is no per-quad scale), and Clay's Text command is the atlas's one size.
filebrowser_paint_icon :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    ic := (^FB_Icon)(user)
    if ic != nil {
        icon_draw(t, ic.icon, r, ic.px, ic.color)
    }
    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    flush_pane(t, clip, win_w, win_h)
}

// A tile's caption, at the reduced size — a Custom for the icon's reason, from the other side:
// Clay lays text out at the atlas size, and this is deliberately smaller than that. Centred
// from the rune count, which a fixed advance makes exact (text_sized_cell).
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

// Grid contents: rows of tiles, each a coloured swatch over an elided name. The swatch is a
// Rectangle rather than a glyph because it is the one thing here that is not text — there are no
// thumbnails to decode, and a filled block says "directory / program / file" at any zoom.
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
                    // The tile's picture: the type icon where there is an icon face, and the
                    // plain coloured swatch where there is not (download-deps.sh can vendor no
                    // icons at all). Same box either way, so the grid does not reflow.
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
                    // The caption, at FB_TILE_NAME_SCALE of the text size — its own Custom,
                    // since Clay only lays text out at the atlas's one size.
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

// An entry's colour, which is also its tile swatch's: directories read as directories in both
// presentations, a file in the unsaved ring keeps the urgent tint the filetree gives it, and
// anything with the execute bit is called out — the browser's answer to the filetree's mode
// column, which a tile has no room for.
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

// The pane's per-frame entry point: the template's four phases, with the hover written per KIND
// of target from the one hit the click consumes, and `cols` published for the keyboard (Up/Down
// move by a grid row, and only the geometry knows how wide one is).
filebrowser_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    br := &a.filebrowser
    area, bar, _, content, row_h, bar_h := filebrowser_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    rows, cols := filebrowser_rows(content, br.view, row_h, a.scale, t.font.line_height, t.font.cell_w)
    br.cols = cols

    // The window the LAST frame painted is what the pointer is over, so the hit resolves
    // against the ANIMATED top; smooth_scroll re-aims the tween, and app_next_wake schedules
    // the next frame off it. The view is read twice for the editor's reason (editor_frame).
    unit := filebrowser_row_h(br.view, row_h, a.scale, t.font.line_height, t.font.cell_w)
    top, off0 := smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, unit)

    // The open line is the pane's, not the program's: whatever took the keyboard away from this
    // pane also closed the line, or it would be waiting for keys that go somewhere else now.
    if br.path_edit && !filebrowser_path_live(a) {
        filebrowser_path_cancel(a)
    }

    segs := filebrowser_segments(a.tree.dir)
    path := filebrowser_path_rect(bar, bar_h)
    first_seg := filebrowser_seg_first(segs, filebrowser_path_cells(bar, bar_h, t.font.cell_w))
    hit := filebrowser_hit(a, segs, first_seg, top, list_visible_rows(content.h, off0, unit), cols)
    br.hover_row = hit.kind == .Row ? hit.index : -1
    br.hover_place = hit.kind == .Place ? hit.index : -1
    br.hover_seg = hit.kind == .Segment ? hit.index : -1
    br.hover_btn = hit.kind == .Button ? hit.btn : .None

    filebrowser_click(a, segs, hit, path, t.font.cell_w)
    filebrowser_rclick(a, segs, hit)
    filebrowser_scroll_apply(a, rows, cols, a.scroll_mode == .Middle)

    // A live drag extends the line's selection, beside the click for editor_drag's reason — the
    // gesture that walks the caret off the end must move the window in the frame that moved it,
    // which is the next two statements in order.
    if br.path_edit {
        field_drag(a, filebrowser_path_box(a, path, t.font.cell_w), now)
    }
    // The window follows the caret the way the listing's follows the selection, and for the same
    // reason: an edit that put the caret off the end must not leave you typing blind.
    if br.path_edit && len(br.path.lines) > 0 {
        n := line_len(&br.path.lines[0])
        cur := br.path.cursors[br.path.primary].head.col
        br.path_off = field_scroll(br.path_off, n, cur, field_cells(path, t.font.cell_w))
    }

    off: i32
    top, off = smooth_scroll(&a.tree.scroll_anim, a.tree.scroll, now, unit)
    filebrowser_declare(a, &t.font, pane, top, off, now)
}
