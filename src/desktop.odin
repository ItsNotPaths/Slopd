package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The launcher entry: slopd.desktop and the icon it names.
//
// Separate from install.odin. Installing puts a binary where a shell finds it; this puts an
// entry where a LAUNCHER finds it, and neither implies the other — so the Config pane offers it
// as its own add/remove pair. Both files are #load-ed, so the binary carries what it writes.

DESKTOP_ENTRY_SRC := string(#load("../slopd.desktop"))
DESKTOP_ICON_SRC := string(#load("../slopd.svg"))

// <app-id>.desktop, which is what ties a window back to its entry.
DESKTOP_ENTRY_NAME :: INSTALL_BIN + ".desktop"

// Off $XDG_DATA_HOME, but not off Slopd's own folder in it: applications/ and icons/ are shared
// trees every launcher reads, so an entry under slopd/ would be invisible. hicolor is the
// fallback theme every icon theme inherits from, and scalable/ is where an SVG goes.
DESKTOP_APPS_REL :: "applications"
DESKTOP_ICON_REL :: "icons/hicolor/scalable/apps"

desktop_apps_dir :: proc(allocator := context.allocator) -> string {
    return desktop_join({DESKTOP_APPS_REL}, allocator)
}

desktop_entry_path :: proc(allocator := context.allocator) -> string {
    return desktop_join({DESKTOP_APPS_REL, DESKTOP_ENTRY_NAME}, allocator)
}

desktop_icon_path :: proc(allocator := context.allocator) -> string {
    return desktop_join({DESKTOP_ICON_REL, INSTALL_BIN + ".svg"}, allocator)
}

@(private = "file")
desktop_join :: proc(parts: []string, allocator := context.allocator) -> string {
    base := xdg_data_home(context.temp_allocator)
    if base == "" {
        return strings.clone("", allocator)
    }
    all := make([dynamic]string, 0, len(parts) + 1, context.temp_allocator)
    append(&all, base)
    append(&all, ..parts)
    return filepath.join(all[:], allocator) or_else strings.clone("", allocator)
}

// The ENTRY decides, not the icon: a missing icon degrades to a generic one, not to nothing.
desktop_present :: proc() -> bool {
    path := desktop_entry_path(context.temp_allocator)
    return path != "" && os.exists(path)
}

// --- add / remove ---

// Replacing whatever is there. Unlike the config, this file is not yours to edit: it is
// generated from the binary you are running, so a re-add after a move refreshes its path.
desktop_add :: proc() -> (ok: bool, msg: string) {
    entry := desktop_entry_path(context.temp_allocator)
    icon := desktop_icon_path(context.temp_allocator)
    if entry == "" {
        return false, "desktop: no $HOME — nowhere to file an entry"
    }

    exec := desktop_exec_target(context.temp_allocator)
    body := desktop_entry_text(DESKTOP_ENTRY_SRC, exec, context.temp_allocator)

    ensure_parent(entry)
    if err := os.write_entire_file(entry, transmute([]byte)body); err != nil {
        return false, fmt.tprintf("desktop: cannot write %s (%v)", entry, err)
    }

    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintfln(&b, "  %s", entry)
    fmt.sbprintfln(&b, "  Exec=%s", exec)

    // Best-effort: an entry with no icon still launches, and reporting a failed icon write as
    // a failed add would hide the entry that DID land.
    if icon != "" {
        ensure_parent(icon)
        if err := os.write_entire_file(icon, transmute([]byte)DESKTOP_ICON_SRC); err == nil {
            fmt.sbprintfln(&b, "  %s", icon)
        }
    }
    desktop_reindex()
    return true, fmt.tprintf("added to the application list\n%s", strings.trim_right_space(strings.to_string(b)))
}

// Both are ours, generated and never edited, so unlike the uninstall this takes them with it.
desktop_remove :: proc() -> (ok: bool, msg: string) {
    entry := desktop_entry_path(context.temp_allocator)
    if entry == "" {
        return false, "desktop: no $HOME — nothing could have been filed"
    }
    if !os.exists(entry) {
        return false, fmt.tprintf("desktop: %s is not there — nothing to remove", entry)
    }
    if err := os.remove(entry); err != nil {
        return false, fmt.tprintf("desktop: cannot remove %s (%v)", entry, err)
    }
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintfln(&b, "  removed %s", entry)
    if icon := desktop_icon_path(context.temp_allocator); icon != "" && os.exists(icon) {
        if os.remove(icon) == nil {
            fmt.sbprintfln(&b, "  removed %s", icon)
        }
    }
    desktop_reindex()
    return true, fmt.tprintf("removed from the application list\n%s", strings.trim_right_space(strings.to_string(b)))
}

// The INSTALLED copy when there is one, since that path survives this folder being deleted;
// otherwise the binary running now. Not simply the running binary, because install.sh downloads
// to a temp folder and an entry pointing there would break when the script cleaned up.
desktop_exec_target :: proc(allocator := context.allocator) -> string {
    if p := install_bin_path(context.temp_allocator); p != "" && os.exists(p) {
        return strings.clone(p, allocator)
    }
    return exe_path(allocator)
}

// Pure, so the suite can check the substitution without a $HOME or a launcher. Everything else
// in the template is copied through verbatim.
desktop_entry_text :: proc(src, exec: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(src) + len(exec) * 2, allocator)
    rest := src
    for line in strings.split_lines_iterator(&rest) {
        switch {
        case strings.has_prefix(line, "Exec="):
            fmt.sbprintf(&b, "Exec=%s", exec)
        case strings.has_prefix(line, "TryExec="):
            fmt.sbprintf(&b, "TryExec=%s", exec)
        case:
            strings.write_string(&b, line)
        }
        strings.write_byte(&b, '\n')
    }
    return strings.to_string(b)
}

// Where the machine keeps one. Most launchers read the directory itself; the ones that cache
// miss a new entry until this runs. The result is discarded: the command is absent on plenty of
// systems, and that is not a failure of the write that already succeeded.
@(private = "file")
desktop_reindex :: proc() {
    dir := desktop_apps_dir(context.temp_allocator)
    if dir == "" {
        return
    }
    // The directory travels as $1, never re-parsed as shell syntax.
    argv := []string{"sh", "-c", `command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$1"`, "sh", dir}
    _, _, _, _ = os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
}

// --- CLI (`slopd --desktop [add|remove]`) ---

// Bare `--desktop` adds; `remove` is spelled out, like `--grammar uninstall`. Before the window
// opens, so the Config pane's rows can run it in t1 and see the output.
desktop_cli :: proc(args: []string) -> (handled: bool) {
    for arg, i in args {
        if arg != "--desktop" {
            continue
        }
        action := i + 1 < len(args) ? args[i + 1] : "add"
        switch action {
        case "add", "":
            _, msg := desktop_add()
            fmt.println(msg)
        case "remove", "uninstall":
            _, msg := desktop_remove()
            fmt.println(msg)
        case:
            fmt.eprintln("usage: slopd --desktop [add|remove]")
        }
        return true
    }
    return false
}
