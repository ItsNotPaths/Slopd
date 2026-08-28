package tests

import app "../slopd"
import "core:strings"
import "core:testing"

// The launcher entry: the template baked into the binary, and the one substitution made on its
// way to ~/.local/share/applications.

// #load-ed, so an empty one would ship an entry that launches nothing. Pin the keys a launcher
// needs, and the app-id that ties a running window back to the entry.
@(test)
test_desktop_entry_source :: proc(t: ^testing.T) {
    src := app.DESKTOP_ENTRY_SRC
    testing.expect(t, len(src) > 100, "the desktop entry did not get #load-ed")
    testing.expect(t, strings.has_prefix(src, "[Desktop Entry]"), "a desktop file must open with its group header")
    for key in ([]string{"Type=Application", "Name=Slopd", "Icon=slopd", "StartupWMClass=slopd", "Categories="}) {
        testing.expect(t, strings.contains(src, key), key)
    }

    // What the entry's `Icon=slopd` resolves to through the hicolor theme. A launcher that
    // cannot parse it falls back to a generic icon, so this only checks a document arrived.
    testing.expect(t, strings.contains(app.DESKTOP_ICON_SRC, "<svg"), "the icon did not get #load-ed")
}

// Exec and TryExec get an ABSOLUTE path: an entry is launched with the session's PATH, and
// ~/.local/bin is not always on it.
@(test)
test_desktop_entry_text :: proc(t: ^testing.T) {
    out := app.desktop_entry_text(app.DESKTOP_ENTRY_SRC, "/home/me/.local/bin/slopd", context.temp_allocator)
    testing.expect(t, strings.contains(out, "Exec=/home/me/.local/bin/slopd\n"))
    testing.expect(t, strings.contains(out, "TryExec=/home/me/.local/bin/slopd\n"))
    testing.expect(t, !strings.contains(out, "Exec=slopd\n"), "the template's bare name must not survive")

    // Everything else is copied verbatim, the comments included.
    testing.expect(t, strings.contains(out, "StartupWMClass=slopd"))
    testing.expect(t, strings.contains(out, "Categories=Utility;TextEditor;"))
    testing.expect(t, strings.contains(out, "# Utility is the one main category"))

    // Icon=slopd is a name resolved through the icon theme, not a path to rewrite.
    testing.expect(t, strings.contains(out, "Icon=slopd\n"))
}

// A template with no Exec still produces a file, and adds nothing.
@(test)
test_desktop_entry_text_minimal :: proc(t: ^testing.T) {
    out := app.desktop_entry_text("[Desktop Entry]\nName=X\n", "/bin/x", context.temp_allocator)
    testing.expect_value(t, out, "[Desktop Entry]\nName=X\n")
}

// Off the SHARED trees under ~/.local/share, not Slopd's own folder in it: a .desktop under
// share/slopd/ is a file no launcher will read.
@(test)
test_desktop_paths :: proc(t: ^testing.T) {
    entry := app.desktop_entry_path(context.temp_allocator)
    icon := app.desktop_icon_path(context.temp_allocator)
    if entry == "" { // no $HOME: there is nowhere to file an entry, and that is an answer
        testing.expect_value(t, icon, "")
        return
    }
    testing.expect(t, strings.has_suffix(entry, "/applications/slopd.desktop"), entry)
    testing.expect(t, strings.has_suffix(icon, "/icons/hicolor/scalable/apps/slopd.svg"), icon)
    testing.expect(t, !strings.contains(entry, "/slopd/"), "the entry must not be filed under Slopd's own data folder")
}
