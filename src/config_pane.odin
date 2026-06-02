package main

// ConfigPane — the Config aux mode's state: navigation across the settings rows and
// the language list, the inline settings editor (a one-line Doc, sharing the buffer
// editing core like the command line does), and each known language's grammar
// status. The settings VALUES live on App (they're editor config); this owns only
// the pane's own navigation state and the language list. Status is read from
// grammars/ at init and re-read on demand (config_pane_refresh).

LangStatus :: struct {
    name:    string, // borrowed from cp.grammars (the loaded registry) — not owned
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

ConfigPane :: struct {
    sel:      int, // selected row: [0, SETTING_COUNT) are settings, then one per lang
    expanded: int, // the language row whose options are open, or -1
    opt_sel:  int, // selection within an open dropdown: -1 = the language root, 0.. = options
    editing:  bool, // a settings value is being edited (keys go to `edit`)
    edit:     Doc, // the one-line edit buffer
    dir:      string, // grammars directory (owned)
    grammars: []Grammar, // the language registry (owned); backs the langs list
    langs:    [dynamic]LangStatus,
}

SETTING_COUNT :: len(Setting)

config_pane_init :: proc(cp: ^ConfigPane) {
    doc_init(&cp.edit)
    cp.expanded = -1
    cp.dir = grammars_dir()
    cp.grammars = load_grammars()
    for g in cp.grammars {
        append(&cp.langs, LangStatus{name = g.name, present = grammar_present(cp.dir, g.name)})
    }
}

config_pane_destroy :: proc(cp: ^ConfigPane) {
    doc_destroy(&cp.edit)
    delete(cp.langs)
    grammars_destroy(cp.grammars)
    delete(cp.dir)
}

// Re-stat every grammar (entering the pane, or after an install/uninstall).
config_pane_refresh :: proc(cp: ^ConfigPane) {
    for &l in cp.langs {
        l.present = grammar_present(cp.dir, l.name)
    }
}

// Total navigable rows: the settings block followed by one row per language.
config_pane_rows :: proc(cp: ^ConfigPane) -> int {
    return SETTING_COUNT + len(cp.langs)
}

// The Setting at row r, or (_, false) when r is a language row.
config_pane_setting :: proc(r: int) -> (Setting, bool) {
    if r >= 0 && r < SETTING_COUNT {
        return Setting(r), true
    }
    return {}, false
}

// The language at row r, or nil when r is a settings row.
config_pane_lang :: proc(cp: ^ConfigPane, r: int) -> ^LangStatus {
    i := r - SETTING_COUNT
    if i < 0 || i >= len(cp.langs) {
        return nil
    }
    return &cp.langs[i]
}

config_pane_move :: proc(cp: ^ConfigPane, delta: int) {
    cp.sel = clamp(cp.sel + delta, 0, max(0, config_pane_rows(cp) - 1))
}

// Esc handling: cancel an in-progress edit, else close an open dropdown. Returns
// true if it consumed the Esc (so the app doesn't fall through to quitting).
config_pane_cancel :: proc(cp: ^ConfigPane) -> bool {
    if cp.editing {
        cp.editing = false
        doc_clear(&cp.edit)
        return true
    }
    if cp.expanded >= 0 {
        cp.expanded = -1
        return true
    }
    return false
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
