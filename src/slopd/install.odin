package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "../paths"

// The install / uninstall the Config pane's first row drives, and `--install` / `--uninstall`.
//
// Slopd is one binary carrying its own README, licence, language registry, default theme,
// default config and launcher entry — the release is that binary and nothing else. What it
// cannot carry is what you CHANGE: slopd.config, the themes/ and grammars/ you add.
//
// WHERE those sit is src/paths: the running binary's own location picks one directory per kind
// of file, and there is no search path. Slopd never creates slopd.config on its own — only
// `--install` does, so a setting is saved to a file that exists, or not at all.

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
    if paths.install_mode() == .ReadOnly {
        return false
    }
    return os.exists(paths.config_asset("slopd.config", context.temp_allocator))
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
    dst := paths.install_bin_path(context.temp_allocator)
    if dst == "" {
        return false, "install: no $HOME — nowhere to install to"
    }

    data := paths.install_data_dir(context.temp_allocator)
    dirs := [?]string {
        paths.install_bin_dir(context.temp_allocator),
        paths.install_config_dir(context.temp_allocator),
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

    src := paths.exe_path(context.temp_allocator)
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
    from := paths.exe_dir(context.temp_allocator)
    cfgdir := paths.install_config_dir(context.temp_allocator)
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
    if !on_path(paths.install_bin_dir(context.temp_allocator)) {
        fmt.sbprintfln(
            &b,
            "\n  %s is not on your PATH. Add it:\n    export PATH=\"%s:$PATH\"",
            paths.install_bin_dir(context.temp_allocator),
            paths.install_bin_dir(context.temp_allocator),
        )
    }
    return true, fmt.tprintf("installed\n%s", strings.trim_right_space(strings.to_string(b)))
}

// The binary and nothing else. Settings, themes and grammars stay on the disk.
install_remove :: proc() -> (ok: bool, msg: string) {
    dst := paths.install_bin_path(context.temp_allocator)
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
        paths.install_config_dir(context.temp_allocator),
        paths.install_data_dir(context.temp_allocator),
    )
}

// Every path Slopd uses, and the mode that chose them. Temp-allocated.
install_where :: proc() -> string {
    b := strings.builder_make(context.temp_allocator)
    cfg := paths.config_asset("slopd.config", context.temp_allocator)
    entry := desktop_entry_path(context.temp_allocator)
    fmt.sbprintfln(&b, "mode:      %s", install_status_label())
    fmt.sbprintfln(&b, "binary:    %s", paths.exe_path(context.temp_allocator))
    fmt.sbprintfln(&b, "config:    %s%s", cfg, os.exists(cfg) ? "" : "   (not there yet)")
    fmt.sbprintfln(&b, "themes:    %s", paths.data_asset("themes", context.temp_allocator))
    fmt.sbprintfln(&b, "grammars:  %s", paths.data_asset("grammars", context.temp_allocator))
    fmt.sbprintfln(&b, "launcher:  %s", desktop_present() ? entry : "not in the application list")
    if paths.install_mode() == .ReadOnly {
        fmt.sbprintfln(
            &b,
            "\n%s cannot be written, so no setting can be saved.\nInstall a copy that can: %s --install",
            paths.exe_dir(context.temp_allocator),
            paths.exe_path(context.temp_allocator),
        )
    } else if !os.exists(cfg) {
        // Where a downloaded binary starts: it runs on the baked-in defaults, but a settings
        // change has no file to land in until you install.
        fmt.sbprintfln(
            &b,
            "\nThere is no config file, so no setting can be saved. Slopd is running on the\ndefaults baked into the binary. Write them out: %s --install",
            paths.exe_path(context.temp_allocator),
        )
    }
    return strings.trim_right_space(strings.to_string(b))
}

install_mode_label :: proc(m: paths.Install_Mode) -> string {
    switch m {
    case .Portable:  return "portable"
    case .Installed: return "installed"
    case .ReadOnly:  return "read-only"
    }
    return ""
}

// Installed for real. `.Installed` only means the binary SITS at the install path, which is all
// install.sh does — it downloads the binary and stops. Everything an install writes is this
// program's own step, so a path that looks installed is not one until the config is there.
install_complete :: proc() -> bool {
    return paths.install_mode() == .Installed && config_writable()
}

// The word the pane and `--where` use.
install_status_label :: proc() -> string {
    if paths.install_mode() == .Installed && !install_complete() {
        return "not installed"
    }
    return install_mode_label(paths.install_mode())
}

// The mode, the place it chose, and any reason nothing below can be saved. First row of the
// pane so that reason sits above the settings it applies to. Always a fresh string in
// `allocator`, since the row it feeds outlives every temp path here.
install_state_text :: proc(allocator := context.allocator) -> string {
    where_: string
    switch paths.install_mode() {
    case .Installed:
        where_ = paths.install_bin_path(context.temp_allocator)
    case .Portable, .ReadOnly:
        where_ = paths.exe_dir(context.temp_allocator)
    }
    short := home_abbrev(where_, context.temp_allocator)
    if paths.install_mode() == .ReadOnly {
        return fmt.aprintf("read-only · %s · nothing can be saved", short, allocator = allocator)
    }
    if !config_writable() {
        // No file to write a change to; the row names the fix as well as the state.
        return fmt.aprintf("%s · %s · no config file — install to save settings", install_status_label(), short, allocator = allocator)
    }
    return fmt.aprintf("%s · %s", install_status_label(), short, allocator = allocator)
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
