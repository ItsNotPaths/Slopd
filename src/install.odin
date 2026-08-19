package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

// Where Slopd's files live, and the install / uninstall the Config pane's first row drives.
//
// Slopd is one binary carrying its own README, licence, language registry, default theme,
// default config and launcher entry — the release is that binary and nothing else. What it
// cannot carry is what you CHANGE: slopd.config, the themes/ and grammars/ you add. The
// running binary's own location decides where those sit:
//
//   Portable   the folder beside the binary is writable — a download, or a build folder.
//              Everything lives there; move the folder and its world moves with it.
//   Installed  the binary IS the copy `--install` made at ~/.local/bin/slopd, so the files go
//              to the XDG folders: a bin folder holds programs, not their data.
//   ReadOnly   the folder beside the binary cannot be written (someone put it in /usr/bin).
//              Slopd reads what is there and writes nothing.
//
// There is no search path: a mode picks one directory per kind of file and reads and writes
// only there. And Slopd never creates slopd.config on its own — only `--install` does, so a
// setting is saved to a file that exists, or not at all.

Install_Mode :: enum {
    Portable,
    Installed,
    ReadOnly,
}

// Lower case, because it is what you type. The same name the build writes and the window
// reports as its app-id (APP_ID), so the desktop entry's Exec and the window rule agree.
INSTALL_BIN :: "slopd"

// Not an XDG variable: XDG has no user bin folder, and ~/.local/bin is what shells add to PATH.
INSTALL_BIN_DIR :: ".local/bin"

// --- the mode, and the directories it chooses ---

// Asked on nearly every path lookup and cannot change while we run, so resolved once.
@(private = "file")
mode_cache: Install_Mode
@(private = "file")
mode_known: bool

install_mode :: proc() -> Install_Mode {
    if !mode_known {
        mode_cache = install_classify(
            exe_path(context.temp_allocator),
            install_bin_path(context.temp_allocator),
            dir_writable(exe_dir(context.temp_allocator)),
        )
        mode_known = true
    }
    return mode_cache
}

// Pure, so the suite can ask about paths this machine does not have. `installed` is "" with no
// $HOME, which leaves the beside-the-binary answer.
install_classify :: proc(exe, installed: string, exe_dir_writable: bool) -> Install_Mode {
    if installed != "" && exe == installed {
        return .Installed
    }
    return exe_dir_writable ? .Portable : .ReadOnly
}

// "" with no $HOME, which makes every user path below "" — and no caller writes to a "" path.
@(private = "file")
home_dir :: proc(allocator := context.allocator) -> string {
    return strings.clone(os.get_env("HOME", context.temp_allocator), allocator)
}

// $VAR if absolute, else $HOME/<fallback>. The XDG rule: a relative value is invalid.
@(private = "file")
xdg_dir :: proc(env, fallback: string, allocator := context.allocator) -> string {
    if v := os.get_env(env, context.temp_allocator); strings.has_prefix(v, "/") {
        return strings.clone(v, allocator)
    }
    home := home_dir(context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({home, fallback}, allocator) or_else strings.clone("", allocator)
}

// What `--install` writes and `--uninstall` removes, and what install_classify compares the
// running binary against. "" without a $HOME.
install_bin_path :: proc(allocator := context.allocator) -> string {
    dir := install_bin_dir(context.temp_allocator)
    if dir == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({dir, INSTALL_BIN}, allocator) or_else strings.clone("", allocator)
}

install_bin_dir :: proc(allocator := context.allocator) -> string {
    home := home_dir(context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({home, INSTALL_BIN_DIR}, allocator) or_else strings.clone("", allocator)
}

install_config_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_dir("XDG_CONFIG_HOME", ".config", context.temp_allocator), allocator)
}

// themes/, grammars/ and perf.log once installed. Split from config because one folder is
// yours to edit and the other is Slopd's to fill.
install_data_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_data_home(context.temp_allocator), allocator)
}

// The root of it, not Slopd's folder inside: the launcher entry and its icon go in the shared
// applications/ and icons/ trees, which is where a launcher looks (desktop.odin).
xdg_data_home :: proc(allocator := context.allocator) -> string {
    return xdg_dir("XDG_DATA_HOME", ".local/share", allocator)
}

@(private = "file")
install_subdir :: proc(base: string, allocator := context.allocator) -> string {
    if base == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({base, INSTALL_BIN}, allocator) or_else strings.clone("", allocator)
}

// --- resolving one file ---

// In whichever directory the mode chose. Returned whether or not it exists: it is also the
// write target.
config_asset :: proc(name: string, allocator := context.allocator) -> string {
    if install_mode() == .Installed {
        return install_file(install_config_dir(context.temp_allocator), name, allocator)
    }
    return beside_exe(name, allocator)
}

// themes/, grammars/, perf.log — in whichever directory the mode chose, existing or not.
data_asset :: proc(name: string, allocator := context.allocator) -> string {
    if install_mode() == .Installed {
        return install_file(install_data_dir(context.temp_allocator), name, allocator)
    }
    return beside_exe(name, allocator)
}

@(private = "file")
install_file :: proc(dir, name: string, allocator := context.allocator) -> string {
    if dir == "" {
        return beside_exe(name, allocator) // no $HOME, nowhere else to go
    }
    return filepath.join({dir, name}, allocator) or_else strings.clone(name, allocator)
}

// <exe_dir>/<name>, falling back to the launch folder for `odin run`, which leaves the binary
// in a temp folder. Returned even when nothing is there, since that is the write target.
beside_exe :: proc(name: string, allocator := context.allocator) -> string {
    exe := exe_dir(context.temp_allocator)
    beside := filepath.join({exe, name}, context.temp_allocator) or_else strings.clone(name, context.temp_allocator)
    if os.exists(beside) {
        return strings.clone(beside, allocator)
    }
    // Only where the folder beside the binary is ours to write: otherwise the folder you
    // happened to launch from would be the search path this design does not have.
    if install_mode() != .ReadOnly {
        cwd := filepath.join({launch_dir(), name}, context.temp_allocator) or_else ""
        if cwd != "" && os.exists(cwd) {
            return strings.clone(cwd, allocator)
        }
    }
    return strings.clone(beside, allocator)
}

// The launch cwd, asked once and kept. Not the live cwd: `:cd` moves that, and a config file
// that moved with it would be a different file each time. A fixed buffer because nothing owns
// a cache that lives as long as the process.
@(private = "file")
launch_buf: [4096]u8
@(private = "file")
launch_len := -1 // not asked yet; 0 is a legitimate answer

@(private = "file")
launch_dir :: proc() -> string {
    if launch_len < 0 {
        launch_len = copy(launch_buf[:], os.get_working_directory(context.temp_allocator) or_else "")
    }
    return string(launch_buf[:launch_len])
}

// From /proc/self/exe, falling back to argv[0]'s directory. The caller owns the result.
exe_dir :: proc(allocator := context.allocator) -> string {
    path := os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
    return strings.clone(filepath.dir(path), allocator) // filepath.dir slices path
}

// For re-invoking ourselves (`<exe> --install`) without relying on slopd being on PATH.
exe_path :: proc(allocator := context.allocator) -> string {
    return strings.clone(os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0], allocator)
}

// One access(2) — not a probe file, which would write to the release folder every launch.
dir_writable :: proc(dir: string) -> bool {
    if dir == "" {
        return false
    }
    c := strings.clone_to_cstring(dir, context.temp_allocator)
    return linux.access(c, linux.W_OK) == .NONE
}

// Two ways it cannot be:
//   ReadOnly        every write would fail with EACCES; refusing early keeps a half-written
//                   config off the disk.
//   no config file  Slopd does not create one — `--install` does. A downloaded binary runs on
//                   the baked-in defaults until then.
// The test seam counts as writable: the override is a path the test owns.
config_writable :: proc() -> bool {
    if config_path_override != "" {
        return true
    }
    if install_mode() == .ReadOnly {
        return false
    }
    return os.exists(config_asset("slopd.config", context.temp_allocator))
}

// A no-op in Portable mode, and the first write's setup once installed.
ensure_parent :: proc(path: string) {
    if dir := filepath.dir(path); dir != "" { // a slice of `path`
        _ = os.make_directory_all(dir)
    }
}

// --- install / uninstall ---

// Copy the binary to ~/.local/bin/slopd, create the XDG folders, and lay the config down in the
// one place it is ever created. Idempotent: a rerun after a rebuild replaces the copy and
// leaves every file it already wrote alone. install.sh stops after the PATH, so the remaining
// work here is the config and the folders.
//
// The copy is staged and renamed because writing over a RUNNING binary fails with ETXTBSY.
install_run :: proc() -> (ok: bool, msg: string) {
    b := strings.builder_make(context.temp_allocator)
    dst := install_bin_path(context.temp_allocator)
    if dst == "" {
        return false, "install: no $HOME — nowhere to install to"
    }

    data := install_data_dir(context.temp_allocator)
    dirs := [?]string {
        install_bin_dir(context.temp_allocator),
        install_config_dir(context.temp_allocator),
        data,
        // Created empty rather than on first use, so the folders an install names are
        // folders you can open.
        filepath.join({data, "themes"}, context.temp_allocator) or_else "",
        filepath.join({data, "grammars"}, context.temp_allocator) or_else "",
    }
    for dir in dirs {
        if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
            return false, fmt.tprintf("install: cannot create %s (%v)", dir, err)
        }
    }

    src := exe_path(context.temp_allocator)
    if src == dst {
        fmt.sbprintfln(&b, "  %s is already the installed copy", dst)
    } else {
        stage := fmt.tprintf("%s.tmp", dst)
        _ = os.remove(stage) // a stale stage from a failed run
        if err := os.copy_file(stage, src); err != nil {
            return false, fmt.tprintf("install: cannot copy to %s (%v)", stage, err)
        }
        if err := os.rename(stage, dst); err != nil {
            _ = os.remove(stage)
            return false, fmt.tprintf("install: cannot publish %s (%v)", dst, err)
        }
        fmt.sbprintfln(&b, "  %s -> %s", src, dst)
    }

    // Two sources, in this order, and only where the target has none — a reinstall must not
    // roll your settings back:
    //   1. the portable folder's own slopd.config, if you are installing from one
    //   2. the copy baked into this binary (the ordinary path)
    from := exe_dir(context.temp_allocator)
    cfgdir := install_config_dir(context.temp_allocator)
    cfgdst := filepath.join({cfgdir, "slopd.config"}, context.temp_allocator) or_else ""
    beside := filepath.join({from, "slopd.config"}, context.temp_allocator) or_else ""
    if copy_missing(cfgdir, beside) {
        fmt.sbprintfln(&b, "  slopd.config -> %s (moved in from %s)", cfgdst, from)
    } else if config_default_write(cfgdst) {
        fmt.sbprintfln(&b, "  slopd.config -> %s (defaults, from the binary)", cfgdst)
    }
    for name in ([?]string{"themes", "grammars"}) {
        srcdir := filepath.join({from, name}, context.temp_allocator) or_else ""
        dstdir := filepath.join({data, name}, context.temp_allocator) or_else ""
        if n := copy_dir_flat(dstdir, srcdir); n > 0 {
            fmt.sbprintfln(&b, "  %s/ -> %s (%d file%s)", name, dstdir, n, n == 1 ? "" : "s")
        }
    }

    fmt.sbprintfln(&b, "  config:   %s", cfgdir)
    fmt.sbprintfln(&b, "  data:     %s", data)
    if !on_path(install_bin_dir(context.temp_allocator)) {
        fmt.sbprintfln(
            &b,
            "\n  %s is not on your PATH. Add it:\n    export PATH=\"%s:$PATH\"",
            install_bin_dir(context.temp_allocator),
            install_bin_dir(context.temp_allocator),
        )
    }
    return true, fmt.tprintf("installed\n%s", strings.trim_right_space(strings.to_string(b)))
}

// The binary and nothing else. Settings, themes and grammars stay on the disk.
install_remove :: proc() -> (ok: bool, msg: string) {
    dst := install_bin_path(context.temp_allocator)
    if dst == "" {
        return false, "uninstall: no $HOME — nothing could have been installed"
    }
    if !os.exists(dst) {
        return false, fmt.tprintf("uninstall: %s is not there — nothing to remove", dst)
    }
    if err := os.remove(dst); err != nil {
        return false, fmt.tprintf("uninstall: cannot remove %s (%v)", dst, err)
    }
    // Named with the line that removes them, and left alone.
    return true, fmt.tprintf(
        "uninstalled\n  removed %s\n\n  your settings, themes and grammars are still here:\n    rm -rf %s %s",
        dst,
        install_config_dir(context.temp_allocator),
        install_data_dir(context.temp_allocator),
    )
}

// Every path Slopd uses, and the mode that chose them. Temp-allocated.
install_where :: proc() -> string {
    b := strings.builder_make(context.temp_allocator)
    cfg := config_asset("slopd.config", context.temp_allocator)
    entry := desktop_entry_path(context.temp_allocator)
    fmt.sbprintfln(&b, "mode:      %s", install_mode_label(install_mode()))
    fmt.sbprintfln(&b, "binary:    %s", exe_path(context.temp_allocator))
    fmt.sbprintfln(&b, "config:    %s%s", cfg, os.exists(cfg) ? "" : "   (not there yet)")
    fmt.sbprintfln(&b, "themes:    %s", data_asset("themes", context.temp_allocator))
    fmt.sbprintfln(&b, "grammars:  %s", data_asset("grammars", context.temp_allocator))
    fmt.sbprintfln(&b, "launcher:  %s", desktop_present() ? entry : "not in the application list")
    if install_mode() == .ReadOnly {
        fmt.sbprintfln(
            &b,
            "\n%s cannot be written, so no setting can be saved.\nInstall a copy that can: %s --install",
            exe_dir(context.temp_allocator),
            exe_path(context.temp_allocator),
        )
    } else if !os.exists(cfg) {
        // Where a downloaded binary starts: it runs on the baked-in defaults, but a settings
        // change has no file to land in until you install.
        fmt.sbprintfln(
            &b,
            "\nThere is no config file, so no setting can be saved. Slopd is running on the\ndefaults baked into the binary. Write them out: %s --install",
            exe_path(context.temp_allocator),
        )
    }
    return strings.trim_right_space(strings.to_string(b))
}

install_mode_label :: proc(m: Install_Mode) -> string {
    switch m {
    case .Portable:  return "portable"
    case .Installed: return "installed"
    case .ReadOnly:  return "read-only"
    }
    return ""
}

// The mode, the place it chose, and any reason nothing below can be saved. First row of the
// pane so that reason sits above the settings it applies to. Always a fresh string in
// `allocator`, since the row it feeds outlives every temp path here.
install_state_text :: proc(allocator := context.allocator) -> string {
    where_: string
    switch install_mode() {
    case .Installed:
        where_ = install_bin_path(context.temp_allocator)
    case .Portable, .ReadOnly:
        where_ = exe_dir(context.temp_allocator)
    }
    short := home_abbrev(where_, context.temp_allocator)
    if install_mode() == .ReadOnly {
        return fmt.aprintf("read-only · %s · nothing can be saved", short, allocator = allocator)
    }
    if !config_writable() {
        // No file to write a change to; the row names the fix as well as the state.
        return fmt.aprintf("%s · %s · no config file — install to save settings", install_mode_label(install_mode()), short, allocator = allocator)
    }
    return fmt.aprintf("%s · %s", install_mode_label(install_mode()), short, allocator = allocator)
}

// --- the copying, and the PATH check ---

// false covers "no source", "already there" and a failed copy — the caller reports only what
// actually moved.
@(private = "file")
copy_missing :: proc(dir, src: string) -> bool {
    if dir == "" || src == "" || !os.exists(src) {
        return false
    }
    dst := filepath.join({dir, filepath.base(src)}, context.temp_allocator) or_else ""
    if dst == "" || dst == src || os.exists(dst) {
        return false
    }
    return os.copy_file(dst, src) == nil
}

// Skips any file already there. Flat on purpose: themes/ and grammars/ hold files and nothing
// else, so a recursive copy would only add a way to follow something unexpected.
@(private = "file")
copy_dir_flat :: proc(dst, src: string) -> (n: int) {
    if dst == "" || src == "" || dst == src || !os.exists(src) {
        return 0
    }
    f, oerr := os.open(src)
    if oerr != nil {
        return 0
    }
    defer os.close(f)
    it := os.read_directory_iterator_create(f)
    defer os.read_directory_iterator_destroy(&it)
    for fi in os.read_directory_iterator(&it) {
        if fi.type != .Regular {
            continue
        }
        if n == 0 {
            _ = os.make_directory_all(dst)
        }
        from := filepath.join({src, fi.name}, context.temp_allocator) or_else ""
        to := filepath.join({dst, fi.name}, context.temp_allocator) or_else ""
        if from == "" || to == "" || os.exists(to) {
            continue
        }
        if os.copy_file(to, from) == nil {
            n += 1
        }
    }
    return n
}

// An exact match: a prefix test would call ~/.local/binaries a hit.
@(private = "file")
on_path :: proc(dir: string) -> bool {
    if dir == "" {
        return false
    }
    rest := os.get_env("PATH", context.temp_allocator)
    for entry in strings.split_iterator(&rest, ":") {
        if entry == dir {
            return true
        }
    }
    return false
}

// --- CLI (`slopd --install`, `--uninstall`, `--where`) ---

// Handled before the GLFW window opens: the Config pane's install row runs these in a terminal, and
// they must answer on a machine with no display.
install_cli :: proc(args: []string) -> (handled: bool) {
    for arg in args {
        switch arg {
        case "--install":
            _, msg := install_run()
            fmt.println(msg)
            return true
        case "--uninstall":
            _, msg := install_remove()
            fmt.println(msg)
            return true
        case "--where":
            fmt.println(install_where())
            return true
        }
    }
    return false
}
