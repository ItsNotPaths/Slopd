package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "ui"

// A self-contained dired-style listing: read a directory, move or enter, pre-format each row's
// fixed-width columns. No App and no GL — the host wires up rendering, the unsaved-ring prefix
// and what Enter does.

FT_NAME_W :: 24 // name column width, in cells (padded / truncated)
FT_SIZE_W :: 8 // size column width, right-justified

FileEntry :: struct {
    name:    string, // base name (owned)
    path:    string, // absolute path (owned)
    is_dir:  bool,
    exec:    bool, // the owner's execute bit: something the host can offer to run
    display: string, // owned "<mode>  <name>  <size>  <mtime>"; the host adds the prefix
}

// Duplicate (Copy) or move (Cut), decided by the chord that FILLED the clipboard rather than by
// a separate toggle.
Clip_Mode :: enum {
    Copy,
    Cut,
}

FileTree :: struct {
    dir:      string, // current directory, absolute (owned)
    entries:  [dynamic]FileEntry,
    selected: int,
    scroll:   int, // first visible row: the viewport top
    hover:    int, // the entry under the pointer, or -1; transient frame state

    // Wheel-detached at this glfw time; 0 = following the selection. See list_scroll_apply.
    scroll_detached: f64,

    // The tween toward `scroll`, in rows: `scroll` is where the view is going, this is where it
    // IS, and the two differ for SCROLL_DUR after a move. Shared by both presentations, since
    // both scroll this one field and only one is ever on screen.
    scroll_anim: ui.Anim,

    // Two sets, deliberately separate. `marks` is the MULTI-SELECTION: what a file op acts on
    // instead of the row under the cursor. `clip` is the CLIPBOARD: what copy/cut took, owned
    // and kept across navigation, applied by `clip_mode`.
    marks:     [dynamic]string,
    clip:      [dynamic]string,
    clip_mode: Clip_Mode,
}

filetree_init :: proc(ft: ^FileTree) {
    ft.hover = -1
    cwd, err := os.get_working_directory(context.allocator)
    if err != nil {
        cwd = strings.clone(".")
    }
    defer delete(cwd)
    filetree_load(ft, cwd)
}

filetree_destroy :: proc(ft: ^FileTree) {
    filetree_clear(ft)
    delete(ft.entries)
    filetree_marks_reset(ft)
    delete(ft.marks)
    filetree_clip_clear(ft)
    delete(ft.clip)
}

// ".." is always first, bar at the filesystem root; the rest sort directories-first, then by
// name.
filetree_load :: proc(ft: ^FileTree, dir: string) {
    filetree_clear(ft)
    ft.dir = strings.clone(dir)
    ft.selected = 0
    ft.scroll = 0 // do not carry the old dir's viewport

    if f, oerr := os.open(dir); oerr == nil {
        defer os.close(f)
        it := os.read_directory_iterator_create(f)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            append(&ft.entries, entry_from(dir, fi))
        }
    }
    slice.sort_by(ft.entries[:], entry_less)

    parent := filepath.dir(dir) // slices into dir; not owned
    if parent != dir { // not at the filesystem root
        inject_at(&ft.entries, 0, dotdot_entry(parent))
    }
}

filetree_move :: proc(ft: ^FileTree, delta: int) {
    if len(ft.entries) == 0 {
        return
    }
    ft.selected = clamp(ft.selected + delta, 0, len(ft.entries) - 1)
}

filetree_selected :: proc(ft: ^FileTree) -> ^FileEntry {
    if ft.selected < 0 || ft.selected >= len(ft.entries) {
        return nil
    }
    return &ft.entries[ft.selected]
}

// Right / l. A no-op on a file.
filetree_enter :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || !e.is_dir {
        return
    }
    target := strings.clone(e.path, context.temp_allocator) // freed by the reload
    filetree_load(ft, target)
}

// Load `dir` and put the cursor back on the directory we left, when the new listing holds it.
// Every navigation goes through here, so stepping out lands on where you were under both
// presentations. Both paths are cloned into temp: the load frees ft.dir, which they can alias.
filetree_goto :: proc(ft: ^FileTree, dir: string) {
    target := strings.clone(dir, context.temp_allocator)
    came_from := strings.clone(ft.dir, context.temp_allocator)
    filetree_load(ft, target)
    for e, i in ft.entries {
        if e.path == came_from {
            ft.selected = i
            break
        }
    }
}

// Left / h, re-selecting the directory we came from.
filetree_parent :: proc(ft: ^FileTree) {
    parent := filepath.dir(ft.dir) // slices into ft.dir; not owned
    if parent == ft.dir { // already at the filesystem root
        return
    }
    filetree_goto(ft, parent)
}

// Descend into a directory, or report a file path to open. ("", false) when it descended.
filetree_activate :: proc(ft: ^FileTree) -> (path: string, is_file: bool) {
    e := filetree_selected(ft)
    if e == nil {
        return "", false
    }
    if e.is_dir {
        target := strings.clone(e.path, context.temp_allocator) // freed by the reload
        filetree_load(ft, target)
        return "", false
    }
    return e.path, true
}

// --- marks, clipboard and file operations --- Marking says WHAT an op acts on; copy/cut fill
// the clipboard from that, or from the row under the cursor, and say what paste will DO. Every
// op that changes the directory reloads the listing, keeping the cursor row where it can.

// ".." is never marked.
filetree_mark_toggle :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || e.name == ".." {
        return
    }
    for p, i in ft.marks {
        if p == e.path {
            delete(ft.marks[i])
            ordered_remove(&ft.marks, i)
            return
        }
    }
    append(&ft.marks, strings.clone(e.path))
}

// Idempotent, unlike the toggle, so the sweep re-crossing a row never un-marks it.
filetree_mark_add :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || e.name == ".." || filetree_marked(ft, e.path) {
        return
    }
    append(&ft.marks, strings.clone(e.path))
}

// Mark the current row, step, mark the row it lands on — so Shift+Up/Down paints a run.
filetree_mark_sweep :: proc(ft: ^FileTree, delta: int) {
    filetree_mark_add(ft)
    filetree_move(ft, delta)
    filetree_mark_add(ft)
}

// The "unmark" chord.
filetree_marks_reset :: proc(ft: ^FileTree) {
    for p in ft.marks {
        delete(p)
    }
    clear(&ft.marks)
}

filetree_marked :: proc(ft: ^FileTree, path: string) -> bool {
    for p in ft.marks {
        if p == path {
            return true
        }
    }
    return false
}

filetree_clip_clear :: proc(ft: ^FileTree) {
    for p in ft.clip {
        delete(p)
    }
    clear(&ft.clip)
}

// From the marked set, or the row under the cursor when nothing is marked, recording which the
// paste will be. The paths are OWNED: the listing they came from is freed by the next
// navigation. An empty take leaves the previous clipboard intact.
filetree_clip_take :: proc(ft: ^FileTree, mode: Clip_Mode) {
    src := filetree_targets(ft, len(ft.marks) > 0, context.temp_allocator)
    if len(src) == 0 {
        return
    }
    filetree_clip_clear(ft)
    for p in src {
        append(&ft.clip, strings.clone(p))
    }
    ft.clip_mode = mode
}

// For the caller that NAMES what to act on rather than pointing at it: the context menu opened
// on a path-bar segment or a places row.
filetree_clip_one :: proc(ft: ^FileTree, path: string, mode: Clip_Mode) {
    if path == "" {
        return
    }
    filetree_clip_clear(ft)
    append(&ft.clip, strings.clone(path))
    ft.clip_mode = mode
}

// Copy duplicates, Cut moves. Each destination name is made unique, so nothing is clobbered. A
// cut is SPENT by its paste, since the sources are gone; a copy stays, so the same set can go
// into several directories.
filetree_paste :: proc(ft: ^FileTree) {
    if len(ft.clip) == 0 {
        return
    }
    for src in ft.clip {
        dst := fs_unique_dest(ft.dir, filepath.base(src)) // base slices src; used at once
        if ft.clip_mode == .Cut {
            // An atomic move on one filesystem; across devices (EXDEV) rename cannot relink
            // the inode, so fall back to copy + remove.
            if os.rename(src, dst) != nil && fs_copy_path(src, dst) {
                fs_remove_path(src)
            }
        } else {
            fs_copy_path(src, dst)
        }
    }
    if ft.clip_mode == .Cut {
        filetree_clip_clear(ft)
        filetree_marks_reset(ft)
    }
    filetree_reload(ft)
}

// The whole marked set, or the highlighted entry, with ".." excluded. The strings are BORROWED
// from the tree, so use them before the next reload. The host turns these into a staged
// `rm -rf` line, not a delete behind a modal prompt.
filetree_targets :: proc(ft: ^FileTree, marked: bool, alloc := context.allocator) -> []string {
    if marked {
        return slice.clone(ft.marks[:], alloc)
    }
    e := filetree_selected(ft)
    if e == nil || e.name == ".." {
        return nil
    }
    out := make([]string, 1, alloc)
    out[0] = e.path
    return out
}

// Keeps the cursor near where it was, which filetree_load would reset. ft.dir is freed by the
// load, so clone before handing it back.
filetree_reload :: proc(ft: ^FileTree) {
    if ft.dir == "" {
        return
    }
    idx := ft.selected
    dir := strings.clone(ft.dir, context.temp_allocator)
    filetree_load(ft, dir)
    ft.selected = clamp(idx, 0, max(0, len(ft.entries) - 1))
}

// --- internals ---

// The bare name if free, else "<stem>_copy<ext>", "_copy2", … so a paste never overwrites.
@(private = "file")
fs_unique_dest :: proc(dir, name: string) -> string {
    base := filepath.join({dir, name}, context.temp_allocator) or_else ""
    if !os.exists(base) {
        return base
    }
    ext := filepath.ext(name) // includes the dot, or "" 
    stem := name[:len(name) - len(ext)]
    for i in 1 ..< 10000 {
        suffix := i == 1 ? "_copy" : fmt.tprintf("_copy%d", i)
        cand := filepath.join({dir, fmt.tprintf("%s%s%s", stem, suffix, ext)}, context.temp_allocator) or_else ""
        if !os.exists(cand) {
            return cand
        }
    }
    return base
}

// False if any leaf failed. Best-effort: a partial tree may remain.
@(private = "file")
fs_copy_path :: proc(src, dst: string) -> bool {
    if os.is_dir(src) {
        os.make_directory(dst) // "already exists" is fine; fs_unique_dest kept it fresh
        ok := true
        if f, oerr := os.open(src); oerr == nil {
            defer os.close(f)
            it := os.read_directory_iterator_create(f)
            defer os.read_directory_iterator_destroy(&it)
            for fi in os.read_directory_iterator(&it) {
                cs := filepath.join({src, fi.name}, context.temp_allocator) or_else ""
                cd := filepath.join({dst, fi.name}, context.temp_allocator) or_else ""
                if !fs_copy_path(cs, cd) {
                    ok = false
                }
            }
        }
        return ok
    }
    data, rerr := os.read_entire_file(src, context.allocator)
    if rerr != nil {
        return false
    }
    defer delete(data)
    return os.write_entire_file(dst, data) == nil
}

// A directory is emptied first, with its handle closed before the rmdir. Only the cross-device
// Cut path uses this: a user-facing delete is a staged `rm -rf`.
@(private = "file")
fs_remove_path :: proc(path: string) -> bool {
    if os.is_dir(path) {
        if f, oerr := os.open(path); oerr == nil {
            it := os.read_directory_iterator_create(f)
            for fi in os.read_directory_iterator(&it) {
                fs_remove_path(filepath.join({path, fi.name}, context.temp_allocator) or_else "")
            }
            os.read_directory_iterator_destroy(&it)
            os.close(f)
        }
    }
    return os.remove(path) == nil
}

@(private = "file")
filetree_clear :: proc(ft: ^FileTree) {
    for &e in ft.entries {
        delete(e.name)
        delete(e.path)
        delete(e.display)
    }
    clear(&ft.entries)
    delete(ft.dir)
    ft.dir = ""
}

@(private = "file")
entry_less :: proc(a, b: FileEntry) -> bool {
    if a.is_dir != b.is_dir {
        return a.is_dir // directories first
    }
    return a.name < b.name
}

@(private = "file")
entry_from :: proc(dir: string, fi: os.File_Info) -> FileEntry {
    path := filepath.join({dir, fi.name}) or_else strings.clone(fi.name)
    // A symlink to a directory navigates and tints like one, so stat follows the link; the mode
    // column still shows 'l'. The exec bit comes from the same stat, since a symlink's own mode
    // is always rwx.
    is_dir := fi.type == .Directory
    exec := .Execute_User in fi.mode
    if fi.type == .Symlink {
        if target, err := os.stat(path, context.temp_allocator); err == nil {
            is_dir = target.type == .Directory
            exec = .Execute_User in target.mode
        }
    }
    mbuf: [10]u8
    sbuf: [16]u8
    tbuf: [24]u8
    return FileEntry {
        name   = strings.clone(fi.name),
        path   = path,
        is_dir = is_dir,
        exec   = exec,
        display = format_row(
            mode_string(mbuf[:], fi.type, fi.mode),
            fi.name,
            size_string(sbuf[:], fi.size),
            time_string(tbuf[:], fi.modification_time),
        ),
    }
}

@(private = "file")
dotdot_entry :: proc(parent: string) -> FileEntry {
    e := FileEntry {
        name   = strings.clone(".."),
        path   = strings.clone(parent), // parent is a slice
        is_dir = true,
    }
    mbuf: [10]u8
    sbuf: [16]u8
    tbuf: [24]u8
    if fi, err := os.stat(parent, context.temp_allocator); err == nil {
        e.display = format_row(
            mode_string(mbuf[:], fi.type, fi.mode),
            "..",
            size_string(sbuf[:], fi.size),
            time_string(tbuf[:], fi.modification_time),
        )
    } else {
        e.display = format_row("d---------", "..", "", "")
    }
    return e
}

@(private = "file")
format_row :: proc(mode, name, size, mtime: string) -> string {
    b := strings.builder_make()
    strings.write_string(&b, mode)
    strings.write_string(&b, "  ")
    write_padded(&b, name, FT_NAME_W)
    strings.write_string(&b, "  ")
    write_rjust(&b, size, FT_SIZE_W)
    strings.write_string(&b, "  ")
    strings.write_string(&b, mtime)
    return strings.to_string(b)
}

@(private = "file")
write_padded :: proc(b: ^strings.Builder, s: string, w: int) {
    n := utf8.rune_count_in_string(s)
    if n <= w {
        strings.write_string(b, s)
        for _ in n ..< w {
            strings.write_byte(b, ' ')
        }
        return
    }
    i := 0
    for r in s {
        if i == w - 1 {
            break
        }
        strings.write_rune(b, r)
        i += 1
    }
    strings.write_byte(b, '~') // truncation marker
}

@(private = "file")
write_rjust :: proc(b: ^strings.Builder, s: string, w: int) {
    for _ in len(s) ..< w {
        strings.write_byte(b, ' ')
    }
    strings.write_string(b, s)
}

@(private = "file")
mode_string :: proc(buf: []u8, type: os.File_Type, p: os.Permissions) -> string {
    bit :: proc(p: os.Permissions, f: os.Permission_Flag, ch: u8) -> u8 {
        return f in p ? ch : '-'
    }
    buf[0] = type_char(type)
    buf[1] = bit(p, .Read_User, 'r')
    buf[2] = bit(p, .Write_User, 'w')
    buf[3] = bit(p, .Execute_User, 'x')
    buf[4] = bit(p, .Read_Group, 'r')
    buf[5] = bit(p, .Write_Group, 'w')
    buf[6] = bit(p, .Execute_Group, 'x')
    buf[7] = bit(p, .Read_Other, 'r')
    buf[8] = bit(p, .Write_Other, 'w')
    buf[9] = bit(p, .Execute_Other, 'x')
    return string(buf[:10])
}

@(private = "file")
type_char :: proc(t: os.File_Type) -> u8 {
    #partial switch t {
    case .Directory:
        return 'd'
    case .Symlink:
        return 'l'
    case:
        return '-'
    }
}

@(private = "file")
size_string :: proc(buf: []u8, size: i64) -> string {
    units := [?]string{"", "K", "M", "G", "T"}
    f := f64(size)
    u := 0
    for f >= 1024 && u < len(units) - 1 {
        f /= 1024
        u += 1
    }
    if u == 0 {
        return fmt.bprintf(buf, "%dB", size)
    }
    return fmt.bprintf(buf, "%.1f%s", f, units[u])
}

@(private = "file")
time_string :: proc(buf: []u8, t: time.Time) -> string {
    y, mo, d := time.date(t)
    h, mi, _ := time.clock_from_time(t)
    return fmt.bprintf(buf, "%4d-%02d-%02d %02d:%02d", y, int(mo), d, h, mi)
}
