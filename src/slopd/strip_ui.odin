package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import clay "../../bindings/clay"
import "../txt"
import "../gfx"
import "../syntax"
import "../ui"
import "../edit"

// One row along the bottom, showing one of two things:
//   the command line while it is open — a prompt, an editable line, a ghosted hint
//   the modeline otherwise — file, project root, language / caret / line count
//
// A disk conflict has no line of its own here: it stages `:reload ` in the command line, where
// its answer is typed. The modeline carries only the state — the name's `*` becomes a `!`.
//
// No hit test and no click verb: nothing in the strip is clickable.
//
// The modeline is three anchored labels, not a row: three grown thirds stop being thirds the
// moment one outgrows its share, and the root would drift off centre as the file name changed.
// `clipTo = .AttachedParent` keeps them in the strip's scissor, which a floating child does not
// get by default — it is hoisted to the root's floating list and would paint over the panes.

// The margin either end, in cells, past the ring the strip does not draw — a pane's text starts
// one cell inside its ring, and the strip's has to start on the same column.
STRIP_PAD_CELLS :: 1

// Named because two phases ask it: the ring and the declaration.
Strip_Mode :: enum {
    Status,
    Command,
}

strip_mode :: proc(a: ^App) -> Strip_Mode {
    return a.cl_active ? .Command : .Status
}

// The region and the margin, in Clay's units. The region is the whole strip — it has no focus
// ring, being nothing you can focus — but the margin is ruled as if it had one, or the typed
// line would sit a ring's width off the editor's columns.
strip_geom :: proc(strip: gfx.Rect, line_h, cell_w: f32) -> (area: gfx.Rect, pad: u16) {
    return strip, u16(gfx.grid_phase(line_h) + gfx.cells(cell_w, STRIP_PAD_CELLS))
}

// Pinned to one corner, out of the flow — see the header. The offset is the margin: a floating
// child attaches to its parent's BOX, not its content box, so the padding does not reach it.
@(private = "file")
strip_slot :: proc(at: clay.FloatingAttachPointType, dx: f32) -> clay.ElementDeclaration {
    return {
        layout = {childAlignment = {y = .Center}},
        floating = {
            attachTo           = .Parent,
            attachment         = {element = at, parent = at},
            offset             = {dx, 0},
            clipTo             = .AttachedParent,
            pointerCaptureMode = .Passthrough,
        },
    }
}

// The one-line Doc and the frame's timestamp, for the blink. Lives in the frame's temp arena.
Strip_Edit :: struct {
    doc: ^txt.Doc,
    now: f64,
}

// The typed runes, a selection span per cursor and a caret per cursor. A caret is an over-quad
// and must land above the glyphs, which a Clay Rectangle cannot do.
strip_paint_cl :: proc(t: ^gfx.Draw, r, clip: gfx.Rect, win_w, win_h: i32, host: rawptr, user: rawptr) {
    a := (^App)(host)
    e := (^Strip_Edit)(user)
    if e == nil || e.doc == nil || txt.doc_line_count(e.doc) == 0 {
        return
    }
    th := &a.theme
    cw := gfx.face(t).cell_w
    lh := gfx.face(t).line_height
    ox := f32(r.x)
    ty := f32(r.y) + (f32(r.h) - lh) / 2
    y := i32(ty) // selection and caret share the glyph cell's top

    cells := txt.doc_cells(e.doc, 0) // one line; bytes -> the cell grid
    for c in e.doc.cursors {
        if txt.cursor_has_selection(c) {
            lo, hi := txt.cursor_range(c)
            x0 := txt.cells_col(cells, lo.col)
            x1 := txt.cells_col(cells, hi.col)
            gfx.fill(t, gfx.Rect{i32(ox + cw * f32(x0)), y, i32(cw * f32(x1 - x0)), i32(lh)}, th.selection)
        }
    }
    gfx.text_draw_runes(t, cells.runes, ox, ty, th.fg)
    if ui.caret_blink_on(ctx_of(a), e.now) {
        for c in e.doc.cursors {
            cx := ox + cw * f32(txt.cells_col(cells, c.head.col))
            gfx.caret(t, gfx.Rect{i32(cx), y, max(1, gfx.hairline(lh)), i32(lh)}, th.fg)
        }
    }
    // The ClayCustom contract: the painter ends with its own flush.
    gfx.flush_pane(t, clip, win_w, win_h)
}

// Declare the strip into the window's tree. Reads App, writes only Clay — no mutation, no GL.
//
//   st_pane   the strip, floating at its rect, clipping its content, and the one element here
//             that paints a background — there is no panel() down here
//     .Command   st_prompt  the "> ", muted
//                st_edit    the typed line, as a Custom — runes, selections, carets
//                st_hint    the ghosted argument hint, one cell past the text
//                (plus a border on st_pane while an injected line is still pristine)
//     .Status    st_left    the modified marker and file name, pinned left
//                st_root    the project root, centred
//                st_right   language / caret / line count / cursors / scroll, pinned right
strip_declare :: proc(a: ^App, face: gfx.Face, strip: gfx.Rect, now: f64 = 0) {
    th := &a.theme
    area, pad := strip_geom(strip, face.line_height, face.cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := face.cell_w
    lh := i32(face.line_height)
    mode := strip_mode(a)

    // Rung in the alert colour when it holds an untouched injected line. Any edit bumps
    // doc.version past the mark and the ring clears itself.
    ring := mode == .Command && a.cl.injected && a.cl.doc.version == a.cl.inject_ver
    bw := u16(max(1, gfx.hairline(a.face.line_height)))

    box := ui.clay_pane_box(area)
    box.layout.layoutDirection = .LeftToRight
    box.layout.padding = {left = pad, right = pad}
    box.layout.childAlignment = {y = .Center}
    box.backgroundColor = ui.clay_rgb(th.border_light)
    if ring {
        box.border = {color = ui.clay_rgb(th.cl_inject), width = {left = bw, right = bw, top = bw, bottom = bw}}
    }

    if clay.UI(clay.ID("st_pane"))(box) {
        switch mode {
        case .Command:
            strip_declare_command(a, cw, lh, now)
        case .Status:
            strip_declare_status(a, face, area, pad)
        }
    }
}

// Prompt, field, hint, left to right and touching. The field is the typed text plus one cell:
// the caret column, which is also where the hint starts.
@(private = "file")
strip_declare_command :: proc(a: ^App, cw: f32, lh: i32, now: f64) {
    PROMPT :: "> "
    th := &a.theme
    if txt.doc_line_count(&a.cl.doc) == 0 {
        return // never cl_init'd, so there is no line to show
    }
    text := string(txt.doc_line(&a.cl.doc, 0))
    ncells := txt.cells_count(txt.doc_cells(&a.cl.doc, 0))

    if clay.UI(clay.ID("st_prompt"))({layout = {sizing = {width = clay.SizingFixed(cw * f32(len(PROMPT)))}}}) {
        clay.Text(PROMPT, ui.clay_text_config(th.muted, lh))
    }

    ed := new(Strip_Edit, context.temp_allocator)
    ed^ = Strip_Edit{doc = &a.cl.doc, now = now}
    cu := new(ui.ClayCustom, context.temp_allocator)
    cu^ = ui.ClayCustom{paint = strip_paint_cl, user = ed}
    if clay.UI(clay.ID("st_edit"))(
        {
            layout = {sizing = {clay.SizingFixed(cw * f32(ncells + 1)), clay.SizingGrow()}},
            custom = {customData = cu},
        },
    ) {}

    // e.g. `:reload` -> "(y/n)", until an argument is entered.
    if hint := cl_ghost_hint(a, text); hint != "" {
        if clay.UI(clay.ID("st_hint"))({layout = {childAlignment = {y = .Center}}}) {
            clay.Text(hint, ui.clay_text_config(th.muted, lh))
        }
    }
}

// An emacs-style readout of the document pane, as three anchored labels. The right-hand one is
// a single string: it is one thing in one colour, and "   " says what three gaps would.
@(private = "file")
strip_declare_status :: proc(a: ^App, face: gfx.Face, area: gfx.Rect, pad: u16) {
    th := &a.theme
    lh := i32(face.line_height)
    cw := face.cell_w
    dx := f32(pad)

    // No editor on screen: name the aux pane. The rest is about a document, and there is none.
    // A file dialog says what it wants instead, in the accent, because that is the one thing
    // about this window that is not ordinary.
    if !panes_visible(a).editor {
        label, col := aux_mode_name(a.aux_mode), th.muted
        if pick_live(a) {
            label, col = pick_label(a), th.accent
        }
        if clay.UI(clay.ID("st_left"))(strip_slot(.LeftCenter, dx)) {
            clay.Text(label, ui.clay_text_config(col, lh))
        }
        return
    }

    left, right: string
    left_col: [3]f32
    if a.main == .Image {
        // Media, not a buffer: name, pixel dimensions, zoom. Nothing here has a line:col.
        m := &a.media
        left = fmt.tprintf("  %s", m.path == "" ? "(no image)" : filepath.base(m.path))
        left_col = th.muted
        right = fmt.tprintf("image   %dx%d   %d%%", m.img.w, m.img.h, int(m.zoom * 100 + 0.5))
    } else {
        b := edit.editor_current(&a.editor)
        name := b.path == "" ? "untitled" : filepath.base(b.path)
        // One column, three states: clean, `*` unsaved, `!` unsaved and changed on disk. `!`
        // is the whole report of a pending conflict, so it takes the alert colour.
        mark := b.conflict ? "!" : b.dirty ? "*" : " "
        left = fmt.tprintf("%s %s", mark, name) // a dirty buffer reads brighter
        left_col = b.conflict ? th.urgent : b.dirty ? th.fg : th.muted
        head := b.cursors[b.primary].head
        nlines := txt.doc_line_count(&b.doc)
        cursors := len(b.cursors) > 1 ? fmt.tprintf("   %d cursors", len(b.cursors)) : ""
        eol := b.crlf ? "   CRLF" : "" // LF is the norm and says nothing; CRLF has to be visible
        right = fmt.tprintf(
            "%s%s   L%d:%d   %d lines%s   %s",
            status_lang(a, b.path), eol, head.line + 1, txt.doc_cell_col(&b.doc, head) + 1, nlines,
            cursors, scroll_label(head.line, nlines),
        )
    }

    if clay.UI(clay.ID("st_left"))(strip_slot(.LeftCenter, dx)) {
        clay.Text(left, ui.clay_text_config(left_col, lh))
    }
    // Clay pins and centres in pixels, so either label lands mid-cell as often as not; the extra
    // offset walks it back to the column below it, where the left one already starts.
    col0 := f32(area.x + gfx.grid_phase(face.line_height)) // the strip's first column
    right_dx := dx + gfx.grid_off(f32(area.x + area.w) - dx - gfx.text_w(right, cw), col0, cw)
    if clay.UI(clay.ID("st_right"))(strip_slot(.RightCenter, -right_dx)) {
        clay.Text(right, ui.clay_text_config(th.muted, lh))
    }

    // The project root, so the root the tools and `:tu` use is visible whenever the command
    // line is not.
    if root := home_abbrev(a.project_root, context.temp_allocator); root != "" {
        root_dx := -gfx.grid_off(f32(area.x) + (f32(area.w) - gfx.text_w(root, cw)) / 2, col0, cw)
        if clay.UI(clay.ID("st_root"))(strip_slot(.CenterCenter, root_dx)) {
            clay.Text(root, ui.clay_text_config(th.muted, lh))
        }
    }
}

// Test-facing wrapper; see filetree_layout.
strip_layout :: proc(a: ^App, face: gfx.Face, strip: gfx.Rect, win_w, win_h: i32, now: f64 = 0) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        strip_declare(a, face, strip, now)
    }
    return clay.EndLayout(0)
}

// Shorter than any pane's: with no list, no viewport and no click there is nothing to do
// before declaring.
strip_frame :: proc(t: ^gfx.Draw, a: ^App, strip: gfx.Rect, now: f64) {
    strip_declare(a, gfx.face(t), strip, now)
}

// /home/me/src -> ~/src. Borrows `path` when nothing changes, else a fresh string in `alloc`.
home_abbrev :: proc(path: string, alloc := context.allocator) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && strings.has_prefix(path, home) {
        return strings.concatenate({"~", path[len(home):]}, alloc)
    }
    return path
}

// The registry's name for the extension, else the bare extension, else "text".
@(private = "file")
status_lang :: proc(a: ^App, path: string) -> string {
    ext := strings.trim_prefix(filepath.ext(path), ".")
    if ext == "" {
        return "text"
    }
    if name, ok := syntax.grammar_for_ext(a.gram_ext, ext); ok {
        return name
    }
    return ext
}

// Emacs-style: Top / Bot / All, else percent through the buffer.
@(private = "file")
scroll_label :: proc(line, nlines: int) -> string {
    if nlines <= 1 {
        return "All"
    }
    if line == 0 {
        return "Top"
    }
    if line >= nlines - 1 {
        return "Bot"
    }
    return fmt.tprintf("%d%%", line * 100 / (nlines - 1))
}
