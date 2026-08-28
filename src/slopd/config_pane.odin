package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "../txt"
import "../paths"
import "../syntax"

// The Config aux mode's state: navigation across the install row, the settings rows and the
// language list, the inline editor (a one-line Doc), and each language's grammar status. The
// settings VALUES live on App; this owns only navigation and the language list.

LangStatus :: struct {
    name:    string, // borrowed from the App registry, not owned
    present: bool,   // grammars/<name>.so exists
}

// The same shape as a language's options: a program you can install has an install state, and
// the pane should not have two ways of saying so. `Where` is harmless, so it comes first.
//
// The launcher entry is its own pair: installing puts a binary where a SHELL finds it, the
// entry puts Slopd where a LAUNCHER finds it, and neither implies the other.
Install_Option :: enum {
    Where,
    Install,
    Reinstall,
    Uninstall,
    DesktopAdd,
    DesktopRemove,
}

// Health is always offered; the install state decides between Install and Update/Uninstall.
LangOption :: enum {
    Health,
    Install,
    Update,
    Uninstall,
}

// All three share opt_sel and the dropdown navigation; `open_idx` says which row. The install
// row is the pane's only one, so it needs no index.
Open_Kind :: enum {
    None,
    Setting,
    Lang,
    Install,
}

// There is no edit mode: the highlighted row owns the keys. Most settings open a dropdown; a
// free-text setting is an editor while highlighted, as the search row is. `edit` commits on
// Enter or on leaving the row.
ConfigPane :: struct {
    // The install row, the settings, the search row, then the FILTERED langs — see the ROW_*
    // map below, which every accessor counts with.
    sel:    int,
    scroll: int, // first visible DISPLAY row: the viewport top
    // Wheel-detached at this glfw time; 0 = following the selection.
    scroll_detached: f64,
    open:            Open_Kind,
    open_idx:        int, // Setting(open_idx) when open==.Setting; langs[open_idx] when .Lang
    opt_sel:         int, // within an open dropdown: -1 = the language root, 0.. = options
    search:          txt.Doc, // the persistent syntax filter query
    // The inline editor for a free-text setting. One Doc, since only the highlighted row can be
    // typed into. `edit_row` names that row and `edit_seed` its seeded value, which is how
    // config_edit_sync tells an edit from a row merely visited.
    edit:            txt.Doc,
    edit_row:        int, // -1 when no text row is highlighted
    edit_seed:       string, // owned: the value `edit` was seeded from
    dir:             string, // grammars directory (owned)
    langs:           [dynamic]LangStatus, // names borrow the App registry
    filtered:        [dynamic]int, // indices into langs matching `search`
    // The DISPLAY row under the pointer, or -1. Written by config_frame before it declares, so
    // the declaration can tint it without hit-testing again.
    hover:    int,
}

SETTING_COUNT :: len(Setting)

// The row map, in display order. Named rather than counted at each use, so a row added at the
// top cannot silently shift a setting under a caller that assumed row 0.
ROW_INSTALL :: 0 // first, because it says where every write below lands
ROW_SETTINGS :: ROW_INSTALL + 1 // the first settings row; Setting(r - ROW_SETTINGS)
ROW_BINDS :: ROW_SETTINGS + SETTING_COUNT // the key table, edited in its own pane
ROW_MACROS :: ROW_BINDS + 1 // the `[macros]` block, opened in the editor
ROW_SEARCH :: ROW_MACROS + 1 // the language filter
ROW_LANGS :: ROW_SEARCH + 1 // the first filtered language

// The pane borrows each name from the App-owned registry, which outlives it, so it frees only
// its own langs array.
config_pane_init :: proc(cp: ^ConfigPane, grammars: []syntax.Grammar) {
    txt.doc_init(&cp.search)
    txt.doc_init(&cp.edit)
    cp.edit_row = -1 // until config_edit_sync says otherwise
    cp.open = .None
    cp.hover = -1
    cp.dir = syntax.grammars_dir()
    for g in grammars {
        append(&cp.langs, LangStatus{name = g.name, present = syntax.grammar_present(cp.dir, g.name)})
    }
    config_pane_filter(cp) // filtered = all languages
}

config_pane_destroy :: proc(cp: ^ConfigPane) {
    txt.doc_destroy(&cp.search)
    txt.doc_destroy(&cp.edit)
    delete(cp.edit_seed)
    delete(cp.langs)
    delete(cp.filtered)
    delete(cp.dir)
}

// On entering the pane, or after an install/uninstall.
config_pane_refresh :: proc(cp: ^ConfigPane) {
    for &l in cp.langs {
        l.present = syntax.grammar_present(cp.dir, l.name)
    }
}

// Case-insensitive substring; empty shows all. Closes any dropdown and clamps the selection.
config_pane_filter :: proc(cp: ^ConfigPane) {
    clear(&cp.filtered)
    q := strings.to_lower(strings.trim_space(txt.doc_string(&cp.search, context.temp_allocator)), context.temp_allocator)
    for l, i in cp.langs {
        if q == "" || strings.contains(strings.to_lower(l.name, context.temp_allocator), q) {
            append(&cp.filtered, i)
        }
    }
    cp.open = .None
    cp.sel = clamp(cp.sel, 0, max(0, config_pane_rows(cp) - 1))
}

// The install row, the settings block, the search row, one per filtered language.
config_pane_rows :: proc(cp: ^ConfigPane) -> int {
    return ROW_LANGS + len(cp.filtered)
}

config_pane_setting :: proc(r: int) -> (Setting, bool) {
    if r >= ROW_SETTINGS && r < ROW_BINDS {
        return Setting(r - ROW_SETTINGS), true
    }
    return {}, false
}

config_pane_is_install :: proc(r: int) -> bool {
    return r == ROW_INSTALL
}

config_pane_is_binds :: proc(r: int) -> bool {
    return r == ROW_BINDS
}

config_pane_is_macros :: proc(r: int) -> bool {
    return r == ROW_MACROS
}

config_pane_is_search :: proc(r: int) -> bool {
    return r == ROW_SEARCH
}

config_pane_lang_index :: proc(cp: ^ConfigPane, r: int) -> (int, bool) {
    i := r - ROW_LANGS
    if i < 0 || i >= len(cp.filtered) {
        return 0, false
    }
    return cp.filtered[i], true
}

config_pane_lang :: proc(cp: ^ConfigPane, r: int) -> ^LangStatus {
    if i, ok := config_pane_lang_index(cp, r); ok {
        return &cp.langs[i]
    }
    return nil
}

// The language filter, or a free-text setting: the rows that take typed characters and carry a
// caret. Every other row is a dropdown.
config_pane_is_text :: proc(r: int) -> bool {
    if config_pane_is_search(r) {
        return true
    }
    s, ok := config_pane_setting(r)
    return ok && setting_is_text(s)
}

// Config holds focus, the highlighted row edits text, and no dropdown is open over it. The
// painter and the scheduler must ask the same question, or an unfocused pane keeps a drawn '|'
// that never blinks.
config_caret_live :: proc(a: ^App) -> bool {
    if a.focus != .Aux || a.aux_mode != .Config {
        return false // on screen, perhaps, but not taking keystrokes
    }
    cp := &a.config_pane
    return config_pane_is_text(cp.sel) && cp.open == .None
}

// --- the free-text setting's editor --- A text row is an editor while highlighted and stored
// text otherwise, and nothing announces the change, so the pane reconciles: config_edit_sync
// compares the highlighted row against the Doc's row.

// Commit the row being left, seed the row being entered. Idempotent, so the frame calls it after
// a click and the key paths before they read the Doc.
config_edit_sync :: proc(a: ^App) {
    cp := &a.config_pane
    want := -1
    if s, ok := config_pane_setting(cp.sel); ok && setting_is_text(s) && cp.open == .None {
        want = cp.sel
    }
    if cp.edit_row == want {
        return
    }
    config_edit_commit(a) // whatever was typed into the row being left
    cp.edit_row = want
    delete(cp.edit_seed)
    cp.edit_seed = ""
    txt.doc_clear(&cp.edit)
    if s, ok := config_pane_setting(want); ok {
        cp.edit_seed = strings.clone(setting_value(a, s)) // a borrow of App state
        txt.doc_set_text(&cp.edit, cp.edit_seed)
        txt.doc_cursor_to_end(&cp.edit) // at the end of the value, ready to append
    }
}

// If it actually changed. false covers "no text row is live", "visited without editing" and
// "setting_commit refused" — the no-change case matters because committing persists.
config_edit_commit :: proc(a: ^App) -> bool {
    cp := &a.config_pane
    s, ok := config_pane_setting(cp.edit_row)
    if !ok {
        return false
    }
    val := strings.trim_space(txt.doc_string(&cp.edit, context.temp_allocator))
    if val == cp.edit_seed {
        return false
    }
    if !setting_commit(a, s, val) {
        return false // invalid: the row keeps its value (setting_commit's contract)
    }
    delete(cp.edit_seed)
    cp.edit_seed = strings.clone(val)
    return true
}

// A pure clamp. config_edit_sync reconciles the inline editor afterwards, so every mover gets
// that for free.
config_pane_move :: proc(cp: ^ConfigPane, delta: int) {
    cp.sel = clamp(cp.sel + delta, 0, max(0, config_pane_rows(cp) - 1))
}

// Highlights `where`, the one option that only reports; install and uninstall are a row down.
config_pane_open_install :: proc(a: ^App) {
    cp := &a.config_pane
    cp.open = .Install
    cp.open_idx = ROW_INSTALL
    cp.opt_sel = 0
}

// Pre-selecting the row's current value.
config_pane_open_setting :: proc(a: ^App, s: Setting) {
    if setting_is_text(s) {
        return // free text has no choices; the row is already an editor
    }
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

// Into `buf`, in display order. The count varies with install state, so callers pass a
// [len(LangOption)]LangOption and use the returned slice.
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

// lang_options' contract, for Slopd's own row. An installed copy can be replaced or removed;
// anything else can be installed. `desktop` decides the launcher pair the same way.
install_options :: proc(m: paths.Install_Mode, desktop: bool, buf: []Install_Option) -> []Install_Option {
    n := 0
    buf[n] = .Where;n += 1
    if m == .Installed {
        buf[n] = .Reinstall;n += 1
        buf[n] = .Uninstall;n += 1
    } else {
        buf[n] = .Install;n += 1
    }
    buf[n] = desktop ? .DesktopRemove : .DesktopAdd;n += 1
    return buf[:n]
}

install_option_label :: proc(o: Install_Option) -> string {
    switch o {
    case .Where:         return "where are my files"
    case .Install:       return "install to ~/.local/bin"
    case .Reinstall:     return "reinstall (writes any missing config or folder)"
    case .Uninstall:     return "uninstall (settings are kept)"
    case .DesktopAdd:    return "add to the application list"
    case .DesktopRemove: return "remove from the application list"
    }
    return ""
}

// --- the display flattening --- Display rows over a smaller list of navigable ones: rules and
// titles are display-only, and an open dropdown splices its options in under its row. `item`
// names the navigable row a click selects, `opt` the choice within it.

Config_Row_Kind :: enum {
    Rule, // a full-width horizontal rule
    Header, // a section title
    Install, // install state plus its install/uninstall dropdown
    Setting, // key + value column
    Binds, // opens the key table's block, and carries any load error
    Macros, // opens the `[macros]` block in the editor, and carries any load error
    Text, // a settings row whose value is FREE TEXT
    Search, // the language filter box, always an editor
    Lang, // status mark + name
    Option, // a choice spliced in under an open dropdown
}

// No selection state and no colour: a click changes the selection mid-frame, so encoding it
// would force a rebuild and the hit test, click and declaration could not share one flattening.
ConfigRow :: struct {
    kind:    Config_Row_Kind,
    text:    string,
    value:   string, // drawn at the shared value column; "" otherwise
    item:    int, // the navigable row this selects, or -1 for chrome
    opt:     int, // the choice index within an open dropdown; -1 elsewhere
    indent:  i32, // extra left margin, in cells
    present: bool, // Lang rows only: the grammar is installed
}

// `cols` is the content width in whole cells, which the rules span. Every string comes out of
// `alloc`, so one temp arena owns the frame's rows.
config_rows :: proc(cp: ^ConfigPane, a: ^App, cols: int, alloc := context.allocator) -> []ConfigRow {
    rows := make([dynamic]ConfigRow, 0, 48, alloc)
    rule := strings.repeat("-", max(1, cols - 1), alloc)
    chrome :: proc(kind: Config_Row_Kind, text: string) -> ConfigRow {
        return ConfigRow{kind = kind, text = text, item = -1, opt = -1}
    }

    // First: it names the folder every setting below is written to, and in read-only mode it
    // explains why none of them can be.
    append(&rows, chrome(.Rule, rule), chrome(.Header, "slopd"), chrome(.Rule, rule))
    append(
        &rows,
        ConfigRow {
            kind = .Install,
            text = "install:",
            value = install_state_text(alloc),
            item = ROW_INSTALL,
            opt = -1,
            indent = 1,
        },
    )
    if cp.open == .Install {
        buf: [len(Install_Option)]Install_Option
        for o, oi in install_options(paths.install_mode(), desktop_present(), buf[:]) {
            append(&rows, config_option_row(ROW_INSTALL, oi, install_option_label(o)))
        }
    }

    append(&rows, chrome(.Rule, rule), chrome(.Header, "settings"), chrome(.Rule, rule))
    for si in 0 ..< SETTING_COUNT {
        s := Setting(si)
        val := setting_value(a, s)
        // Still its stored value: which row is highlighted stays out of the flattening, and
        // the declaration swaps in the live Doc for the one row that has it.
        append(
            &rows,
            ConfigRow {
                kind   = setting_is_text(s) ? .Text : .Setting,
                text   = fmt.aprintf("%s:", setting_key(s), allocator = alloc),
                value  = val == "" ? "(default)" : strings.clone(val, alloc),
                item   = ROW_SETTINGS + si,
                opt    = -1,
                indent = 1,
            },
        )
        // A SETTING index, not a row: the row it hangs under is ROW_SETTINGS past it.
        if cp.open == .Setting && cp.open_idx == si {
            for o, oi in setting_options(a, s) {
                append(&rows, config_option_row(ROW_SETTINGS + si, oi, strings.clone(o, alloc)))
            }
        }
    }

    append(
        &rows,
        ConfigRow {
            kind = .Binds,
            text = "bindings:",
            value = binds_row_text(len(a.binds_pane.errs), alloc),
            item = ROW_BINDS,
            opt = -1,
            indent = 1,
        },
    )

    append(
        &rows,
        ConfigRow {
            kind = .Macros,
            text = "macros:",
            value = macros_row_text(len(a.macro_errors), alloc),
            item = ROW_MACROS,
            opt = -1,
            indent = 1,
        },
    )

    append(&rows, chrome(.Rule, rule), chrome(.Header, "syntax"), chrome(.Rule, rule))
    append(
        &rows,
        ConfigRow {
            kind   = .Search,
            text   = "search:",
            value  = txt.doc_string(&cp.search, alloc),
            item   = ROW_SEARCH,
            opt    = -1,
            indent = 1,
        },
    )

    for fi, idx in cp.filtered {
        l := &cp.langs[fi]
        nav := ROW_LANGS + idx
        append(
            &rows,
            ConfigRow {
                kind    = .Lang,
                text    = fmt.aprintf("%s %s", l.present ? "✓" : "✗", l.name, allocator = alloc),
                item    = nav,
                opt     = -1,
                indent  = 1,
                present = l.present,
            },
        )
        // A LANGS index, so it survives the filter list being rebuilt under it.
        if cp.open == .Lang && cp.open_idx == fi {
            buf: [len(LangOption)]LangOption
            for o, oi in lang_options(l.present, buf[:]) {
                append(&rows, config_option_row(nav, oi, lang_option_label(o)))
            }
        }
    }
    return rows[:]
}

@(private = "file")
macros_row_text :: proc(n: int, alloc: runtime.Allocator) -> string {
    if n == 0 {
        return strings.clone("edit command macros", alloc)
    }
    return fmt.aprintf("! %d error%s in macro config", n, n == 1 ? "" : "s", allocator = alloc)
}

@(private = "file")
binds_row_text :: proc(n: int, alloc: runtime.Allocator) -> string {
    if n == 0 {
        return strings.clone("change bindings", alloc)
    }
    return fmt.aprintf("! %d error%s in binding config", n, n == 1 ? "" : "s", allocator = alloc)
}

// Indented past the row that owns it, so the options read as nested.
@(private = "file")
config_option_row :: proc(item, opt: int, text: string) -> ConfigRow {
    return ConfigRow{kind = .Option, text = text, item = item, opt = opt, indent = 4}
}

// Exactly one row does, and it moves INTO an open dropdown: an open setting highlights the
// chosen option, an open language the root until opt_sel leaves it.
config_row_selected :: proc(cp: ^ConfigPane, r: ConfigRow) -> bool {
    if r.item < 0 || cp.sel != r.item {
        return false
    }
    switch r.kind {
    case .Rule, .Header:
        return false
    case .Search, .Text, .Binds, .Macros:
        return true
    case .Install:
        return cp.open != .Install
    case .Setting:
        return cp.open != .Setting || ROW_SETTINGS + cp.open_idx != r.item
    case .Lang:
        return cp.open != .Lang || cp.opt_sel == -1
    case .Option:
        return cp.opt_sel == r.opt
    }
    return false
}

// --- the verbs, shared by the keyboard and the pointer --- Here rather than in input.odin
// because a click reaches all of them, and neither path may grow behaviour the other lacks.

// Open a language's grammar-action dropdown, with the highlight left on the root (-1) rather
// than on a first option nobody asked for.
config_pane_open_lang :: proc(a: ^App) {
    cp := &a.config_pane
    if li, ok := config_pane_lang_index(cp, cp.sel); ok {
        cp.open = .Lang
        cp.open_idx = li // stable under filtering
        cp.opt_sel = -1
    }
}

// Enter/Right and a click on an option both land here. On the language root there is nothing to
// choose, so it just minimises.
config_choose :: proc(a: ^App) {
    cp := &a.config_pane
    defer cp.open = .None
    switch cp.open {
    case .None:
    case .Install:
        buf: [len(Install_Option)]Install_Option
        opts := install_options(paths.install_mode(), desktop_present(), buf[:])
        if cp.opt_sel >= 0 && cp.opt_sel < len(opts) {
            config_run_install(a, opts[cp.opt_sel])
        }
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
        lang := &cp.langs[cp.open_idx] // a language index
        buf: [len(LangOption)]LangOption
        opts := lang_options(lang.present, buf[:])
        if cp.opt_sel < len(opts) {
            config_run_option(a, lang.name, opts[cp.opt_sel])
        }
    }
}

// Through the open dropdown's choices, or the row list. One proc, since a wheel notch must mean
// what Up/Down mean and the dropdown is spliced INTO the list. A settings or install dropdown
// clamps at its ends; a language one steps out into the list.
config_dropdown_move :: proc(a: ^App, delta: int) {
    cp := &a.config_pane
    step := delta < 0 ? -1 : 1
    for _ in 0 ..< abs(delta) {
        switch cp.open {
        case .None:
            config_pane_move(cp, step)
        case .Install:
            buf: [len(Install_Option)]Install_Option
            opts := install_options(paths.install_mode(), desktop_present(), buf[:])
            cp.opt_sel = clamp(cp.opt_sel + step, 0, max(0, len(opts) - 1))
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
                cp.open = .None // out, below the dropdown
                config_pane_move(cp, 1)
            } else if step < 0 && cp.opt_sel <= -1 {
                cp.open = .None // off the root, upward
                config_pane_move(cp, -1)
            } else {
                cp.opt_sel += step
            }
        }
    }
}

// A chosen option builds a `slopd ...` line and runs it in the CL's session, through the seam
// line's shell path uses. The pointer reaches these too, hence the verb living beside the
// choice.
config_run_option :: proc(a: ^App, lang: string, opt: LangOption) {
    // By absolute path, quoted, so these work where slopd is not on PATH — and where the path
    // to it carries a quote of its own.
    self := sh_quote(paths.exe_path(context.temp_allocator), context.temp_allocator)
    cmd: string
    switch opt {
    case .Health:
        cmd = fmt.tprintf("%s --health %s", self, sh_quote(lang, context.temp_allocator))
    case .Install:
        cmd = fmt.tprintf("%s --grammar install %s", self, sh_quote(lang, context.temp_allocator))
    case .Update:
        cmd = fmt.tprintf("%s --grammar update %s", self, sh_quote(lang, context.temp_allocator))
    case .Uninstall:
        cmd = fmt.tprintf("%s --grammar uninstall %s", self, sh_quote(lang, context.temp_allocator))
    }
    run_in_cl_term(a, cmd)
}

// Run the same way a language's are. Installing moves the binary Slopd is running from, which
// no editor should do behind its own back, so it happens in a terminal you are looking at.
config_run_install :: proc(a: ^App, opt: Install_Option) {
    self := sh_quote(paths.exe_path(context.temp_allocator), context.temp_allocator)
    cmd: string
    switch opt {
    case .Where:
        cmd = fmt.tprintf("%s --where", self)
    case .Install, .Reinstall:
        cmd = fmt.tprintf("%s --install", self)
    case .Uninstall:
        cmd = fmt.tprintf("%s --uninstall", self)
    case .DesktopAdd:
        cmd = fmt.tprintf("%s --desktop add", self)
    case .DesktopRemove:
        cmd = fmt.tprintf("%s --desktop remove", self)
    }
    run_in_cl_term(a, cmd)
}
