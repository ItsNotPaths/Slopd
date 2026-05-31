package tests

import app ".."
import "core:strings"
import "core:testing"

// Navigation runs against the real working directory; skips if not launched from
// the project root (so it stays deterministic without a fixture).
@(test)
test_filetree_nav :: proc(t: ^testing.T) {
    ft: app.FileTree
    app.filetree_init(&ft)
    defer app.filetree_destroy(&ft)

    src := -1
    for e, i in ft.entries {
        if e.name == "src" {
            src = i
            break
        }
    }
    if src < 0 {
        return
    }

    ft.selected = src
    app.filetree_enter(&ft)
    testing.expect(t, strings.has_suffix(ft.dir, "src"))

    app.filetree_parent(&ft)
    testing.expect(t, strings.has_suffix(ft.dir, "PitEd"))
}
