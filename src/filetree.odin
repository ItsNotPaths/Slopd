package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// FileTree — a self-contained dired-style directory listing. It reads a directory,
// moves/enters, and pre-formats each row's fixed-width columns. It has NO dependency
// on the rest of Slopd (no App, no GL), so it can be lifted into another project; the
// host wires up rendering, the unsaved-ring prefix, and what Enter does with a file.

FT_NAME_W :: 24 // name column width, in cells (padded / truncated)
FT_SIZE_W :: 8 // size column width, right-justified

FileEntry :: struct {
    name:    string, // base name (owned)
    path:    string, // absolute path (owned)
    is_dir:  bool,
    exec:    bool, // the owner's execute bit — a binary or a script the host can offer to RUN
    display: string, // owned "<mode>  <name>  <size>  <mtime>"; host adds the ring prefix
}

// What a paste does with the marked set: duplicate the files (Copy) or move them
// (Cut, which also empties the set afterwards). Set by the copy/cut chords; Copy is
// the default so paste works even if you never pressed one.
YankMode :: enum {
    Copy,
    Cut,
}

FileTree :: struct {
    dir:      string, // current directory, absolute (owned)
    entries:  [dynamic]FileEntry,
    selected: int,
    scroll:   int, // first visible row — the viewport top (see list_scroll_target)
    hover:    int, // the entry under the pointer, or -1 — transient frame state (config_ui)

    // A wheel gesture DETACHES the view from the selection (glfw time; 0 = following it),
    // the flat-row twin of Buffer.scroll_detached. While it is set neither viewport policy
    // runs, so the wheel moves the view rather than the cursor; the next keystroke that
    // reaches this pane re-attaches it. See list_scroll_apply (scroll.odin).
    scroll_detached: f64,

    // The yank set: paths marked for a pending copy/cut, OWNED and kept across dir
    // navigation (yank here, walk elsewhere, paste there). yank_mode says what paste
    // does with them.
    yanked:    [dynamic]string,
    yank_mode: YankMode,
}

filetree_init :: proc(ft: ^FileTree) {
    ft.hover = -1 // nothing is hovered until a pointer event says so
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
    filetree_yank_reset(ft)
    delete(ft.yanked)
}

// (Re)reads dir. ".." is always the first entry (except at the filesystem root);
// the rest are sorted directories-first, then by name.
filetree_load :: proc(ft: ^FileTree, dir: string) {
    filetree_clear(ft)
    ft.dir = strings.clone(dir)
    ft.selected = 0
    ft.scroll = 0 // a new listing starts at the top; don't carry the old dir's viewport

    if f, oerr := os.open(dir); oerr == nil {
        defer os.close(f)
        it := os.read_directory_iterator_create(f)
        defer os.read_directory_iterator_destroy(&it)
        for fi in os.read_directory_iterator(&it) {
            append(&ft.entries, entry_from(dir, fi))
        }
    }
    slice.sort_by(ft.entries[:], entry_less)

    parent := filepath.dir(dir) // slices into dir — not owned, never delete it
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

// Enter the selected directory (no-op on a file). Right / l.
filetree_enter :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || !e.is_dir {
        return
    }
    target := strings.clone(e.path, context.temp_allocator) // e.path is freed by reload
    filetree_load(ft, target)
}

// Go to the parent directory, re-selecting the directory we came from. Left / h.
filetree_parent :: proc(ft: ^FileTree) {
    parent := filepath.dir(ft.dir) // slices into ft.dir — not owned
    if parent == ft.dir { // already at the filesystem root
        return
    }
    // Clone before reloading: the reload frees ft.dir, which parent aliases.
    parent_dir := strings.clone(parent, context.temp_allocator)
    came_from := strings.clone(ft.dir, context.temp_allocator)
    filetree_load(ft, parent_dir)
    for e, i in ft.entries {
        if e.path == came_from {
            ft.selected = i
            break
        }
    }
}

// Activate the selection: descend into a directory (reloading) or report a file
// path to open. Returns ("", false) when it entered a directory.
filetree_activate :: proc(ft: ^FileTree) -> (path: string, is_file: bool) {
    e := filetree_selected(ft)
    if e == nil {
        return "", false
    }
    if e.is_dir {
        target := strings.clone(e.path, context.temp_allocator) // e.path is freed by reload
        filetree_load(ft, target)
        return "", false
    }
    return e.path, true
}

// --- yank set + file operations ---
//
// The yank set is a list of marked absolute paths plus a mode (copy/cut). Marking is
// toggle-on-toggle-off; paste applies the mode into the current dir; filetree_targets
// reports the highlighted entry or the whole set for the host to delete (as a staged
// `rm -rf` command line). All paths are owned by ft.yanked and survive dir navigation,
// so you can mark in one directory and paste in another. Every op reloads the listing
// afterwards (preserving the cursor row where it can).

// Toggle the highlighted entry in/out of the yank set. ".." is never marked.
filetree_yank_toggle :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || e.name == ".." {
        return
    }
    for p, i in ft.yanked {
        if p == e.path {
            delete(ft.yanked[i])
            ordered_remove(&ft.yanked, i)
            return
        }
    }
    append(&ft.yanked, strings.clone(e.path))
}

// Add the highlighted entry to the yank set if absent (idempotent — unlike the toggle).
// ".." is never marked. Used by the sweep so re-crossing a row never un-marks it.
filetree_yank_add :: proc(ft: ^FileTree) {
    e := filetree_selected(ft)
    if e == nil || e.name == ".." || filetree_yanked_contains(ft, e.path) {
        return
    }
    append(&ft.yanked, strings.clone(e.path))
}

// Sweep-mark: mark the current row, step the cursor, mark the row it lands on. Holding
// Shift while pressing Up/Down thus paints a contiguous marked run as the cursor moves.
filetree_yank_sweep :: proc(ft: ^FileTree, delta: int) {
    filetree_yank_add(ft)
    filetree_move(ft, delta)
    filetree_yank_add(ft)
}

// Clear the whole yank set (the "reset" chord).
filetree_yank_reset :: proc(ft: ^FileTree) {
    for p in ft.yanked {
        delete(p)
    }
    clear(&ft.yanked)
}

filetree_yanked_contains :: proc(ft: ^FileTree, path: string) -> bool {
    for p in ft.yanked {
        if p == path {
            return true
        }
    }
    return false
}

// Apply the yank set to the current dir: Copy duplicates, Cut moves (then empties the
// set). Each destination name is made unique so an existing file is never clobbered.
filetree_paste :: proc(ft: ^FileTree) {
    if len(ft.yanked) == 0 {
        return
    }
    for src in ft.yanked {
        dst := fs_unique_dest(ft.dir, filepath.base(src)) // base slices src; used at once
        if ft.yank_mode == .Cut {
            // rename is an atomic move on one filesystem; fall back to copy+remove
            // across devices (EXDEV), where rename can't relink the inode.
            if os.rename(src, dst) != nil && fs_copy_path(src, dst) {
                fs_remove_path(src)
            }
        } else {
            fs_copy_path(src, dst)
        }
    }
    if ft.yank_mode == .Cut {
        filetree_yank_reset(ft) // the sources are gone; the marks would dangle
    }
    filetree_reload(ft)
}

// The paths a file op acts on: the whole marked set, or just the highlighted entry
// (".." excluded). The strings are BORROWED from the tree — use them before the next
// reload frees them. Deleting is no longer done here: the host turns these into an
// `rm -rf` command line (see rm_command), so the paths are read and confirmed as a
// real command rather than behind a modal prompt.
filetree_targets :: proc(ft: ^FileTree, marked: bool, alloc := context.allocator) -> []string {
    if marked {
        return slice.clone(ft.yanked[:], alloc)
    }
    e := filetree_selected(ft)
    if e == nil || e.name == ".." {
        return nil
    }
    out := make([]string, 1, alloc)
    out[0] = e.path
    return out
}

// Re-read the current dir, keeping the cursor near where it was (filetree_load resets
// it to 0). ft.dir is freed by the load, so clone before handing it back in. A tree that
// was never loaded (dir == "") has nothing to re-read.
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

// A destination path under `dir` for base name `name` that does not already exist:
// the bare name if it's free, else "<stem>_copy<ext>", "<stem>_copy2<ext>", ... So a
// paste never overwrites (and pasting into the source dir yields a duplicate).
@(private = "file")
fs_unique_dest :: proc(dir, name: string) -> string {
    base := filepath.join({dir, name}, context.temp_allocator) or_else ""
    if !os.exists(base) {
        return base
    }
    ext := filepath.ext(name) // includes the dot, or "" if none
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

// Recursively copy a file or directory tree src -> dst. Returns false if any leaf
// failed (best-effort: a partial tree may remain).
@(private = "file")
fs_copy_path :: proc(src, dst: string) -> bool {
    if os.is_dir(src) {
        os.make_directory(dst) // ignore "already exists" — fs_unique_dest kept it fresh
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

// Recursively remove a file or directory tree. A directory is emptied first (os.remove
// is rmdir on a dir, which needs it empty), with its handle closed before the rmdir. Only
// the cross-device Cut path uses this — a user-facing delete is a staged `rm -rf` (see
// filetree_targets), so nothing here removes files behind the user's back.
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
    // A symlink to a directory should navigate and tint like one; stat follows the
    // link (broken/circular links fall back to non-dir). The mode column still
    // shows 'l' so the listing stays honest about what it is. The exec bit comes from
    // the same stat — a symlink's own mode is always rwx, so only the TARGET's bit says
    // whether Shift+Enter has something to run.
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
        path   = strings.clone(parent), // parent is a slice; own a copy
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
