package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// FileBrowser — the file-manager presentation of a directory: a top bar of square buttons, a places
// sidebar, and contents as a list or a grid of tiles. **The listing itself is still `FileTree`**
// (filetree.odin): the entries, the marks, the clipboard and the file ops are the same model
// under both presentations, so a chord does one thing in this program and the config chooses how
// it LOOKS. What lives here is only what the tree has no concept of — where you have been, where
// you keep shortcuts to, and how many tiles fit across.
//
// Host-independent in the same way filetree.odin is: no App, no Clay, no GL. filebrowser_ui.odin is
// the half that knows about the theme, the pointer and the pane rect.

// The two content presentations. Chosen by the top bar's rightmost button (and `^g`), and NOT by
// the zoom: font zoom scales whichever one is up, which is why this is a stored enum rather than
// a threshold on the cell size.
Browse_View :: enum {
    List,
    Grid,
}

// A sidebar shortcut: a display name and the directory it opens. Both owned. Order is the
// sidebar's order and the config block's order, which is why this is a slice and not a map.
Place :: struct {
    name: string,
    path: string,
}

// A grid tile's proportions. The width is in CELLS and the two bands are in TEXT ROWS, so the
// whole tile grows with the font zoom by construction — the whole of "scaled by zoom".
//
// The icon band is deliberately taller than two rows and the caption deliberately shorter than
// one: a tile is read icon-first, and a caption at body size competes with it. The caption is
// baked at FB_TILE_NAME_SCALE of the text size (font.odin's `small` cache) rather than elided
// harder, because the point is a quieter label, not a shorter one.
FB_TILE_CELLS :: 14
FB_TILE_ICON_ROWS :: 2.4
FB_TILE_NAME_SCALE :: 0.8

// The places sidebar's width, in cells. Wide enough for the default names plus their one-cell
// margin; the sidebar clips rather than reflows, as every other list in the program does.
FB_SIDE_CELLS :: 16

FileBrowser :: struct {
    view: Browse_View,

    // Where we have been and where we came back from — the two stacks behind [<] and [>], each
    // holding OWNED absolute paths. `fwd` is cleared by any navigation that is not a `back`,
    // which is the one rule that makes forward mean anything.
    back: [dynamic]string,
    fwd:  [dynamic]string,

    // The sidebar shortcuts (owned), loaded from the config's `[places]` block at startup and
    // rewritten there on every add/remove. Never edited by the visual config editor: it is a
    // list of paths, and the pane you point at directories with is a better editor for it than
    // a settings row could be.
    places: [dynamic]Place,

    // Transient frame state, written where the hit is taken and read by the declaration — the
    // hovered thing under the pointer, one per kind of target the pane has (rule 6). `cols` is
    // the grid's current column count, written by filebrowser_frame because the KEYBOARD needs it:
    // Up/Down move by a row, and only geometry knows how wide a row is.
    hover_row:   int,
    hover_place: int,
    hover_seg:   int,
    hover_btn:   Browse_Btn,
    cols:        int,
}

// The top bar's fixed buttons, left to right — the path segments between them are not here
// because there is an arbitrary number of those and they are keyed by index.
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
}

filebrowser_places_clear :: proc(br: ^FileBrowser) {
    for p in br.places {
        delete(p.name)
        delete(p.path)
    }
    clear(&br.places)
}

// --- history ---

// Go to `dir`, remembering where we were. The forward stack is dropped: arriving somewhere by
// any route other than [>] makes what was ahead of you unreachable, which is what every browser
// does and what stops [>] pointing at a branch you have left.
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
    target := strings.clone(dir, context.temp_allocator) // ft.dir is freed by the load
    filetree_load(ft, target)
}

filebrowser_can_back :: proc(br: ^FileBrowser) -> bool {
    return len(br.back) > 0
}

filebrowser_can_forward :: proc(br: ^FileBrowser) -> bool {
    return len(br.fwd) > 0
}

// [<]: pop the back stack onto the forward one. Both directions are the same two lines with the
// stacks swapped, hence the shared body — a `back` that pushed a different thing than `forward`
// pops is the classic way to make the two disagree after a few steps.
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
    target := strings.clone(dir, context.temp_allocator)
    filetree_load(ft, target)
}

// --- the path bar ---

// One clickable segment of the current directory: the name shown on the button and the absolute
// path clicking it goes to.
Path_Seg :: struct {
    name: string,
    path: string,
}

// Split an absolute path into its clickable segments, root first: "/a/b" -> "/", "a", "b". Both
// fields SLICE `dir` (bar the root's name), so they live exactly as long as it does — the caller
// is the declaration, which runs inside the frame that read `ft.dir`.
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

// The first segment to SHOW when the whole path is wider than the bar. A path bar elides from
// the LEFT — the directory you are in matters more than the root you came from — so this walks
// back from the last segment while the running width fits, and the caller marks the cut with a
// leading ellipsis. Widths are counted in runes, as clay_measure_dims measures them.
filebrowser_seg_first :: proc(segs: []Path_Seg, maxw: int) -> int {
    if len(segs) == 0 {
        return 0
    }
    w := 0
    for i := len(segs) - 1; i >= 0; i -= 1 {
        w += utf8.rune_count_in_string(segs[i].name) + 1 // the button's own one-cell separator
        if w > maxw && i < len(segs) - 1 {
            return i + 1 // the last segment always shows, however narrow the pane
        }
    }
    return 0
}

// --- the grid ---

// How many tiles fit across `width` pixels, at least one. Below one tile's width the grid becomes
// a single clipped column rather than dividing by zero or reflowing to nothing.
//
// `gap` goes BETWEEN tiles and not after the last one, so the width to divide is one gap wider
// than the region: n tiles need n*(tile+gap) - gap, which is the same test as (width+gap) / pitch.
filebrowser_grid_cols :: proc(width: i32, tile_w: f32, gap: f32 = 0) -> int {
    if tile_w <= 0 || width <= 0 {
        return 1
    }
    return max(1, int((f32(width) + gap) / (tile_w + gap)))
}

// How many tile ROWS `n` entries take. The grid's scroll unit is this row, not the entry, so the
// wheel and the viewport policy move whole rows of tiles — `ft.scroll` means "first visible row"
// under both presentations, which is what lets them share one field.
filebrowser_grid_rows :: proc(n, cols: int) -> int {
    if cols <= 0 {
        return 0
    }
    return (n + cols - 1) / cols
}

// The row a selection sits on, for the viewport policy: the entry index in List, its tile row in
// Grid. One proc so the scroll and the declaration cannot disagree about which unit is in force.
filebrowser_anchor :: proc(ft: ^FileTree, view: Browse_View, cols: int) -> int {
    if view == .List || cols <= 0 {
        return ft.selected
    }
    return ft.selected / cols
}

// --- places ---

// The shortcuts a fresh install starts with: HOME, the XDG-ish folders under it that actually
// EXIST, and the filesystem root. Nothing is invented — a machine with no ~/Videos gets no
// Videos row — because a shortcut to a directory that is not there is worse than a shorter list.
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

// Whether `path` is already a place — the predicate behind the context menu offering "add to
// places" or "remove from places" rather than both.
filebrowser_place_index :: proc(br: ^FileBrowser, path: string) -> int {
    for p, i in br.places {
        if p.path == path {
            return i
        }
    }
    return -1
}

// Add a directory to the sidebar under its base name, and persist the block. A duplicate path is
// a no-op rather than a second row: the sidebar is a set of destinations, and two rows opening
// the same directory is a listing bug the user has to clean up by hand.
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

// A name cut to `w` cells with a '~' marking the cut, in RUNES — the twin of filetree.odin's
// column padding, minus the padding: a tile's name is centred by the solver, so it needs the
// truncation and nothing else. Returns a slice of `s` when it already fits.
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
