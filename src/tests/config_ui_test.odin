package tests

import app ".."
import clay "../../bindings/clay"
import "core:os"
import "core:testing"

// The config / syntax pane declared in Clay. The filetree proved a flat list of one-row items
// and grep one item spanning several rows; this pane adds rows that select NOTHING (section
// rules and titles) and rows carrying a second coordinate (a choice inside an open dropdown),
// plus the Custom the live search field needs.
//
// The pane is {100, 50, 300, 200} at scale 1 with the synthetic 10x16 font: a content area of
// {102, 52, 296, 196}, an 18px row, 10 rows fitting, and 29 whole cells across.

@(private = "file")
PANE :: app.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: app.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 18
@(private = "file")
MAX_ROWS :: 10
@(private = "file")
COLS :: 29

// A rule, the "slopd" title, a rule, and Slopd's own row. Chrome plus one row, never changing
// size, so every DISPLAY row number below counts from past it.
@(private = "file")
INSTALL_ROWS :: 4

@(private = "file")
BINDS_ROWS :: 2 // bindings and macros

// In cells: the widest setting key ("conflict_stage", 14) plus ": ". Pinned, because every
// column assertion below multiplies it out — a longer key fails exactly this assertion rather
// than a dozen pixel ones.
@(private = "file")
VAL_OFF :: 16

// In framebuffer pixels: chrome at the one-cell margin, an indent-1 row one cell further in, an
// indent-4 option row three past that.
@(private = "file")
X_FLUSH :: AREA.x + 10
@(private = "file")
X_ROW :: AREA.x + 20
@(private = "file")
X_VALUE :: X_ROW + VAL_OFF * 10
@(private = "file")
X_OPT :: AREA.x + 50

// Three synthetic languages, so the row maths does not depend on the generated `languages`
// registry being on the machine.
@(private = "file")
fixture :: proc(a: ^app.App) {
    app.config_pane_init(&a.config_pane, nil)
    a.scale = 1
    a.theme = app.default_theme() // a zero palette is all black, which hides colour bugs
    clear(&a.config_pane.langs)
    append(
        &a.config_pane.langs,
        app.LangStatus{name = "a"},
        app.LangStatus{name = "b", present = true},
        app.LangStatus{name = "c"},
    )
    app.config_pane_filter(&a.config_pane)
}

@(test)
test_config_geom :: proc(t: ^testing.T) {
    area, row_h, rows, cols := app.config_geom(PANE, 1, 16, 10)
    testing.expect_value(t, area, AREA)
    testing.expect_value(t, row_h, i32(ROW_H))
    // No row is reserved for a header: the first row is already a section rule, which is the
    // one geometry difference from the filetree and grep.
    testing.expect_value(t, rows, MAX_ROWS) // 196 / 18
    testing.expect_value(t, cols, COLS) // 296 / 10

    _, _, none, _ := app.config_geom(app.Rect{}, 1, 16, 10)
    testing.expect_value(t, none, 0)

    testing.expect_value(t, app.config_val_off(), f32(VAL_OFF))
}

// Every later assertion rests on this shape, and `item` is the field that makes a click
// possible.
@(test)
test_config_rows_flatten :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    // Three chrome rows per section, Slopd's row, one per setting, the search row, one per
    // language.
    testing.expect_value(t, len(rows), sc + 10 + INSTALL_ROWS + BINDS_ROWS)

    // Chrome selects nothing: a rule or a title is dead space, as grep's spacers are.
    testing.expect_value(t, rows[0].kind, app.Config_Row_Kind.Rule)
    testing.expect_value(t, rows[0].item, -1)
    testing.expect_value(t, len(rows[0].text), COLS - 1) // the rule spans the pane
    testing.expect_value(t, rows[1].kind, app.Config_Row_Kind.Header)
    testing.expect_value(t, rows[1].text, "slopd")
    testing.expect_value(t, rows[1].item, -1)

    // Slopd's own row opens the pane, above the settings it says where to write.
    testing.expect_value(t, rows[3].kind, app.Config_Row_Kind.Install)
    testing.expect_value(t, rows[3].item, app.ROW_INSTALL)
    testing.expect_value(t, rows[3].text, "install:")
    testing.expect(t, rows[3].value != "") // the mode, whichever this machine is in
    testing.expect_value(t, rows[3].opt, -1)

    testing.expect_value(t, rows[INSTALL_ROWS + 1].kind, app.Config_Row_Kind.Header)
    testing.expect_value(t, rows[INSTALL_ROWS + 1].text, "settings")

    // Settings map row -> Setting index and carry their value for the shared column.
    first := INSTALL_ROWS + 3
    testing.expect_value(t, rows[first].kind, app.Config_Row_Kind.Setting)
    testing.expect_value(t, rows[first].item, app.ROW_SETTINGS)
    testing.expect_value(t, rows[first].text, "theme:")
    testing.expect_value(t, rows[first].value, "(default)") // "" reads as the default
    testing.expect_value(t, rows[first].opt, -1)

    // The bindings row closes the settings block; it is the whole of the binds pane's entry.
    binds := INSTALL_ROWS + 3 + sc
    testing.expect_value(t, rows[binds].kind, app.Config_Row_Kind.Binds)
    testing.expect_value(t, rows[binds].item, app.ROW_BINDS)
    testing.expect_value(t, rows[binds].text, "bindings:")
    testing.expect_value(t, rows[binds].value, "change bindings") // no errors on a zero App

    // The search row, then the languages, numbered as config_pane_rows numbers them.
    search := INSTALL_ROWS + 3 + sc + BINDS_ROWS + 3
    testing.expect_value(t, rows[search].kind, app.Config_Row_Kind.Search)
    testing.expect_value(t, rows[search].item, app.ROW_SEARCH)
    testing.expect_value(t, rows[search + 1].kind, app.Config_Row_Kind.Lang)
    testing.expect_value(t, rows[search + 1].item, app.ROW_LANGS)
    testing.expect_value(t, rows[search + 1].text, "✗ a")
    testing.expect(t, !rows[search + 1].present)
    testing.expect_value(t, rows[search + 2].text, "✓ b")
    testing.expect(t, rows[search + 2].present, "an installed grammar is not marked present")
}

// A dropdown like any other, with the mode's options: an installed copy can be replaced or
// removed, anything else installed. `where` is always first, so Enter lands on the harmless
// option.
@(test)
test_install_options :: proc(t: ^testing.T) {
    buf: [len(app.Install_Option)]app.Install_Option

    for m in ([]app.Install_Mode{.Portable, .ReadOnly}) {
        opts := app.install_options(m, false, buf[:])
        testing.expect_value(t, len(opts), 3)
        testing.expect_value(t, opts[0], app.Install_Option.Where)
        testing.expect_value(t, opts[1], app.Install_Option.Install)
    }

    installed := app.install_options(.Installed, false, buf[:])
    testing.expect_value(t, len(installed), 4)
    testing.expect_value(t, installed[0], app.Install_Option.Where)
    testing.expect_value(t, installed[1], app.Install_Option.Reinstall)
    testing.expect_value(t, installed[2], app.Install_Option.Uninstall)

    // The launcher pair is last, and exactly one option: whichever of add / remove the machine
    // does not have. It does not vary with the install mode.
    for m in app.Install_Mode {
        without := app.install_options(m, false, buf[:])
        testing.expect_value(t, without[len(without) - 1], app.Install_Option.DesktopAdd)
        with := app.install_options(m, true, buf[:])
        testing.expect_value(t, len(with), len(without))
        testing.expect_value(t, with[len(with) - 1], app.Install_Option.DesktopRemove)
    }

    for o in app.Install_Option {
        testing.expect(t, app.install_option_label(o) != "")
    }
}

// Asked about paths this machine need not have. The binary's own location decides: being the
// installed copy first, then whether its folder can be written.
@(test)
test_install_classify :: proc(t: ^testing.T) {
    home := "/home/me/.local/bin/slopd"
    testing.expect_value(t, app.install_classify(home, home, false), app.Install_Mode.Installed)
    testing.expect_value(t, app.install_classify(home, home, true), app.Install_Mode.Installed)

    // An unzipped release folder: not the installed copy, and writable.
    testing.expect_value(t, app.install_classify("/home/me/slopd/Slopd", home, true), app.Install_Mode.Portable)

    // Copied into a system bin folder: writes would fail, so nothing is attempted.
    testing.expect_value(t, app.install_classify("/usr/bin/slopd", home, false), app.Install_Mode.ReadOnly)

    // No $HOME: there is no installed path to be, so only writability answers.
    testing.expect_value(t, app.install_classify("/opt/slopd/Slopd", "", true), app.Install_Mode.Portable)
    testing.expect_value(t, app.install_classify("/opt/slopd/Slopd", "", false), app.Install_Mode.ReadOnly)

    for m in app.Install_Mode {
        testing.expect(t, app.install_mode_label(m) != "")
    }
}

// An open dropdown splices its options into the row list rather than floating over it, which is
// what makes it not an occlusion case.
@(test)
test_config_rows_dropdown_splices :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    ln := int(app.Setting.LineNumbers)
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers) // 2 options: global / relative

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect_value(t, len(rows), sc + 12 + INSTALL_ROWS + BINDS_ROWS) // two rows longer

    // Directly under the row that owns them, carrying its item plus their own index: the second
    // coordinate a click needs.
    own := INSTALL_ROWS + 3 + ln
    testing.expect_value(t, rows[own].item, app.ROW_SETTINGS + ln)
    testing.expect_value(t, rows[own + 1].kind, app.Config_Row_Kind.Option)
    testing.expect_value(t, rows[own + 1].item, app.ROW_SETTINGS + ln)
    testing.expect_value(t, rows[own + 1].opt, 0)
    testing.expect_value(t, rows[own + 1].text, "global")
    testing.expect_value(t, rows[own + 2].opt, 1)
    testing.expect_value(t, rows[own + 2].text, "relative")
    // The row after the dropdown is the next setting, pushed down by two.
    testing.expect_value(t, rows[own + 3].item, app.ROW_SETTINGS + ln + 1)

    // The install row splices the same way, above the settings block.
    cp.open = .None
    cp.sel = app.ROW_INSTALL
    app.config_pane_open_install(&a)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect_value(t, rows[3].kind, app.Config_Row_Kind.Install)
    testing.expect_value(t, rows[4].kind, app.Config_Row_Kind.Option)
    testing.expect_value(t, rows[4].item, app.ROW_INSTALL)
    testing.expect_value(t, rows[4].opt, 0)
    testing.expect_value(t, rows[4].text, app.install_option_label(.Where))
}

// The highlight moves INTO an open dropdown and the scroll anchor follows, which is what stops
// one opening off the bottom of the pane with its chosen option invisible.
@(test)
test_config_selected_and_anchor :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    // Closed: the selected setting row carries the highlight and anchors the scroll.
    cp.sel = app.ROW_SETTINGS
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    first := INSTALL_ROWS + 3
    testing.expect(t, app.config_row_selected(cp, rows[first]), "the selected setting row is not lit")
    testing.expect_value(t, app.pane_anchor(app.config_draw_rows(&a, rows, context.temp_allocator)), first)

    // Open: the setting row goes dark and the chosen option lights.
    ln := int(app.Setting.LineNumbers)
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers)
    cp.opt_sel = 1
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    own := INSTALL_ROWS + 3 + ln
    testing.expect(t, !app.config_row_selected(cp, rows[own]), "an open setting row kept the highlight")
    testing.expect(t, app.config_row_selected(cp, rows[own + 2]), "the chosen option is not lit")
    testing.expect_value(t, app.pane_anchor(app.config_draw_rows(&a, rows, context.temp_allocator)), own + 2)

    // The install row behaves as a setting row does.
    cp.open = .None
    cp.sel = app.ROW_INSTALL
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect(t, app.config_row_selected(cp, rows[3]), "the install row is not lit")
    app.config_pane_open_install(&a)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect(t, !app.config_row_selected(cp, rows[3]), "an open install row kept the highlight")
    testing.expect(t, app.config_row_selected(cp, rows[4]), "the chosen install option is not lit")

    // A language dropdown keeps the highlight on its ROOT until opt_sel leaves it, which is
    // what makes Up out of the list work.
    cp.open = .None
    sc := app.SETTING_COUNT
    cp.sel = app.ROW_LANGS // the first language
    app.config_pane_open_lang(&a)
    testing.expect_value(t, cp.opt_sel, -1)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    root := INSTALL_ROWS + 3 + sc + BINDS_ROWS + 3 + 1
    testing.expect(t, app.config_row_selected(cp, rows[root]), "an open language root lost the highlight")
    testing.expect_value(t, app.pane_anchor(app.config_draw_rows(&a, rows, context.temp_allocator)), root)
}

// The declared tree resolves to the columns the hand-drawn pane used: a one-cell margin, each
// row indented by its depth, every value on one column. Text is asserted in emission order,
// which is row order, so a value and an identically-named option cannot be confused.
@(test)
test_config_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    ln := int(app.Setting.LineNumbers)
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers)
    cp.opt_sel = 1 // "relative"
    cp.scroll = INSTALL_ROWS // frame the settings block

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    cmds := app.config_layout(&a, &f, PANE, rows, 500, 300)

    Seen :: struct {
        text: string,
        x:    i32,
    }
    texts := make([dynamic]Seen, 0, 32, context.temp_allocator)
    rects := 0
    scissor, band: app.Rect
    customs := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .ScissorStart:
            scissor = r
        case .Rectangle:
            rects += 1
            band = r
        case .Custom:
            customs += 1
        case .Text:
            d := c.renderData.text
            append(&texts, Seen{string(d.stringContents.chars[:d.stringContents.length]), r.x})
        }
    }

    // The clip group is the whole content area: no header outside it.
    testing.expect_value(t, scissor, AREA)

    // Exactly one band, on the chosen OPTION at display row 5, not on the open setting row.
    testing.expect_value(t, rects, 1)
    testing.expect_value(t, band, app.Rect{AREA.x, AREA.y + 6 * ROW_H, AREA.w, ROW_H})

    // Ten rows fit and the search row is far below, so nothing is Custom here.
    testing.expect_value(t, customs, 0)

    // Row order, with each string's column. The two "global"s are the point: one the
    // line_numbers VALUE at the shared column, the other its first OPTION, indented.
    testing.expect_value(t, len(texts), 15)
    testing.expect_value(t, texts[1].text, "settings")
    testing.expect_value(t, texts[1].x, i32(X_FLUSH))
    testing.expect_value(t, texts[3].text, "theme:")
    testing.expect_value(t, texts[3].x, i32(X_ROW))
    testing.expect_value(t, texts[4].text, "(default)")
    testing.expect_value(t, texts[4].x, i32(X_VALUE))
    testing.expect_value(t, texts[5].text, "line_numbers:")
    testing.expect_value(t, texts[5].x, i32(X_ROW)) // the longest key starts at the margin
    testing.expect_value(t, texts[6].text, "global")
    testing.expect_value(t, texts[6].x, i32(X_VALUE)) // …and its value shares the column
    testing.expect_value(t, texts[7].text, "global")
    testing.expect_value(t, texts[7].x, i32(X_OPT)) // the option, nested under it
    testing.expect_value(t, texts[8].text, "relative")
    testing.expect_value(t, texts[8].x, i32(X_OPT))
    testing.expect_value(t, texts[9].text, "scroll_mode:") // the row after the dropdown
    testing.expect_value(t, texts[9].x, i32(X_ROW))
}

// A Custom, because a caret is an over-quad and Clay's rectangles are under-quads. It occupies
// the value column and the rest of the row.
@(test)
test_config_search_is_custom :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    // Scroll the syntax section into view: the search row is the fourth visible.
    cp.scroll = INSTALL_ROWS + 3 + sc + BINDS_ROWS
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    cmds := app.config_layout(&a, &f, PANE, rows, 500, 300)

    customs := 0
    box: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Custom {
            customs += 1
            box = app.clay_rect(c.boundingBox)
        }
    }
    testing.expect_value(t, customs, 1)
    // From the shared value column to the pane's right edge, one row tall.
    testing.expect_value(
        t,
        box,
        app.Rect{X_VALUE, AREA.y + 3 * ROW_H, AREA.x + AREA.w - X_VALUE, ROW_H},
    )
}

// An editor only while HIGHLIGHTED: selected it declares the search box's Custom, unselected it
// is the stored value as text. Decided at declaration time rather than in the flattening,
// because a click moves the selection mid-frame.
@(test)
test_config_text_setting_is_custom_when_selected :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    a.git_tool = "lazygit"

    // Frame the git_tool row with the selection elsewhere. The search row is far below the
    // fold, so any Custom seen here is this row's.
    cp.scroll = INSTALL_ROWS + 5
    cp.sel = app.ROW_SETTINGS
    customs, x := text_field_probe(&a, &f, "lazygit")
    testing.expect_value(t, customs, 0)
    testing.expect_value(t, x, i32(X_VALUE)) // the stored value, at the shared column

    // Selected, the same row becomes the live field: one Custom, and the value is no longer
    // drawn as text.
    cp.sel = app.ROW_SETTINGS + int(app.Setting.GitTool)
    app.config_edit_sync(&a)
    customs, x = text_field_probe(&a, &f, "lazygit")
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, x, i32(-1)) // not drawn as text anywhere
}

// Lays the pane out and reports how many Customs it declared plus the x of `want` if it was
// drawn as text (-1 when it wasn't) — the two halves of "is this row a field or a label".
@(private = "file")
text_field_probe :: proc(a: ^app.App, f: ^app.Font, want: string) -> (customs: int, x: i32) {
    x = -1
    rows := app.config_rows(&a.config_pane, a, COLS, context.temp_allocator)
    cmds := app.config_layout(a, f, PANE, rows, 500, 300)
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
        case .Text:
            d := c.renderData.text
            if string(d.stringContents.chars[:d.stringContents.length]) == want {
                x = app.clay_rect(c.boundingBox).x
            }
        }
    }
    return
}

// Off, the pointer changes nothing; on, the row under it takes a band that is not the
// selection's.
@(test)
test_config_hover_is_toggleable :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    cp.sel = app.ROW_INSTALL
    cp.hover = INSTALL_ROWS + 5 // a settings row, below the selected one

    count_rects :: proc(cmds: ^clay.ClayArray(clay.RenderCommand)) -> int {
        n := 0
        for i in 0 ..< cmds.length {
            if clay.RenderCommandArray_Get(cmds, i).commandType == .Rectangle {
                n += 1
            }
        }
        return n
    }

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)

    a.hover_on = false
    off := app.config_layout(&a, &f, PANE, rows, 500, 300)
    testing.expect_value(t, count_rects(&off), 1) // the selection, and nothing else

    a.hover_on = true
    on := app.config_layout(&a, &f, PANE, rows, 500, 300)
    testing.expect_value(t, count_rects(&on), 2)

    // Chrome never hovers: there is nothing there to click.
    cp.hover = 1 // the "slopd" title
    only_sel := app.config_layout(&a, &f, PANE, rows, 500, 300)
    testing.expect_value(t, count_rects(&only_sel), 1)

    // The tint is a hint, not a second selection: strictly between the pane background and
    // the selection bar.
    th := &a.theme
    testing.expect(t, app.hover_bg(th) != th.bg && app.hover_bg(th) != th.separator)
}

// To a DISPLAY row, with the list SCROLLED: the case that separates a real row index from a
// visible-row index, which agree only at the top.
@(test)
test_config_hit_with_scroll :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    cp.scroll = INSTALL_ROWS + 1 // the "settings" title, a rule, then the settings rows
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    _ = app.config_layout(&a, &f, PANE, rows, 500, 300) // frame 1: boxes to hit

    hit_at :: proc(a: ^app.App, f: ^app.Font, rows: []app.ConfigRow, visible_row: int) -> int {
        clay.SetPointerState({f32(AREA.x + 30), f32(AREA.y + i32(visible_row) * ROW_H + 4)}, false)
        _ = app.config_layout(a, f, PANE, rows, 500, 300)
        ui := app.config_draw_rows(a, rows, context.temp_allocator)
        return app.pane_hit(app.CONFIG_IDS, ui, a.config_pane.scroll, MAX_ROWS)
    }

    // The third visible row is the first setting: a display row, not a visible-row index.
    testing.expect_value(t, hit_at(&a, &f, rows, 2), INSTALL_ROWS + 3)
    testing.expect_value(t, hit_at(&a, &f, rows, 3), INSTALL_ROWS + 4)

    // The section title and the rule under it are chrome.
    testing.expect_value(t, hit_at(&a, &f, rows, 0), -1)
    testing.expect_value(t, hit_at(&a, &f, rows, 1), -1)

    // Below the last declared row, and off the pane entirely.
    clay.SetPointerState({f32(AREA.x + 30), f32(AREA.y + AREA.h + 20)}, false)
    _ = app.config_layout(&a, &f, PANE, rows, 500, 300)
    ui := app.config_draw_rows(&a, rows, context.temp_allocator)
    testing.expect_value(t, app.pane_hit(app.CONFIG_IDS, ui, cp.scroll, MAX_ROWS), -1)
}

// Single click selects a row, double click opens its dropdown, and a press that hit nothing is
// left for whoever else is drawing.
@(test)
test_config_click_selects_and_opens :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    a.mouse_on = true
    sc := app.SETTING_COUNT

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)

    lang2 := INSTALL_ROWS + 3 + sc + BINDS_ROWS + 3 + 2 // the second language

    // A single click on a language row selects it and claims the press.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, lang2)
    testing.expect_value(t, cp.sel, app.ROW_LANGS + 1)
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect(t, !a.mouse.click, "a click that hit a row must be claimed")

    // A double click is Right/Enter: it opens that row's dropdown.
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, lang2)
    testing.expect_value(t, cp.open, app.Open_Kind.Lang)
    testing.expect_value(t, cp.opt_sel, -1) // the highlight stays on the root

    // A press on chrome hits nothing and must not be claimed: the one-noun rule.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, 1) // the "slopd" title
    testing.expect(t, a.mouse.click, "a click on chrome must not be claimed")
    testing.expect_value(t, cp.open, app.Open_Kind.Lang) // and changes nothing

    // Clicking a different row closes the open dropdown — the one thing the keyboard cannot
    // express, since Up/Down are captured while one is open.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, INSTALL_ROWS + 3) // the first setting row
    testing.expect_value(t, cp.sel, app.ROW_SETTINGS)
    testing.expect_value(t, cp.open, app.Open_Kind.None)

    // Slopd's own row opens on a double click too, and a second minimises it.
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, 3)
    testing.expect_value(t, cp.sel, app.ROW_INSTALL)
    testing.expect_value(t, cp.open, app.Open_Kind.Install)
    testing.expect_value(t, cp.opt_sel, 0) // `where`, the option that only reports
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, 3)
    testing.expect_value(t, cp.open, app.Open_Kind.None)

    // With the mouse off, nothing is claimed and nothing moves.
    cp.sel = app.ROW_SETTINGS
    a.mouse_on = false
    a.mouse.click = true
    app.config_click(&a, rows, INSTALL_ROWS + 3 + sc + 3 + 1)
    testing.expect_value(t, cp.sel, app.ROW_SETTINGS)
}

// A click on an option chooses it: a departure from single-selects / double-activates, since an
// option list is already the second half of a gesture. The commit is real, so the config write
// is pointed at a scratch file.
@(test)
test_config_click_chooses_option :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_ui_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("# scratch\n")) == nil)
    defer os.remove(path)
    config_override(path)
    defer config_override_release()

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    a.mouse_on = true

    ln := int(app.Setting.LineNumbers)
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers)
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    opt1 := INSTALL_ROWS + 3 + ln + 2 // the "relative" option

    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, opt1)
    testing.expect_value(t, a.line_numbers, app.Line_Numbers.Relative) // committed
    testing.expect_value(t, cp.open, app.Open_Kind.None) // and closed behind it
    testing.expect(t, !a.mouse.click, "a click on an option must be claimed")

    // The second press of a double click is swallowed: without it, it would land on whatever
    // row slid up into that spot and open ITS dropdown.
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    before := cp.opt_sel
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, INSTALL_ROWS + 3 + ln + 1) // the "global" option
    testing.expect_value(t, cp.open, app.Open_Kind.Setting) // still open, nothing chosen
    testing.expect_value(t, cp.opt_sel, before)
    testing.expect(t, !a.mouse.click, "the swallowed press is still consumed")
}

// One proc drives Up/Down and the wheel, so a notch over this pane means what the arrows do.
@(test)
test_config_dropdown_move :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    // Nothing open: it moves the row selection, clamped.
    cp.sel = app.ROW_INSTALL
    app.config_dropdown_move(&a, 3)
    testing.expect_value(t, cp.sel, 3)
    app.config_dropdown_move(&a, -99)
    testing.expect_value(t, cp.sel, app.ROW_INSTALL)

    // A settings dropdown clamps at both ends: its options are a closed choice, and you leave
    // with Left or Enter rather than by walking off.
    ln := int(app.Setting.LineNumbers)
    cp.sel = app.ROW_SETTINGS + ln
    app.config_pane_open_setting(&a, .LineNumbers) // 2 options
    app.config_dropdown_move(&a, 5)
    testing.expect_value(t, cp.open, app.Open_Kind.Setting)
    testing.expect_value(t, cp.opt_sel, 1)
    app.config_dropdown_move(&a, -5)
    testing.expect_value(t, cp.opt_sel, 0)
    testing.expect_value(t, cp.sel, app.ROW_SETTINGS + ln) // and the row never moved

    // The install dropdown clamps the same way: a section rule above and one below, so there
    // is nothing to step out onto.
    cp.open = .None
    cp.sel = app.ROW_INSTALL
    app.config_pane_open_install(&a)
    app.config_dropdown_move(&a, 9)
    testing.expect_value(t, cp.open, app.Open_Kind.Install)
    testing.expect_value(t, cp.sel, app.ROW_INSTALL)
    app.config_dropdown_move(&a, -9)
    testing.expect_value(t, cp.opt_sel, 0)
    testing.expect_value(t, cp.open, app.Open_Kind.Install)

    // A language dropdown steps out instead, because its options are just more rows.
    cp.open = .None
    cp.sel = app.ROW_LANGS + 1 // language "b", present, so 3 options
    app.config_pane_open_lang(&a)
    app.config_dropdown_move(&a, 3) // root -> 0 -> 1 -> 2
    testing.expect_value(t, cp.opt_sel, 2)
    testing.expect_value(t, cp.open, app.Open_Kind.Lang)
    app.config_dropdown_move(&a, 1) // off the end
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect_value(t, cp.sel, app.ROW_LANGS + 2)

    cp.sel = app.ROW_LANGS + 1
    app.config_pane_open_lang(&a)
    testing.expect_value(t, cp.opt_sel, -1)
    app.config_dropdown_move(&a, -1) // up off the root
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect_value(t, cp.sel, app.ROW_LANGS)
}
