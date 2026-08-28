package tests

import app "../slopd"
import "core:os"
import "core:strings"
import "core:testing"
import "../search"

// The exclusion list (exclude.odin) — ONE config line read by two tools, so what is asserted
// here is that both read it the same way: the patterns a line splits into, the directories they
// match, and the `--exclude-dir` flags a search is handed for them.

@(test)
test_exclude_split :: proc(t: ^testing.T) {
    pats := search.exclude_split(".git, vendor, node_modules")
    testing.expect_value(t, len(pats), 3)
    testing.expect_value(t, pats[0], ".git")
    testing.expect_value(t, pats[1], "vendor")
    testing.expect_value(t, pats[2], "node_modules")

    // A trailing slash is how a directory is usually written, so `vendor/` is `vendor`. Empty
    // entries (a stray comma, a blank line's worth of spaces) are dropped rather than matching
    // everything or nothing in particular.
    trimmed := search.exclude_split("  vendor/ ,, target//  ,")
    testing.expect_value(t, len(trimmed), 2)
    testing.expect_value(t, trimmed[0], "vendor")
    testing.expect_value(t, trimmed[1], "target")

    testing.expect_value(t, len(search.exclude_split("")), 0) // unset: search everything
}

// Matching is grep's own: a shell glob over the directory NAME, at any depth. That is the whole
// unification — whatever a pattern means here is what grep is handed for it.
@(test)
test_exclude_hit :: proc(t: ^testing.T) {
    pats := search.exclude_split("vendor, node_modules, *.bundle")
    testing.expect(t, search.exclude_hit(pats, "vendor"))
    testing.expect(t, search.exclude_hit(pats, "node_modules"))
    testing.expect(t, search.exclude_hit(pats, "assets.bundle"))
    testing.expect(t, !search.exclude_hit(pats, "vendored"), "a pattern matches the WHOLE name")
    testing.expect(t, !search.exclude_hit(pats, "src"))
    testing.expect(t, !search.exclude_hit(nil, "vendor"), "an empty list excludes nothing")

    // A pattern that will not compile matches nothing: a typo must not empty the jump list.
    testing.expect(t, !search.exclude_hit(search.exclude_split("[bad"), "anything"))
}

// The command line a search runs. Asserted rather than executed, so this holds on a machine
// with no grep — and so the flags cannot drift from what the config line promises.
@(test)
test_grep_argv :: proc(t: ^testing.T) {
    argv := search.grep_argv("/w", "needle", search.exclude_split(".git, vendor"), false, false)
    joined := strings.join(argv, " ", context.temp_allocator)
    testing.expect_value(t, joined, "grep -rnIH --exclude-dir=.git --exclude-dir=vendor -- needle /w")

    // The symbol lookup's two extra flags, and the pattern still last but one: `--` guards a
    // query that starts with a '-'.
    word := search.grep_argv("/w", "-x", nil, true, true)
    testing.expect_value(t, strings.join(word, " ", context.temp_allocator), "grep -rnIH -w -F -- -x /w")
}

// The config row: free text, like git_tool, since a list of patterns has no menu of answers.
@(test)
test_exclude_setting :: proc(t: ^testing.T) {
    path := "/tmp/slopd_exclude.config"
    os.remove(path)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    a: app.App
    testing.expect(t, app.setting_is_text(.Exclude))
    testing.expect(t, app.setting_options(&a, .Exclude) == nil)
    testing.expect_value(t, app.setting_key(.Exclude), "exclude")
    testing.expect_value(t, app.setting_value(&a, .Exclude), "")

    testing.expect(t, app.setting_commit(&a, .Exclude, ".git, vendor"))
    defer delete(a.exclude)
    testing.expect_value(t, a.exclude, ".git, vendor")
    testing.expect_value(t, app.setting_value(&a, .Exclude), ".git, vendor")
    testing.expect_value(t, len(app.exclude_dirs(&a)), 2)

    // Written back, and read back as itself.
    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.exclude, ".git, vendor")

    // git_tool's one limit, for git_tool's reason: a '#' after a space would write whole and
    // read back truncated, so the value is refused rather than saved unreadable.
    testing.expect(t, !app.setting_commit(&a, .Exclude, "vendor #nope"))
    testing.expect_value(t, a.exclude, ".git, vendor")
}
