package tests

import app ".."
import clay "../../bindings/clay"
import "core:os"
import "core:testing"

// C5b: the config / syntax pane declared in Clay. The filetree proved a flat list of
// one-row items and grep proved one item spanning several rows; this pane adds the two
// things neither had — rows that select NOTHING (section rules and titles) and rows that
// carry a second coordinate (a choice inside an open dropdown) — so those are what the
// assertions here are about, plus the Custom the live search field needs.
//
// The pane used throughout is {100, 50, 300, 200} at scale 1 with the synthetic 10x16
// font: a content area of {102, 52, 296, 196}, an 18px row (16px line + 2px
// CONFIG_ROW_PAD), 10 rows fitting in it, and 29 whole cells across.

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

// The shared value column, in cells: the widest setting key ("indent_guides" /
// "disk_conflict", 13) plus ": ". Derived by hand and pinned, because every column
// assertion below multiplies it out — if a longer key is ever added, exactly this
// assertion fails rather than a dozen mysterious pixel ones.
@(private = "file")
VAL_OFF :: 15

// Three settings-independent columns, in framebuffer pixels: chrome sits at the one-cell
// margin, an indent-1 row one cell further in, an indent-4 option row three past that.
@(private = "file")
X_FLUSH :: AREA.x + 10
@(private = "file")
X_ROW :: AREA.x + 20
@(private = "file")
X_VALUE :: X_ROW + VAL_OFF * 10
@(private = "file")
X_OPT :: AREA.x + 50

// A pane with three synthetic languages, so the row maths does not depend on the generated
// `languages` registry being present on the machine running the tests.
@(private = "file")
fixture :: proc(a: ^app.App) {
    app.config_pane_init(&a.config_pane, nil)
    a.scale = 1
    a.theme = app.default_theme() // a zero App's palette is all black, which hides colour bugs
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
    // No row is reserved for a header here — the pane's first row is already a section
    // rule — which is the one geometry difference from the filetree and grep.
    testing.expect_value(t, rows, MAX_ROWS) // 196 / 18
    testing.expect_value(t, cols, COLS) // 296 / 10

    _, _, none, _ := app.config_geom(app.Rect{}, 1, 16, 10)
    testing.expect_value(t, none, 0)

    testing.expect_value(t, app.config_val_off(), f32(VAL_OFF))
}

// The flattening that used to be a local `Row` struct inside draw_config. Every later
// assertion rests on this shape, and `item` is the field that makes a click possible.
@(test)
test_config_rows_flatten :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    // 3 chrome rows per section, one row per setting, the search row, one row per language.
    testing.expect_value(t, len(rows), sc + 10)

    // Chrome selects nothing: a press on a rule or a section title is dead space, the way
    // grep's spacers are.
    testing.expect_value(t, rows[0].kind, app.Config_Row_Kind.Rule)
    testing.expect_value(t, rows[0].item, -1)
    testing.expect_value(t, len(rows[0].text), COLS - 1) // the rule spans the pane
    testing.expect_value(t, rows[1].kind, app.Config_Row_Kind.Header)
    testing.expect_value(t, rows[1].text, "settings")
    testing.expect_value(t, rows[1].item, -1)

    // Settings map row -> Setting index, and carry their value for the shared column.
    testing.expect_value(t, rows[3].kind, app.Config_Row_Kind.Setting)
    testing.expect_value(t, rows[3].item, 0)
    testing.expect_value(t, rows[3].text, "theme:")
    testing.expect_value(t, rows[3].value, "(default)") // "" reads as the default
    testing.expect_value(t, rows[3].opt, -1)

    // The search row, then the languages, numbered as config_pane_rows numbers them.
    search := 3 + sc + 3
    testing.expect_value(t, rows[search].kind, app.Config_Row_Kind.Search)
    testing.expect_value(t, rows[search].item, sc)
    testing.expect_value(t, rows[search + 1].kind, app.Config_Row_Kind.Lang)
    testing.expect_value(t, rows[search + 1].item, sc + 1)
    testing.expect_value(t, rows[search + 1].text, "✗ a")
    testing.expect(t, !rows[search + 1].present)
    testing.expect_value(t, rows[search + 2].text, "✓ b")
    testing.expect(t, rows[search + 2].present, "an installed grammar is not marked present")
}

// An open dropdown SPLICES its options into the row list rather than floating over it —
// which is what makes this pane's dropdown not an occlusion case at all (see config_ui.odin).
@(test)
test_config_rows_dropdown_splices :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    ln := int(app.Setting.LineNumbers)
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers) // 2 options: global / relative

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect_value(t, len(rows), sc + 12) // two rows longer than the closed pane

    // The options sit directly under the row that owns them, carrying its item plus their
    // own index — the second coordinate a click needs.
    own := 3 + ln
    testing.expect_value(t, rows[own].item, ln)
    testing.expect_value(t, rows[own + 1].kind, app.Config_Row_Kind.Option)
    testing.expect_value(t, rows[own + 1].item, ln)
    testing.expect_value(t, rows[own + 1].opt, 0)
    testing.expect_value(t, rows[own + 1].text, "global")
    testing.expect_value(t, rows[own + 2].opt, 1)
    testing.expect_value(t, rows[own + 2].text, "relative")
    // The row AFTER the dropdown is the next setting, pushed down by two.
    testing.expect_value(t, rows[own + 3].item, ln + 1)
}

// The highlight moves INTO an open dropdown, and the scroll anchor follows it there. This
// is the rule that stops a dropdown opening off the bottom of the pane with its chosen
// option invisible.
@(test)
test_config_selected_and_anchor :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane

    // Closed: the selected setting row carries the highlight, and anchors the scroll.
    cp.sel = 0
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    testing.expect(t, app.config_row_selected(cp, rows[3]), "the selected setting row is not lit")
    testing.expect_value(t, app.config_anchor(cp, rows), 3)

    // Open: the setting row goes dark and the chosen OPTION lights instead.
    ln := int(app.Setting.LineNumbers)
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers)
    cp.opt_sel = 1
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    own := 3 + ln
    testing.expect(t, !app.config_row_selected(cp, rows[own]), "an open setting row kept the highlight")
    testing.expect(t, app.config_row_selected(cp, rows[own + 2]), "the chosen option is not lit")
    testing.expect_value(t, app.config_anchor(cp, rows), own + 2)

    // A language dropdown keeps the highlight on its ROOT until opt_sel leaves it (-1 is
    // the root; 0.. are the options), which is what makes Up out of the list work.
    cp.open = .None
    sc := app.SETTING_COUNT
    cp.sel = sc + 1 // the first language
    app.config_pane_open_lang(&a)
    testing.expect_value(t, cp.opt_sel, -1)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    root := 3 + sc + 3 + 1
    testing.expect(t, app.config_row_selected(cp, rows[root]), "an open language root lost the highlight")
    testing.expect_value(t, app.config_anchor(cp, rows), root)
}

// The end-to-end claim: the declared tree resolves to the columns the hand-drawn pane used
// — a one-cell margin, each row indented by its own depth, and every value on one column
// regardless of key length. Text is asserted in EMISSION order, which is row order, so a
// value and an identically-named option cannot be confused for each other.
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
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers)
    cp.opt_sel = 1 // "relative"

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

    // The clip group is the whole content area: this pane has no header outside it.
    testing.expect_value(t, scissor, AREA)

    // Exactly one band, on the chosen OPTION (display row 5 — three chrome rows, the theme
    // row, the line_numbers row, then its first option) — not on the open setting row.
    testing.expect_value(t, rects, 1)
    testing.expect_value(t, band, app.Rect{AREA.x, AREA.y + 6 * ROW_H, AREA.w, ROW_H})

    // Ten rows fit, and the search row is far below them, so nothing is Custom here.
    testing.expect_value(t, customs, 0)

    // Row order, with each string's column. The two "global"s are the point: one is the
    // line_numbers VALUE at the shared column, the other its first OPTION, indented.
    testing.expect_value(t, len(texts), 15)
    testing.expect_value(t, texts[1].text, "settings")
    testing.expect_value(t, texts[1].x, i32(X_FLUSH))
    testing.expect_value(t, texts[3].text, "theme:")
    testing.expect_value(t, texts[3].x, i32(X_ROW))
    testing.expect_value(t, texts[4].text, "(default)")
    testing.expect_value(t, texts[4].x, i32(X_VALUE))
    testing.expect_value(t, texts[5].text, "line_numbers:")
    testing.expect_value(t, texts[5].x, i32(X_ROW)) // the longest key still starts at the margin
    testing.expect_value(t, texts[6].text, "global")
    testing.expect_value(t, texts[6].x, i32(X_VALUE)) // ...and its value shares the column
    testing.expect_value(t, texts[7].text, "global")
    testing.expect_value(t, texts[7].x, i32(X_OPT)) // the option, nested under it
    testing.expect_value(t, texts[8].text, "relative")
    testing.expect_value(t, texts[8].x, i32(X_OPT))
    testing.expect_value(t, texts[9].text, "scroll_mode:") // the row after the dropdown
    testing.expect_value(t, texts[9].x, i32(X_ROW))
}

// The live language filter is a Custom, because a caret is an over-quad and Clay's
// rectangles are under-quads (see config_ui.odin's header). It occupies the value column
// and the rest of the row.
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

    // Scroll the syntax section into view: the search row is the fourth visible row.
    cp.scroll = 3 + sc
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
    // Starts at the shared value column, runs to the pane's right edge, one row tall.
    testing.expect_value(
        t,
        box,
        app.Rect{X_VALUE, AREA.y + 3 * ROW_H, AREA.x + AREA.w - X_VALUE, ROW_H},
    )
}

// Hover is a config toggle (open decision 5, settled here): off, the pointer changes
// nothing; on, the row under it takes a band that is NOT the selection's.
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
    cp.sel = 0
    cp.hover = 5 // a settings row, two below the selected one

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
    cp.hover = 1 // the "settings" title
    only_sel := app.config_layout(&a, &f, PANE, rows, 500, 300)
    testing.expect_value(t, count_rects(&only_sel), 1)

    // And the tint is a hint, not a second selection — strictly between the pane
    // background and the selection bar.
    th := &a.theme
    testing.expect(t, app.hover_bg(th) != th.bg && app.hover_bg(th) != th.separator)
}

// A hit resolves to a DISPLAY row, WITH THE LIST SCROLLED — the case that separates a real
// row index from a visible-row index, which agree only at the top.
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

    cp.scroll = 1 // visible: the "settings" title, a rule, then the settings rows
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    _ = app.config_layout(&a, &f, PANE, rows, 500, 300) // frame 1: gives Clay boxes to hit

    hit_at :: proc(a: ^app.App, f: ^app.Font, rows: []app.ConfigRow, visible_row: int) -> int {
        clay.SetPointerState({f32(AREA.x + 30), f32(AREA.y + i32(visible_row) * ROW_H + 4)}, false)
        _ = app.config_layout(a, f, PANE, rows, 500, 300)
        return app.config_hit(rows, a.config_pane.scroll, MAX_ROWS)
    }

    // The third visible row is display row 3 — the first setting — not row 2.
    testing.expect_value(t, hit_at(&a, &f, rows, 2), 3)
    testing.expect_value(t, hit_at(&a, &f, rows, 3), 4)

    // The section title and the rule under it are chrome: dead space.
    testing.expect_value(t, hit_at(&a, &f, rows, 0), -1)
    testing.expect_value(t, hit_at(&a, &f, rows, 1), -1)

    // Below the last declared row, and off the pane entirely.
    clay.SetPointerState({f32(AREA.x + 30), f32(AREA.y + AREA.h + 20)}, false)
    _ = app.config_layout(&a, &f, PANE, rows, 500, 300)
    testing.expect_value(t, app.config_hit(rows, cp.scroll, MAX_ROWS), -1)
}

// The verb half. Single click selects a row, double click opens its dropdown, and a press
// that hit nothing is left for whoever else is drawing.
@(test)
test_config_click_selects_and_opens :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    a.mouse_on = true
    sc := app.SETTING_COUNT

    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)

    // A single click on a language row selects it, and claims the press.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, 3 + sc + 3 + 2) // the second language
    testing.expect_value(t, cp.sel, sc + 2)
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect(t, !a.mouse.click, "a click that hit a row must be claimed")

    // A double click is Right/Enter: it opens that row's dropdown.
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, 3 + sc + 3 + 2)
    testing.expect_value(t, cp.open, app.Open_Kind.Lang)
    testing.expect_value(t, cp.opt_sel, -1) // the highlight stays on the root

    // A press on chrome hits nothing and must NOT be claimed — the one-noun rule.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, 1) // the "settings" title
    testing.expect(t, a.mouse.click, "a click on chrome must not be claimed")
    testing.expect_value(t, cp.open, app.Open_Kind.Lang) // and changes nothing

    // Clicking a DIFFERENT row closes the open dropdown — the one thing the keyboard
    // cannot express, since its Up/Down are captured while a dropdown is open.
    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, 3) // the first setting row
    testing.expect_value(t, cp.sel, 0)
    testing.expect_value(t, cp.open, app.Open_Kind.None)

    // With the mouse configured off, nothing is claimed and nothing moves.
    a.mouse_on = false
    a.mouse.click = true
    app.config_click(&a, rows, 3 + sc + 3 + 1)
    testing.expect_value(t, cp.sel, 0)
}

// A click on an option CHOOSES it — the deliberate departure from single-selects /
// double-activates, since an option list is already the second half of a gesture. The
// commit is real, so the config write is pointed at a scratch file.
@(test)
test_config_click_chooses_option :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_ui_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("# scratch\n")) == nil)
    defer os.remove(path)
    os.set_env("SLOPD_CONFIG", path)
    defer os.unset_env("SLOPD_CONFIG")

    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    a.mouse_on = true

    ln := int(app.Setting.LineNumbers)
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers)
    rows := app.config_rows(cp, &a, COLS, context.temp_allocator)
    opt1 := 3 + ln + 2 // the "relative" option

    a.mouse.click, a.mouse.click_count = true, 1
    app.config_click(&a, rows, opt1)
    testing.expect_value(t, a.line_numbers, app.Line_Numbers.Relative) // committed
    testing.expect_value(t, cp.open, app.Open_Kind.None) // and closed behind it
    testing.expect(t, !a.mouse.click, "a click on an option must be claimed")

    // The second press of a double click is SWALLOWED. Without this, it would land on
    // whatever row slid up into that spot once the dropdown collapsed and open ITS
    // dropdown — a grammar install one impatient double click away.
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers)
    rows = app.config_rows(cp, &a, COLS, context.temp_allocator)
    before := cp.opt_sel
    a.mouse.click, a.mouse.click_count = true, 2
    app.config_click(&a, rows, 3 + ln + 1) // the "global" option
    testing.expect_value(t, cp.open, app.Open_Kind.Setting) // still open, nothing chosen
    testing.expect_value(t, cp.opt_sel, before)
    testing.expect(t, !a.mouse.click, "the swallowed press is still consumed")
}

// One proc drives Up/Down AND the wheel, so a notch over this pane means what the arrows
// mean. The refusal that used to sit in wheel_apply's .Config branch is gone.
@(test)
test_config_dropdown_move :: proc(t: ^testing.T) {
    a: app.App
    fixture(&a)
    defer app.config_pane_destroy(&a.config_pane)
    cp := &a.config_pane
    sc := app.SETTING_COUNT

    // Nothing open: it moves the row selection, clamped to the list.
    cp.sel = 0
    app.config_dropdown_move(&a, 3)
    testing.expect_value(t, cp.sel, 3)
    app.config_dropdown_move(&a, -99)
    testing.expect_value(t, cp.sel, 0)

    // A settings dropdown CLAMPS at both ends: its options are a closed choice, and you
    // leave it with Left or Enter rather than by walking off it.
    ln := int(app.Setting.LineNumbers)
    cp.sel = ln
    app.config_pane_open_setting(&a, .LineNumbers) // 2 options
    app.config_dropdown_move(&a, 5)
    testing.expect_value(t, cp.open, app.Open_Kind.Setting)
    testing.expect_value(t, cp.opt_sel, 1)
    app.config_dropdown_move(&a, -5)
    testing.expect_value(t, cp.opt_sel, 0)
    testing.expect_value(t, cp.sel, ln) // and the row never moved

    // A language dropdown STEPS OUT instead, because its options are just more rows: down
    // off the last one lands on the next language, up off the root on the previous row.
    cp.open = .None
    cp.sel = sc + 2 // language "b", which is present -> 3 options
    app.config_pane_open_lang(&a)
    app.config_dropdown_move(&a, 3) // root -> 0 -> 1 -> 2
    testing.expect_value(t, cp.opt_sel, 2)
    testing.expect_value(t, cp.open, app.Open_Kind.Lang)
    app.config_dropdown_move(&a, 1) // off the end
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect_value(t, cp.sel, sc + 3)

    cp.sel = sc + 2
    app.config_pane_open_lang(&a)
    testing.expect_value(t, cp.opt_sel, -1)
    app.config_dropdown_move(&a, -1) // up off the root
    testing.expect_value(t, cp.open, app.Open_Kind.None)
    testing.expect_value(t, cp.sel, sc + 1)
}
