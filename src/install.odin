package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

// Where Slopd's files live, and the install / uninstall the Config pane's first row drives.
//
// Slopd is ONE binary that carries its own README, licence, language registry, default theme,
// default config and launcher entry. THE RELEASE IS THAT BINARY AND NOTHING ELSE: download it,
// run it, and every default is already inside. What the binary cannot carry is what you
// CHANGE: slopd.config, the themes/ you add, the grammars/ you install. Those sit in ONE of
// two places, and the running binary's own location decides which — never a search path, an
// environment variable, or a setting:
//
//   Portable   the folder beside the binary is writable — a downloaded binary, or a build
//              folder. Everything lives there; move the folder and its world moves with it.
//   Installed  the binary IS the copy `--install` made, at ~/.local/bin/slopd. The files
//              move to the XDG folders, because a bin folder holds programs, not their data.
//   ReadOnly   the folder beside the binary cannot be written — someone put the binary in
//              /usr/bin. Slopd reads what is there and writes NOTHING; the Config pane says
//              so, and its Install makes a copy that can write.
//
// **There is still no search path.** A mode picks one directory per kind of file and reads
// and writes only there, so what the pane shows and what the disk holds cannot disagree.
//
// **Slopd never CREATES slopd.config on its own — only `--install` writes it.** A lone binary
// with no config file behaves exactly as the baked-in default says (load_config parses it),
// but a settings change cannot be saved, and the Config pane's first row says so in as many
// words. One rule covers the download you have not installed yet, the config you deleted, and
// the copy someone put in /usr/bin: a setting is saved to a file that EXISTS, or not at all.

Install_Mode :: enum {
    Portable,
    Installed,
    ReadOnly,
}

// The installed binary's name: lower case, because it is what you type. It is the same name
// the build writes (release.sh, release.yml) and the same name the window reports as its
// app-id (APP_ID in main.odin), so a desktop entry's Exec, the installed copy and the window
// rule all say `slopd`. The copy keeps its name; nothing is renamed on the way in.
INSTALL_BIN :: "slopd"

// The folder the installed binary goes in. Not an XDG variable: XDG standardises config,
// data and cache, but not a user bin folder, and ~/.local/bin is what shells add to PATH.
INSTALL_BIN_DIR :: ".local/bin"

// --- the mode, and the directories it chooses ---

// The mode is asked for on nearly every path lookup and cannot change while we run — the
// binary does not move under itself — so it is resolved once, on the first question.
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

// The mode rule, kept pure so the suite can ask it about paths this machine does not have.
// `installed` is "" when there is no $HOME, which leaves the beside-the-binary answer.
install_classify :: proc(exe, installed: string, exe_dir_writable: bool) -> Install_Mode {
    if installed != "" && exe == installed {
        return .Installed
    }
    return exe_dir_writable ? .Portable : .ReadOnly
}

// $HOME, or "" when the environment has none. Every user path below is "" in that case, and
// a "" path is one no caller writes to — see install_run, which refuses rather than guesses.
@(private = "file")
home_dir :: proc(allocator := context.allocator) -> string {
    return strings.clone(os.get_env("HOME", context.temp_allocator), allocator)
}

// $VAR if the environment sets an absolute one, else $HOME/<fallback>. The XDG rule: a
// relative value is invalid and is ignored rather than resolved against anything.
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

// ~/.local/bin/slopd — the file `--install` writes and `--uninstall` removes, and the one
// path install_classify compares the running binary against. "" without a $HOME.
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

// $XDG_CONFIG_HOME/slopd, else ~/.config/slopd — where slopd.config lives once installed.
install_config_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_dir("XDG_CONFIG_HOME", ".config", context.temp_allocator), allocator)
}

// $XDG_DATA_HOME/slopd, else ~/.local/share/slopd — themes/, grammars/ and perf.log once
// installed. Config and data are split because that is the split the folders themselves make:
// one is yours to edit, the other is Slopd's to fill.
install_data_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_data_home(context.temp_allocator), allocator)
}

// $XDG_DATA_HOME, else ~/.local/share — the ROOT of it, not Slopd's folder inside it. The
// launcher entry and its icon go in the SHARED applications/ and icons/ trees there rather
// than under slopd/, because that is where a launcher looks (see desktop.odin).
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

// The config file (slopd.config), in whichever directory the mode chose. Returned whether or
// not it exists: it is also the WRITE target, created on the first settings change.
config_asset :: proc(name: string, allocator := context.allocator) -> string {
    if install_mode() == .Installed {
        return install_file(install_config_dir(context.temp_allocator), name, allocator)
    }
    return beside_exe(name, allocator)
}

// A data file or folder (themes/, grammars/, perf.log), in whichever directory the mode
// chose. Also returned when it does not exist — grammars/ is created by the first install.
data_asset :: proc(name: string, allocator := context.allocator) -> string {
    if install_mode() == .Installed {
        return install_file(install_data_dir(context.temp_allocator), name, allocator)
    }
    return beside_exe(name, allocator)
}

@(private = "file")
install_file :: proc(dir, name: string, allocator := context.allocator) -> string {
    if dir == "" {
        return beside_exe(name, allocator) // no $HOME: there is nowhere else to go
    }
    return filepath.join({dir, name}, allocator) or_else strings.clone(name, allocator)
}

// The portable answer: <exe_dir>/<name>, falling back to the launch folder for `odin run`,
// which leaves the binary in a temp folder. Returns <exe_dir>/<name> even when nothing exists
// there, since that is the write target. The caller owns the result.
beside_exe :: proc(name: string, allocator := context.allocator) -> string {
    exe := exe_dir(context.temp_allocator)
    beside := filepath.join({exe, name}, context.temp_allocator) or_else strings.clone(name, context.temp_allocator)
    if os.exists(beside) {
        return strings.clone(beside, allocator)
    }
    // `odin run` leaves the binary in a temp folder, so a dev build falls back to the folder
    // Slopd was launched from. ONLY where the folder beside the binary is ours to write: a
    // read-only binary reads what is next to it and nothing else, or the folder you happened
    // to launch from would be the search path this design does not have.
    if install_mode() != .ReadOnly {
        cwd := filepath.join({launch_dir(), name}, context.temp_allocator) or_else ""
        if cwd != "" && os.exists(cwd) {
            return strings.clone(cwd, allocator)
        }
    }
    return strings.clone(beside, allocator)
}

// The working directory Slopd was LAUNCHED from, asked for once and kept. The fallback above
// resolves against this rather than the live cwd: `:cd` moves the live one, and a config file
// that moved with it would be a different file each time it was asked for.
// A fixed buffer rather than an allocation: nothing ever owns a cache that lives as long as
// the process, and PATH_MAX of BSS costs less than a string with no one to free it.
@(private = "file")
launch_buf: [4096]u8
@(private = "file")
launch_len := -1 // -1 = not asked yet; 0 is a legitimate answer

@(private = "file")
launch_dir :: proc() -> string {
    if launch_len < 0 {
        launch_len = copy(launch_buf[:], os.get_working_directory(context.temp_allocator) or_else "")
    }
    return string(launch_buf[:launch_len])
}

// The directory containing the running executable (Linux: the /proc/self/exe link),
// falling back to argv[0]'s directory. The caller owns the result.
exe_dir :: proc(allocator := context.allocator) -> string {
    path := os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
    return strings.clone(filepath.dir(path), allocator) // filepath.dir slices path; clone to own
}

// The full path to the running executable (Linux: the /proc/self/exe link), falling back to
// argv[0]. Used to re-invoke ourselves (`<exe> --grammar install <lang>`, `<exe> --install`)
// without relying on slopd being on PATH. The caller owns the result.
exe_path :: proc(allocator := context.allocator) -> string {
    return strings.clone(os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0], allocator)
}

// Whether this process may create a file in `dir`. One access(2) — not a probe file, which
// would write to the release folder on every launch just to ask a question.
dir_writable :: proc(dir: string) -> bool {
    if dir == "" {
        return false
    }
    c := strings.clone_to_cstring(dir, context.temp_allocator)
    return linux.access(c, linux.W_OK) == .NONE
}

// Whether a settings change can be SAVED. Two ways it cannot be:
//
//   ReadOnly       every write would fail with EACCES anyway. Refusing early keeps a
//                  half-written config off the disk.
//   no config file Slopd does not create one — `--install` does, once, in the place the mode
//                  chose. A lone downloaded binary is the ordinary case here: it runs on the
//                  baked-in defaults, and installing is what gives you a file to change them
//                  in. Deleting your config puts you back in the same state, which is the
//                  point of having one rule rather than a special case per mode.
//
// The test seam counts as writable — the suite's override is a path the test owns and is
// free to create (see config_path_override).
config_writable :: proc() -> bool {
    if config_path_override != "" {
        return true
    }
    if install_mode() == .ReadOnly {
        return false
    }
    return os.exists(config_asset("slopd.config", context.temp_allocator))
}

// Create the directory a file is about to be written into. A no-op in Portable mode (the
// folder is the one we are running from) and the first write's setup once installed, where
// ~/.config/slopd may not exist yet.
ensure_parent :: proc(path: string) {
    if dir := filepath.dir(path); dir != "" { // a slice of `path`, not an allocation
        _ = os.make_directory_all(dir)
    }
}

// --- install / uninstall ---

// Copy the running binary to ~/.local/bin/slopd, create the XDG folders, and lay the config
// down in the one place it is ever created. Idempotent: run it again after a rebuild and it
// replaces the installed copy, leaving every file it already wrote alone.
//
// **This is also what a downloaded binary still needs.** install.sh puts the binary on your
// PATH and stops there, so the copy step below finds itself already in place and says so —
// the work that remains is the config and the folders, which is why the Config pane's Install
// row is not a no-op on a machine where slopd already runs.
//
// The copy is staged and renamed rather than written in place, because writing over a binary
// that is RUNNING fails with ETXTBSY — a rename does not, since the running process keeps the
// old inode until it exits.
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
        // themes/ and grammars/ are created EMPTY rather than on first use, so the folders
        // an install talks about are folders you can open. Both are yours to fill: a theme
        // is a file you drop in, a grammar is what `--grammar install` builds.
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

    // The config, in the one place it is ever created. Two sources, in this order, and only
    // where the target has none — a reinstall after a rebuild must not roll your settings
    // back, so an existing file is left exactly as it is:
    //
    //   1. the portable folder's own slopd.config, if you are installing FROM one. That is
    //      the file you have been editing, and it moves in with you.
    //   2. the copy baked into this binary. This is the ordinary path: the release is one
    //      binary with no file beside it.
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

// Remove the installed binary, and NOTHING else. Settings, themes and grammars are yours:
// they are named here with the line that deletes them, and left on the disk.
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
    // The two folders are NAMED with the line that removes them, and left alone: what you
    // configured is yours, and an uninstall that took it with it would be a trap.
    return true, fmt.tprintf(
        "uninstalled\n  removed %s\n\n  your settings, themes and grammars are still here:\n    rm -rf %s %s",
        dst,
        install_config_dir(context.temp_allocator),
        install_data_dir(context.temp_allocator),
    )
}

// Every path Slopd uses, and the mode that chose them — the answer to "which slopd.config am
// I actually editing?". Temp-allocated.
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
        // The state a downloaded binary starts in. It RUNS on the defaults baked into it —
        // nothing is missing — but a settings change has no file to land in until you install.
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

// What the Config pane's install row shows in its value column: the mode, the place it chose,
// and — when there is one — the reason nothing below this row can be saved. It is the first
// row of the pane so that this reason sits ABOVE the settings it applies to, rather than
// being discovered one silently-unsaved setting at a time.
// Always a fresh string in `allocator`, since the row it feeds outlives every temp path here.
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
        // Running on the baked-in defaults, with no file to write a change to. `install`
        // below is what makes one, so the row names the fix as well as the state.
        return fmt.aprintf("%s · %s · no config file — install to save settings", install_mode_label(install_mode()), short, allocator = allocator)
    }
    return fmt.aprintf("%s · %s", install_mode_label(install_mode()), short, allocator = allocator)
}

// --- the copying, and the PATH check ---

// Copy one file into `dir` if it is not already there. false covers "no source", "already
// there" and a failed copy — the caller reports only what actually moved.
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

// Copy the FILES of one directory into another, creating it, and skipping any that is
// already there. Flat on purpose: themes/ and grammars/ hold files and nothing else, so a
// recursive copy would only add a way to follow something unexpected. Returns how many moved.
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

// Whether `dir` is one of $PATH's entries — an exact match, since PATH holds directories and
// a prefix test would call ~/.local/binaries a hit.
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

// Handled before the GLFW window opens, like the grammar CLI: these are what the Config
// pane's install row runs in t1, and they must answer on a machine with no display.
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
