package tests

import app ".."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// The suite builds its own grammars, once, and caches them where a release cannot wipe them.
// They used to resolve `build/grammars`, which `release.sh` clears, so the tests skipped on most
// checkouts — which is how a broken fixture survived unnoticed.
//
// The build reuses grammar_install, so a grammar the suite can build is one the program can
// install and there is no second path to keep in step.
//
// Offline is fine, silence is not: with no network or compiler the affected tests skip and pass,
// and SLOPD_REQUIRE_GRAMMARS turns that skip into a failure. CI sets it.

// What each grammar is here for:
//   odin    the semantic and scroll-stability tests
//   python  an external scanner holding an INDENT STACK, whose state has to serialise and
//           restore across every incremental edit
//   cpp     the heaviest grammar in the registry: the throughput case
TEST_GRAMMARS :: [?]string{"odin", "python", "cpp"}

// Under vendor/, git-ignored, cached by CI and untouched by the release path.
// SLOPD_TEST_GRAMMARS overrides it for a machine that already has them.
@(private = "file")
grammar_cache_dir :: proc() -> string {
    if d := os.get_env("SLOPD_TEST_GRAMMARS", context.temp_allocator); d != "" {
        return d
    }
    // From the repo root or from within it; both reach the same dir.
    for root in ([]string{"vendor", "../vendor"}) {
        if os.exists(root) {
            return filepath.join({root, "grammars-test"}, context.temp_allocator) or_else root
        }
    }
    return "vendor/grammars-test"
}

// Before the runner starts its threads: an @(init) runs once and single-threaded, which a
// per-test lazy build could not promise. A warm cache costs three os.exists calls; a cold one
// takes a minute or two and says so.
@(init)
grammars_ensure :: proc "contextless" () {
    context = runtime.default_context()
    dir := grammar_cache_dir()
    missing := 0
    for name in TEST_GRAMMARS {
        if !app.grammar_present(dir, name) {
            missing += 1
        }
    }
    if missing == 0 {
        return
    }

    fmt.printfln("[grammars] %d to build into %s — first run only, this takes a minute", missing, dir)
    reg := app.load_grammars()
    defer app.grammars_destroy(reg)
    for name in TEST_GRAMMARS {
        if app.grammar_present(dir, name) {
            continue
        }
        g, found := app.grammar_find(reg, name)
        if !found {
            fmt.printfln("[grammars] %s: not in the registry", name)
            continue
        }
        _, msg := app.grammar_install(dir, g^)
        fmt.printfln("[grammars] %s", msg)
    }
}

// ok=false having announced why: offline it is a skip, under SLOPD_REQUIRE_GRAMMARS a failure.
grammar_or_skip :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    dir = grammar_cache_dir()
    if app.grammar_present(dir, name) {
        return dir, true
    }
    if os.get_env("SLOPD_REQUIRE_GRAMMARS", context.temp_allocator) != "" {
        testing.expectf(t, false, "grammar %q is required here but was not built (see tests/grammars.odin)", name)
    } else {
        fmt.printfln("[skip] %s grammar unavailable — offline, or no cc (see tests/grammars.odin)", name)
    }
    return "", false
}

// Just what highlight_visible touches: a populated theme, an initialised highlighter with `lang`
// preloaded, and the ext->language index the lookup reads.
hl_app :: proc(t: ^testing.T, a: ^app.App, lang, ext: string) -> bool {
    dir, ok := grammar_or_skip(t, lang)
    if !ok {
        return false
    }
    a.theme = app.default_theme()
    app.highlighter_init(&a.hl)
    // So the registry outlives this proc: a `[]T{...}` literal is backed by this frame's stack.
    exts := make([]string, 1, context.temp_allocator)
    exts[0] = ext
    grams := make([]app.Grammar, 1, context.temp_allocator)
    grams[0] = app.Grammar{name = lang, exts = exts}
    a.grammars = grams
    // Through the ext->language index, not the registry: a fixture that only sets `grammars`
    // resolves nothing.
    a.gram_ext = app.grammar_ext_index(a.grammars)
    return app.highlighter_preload(&a.hl, dir, lang)
}

hl_app_destroy :: proc(a: ^app.App) {
    app.highlighter_destroy(&a.hl)
    delete(a.gram_ext)
}
