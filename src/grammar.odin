package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Tree-sitter grammar management — shared by the Config aux pane and the
// `slopd --health` / `slopd --grammar` CLI flags. Grammars are NOT shipped: the
// release's grammars/ folder starts empty and a language is installed at runtime
// (one Enter in the Config pane, or the CLI), which keeps the dist tiny. Each
// installed grammar is a compiled shared library grammars/<lang>.so. Self-contained:
// grammars/ (and themes/) resolve next to the executable, so a release folder runs
// from any cwd.

// The languages Slopd knows how to install. Helix sources its set from a
// languages.toml; ours is a small built-in registry for now.
// TODO(phase2): a declarative registry (extension -> grammar repo + rev + queries).
KNOWN_LANGS := [?]string {
    "odin",
    "c",
    "cpp",
    "rust",
    "go",
    "python",
    "javascript",
    "typescript",
    "json",
    "toml",
    "bash",
    "markdown",
    "zig",
    "lua",
}

// The directory holding compiled grammar libs, resolved next to the binary (a
// release ships Slopd + slopd.config + themes/ + grammars/ side by side). The caller
// owns the result.
grammars_dir :: proc(allocator := context.allocator) -> string {
    return asset_dir("grammars", allocator)
}

// Resolves an asset folder shipped beside the executable. Prefers <exe_dir>/<name>;
// falls back to ./<name> for `odin run` development. Returns <exe_dir>/<name> even
// when it doesn't exist yet — it's the write target, since grammars are created on
// install. The caller owns the result.
asset_dir :: proc(name: string, allocator := context.allocator) -> string {
    exe := exe_dir(context.temp_allocator)
    beside := filepath.join({exe, name}, context.temp_allocator) or_else strings.clone(name, context.temp_allocator)
    if os.exists(beside) {
        return strings.clone(beside, allocator)
    }
    if os.exists(name) {
        return strings.clone(name, allocator)
    }
    return strings.clone(beside, allocator)
}

// The directory containing the running executable (Linux: the /proc/self/exe link),
// falling back to argv[0]'s directory. The caller owns the result.
exe_dir :: proc(allocator := context.allocator) -> string {
    // Linux: resolve via the /proc/self/exe link, falling back to argv[0].
    path := os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
    return strings.clone(filepath.dir(path), allocator) // filepath.dir slices path; clone to own
}

// grammars/<lang>.so for a given grammars dir. The caller owns the result.
grammar_lib_path :: proc(dir, lang: string, allocator := context.allocator) -> string {
    lib := fmt.tprintf("%s.so", lang)
    return filepath.join({dir, lib}, allocator) or_else strings.clone(lib, allocator)
}

// Whether a language's compiled grammar is installed.
grammar_present :: proc(dir, lang: string) -> bool {
    return os.exists(grammar_lib_path(dir, lang, context.temp_allocator))
}

is_known_lang :: proc(lang: string) -> bool {
    for l in KNOWN_LANGS {
        if l == lang {
            return true
        }
    }
    return false
}

// --- install actions (msg is temp-allocated, for printing / surfacing) ---

// Fetch + build a grammar. STUB until the tree-sitter vendor + registry land.
// TODO(phase2): git clone the grammar repo at its pinned rev into a temp dir, then
//   cc -shared -fPIC -I<src> parser.c [scanner.c] -o <dir>/<lang>.so
grammar_install :: proc(dir, lang: string) -> (ok: bool, msg: string) {
    if !is_known_lang(lang) {
        return false, fmt.tprintf("%s: unknown language", lang)
    }
    return false, fmt.tprintf("%s: install not yet implemented", lang)
}

// Re-fetch at the pinned rev and rebuild. STUB, same as install.
// TODO(phase2): implement alongside grammar_install.
grammar_update :: proc(dir, lang: string) -> (ok: bool, msg: string) {
    if !is_known_lang(lang) {
        return false, fmt.tprintf("%s: unknown language", lang)
    }
    return false, fmt.tprintf("%s: update not yet implemented", lang)
}

// Remove an installed grammar. Real now — just deletes the compiled lib.
grammar_uninstall :: proc(dir, lang: string) -> (ok: bool, msg: string) {
    path := grammar_lib_path(dir, lang, context.temp_allocator)
    if !os.exists(path) {
        return false, fmt.tprintf("%s: not installed", lang)
    }
    if err := os.remove(path); err != nil {
        return false, fmt.tprintf("%s: remove failed (%v)", lang, err)
    }
    return true, fmt.tprintf("%s: uninstalled", lang)
}

// --- CLI (`slopd --health [lang]`, `slopd --grammar <action> <lang>`) ---

// Handles the grammar CLI flags before the GLFW window opens. Returns true if a
// command was handled, so the caller exits without launching the editor.
grammar_cli :: proc(args: []string) -> (handled: bool) {
    for i := 0; i < len(args); i += 1 {
        switch args[i] {
        case "--health":
            lang := i + 1 < len(args) ? args[i + 1] : ""
            grammar_print_health(lang)
            return true
        case "--grammar":
            if i + 2 >= len(args) {
                fmt.eprintln("usage: slopd --grammar install|uninstall|update <lang>")
                return true
            }
            grammar_run_action(args[i + 1], args[i + 2])
            return true
        }
    }
    return false
}

@(private = "file")
grammar_run_action :: proc(action, lang: string) {
    dir := grammars_dir(context.temp_allocator)
    msg: string
    switch action {
    case "install":
        _, msg = grammar_install(dir, lang)
    case "uninstall":
        _, msg = grammar_uninstall(dir, lang)
    case "update":
        _, msg = grammar_update(dir, lang)
    case:
        fmt.eprintfln("unknown grammar action: %s (want install|uninstall|update)", action)
        return
    }
    fmt.println(msg)
}

// Prints grammar health for one language, or a ✓/✗ table for all known languages.
grammar_print_health :: proc(lang: string) {
    dir := grammars_dir(context.temp_allocator)
    if lang != "" {
        if !is_known_lang(lang) {
            fmt.printfln("%s: unknown language", lang)
            return
        }
        print_health_row(dir, lang)
        return
    }
    fmt.println("grammars:", dir)
    for l in KNOWN_LANGS {
        print_health_row(dir, l)
    }
}

@(private = "file")
print_health_row :: proc(dir, lang: string) {
    mark := grammar_present(dir, lang) ? "✓ installed    " : "✗ not installed"
    fmt.printfln("  %s  %s", mark, lang)
}
