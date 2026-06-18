package tests

import app ".."
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Syntax-highlighting tests. These need the compiled odin grammar (odin.so + odin.scm)
// on disk; they resolve it from a few candidate dirs and SKIP (not fail) when it's
// absent, so a checkout without grammars still passes the rest of the suite. Install
// it with `./release.sh --local` (writes <repo>/../Slopd-release/grammars) or point
// SLOPD_TEST_GRAMMARS at a dir holding odin.so/odin.scm.

@(private = "file")
grammars_dir :: proc() -> (string, bool) {
    candidates := [?]string {
        os.get_env("SLOPD_TEST_GRAMMARS", context.temp_allocator),
        "../Slopd-release/grammars",
        "/root/projects/Slopd-release/grammars",
        "grammars",
    }
    for c in candidates {
        if c == "" {
            continue
        }
        so := filepath.join({c, "odin.so"}, context.temp_allocator) or_else ""
        if so != "" && os.exists(so) {
            return c, true
        }
    }
    return "", false
}

// A representative odin snippet, long enough to scroll: procs, keywords, types,
// strings, comments, numbers, operators — so highlighting should produce many colours.
@(private = "file")
SNIPPET :: `package demo

import "core:fmt"

// a doc comment
Point :: struct {
    x: int,
    y: int,
}

add :: proc(a: int, b: int) -> int {
    return a + b
}

main :: proc() {
    p := Point{x = 1, y = 2}
    sum := add(p.x, p.y)
    if sum > 0 {
        fmt.println("positive", sum)
    } else {
        fmt.println("non-positive")
    }
    for i in 0 ..< 10 {
        fmt.println(i)
    }
}
`

// Builds a minimal App carrying just what highlight_visible touches: a populated
// theme, an initialised highlighter with the odin grammar preloaded, and a registry
// mapping the .odin extension to it. ok=false when the grammar isn't installed.
@(private = "file")
setup :: proc(a: ^app.App) -> bool {
    dir, found := grammars_dir()
    if !found {
        return false
    }
    a.theme = app.default_theme()
    app.highlighter_init(&a.hl)
    // Heap/temp-allocated so the registry outlives this proc — a `[]T{...}` literal is
    // backed by this frame's stack and would dangle once setup returns.
    exts := make([]string, 1, context.temp_allocator)
    exts[0] = "odin"
    grams := make([]app.Grammar, 1, context.temp_allocator)
    grams[0] = app.Grammar{name = "odin", exts = exts}
    a.grammars = grams
    return app.highlighter_preload(&a.hl, dir, "odin")
}

@(private = "file")
mkbuf :: proc() -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, SNIPPET)
    b.path = "demo.odin"
    return b
}

// Each token below must paint its expected theme slot. This is the heart of the
// regression: before predicate evaluation + later-pattern-wins precedence, gated rules
// (capitalised->@type, ALL_CAPS->@constant, context/self->@variable.builtin) fired on
// every identifier and the catch-all @variable swallowed the rest, so procs/types/etc.
// lost their colour. Positions are (line, col) into SNIPPET; colours are theme-relative
// so the check is independent of the palette.
@(test)
test_highlight_semantic :: proc(t: ^testing.T) {
    a: app.App
    if !setup(&a) {
        fmt.println("[skip] odin grammar not installed; see highlight_test.odin header")
        return
    }
    defer app.highlighter_destroy(&a.hl)
    b := mkbuf()
    defer app.buffer_destroy(&b)
    rows := app.highlight_visible(&a, &b, 0, len(b.lines))
    th := &a.theme

    Case :: struct {
        line, col: int,
        want:      [3]f32,
        what:      string,
    }
    cases := []Case {
        {4, 0, th.code_comment, "comment //"},
        {5, 0, th.code_type, "Point type decl"},
        {6, 7, th.code_type, "builtin type int"},
        {10, 0, th.code_function, "proc name add"}, // the headline fix: procs colour
        {10, 7, th.code_keyword, "keyword proc"},
        {11, 4, th.code_keyword, "keyword return"},
        {11, 13, th.code_operator, "operator +"},
        {15, 19, th.code_number, "number 1"},
        {18, 20, th.code_string, "string literal"},
    }
    for c in cases {
        if c.line >= len(rows) || rows[c.line] == nil || c.col >= len(rows[c.line]) {
            testing.expectf(t, false, "%s: position (%d,%d) out of range", c.what, c.line, c.col)
            continue
        }
        got := rows[c.line][c.col]
        testing.expectf(t, got == c.want, "%s at (%d,%d): got %v want %v", c.what, c.line, c.col, got, c.want)
    }
}

// The flash bug: a line's colours must not depend on the scroll offset (first_line).
// We paint the whole buffer, snapshot each line's colours, then re-paint at every
// scroll offset and assert the overlapping lines match byte-for-byte. Any drift is the
// non-deterministic precedence that made tokens flicker between colours while scrolling.
@(test)
test_highlight_scroll_stable :: proc(t: ^testing.T) {
    a: app.App
    if !setup(&a) {
        fmt.println("[skip] odin grammar not installed; see highlight_test.odin header")
        return
    }
    defer app.highlighter_destroy(&a.hl)
    b := mkbuf()
    defer app.buffer_destroy(&b)

    n := len(b.lines)
    // Snapshot the full-buffer paint (deep copy — the next highlight_visible frees it).
    full := app.highlight_visible(&a, &b, 0, n)
    baseline := make([dynamic][3]f32, 0, 256, context.temp_allocator)
    line_off := make([]int, n, context.temp_allocator) // start of each line in `baseline`
    for li in 0 ..< n {
        line_off[li] = len(baseline)
        for c in full[li] {
            append(&baseline, c)
        }
    }

    window := 8
    for top in 1 ..< n {
        rows := app.highlight_visible(&a, &b, top, window)
        for k in 0 ..< window {
            li := top + k
            if li >= n {
                break
            }
            bo := line_off[li]
            line_len := (li + 1 < n ? line_off[li + 1] : len(baseline)) - bo
            if !testing.expectf(
                t,
                len(rows[k]) == line_len,
                "line %d painted %d runes at scroll %d, baseline %d",
                li,
                len(rows[k]),
                top,
                line_len,
            ) {
                continue
            }
            for ci in 0 ..< line_len {
                if !testing.expectf(
                    t,
                    rows[k][ci] == baseline[bo + ci],
                    "line %d rune %d: colour %v at scroll %d != baseline %v (flicker)",
                    li,
                    ci,
                    rows[k][ci],
                    top,
                    baseline[bo + ci],
                ) {
                    break
                }
            }
        }
    }
}

// Debug: dump every mapped capture competing for the snippet, so we can see the
// precedence the .scm intends. Not an assertion — run with `-define:HLDUMP=true`.
HLDUMP :: #config(HLDUMP, false)

@(test)
test_highlight_dump :: proc(t: ^testing.T) {
    when !HLDUMP {
        return
    }
    a: app.App
    if !setup(&a) {
        return
    }
    defer app.highlighter_destroy(&a.hl)
    b := mkbuf()
    defer app.buffer_destroy(&b)
    app.highlight_dump_captures(&a, &b, 0, len(b.lines))
}
