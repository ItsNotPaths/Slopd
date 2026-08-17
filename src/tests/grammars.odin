package tests

import app ".."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Test grammars — the suite builds its own, once, and caches them where a release cannot wipe
// them. The tests that need tree-sitter used to resolve `build/grammars`, which `release.sh`
// clears, so they SKIPPED on most checkouts; that is how a broken fixture (a.gram_ext, unset,
// so every highlight test resolved no grammar at all) survived unnoticed.
//
// The build reuses grammar_install — the same git fetch at a pinned rev and the same `cc` the
// Config pane and `slopd --grammar install` use — so a grammar the suite can build is a grammar
// the program can install, and there is no second path to keep in step.
//
// **Offline is fine, silence is not.** With no network or no compiler the affected tests print a
// skip and pass, which keeps a plane-journey checkout usable. Setting SLOPD_REQUIRE_GRAMMARS
// turns that skip into a failure — CI sets it, so the coverage cannot quietly disappear again.

// The grammars the suite builds, and what each is here for.
//
//   odin    the semantic and scroll-stability tests (the SNIPPET they assert positions into)
//   python  an external scanner holding an INDENT STACK: its state has to serialise and restore
//           across every incremental edit, and a mistake there yields a wrong tree in silence
//   cpp     the heaviest grammar in the registry — the throughput case, and what the keystroke
//           latency figures in todo.txt are worth measuring against
TEST_GRAMMARS :: [?]string{"odin", "python", "cpp"}

// Built grammars live under vendor/, which is git-ignored and cached by CI, and which nothing in
// the release path touches. SLOPD_TEST_GRAMMARS overrides it for a machine that already has them.
@(private = "file")
grammar_cache_dir :: proc() -> string {
    if d := os.get_env("SLOPD_TEST_GRAMMARS", context.temp_allocator); d != "" {
        return d
    }
    // Run from the repo root (`odin test src/tests`) or from within it; both reach the same dir.
    for root in ([]string{"vendor", "../vendor"}) {
        if os.exists(root) {
            return filepath.join({root, "grammars-test"}, context.temp_allocator) or_else root
        }
    }
    return "vendor/grammars-test"
}

// Build whatever is missing, before the runner starts its threads — an @(init) runs once and
// single-threaded, which a per-test lazy build could not promise. A warm cache costs three
// os.exists calls; a cold one takes a minute or two and says so, because a test run that
// appears to hang is worse than one that explains itself.
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

// The directory holding `name`, or ok=false — having ANNOUNCED why. Offline that is a skip and
// the caller returns; under SLOPD_REQUIRE_GRAMMARS it fails the test instead.
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

// An App carrying just what highlight_visible touches: a populated theme, an initialised
// highlighter with `lang` preloaded, and the ext->language index the lookup actually reads.
// Torn down by hl_app_destroy. ok=false when the grammar could not be built.
hl_app :: proc(t: ^testing.T, a: ^app.App, lang, ext: string) -> bool {
    dir, ok := grammar_or_skip(t, lang)
    if !ok {
        return false
    }
    a.theme = app.default_theme()
    app.highlighter_init(&a.hl)
    // Heap/temp-allocated so the registry outlives this proc — a `[]T{...}` literal is backed by
    // this frame's stack and would dangle once it returns.
    exts := make([]string, 1, context.temp_allocator)
    exts[0] = ext
    grams := make([]app.Grammar, 1, context.temp_allocator)
    grams[0] = app.Grammar{name = lang, exts = exts}
    a.grammars = grams
    // The lookup goes through the ext->language index, NOT the registry — main.odin builds it
    // once at startup, so a fixture that only sets `grammars` resolves nothing at all.
    a.gram_ext = app.grammar_ext_index(a.grammars)
    return app.highlighter_preload(&a.hl, dir, lang)
}

hl_app_destroy :: proc(a: ^app.App) {
    app.highlighter_destroy(&a.hl)
    delete(a.gram_ext)
}
