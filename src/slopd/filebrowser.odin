package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "../txt"
// The file-manager presentation of a directory: a top bar of square buttons, a places sidebar,
// and contents as a list or a grid of tiles. The listing itself is still `FileTree` — entries,
// marks, clipboard and file ops are one model under both presentations — so what lives here is
// only what the tree has no concept of: where you have been, your shortcuts, and the tile count.
//
// Host-independent as filetree.odin is: no App, no Clay, no GL.

// Chosen by the top bar's rightmost button (and `^g`), never by the zoom — font zoom scales
// whichever is up, which is why this is a stored enum and not a threshold on the cell size.
Browse_View :: enum {
    List,
    Grid,
}

// Both owned. Order is the sidebar's and the config block's, hence a slice rather than a map.
Place :: struct {
    name: string,
    path: string,
}

// The width is in CELLS and the two bands in TEXT ROWS, so the tile grows with the font zoom by
// construction. The icon band is taller than two rows and the caption shorter than one: a tile
// is read icon-first, and the caption is baked smaller rather than elided harder, because the
// point is a quieter label and not a shorter one.
FB_TILE_CELLS :: 14
FB_TILE_ICON_ROWS :: 2.4
FB_TILE_NAME_SCALE :: 0.8

// In cells: the default names plus their one-cell margin. The sidebar clips rather than
// reflows, as every other list does.
FB_SIDE_CELLS :: 16

FileBrowser :: struct {
    view: Browse_View,

    // The two stacks behind [<] and [>], each of OWNED absolute paths. `fwd` is cleared by any
    // navigation that is not a `back`, which is what makes forward mean anything.
    back: [dynamic]string,
    fwd:  [dynamic]string,

    // Owned; loaded from the config's `[places]` block and rewritten there on every add or
    // remove. Never edited by the config pane: pointing at a directory is the better editor.
    places: [dynamic]Place,

    // The bar's second state: a text line holding the browsed directory, opened by a press on
    // the bar's empty space. `path_off` is the first rune shown — a long line is cut at the
    // START, where the button bar elides too, because the end of a path is what you work in.
    path_edit: bool,
    path:      txt.Doc,
    path_off:  int,

    // Written where the hit is taken and read by the declaration: the hovered thing, one field
    // per kind of target (rule 6). `cols` is published for the keyboard, since Up/Down move by
    // a grid row and only the geometry knows how wide one is.
    // Which column the KEYBOARD drives, and where it sits in the places list. Tab moves between
    // them; the mouse reaches either without asking, so this is only ever about the arrows.
    on_places: bool,
    place_sel: int,

    hover_row:   int,
    hover_place: int,
    hover_seg:   int,
    hover_btn:   Browse_Btn,
    cols:        int,
}

// Left to right. The path segments between them are keyed by index instead, being arbitrary in
// number.
Browse_Btn :: enum {
    None,
    Back,
    Forward,
    Reload,
    View,
}

filebrowser_init :: proc(br: ^FileBrowser) {
    br.hover_row, br.hover_place, br.hover_seg = -1, -1, -1
    br.cols = 1
    txt.doc_init(&br.path)
    places := config_places(context.allocator)
    if len(places) == 0 {
        places = filebrowser_default_places(context.allocator)
    }
    for p in places {
        append(&br.places, p) // takes ownership of both strings
    }
    delete(places)
}

filebrowser_destroy :: proc(br: ^FileBrowser) {
    for p in br.back {
        delete(p)
    }
    delete(br.back)
    for p in br.fwd {
        delete(p)
    }
    delete(br.fwd)
    filebrowser_places_clear(br)
    delete(br.places)
    txt.doc_destroy(&br.path)
}

filebrowser_places_clear :: proc(br: ^FileBrowser) {
    for p in br.places {
        delete(p.name)
        delete(p.path)
    }
    clear(&br.places)
}

// --- history ---

// The forward stack is dropped: arriving by any route other than [>] makes what was ahead
// unreachable, which stops [>] pointing at a branch you have left.
filebrowser_navigate :: proc(br: ^FileBrowser, ft: ^FileTree, dir: string) {
    if dir == "" || dir == ft.dir {
        return
    }
    if ft.dir != "" {
        append(&br.back, strings.clone(ft.dir))
    }
    for p in br.fwd {
        delete(p)
    }
    clear(&br.fwd)
    filetree_goto(ft, dir)
}

filebrowser_can_back :: proc(br: ^FileBrowser) -> bool {
    return len(br.back) > 0
}

filebrowser_can_forward :: proc(br: ^FileBrowser) -> bool {
    return len(br.fwd) > 0
}

// Both directions are the same two lines with the stacks swapped, hence the shared body: a
// `back` pushing something other than what `forward` pops is how the two drift apart.
filebrowser_back :: proc(br: ^FileBrowser, ft: ^FileTree) {
    filebrowser_step(&br.back, &br.fwd, ft)
}

filebrowser_forward :: proc(br: ^FileBrowser, ft: ^FileTree) {
    filebrowser_step(&br.fwd, &br.back, ft)
}

@(private = "file")
filebrowser_step :: proc(from, to: ^[dynamic]string, ft: ^FileTree) {
    if len(from) == 0 {
        return
    }
    dir := pop(from) // owned; handed to the other stack or freed below
    defer delete(dir)
    if ft.dir != "" {
        append(to, strings.clone(ft.dir))
    }
    filetree_goto(ft, dir)
}

// --- the path bar ---

// The name shown on the button, and the absolute path clicking it goes to.
Path_Seg :: struct {
    name: string,
    path: string,
}

// "/a/b" -> "/", "a", "b". Both fields slice `dir` (bar the root's name), so they live as long
// as it does — the caller is the declaration, inside the frame that read `ft.dir`.
filebrowser_segments :: proc(dir: string, alloc := context.temp_allocator) -> []Path_Seg {
    out := make([dynamic]Path_Seg, 0, 8, alloc)
    append(&out, Path_Seg{name = "/", path = "/"})
    if len(dir) == 0 || dir == "/" {
        return out[:]
    }
    start := 0
    for i in 0 ..< len(dir) + 1 {
        at_end := i == len(dir)
        if !at_end && dir[i] != '/' {
            continue
        }
        if i > start {
            append(&out, Path_Seg{name = dir[start:i], path = dir[:i]})
        }
        start = i + 1
    }
    return out[:]
}

// A path bar elides from the LEFT, so this walks back from the last segment while the running
// width fits and the caller marks the cut with an ellipsis. Widths in runes.
filebrowser_seg_first :: proc(segs: []Path_Seg, maxw: int) -> int {
    if len(segs) == 0 {
        return 0
    }
    w := 0
    for i := len(segs) - 1; i >= 0; i -= 1 {
        w += utf8.rune_count_in_string(segs[i].name) + 1 // plus the one-cell separator
        if w > maxw && i < len(segs) - 1 {
            return i + 1 // the last segment always shows
        }
    }
    return 0
}

// --- the path LINE --- The window (which runes show, where a column falls) is the shared
// field's, in field_ui.odin. What is path behaviour is what a typed line MEANS, which is this.

// `~`, an absolute path, or one relative to `base`. Cleaned and temp-allocated: the caller
// navigates with it at once.
filebrowser_path_resolve :: proc(base, arg: string, alloc := context.temp_allocator) -> string {
    s := strings.trim_space(arg)
    home := os.get_env("HOME", context.temp_allocator)
    raw: string
    switch {
    case s == "" || s == "~":
        raw = home != "" ? home : base
    case strings.has_prefix(s, "~/"):
        raw = filepath.join({home, s[2:]}, context.temp_allocator) or_else s
    case filepath.is_abs(s):
        raw = s
    case:
        raw = filepath.join({base, s}, context.temp_allocator) or_else s
    }
    return filepath.clean(raw, alloc) or_else strings.clone(raw, alloc)
}

// --- the grid ---

// At least one: below a tile's width the grid becomes a single clipped column. `gap` goes
// BETWEEN tiles and not after the last, so n tiles need n*(tile+gap) - gap, which is the same
// test as (width+gap) / pitch.
filebrowser_grid_cols :: proc(width: i32, tile_w: f32, gap: f32 = 0) -> int {
    if tile_w <= 0 || width <= 0 {
        return 1
    }
    return max(1, int((f32(width) + gap) / (tile_w + gap)))
}

// The grid's scroll unit is this row, not the entry, so `ft.scroll` means "first visible row"
// under both presentations and the two can share one field.
filebrowser_grid_rows :: proc(n, cols: int) -> int {
    if cols <= 0 {
        return 0
    }
    return (n + cols - 1) / cols
}

// The entry index in List, the tile row in Grid. One proc, so the scroll and the declaration
// cannot disagree about which unit is in force.
filebrowser_anchor :: proc(ft: ^FileTree, view: Browse_View, cols: int) -> int {
    if view == .List || cols <= 0 {
        return ft.selected
    }
    return ft.selected / cols
}

// --- places ---

// HOME, the XDG-ish folders under it that actually exist, and the filesystem root. Nothing is
// invented: a shortcut to a directory that is not there is worse than a shorter list.
filebrowser_default_places :: proc(alloc := context.allocator) -> []Place {
    out := make([dynamic]Place, 0, 8, alloc)
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" {
        append(&out, Place{strings.clone("Home", alloc), strings.clone(home, alloc)})
        for name in ([?]string{"Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"}) {
            p := filepath.join({home, name}, context.temp_allocator) or_else ""
            if os.is_dir(p) {
                append(&out, Place{strings.clone(name, alloc), strings.clone(p, alloc)})
            }
        }
    }
    append(&out, Place{strings.clone("Root", alloc), strings.clone("/", alloc)})
    return out[:]
}

// Behind the context menu offering "add to places" or "remove from places", not both.
filebrowser_place_index :: proc(br: ^FileBrowser, path: string) -> int {
    for p, i in br.places {
        if p.path == path {
            return i
        }
    }
    return -1
}

// Under its base name, persisting the block. A duplicate path is a no-op rather than a second
// row: the sidebar is a set of destinations.
filebrowser_place_add :: proc(br: ^FileBrowser, path: string) -> bool {
    if path == "" || filebrowser_place_index(br, path) >= 0 {
        return false
    }
    name := filepath.base(path)
    if name == "" || name == "/" {
        name = "Root"
    }
    append(&br.places, Place{strings.clone(name), strings.clone(path)})
    return config_places_write(br.places[:])
}

filebrowser_place_remove :: proc(br: ^FileBrowser, i: int) -> bool {
    if i < 0 || i >= len(br.places) {
        return false
    }
    delete(br.places[i].name)
    delete(br.places[i].path)
    ordered_remove(&br.places, i)
    return config_places_write(br.places[:])
}

// --- display ---

// Cut to `w` cells with a '~' marking the cut, in runes. A tile's name is centred by the solver,
// so it needs the truncation and no padding. Returns a slice of `s` when it already fits.
filebrowser_elide :: proc(s: string, w: int, alloc := context.temp_allocator) -> string {
    if w <= 0 {
        return ""
    }
    if utf8.rune_count_in_string(s) <= w {
        return s
    }
    b := strings.builder_make(alloc)
    i := 0
    for r in s {
        if i == w - 1 {
            break
        }
        strings.write_rune(&b, r)
        i += 1
    }
    strings.write_byte(&b, '~')
    return strings.to_string(b)
}
