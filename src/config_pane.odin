package main

import "core:fmt"
import "core:strings"

// ConfigPane — the Config aux mode's state: navigation across the settings rows and
// the language list, the inline settings editor (a one-line Doc, sharing the buffer
// editing core like the command line does), and each known language's grammar
// status. The settings VALUES live on App (they're editor config); this owns only
// the pane's own navigation state and the language list. Status is read from
// grammars/ at init and re-read on demand (config_pane_refresh).

LangStatus :: struct {
    name:    string, // borrowed from the App registry (passed to init) — not owned
    present: bool,   // grammars/<name>.so exists
}

// The dropdown options for a language. Health is always offered; the install
// state decides between Install and Update/Uninstall.
LangOption :: enum {
    Health,
    Install,
    Update,
    Uninstall,
}

// What kind of row has its dropdown open (if any). Settings pick from a fixed/derived
// choice list; languages pick a grammar action. Both share opt_sel + the dropdown
// navigation; open_idx disambiguates which row (a Setting value, or a langs index).
Open_Kind :: enum {
    None,
    Setting,
    Lang,
}

// There is no edit "mode": the highlighted row owns the keys directly (non-modal).
// Settings are chosen from a dropdown (Right/Enter opens it, like a language row);
// the search row's `search` filters the language list live as you type.
ConfigPane :: struct {
    // Rows: [0, SETTING_COUNT) settings, then the search row, then the FILTERED langs.
    sel:      int, // selected row
    scroll:   int, // first visible DISPLAY row — the viewport top (see list_scroll_target)
    open:     Open_Kind, // which row's dropdown is open (None when none)
    open_idx: int, // Setting(open_idx) when open==.Setting; langs[open_idx] when .Lang
    opt_sel:  int, // selection within an open dropdown: -1 = the language root, 0.. = options
    search:   Doc, // the persistent syntax filter query (live on the search row)
    dir:      string, // grammars directory (owned)
    langs:    [dynamic]LangStatus, // names borrow the App registry (see config_pane_init)
    filtered: [dynamic]int, // indices into langs matching `search` — the displayed langs
    // The DISPLAY row under the pointer, or -1. Transient frame state written by draw_config
    // before it declares (like `scroll`), so the declaration can tint it without hit-testing
    // a second time. -1 whenever the mouse is off or has never moved, because Clay's pointer
    // is parked off-screen then (mouse_feed_clay) and nothing can be over anything.
    hover:    int,
}

SETTING_COUNT :: len(Setting)

// `grammars` is the App-owned registry; the pane borrows each name for its lang list
// (the App outlives the pane), so the pane frees only its own langs array.
config_pane_init :: proc(cp: ^ConfigPane, grammars: []Grammar) {
    doc_init(&cp.search)
    cp.open = .None
    cp.hover = -1 // nothing is hovered until a pointer event says so
    cp.dir = grammars_dir()
    for g in grammars {
        append(&cp.langs, LangStatus{name = g.name, present = grammar_present(cp.dir, g.name)})
    }
    config_pane_filter(cp) // filtered = all languages initially
}

config_pane_destroy :: proc(cp: ^ConfigPane) {
    doc_destroy(&cp.search)
    delete(cp.langs)
    delete(cp.filtered)
    delete(cp.dir)
}

// Re-stat every grammar (entering the pane, or after an install/uninstall).
config_pane_refresh :: proc(cp: ^ConfigPane) {
    for &l in cp.langs {
        l.present = grammar_present(cp.dir, l.name)
    }
}

// Rebuilds the displayed language list from the search query (case-insensitive
// substring on the name; empty query shows all). Closes any open dropdown and keeps
// the selection in range. Call after every change to `search`.
config_pane_filter :: proc(cp: ^ConfigPane) {
    clear(&cp.filtered)
    q := strings.to_lower(strings.trim_space(doc_string(&cp.search, context.temp_allocator)), context.temp_allocator)
    for l, i in cp.langs {
        if q == "" || strings.contains(strings.to_lower(l.name, context.temp_allocator), q) {
            append(&cp.filtered, i)
        }
    }
    cp.open = .None
    cp.sel = clamp(cp.sel, 0, max(0, config_pane_rows(cp) - 1))
}

// Total navigable rows: the settings block, the search row, then one row per filtered
// language.
config_pane_rows :: proc(cp: ^ConfigPane) -> int {
    return SETTING_COUNT + 1 + len(cp.filtered)
}

// The Setting at row r, or (_, false) when r is not a settings row.
config_pane_setting :: proc(r: int) -> (Setting, bool) {
    if r >= 0 && r < SETTING_COUNT {
        return Setting(r), true
    }
    return {}, false
}

// The search row sits between the settings and the (filtered) language list.
config_pane_is_search :: proc(r: int) -> bool {
    return r == SETTING_COUNT
}

// The langs index shown at row r, or (_, false) for non-language rows.
config_pane_lang_index :: proc(cp: ^ConfigPane, r: int) -> (int, bool) {
    i := r - (SETTING_COUNT + 1)
    if i < 0 || i >= len(cp.filtered) {
        return 0, false
    }
    return cp.filtered[i], true
}

// The language at row r, or nil when r is not a language row.
config_pane_lang :: proc(cp: ^ConfigPane, r: int) -> ^LangStatus {
    if i, ok := config_pane_lang_index(cp, r); ok {
        return &cp.langs[i]
    }
    return nil
}

// Pure selection clamp — the caller (config_nav) brackets it with commit/seed.
config_pane_move :: proc(cp: ^ConfigPane, delta: int) {
    cp.sel = clamp(cp.sel + delta, 0, max(0, config_pane_rows(cp) - 1))
}

// Opens the dropdown for the highlighted setting row, pre-selecting its current
// value so the active choice is highlighted. No-op off a setting row.
config_pane_open_setting :: proc(a: ^App, s: Setting) {
    cp := &a.config_pane
    cp.open = .Setting
    cp.open_idx = int(s)
    cp.opt_sel = 0
    cur := setting_value(a, s)
    for o, i in setting_options(a, s) {
        if o == cur {
            cp.opt_sel = i
        }
    }
}

// The options for a language, written into buf, in display order. The count varies
// with install state, so callers pass a [len(LangOption)]LangOption and use the
// returned slice.
lang_options :: proc(present: bool, buf: []LangOption) -> []LangOption {
    n := 0
    buf[n] = .Health;n += 1
    if present {
        buf[n] = .Update;n += 1
        buf[n] = .Uninstall;n += 1
    } else {
        buf[n] = .Install;n += 1
    }
    return buf[:n]
}

lang_option_label :: proc(o: LangOption) -> string {
    switch o {
    case .Health:    return "check health"
    case .Install:   return "install"
    case .Update:    return "update"
    case .Uninstall: return "uninstall"
    }
    return ""
}

// --- the display flattening (C5b) ---
// The pane is a flat list of DISPLAY rows over a smaller list of NAVIGABLE rows: section
// rules and titles are display-only, and an open dropdown splices its options in under the
// row that owns them. So this is grep's row -> item indirection again, with two items per
// row instead of one — `item` names the navigable row a click selects, `opt` the choice
// within it. This used to be a local `Row` struct inside draw_config, which is why nothing
// could hit-test it and why the scroll anchor had to be computed by the painter.

Config_Row_Kind :: enum {
    Rule, // a full-width horizontal rule
    Header, // a section title ("settings", "syntax")
    Setting, // a settings row: key + value column
    Search, // the language filter box — the one row that edits text in place
    Lang, // a language row: status mark + name
    Option, // a choice spliced in under an open dropdown
}

// One display row. Carries NO selection state and no colour, for the reason C5a wrote down:
// a click changes the selection mid-frame, so a row list that encoded it would have to be
// rebuilt immediately after being built, and the hit test, the click and the declaration
// could no longer share one flattening. Both are derived at declaration time instead —
// selectedness from config_row_selected, colour from `kind` + `present`.
ConfigRow :: struct {
    kind:    Config_Row_Kind,
    text:    string,
    value:   string, // the setting's value, drawn at the shared value column; "" otherwise
    item:    int, // the navigable row this selects, or -1 for chrome (rules, titles)
    opt:     int, // the choice index within an open dropdown; -1 on every other row
    indent:  i32, // extra left margin, in cells
    present: bool, // Lang rows only: the grammar is installed (drives the mark and the tint)
}

// Flatten the pane into display rows. `cols` is the content width in whole cells, which is
// all the rules need to span it. Every string is allocated (or borrowed as a literal) out of
// `alloc`, so one temp arena owns the whole frame's rows — the same discipline as grep_rows.
config_rows :: proc(cp: ^ConfigPane, a: ^App, cols: int, alloc := context.allocator) -> []ConfigRow {
    rows := make([dynamic]ConfigRow, 0, 48, alloc)
    rule := strings.repeat("-", max(1, cols - 1), alloc)
    chrome :: proc(kind: Config_Row_Kind, text: string) -> ConfigRow {
        return ConfigRow{kind = kind, text = text, item = -1, opt = -1}
    }

    append(&rows, chrome(.Rule, rule), chrome(.Header, "settings"), chrome(.Rule, rule))
    for si in 0 ..< SETTING_COUNT {
        s := Setting(si)
        val := setting_value(a, s)
        append(
            &rows,
            ConfigRow {
                kind = .Setting,
                text = fmt.aprintf("%s:", setting_key(s), allocator = alloc),
                value = val == "" ? "(default)" : strings.clone(val, alloc),
                item = si,
                opt = -1,
                indent = 1,
            },
        )
        if cp.open == .Setting && cp.open_idx == si {
            for o, oi in setting_options(a, s) {
                append(&rows, config_option_row(si, oi, strings.clone(o, alloc)))
            }
        }
    }

    append(&rows, chrome(.Rule, rule), chrome(.Header, "syntax"), chrome(.Rule, rule))
    append(
        &rows,
        ConfigRow {
            kind = .Search,
            text = "search:",
            value = doc_string(&cp.search, alloc),
            item = SETTING_COUNT,
            opt = -1,
            indent = 1,
        },
    )

    for fi, idx in cp.filtered {
        l := &cp.langs[fi]
        nav := SETTING_COUNT + 1 + idx
        append(
            &rows,
            ConfigRow {
                kind = .Lang,
                text = fmt.aprintf("%s %s", l.present ? "✓" : "✗", l.name, allocator = alloc),
                item = nav,
                opt = -1,
                indent = 1,
                present = l.present,
            },
        )
        // open_idx is a LANGS index here, not a display or navigable row: it has to survive
        // the filter list being rebuilt under it (config_pane_filter).
        if cp.open == .Lang && cp.open_idx == fi {
            buf: [len(LangOption)]LangOption
            for o, oi in lang_options(l.present, buf[:]) {
                append(&rows, config_option_row(nav, oi, lang_option_label(o)))
            }
        }
    }
    return rows[:]
}

// A dropdown choice, indented past the row that owns it so the options read as nested.
@(private = "file")
config_option_row :: proc(item, opt: int, text: string) -> ConfigRow {
    return ConfigRow{kind = .Option, text = text, item = item, opt = opt, indent = 4}
}

// Whether `r` carries the selection highlight. Exactly one row in the list does, and which
// one moves INTO an open dropdown: while a setting is open the highlight is on the chosen
// option rather than the setting row, and while a language is open it is on the language
// root until opt_sel leaves it (-1 is the root; 0.. are the options).
config_row_selected :: proc(cp: ^ConfigPane, r: ConfigRow) -> bool {
    if r.item < 0 || cp.sel != r.item {
        return false
    }
    switch r.kind {
    case .Rule, .Header:
        return false
    case .Search:
        return true
    case .Setting:
        return cp.open != .Setting || cp.open_idx != r.item
    case .Lang:
        return cp.open != .Lang || cp.opt_sel == -1
    case .Option:
        return cp.opt_sel == r.opt
    }
    return false
}

// The display row the scroll policy frames — the selected one. An open dropdown splices
// rows in above and below, so this is a search rather than arithmetic over the nav index.
config_anchor :: proc(cp: ^ConfigPane, rows: []ConfigRow) -> int {
    for r, i in rows {
        if config_row_selected(cp, r) {
            return i
        }
    }
    return 0
}

// --- the verbs, shared by the keyboard and the pointer ---
// These live here rather than in input.odin because a click now reaches all of them, and
// the template's rule is that neither input path may grow behaviour the other lacks.

// Right / Enter on a language row: open its grammar-action dropdown, with the highlight
// left on the language root (-1) rather than on a first option nobody asked for.
config_pane_open_lang :: proc(a: ^App) {
    cp := &a.config_pane
    if li, ok := config_pane_lang_index(cp, cp.sel); ok {
        cp.open = .Lang
        cp.open_idx = li // the language index, stable under filtering
        cp.opt_sel = -1
    }
}

// Commit whatever the open dropdown is highlighting, and close it. Enter/Right on the
// keyboard and a click on an option both land here. On the language root (opt_sel == -1)
// there is nothing to choose, so it just minimises — which is what re-pressing Enter means.
config_choose :: proc(a: ^App) {
    cp := &a.config_pane
    defer cp.open = .None
    switch cp.open {
    case .None:
    case .Setting:
        s := Setting(cp.open_idx)
        opts := setting_options(a, s)
        if cp.opt_sel >= 0 && cp.opt_sel < len(opts) {
            setting_commit(a, s, opts[cp.opt_sel])
        }
    case .Lang:
        if cp.open_idx < 0 || cp.open_idx >= len(cp.langs) || cp.opt_sel < 0 {
            return
        }
        lang := &cp.langs[cp.open_idx] // open_idx is a language index
        buf: [len(LangOption)]LangOption
        opts := lang_options(lang.present, buf[:])
        if cp.opt_sel < len(opts) {
            config_run_option(a, lang.name, opts[cp.opt_sel])
        }
    }
}

// Move by `delta` steps through whatever currently owns the selection: the open dropdown's
// choices, or the row list when nothing is open. One proc for both because a wheel notch
// over this pane must mean the same thing Up/Down mean — and because the dropdown is
// spliced INTO the row list rather than floating over it, so "step out of the dropdown"
// and "move to the next row" are the same motion to a reader looking at the pane.
//
// The two dropdown kinds differ, and deliberately: a settings dropdown CLAMPS at its ends
// (its options are a closed choice — you leave with Left or Enter), while a language
// dropdown steps out into the surrounding list, since its options are just more rows.
config_dropdown_move :: proc(a: ^App, delta: int) {
    cp := &a.config_pane
    step := delta < 0 ? -1 : 1
    for _ in 0 ..< abs(delta) {
        switch cp.open {
        case .None:
            config_pane_move(cp, step)
        case .Setting:
            opts := setting_options(a, Setting(cp.open_idx))
            cp.opt_sel = clamp(cp.opt_sel + step, 0, max(0, len(opts) - 1))
        case .Lang:
            if cp.open_idx < 0 || cp.open_idx >= len(cp.langs) {
                cp.open = .None
                continue
            }
            buf: [len(LangOption)]LangOption
            opts := lang_options(cp.langs[cp.open_idx].present, buf[:])
            if step > 0 && cp.opt_sel >= len(opts) - 1 {
                cp.open = .None // step out below the dropdown
                config_pane_move(cp, 1)
            } else if step < 0 && cp.opt_sel <= -1 {
                cp.open = .None // step off the root, upward
                config_pane_move(cp, -1)
            } else {
                cp.opt_sel += step
            }
        }
    }
}
