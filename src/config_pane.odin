package main

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
}

SETTING_COUNT :: len(Setting)

// `grammars` is the App-owned registry; the pane borrows each name for its lang list
// (the App outlives the pane), so the pane frees only its own langs array.
config_pane_init :: proc(cp: ^ConfigPane, grammars: []Grammar) {
    doc_init(&cp.search)
    cp.open = .None
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
