package paths

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

// Where the product's files live: which directory holds the config, the themes, the grammars,
// and the binary an `--install` writes.
//
// The binary carries its defaults; what it cannot carry is what you CHANGE. The running
// binary's own location decides where those sit:
//
//   Portable   the folder beside the binary is writable — a download, or a build folder.
//              Everything lives there; move the folder and its world moves with it.
//   Installed  the binary sits at ~/.local/bin/<app_name>, so the files go to the XDG folders:
//              a bin folder holds programs, not their data. A location test, and only that —
//              install.sh drops the binary there and stops, so whether the install RAN is a
//              separate question (install_complete, in install.odin).
//   ReadOnly   the folder beside the binary cannot be written (someone put it in /usr/bin).
//              What is there is read, and nothing is written.
//
// There is no search path: a mode picks one directory per kind of file and reads and writes
// only there.

// The product this binary is. Every path below hangs off it, so a second front-end sets it
// once at startup and inherits the whole layout. Lower case, because it is what you type; the
// same name the window reports as its app-id.
app_name := "slopd"

Install_Mode :: enum {
    Portable,
    Installed,
    ReadOnly,
}

// Not an XDG variable: XDG has no user bin folder, and ~/.local/bin is what shells add to PATH.
app_name_DIR :: ".local/bin"

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
    return filepath.join({dir, app_name}, allocator) or_else strings.clone("", allocator)
}

install_bin_dir :: proc(allocator := context.allocator) -> string {
    home := home_dir(context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({home, app_name_DIR}, allocator) or_else strings.clone("", allocator)
}

install_config_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_dir("XDG_CONFIG_HOME", ".config", context.temp_allocator), allocator)
}

// themes/, grammars/ and perf.log once installed. Split from config because one folder is
// yours to edit and the other is the program's to fill.
install_data_dir :: proc(allocator := context.allocator) -> string {
    return install_subdir(xdg_data_home(context.temp_allocator), allocator)
}

// The root of it, not the product's folder inside: the launcher entry and its icon go in the shared
// applications/ and icons/ trees, which is where a launcher looks (desktop.odin).
xdg_data_home :: proc(allocator := context.allocator) -> string {
    return xdg_dir("XDG_DATA_HOME", ".local/share", allocator)
}

@(private = "file")
install_subdir :: proc(base: string, allocator := context.allocator) -> string {
    if base == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({base, app_name}, allocator) or_else strings.clone("", allocator)
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

// For re-invoking ourselves (`<exe> --install`) without relying on the name being on PATH.
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

// A no-op in Portable mode, and the first write's setup once installed.
ensure_parent :: proc(path: string) {
    if dir := filepath.dir(path); dir != "" { // a slice of `path`
        _ = os.make_directory_all(dir)
    }
}
