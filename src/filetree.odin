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
// on the rest of PitEd (no App, no GL), so it can be lifted into another project; the
// host wires up rendering, the unsaved-ring prefix, and what Enter does with a file.

FT_NAME_W :: 24 // name column width, in cells (padded / truncated)
FT_SIZE_W :: 8 // size column width, right-justified

FileEntry :: struct {
    name:    string, // base name (owned)
    path:    string, // absolute path (owned)
    is_dir:  bool,
    display: string, // owned "<mode>  <name>  <size>  <mtime>"; host adds the ring prefix
}

FileTree :: struct {
    dir:      string, // current directory, absolute (owned)
    entries:  [dynamic]FileEntry,
    selected: int,
}

filetree_init :: proc(ft: ^FileTree) {
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
}

// (Re)reads dir. ".." is always the first entry (except at the filesystem root);
// the rest are sorted directories-first, then by name.
filetree_load :: proc(ft: ^FileTree, dir: string) {
    filetree_clear(ft)
    ft.dir = strings.clone(dir)
    ft.selected = 0

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

// --- internals ---

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
    mbuf: [10]u8
    sbuf: [16]u8
    tbuf: [24]u8
    path, _ := filepath.join({dir, fi.name})
    return FileEntry {
        name = strings.clone(fi.name),
        path = path,
        is_dir = fi.type == .Directory,
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
