package tests

import app ".."
import "core:fmt"
import "core:testing"
import stbtt "vendor:stb/truetype"
import "../gfx"

// The file-type icons. Two claims, and the first is the one that cannot be seen by looking at
// the program: **every rune in the tables is a glyph the EMBEDDED face actually carries.** An
// icon outside the vendored subset does not fail, warn, or draw tofu — font_glyph caches it
// absent and the row simply has a blank where its icon should be. A codepoint typed by hand,
// or a subset range narrowed in download-deps.sh, would do exactly that, everywhere, silently.
//
// GL-free: stb's glyph lookup is CPU-only, so this reads the same bytes the binary embeds
// without a window or an atlas.

// Whether icons were vendored at all. download-deps.sh writes a ZERO-BYTE file when fontTools
// is missing, which is how it says "no icons" — so the assertions below skip rather than fail
// on a machine that built without it, exactly as the grammar tests skip.
@(private = "file")
icons_embedded :: proc() -> bool {
    return len(gfx.ICONS_TTF) > 0
}

@(test)
test_icon_runes_are_in_the_embedded_face :: proc(t: ^testing.T) {
    if !icons_embedded() {
        fmt.println("[skip] no icon face vendored; see download-deps.sh (fontTools)")
        return
    }
    info: stbtt.fontinfo
    testing.expect(t, bool(stbtt.InitFont(&info, raw_data(gfx.ICONS_TTF), 0)), "the icon face does not parse")

    // The reference glyph the bake size is derived from. Without it every icon still draws, but
    // at the wrong size — font_load falls back to the text px and the advance stops matching
    // the cell — so it is worth naming rather than leaving to the sweep below.
    testing.expect(t, stbtt.FindGlyphIndex(&info, gfx.ICON_REF) != 0, "ICON_REF is not in the face")

    missing := 0
    for r in gfx.ICON_BY_NAME {
        if stbtt.FindGlyphIndex(&info, r.icon) == 0 {
            missing += 1
            testing.expectf(t, false, "name rule %q maps to U+%04X, which the face lacks", r.key, r.icon)
        }
    }
    for r in gfx.ICON_BY_EXT {
        if stbtt.FindGlyphIndex(&info, r.icon) == 0 {
            missing += 1
            testing.expectf(t, false, "ext rule %q maps to U+%04X, which the face lacks", r.key, r.icon)
        }
    }
    testing.expect_value(t, missing, 0)

    // And the two the tables do not have to name, because file_icon returns them directly.
    testing.expect(t, stbtt.FindGlyphIndex(&info, gfx.ICON_FOLDER) != 0, "no folder icon")
    testing.expect(t, stbtt.FindGlyphIndex(&info, gfx.ICON_FILE) != 0, "no generic file icon")
}

// The mapping itself: a directory is a folder whatever it is called, a name beats an
// extension, and anything unknown is the generic file rather than a guess.
@(test)
test_file_icon_mapping :: proc(t: ^testing.T) {
    testing.expect_value(t, gfx.file_icon("src", true), gfx.ICON_FOLDER)
    testing.expect_value(t, gfx.file_icon("Makefile", true), gfx.ICON_FOLDER) // a dir named like a file

    // The name table is matched first, and case-insensitively — `MAKEFILE` and `Dockerfile`
    // are both real spellings in the wild.
    testing.expect_value(t, gfx.file_icon("Makefile", false), gfx.ICON_MAKEFILE)
    testing.expect_value(t, gfx.file_icon("MAKEFILE", false), gfx.ICON_MAKEFILE)
    testing.expect_value(t, gfx.file_icon("Dockerfile", false), gfx.ICON_DOCKER)
    testing.expect_value(t, gfx.file_icon(".gitignore", false), gfx.ICON_GITIGNORE)
    testing.expect_value(t, gfx.file_icon("LICENSE", false), gfx.ICON_LICENSE)
    testing.expect_value(t, gfx.file_icon("Cargo.toml", false), gfx.ICON_RUST) // name beats .toml
    testing.expect_value(t, gfx.file_icon("other.toml", false), gfx.ICON_TOML)

    // Extensions, lower-cased.
    testing.expect_value(t, gfx.file_icon("main.rs", false), gfx.ICON_RUST)
    testing.expect_value(t, gfx.file_icon("main.c", false), gfx.ICON_C)
    testing.expect_value(t, gfx.file_icon("main.CPP", false), gfx.ICON_CPP)
    testing.expect_value(t, gfx.file_icon("photo.JPEG", false), gfx.ICON_IMAGE)
    testing.expect_value(t, gfx.file_icon("a.tar.gz", false), gfx.ICON_ARCHIVE) // the LAST extension
    testing.expect_value(t, gfx.file_icon("notes.md", false), gfx.ICON_MARKDOWN)

    // A dotfile with no second dot is a name, not a type: `.bashrc` must not be read as the
    // "bashrc" extension, which is what filepath.ext returning "" for it buys.
    testing.expect_value(t, gfx.file_icon(".bashrc", false), gfx.ICON_FILE)

    // Unknown, and deliberately unknown: Nerd Fonts has no Odin glyph, and a wrong logo is
    // worse than the generic one. This asserts the choice rather than the absence.
    testing.expect_value(t, gfx.file_icon("app.odin", false), gfx.ICON_FILE)
    testing.expect_value(t, gfx.file_icon("mystery.qqq", false), gfx.ICON_FILE)
    testing.expect_value(t, gfx.file_icon("noext", false), gfx.ICON_FILE)
    testing.expect_value(t, gfx.file_icon("", false), gfx.ICON_FILE)
}

// A duplicate key is dead weight: the scan returns the first, so the second can never fire and
// the two will drift apart the next time someone edits one of them.
@(test)
test_icon_tables_have_no_duplicate_keys :: proc(t: ^testing.T) {
    for r, i in gfx.ICON_BY_NAME {
        for s, j in gfx.ICON_BY_NAME {
            if i < j && r.key == s.key {
                testing.expectf(t, false, "duplicate name rule %q", r.key)
            }
        }
    }
    for r, i in gfx.ICON_BY_EXT {
        for s, j in gfx.ICON_BY_EXT {
            if i < j && r.key == s.key {
                testing.expectf(t, false, "duplicate ext rule %q", r.key)
            }
        }
    }
}
