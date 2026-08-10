package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import clay "../bindings/clay"

// The status strip — C8b, and the last surface that was not a pane. It is one row along the
// bottom of the window showing exactly one of three things:
//
//   the command line    while it is open — a prompt, an editable line, a ghosted hint
//   the conflict prompt when the open file changed on disk and the CL is closed
//   the modeline        otherwise — file, project root, language / caret / line count
//
// **This is the surface invariant 11 was in the way of, and that is why it waited for C8a.**
// The strip draws LAST. While every pane declared its own tree, a strip declared in Clay
// would have ended the frame holding it — and the filetree, grep, config and procmon would
// all have gone blind on the following frame, because their `PointerOver` resolves against
// whatever the last EndLayout produced. Those four panes only ever worked because the aux
// pane happened to be the last declaration. So porting the strip was never a matter of
// writing this file; it was gated on the window frame, and now it is a normal port.
//
// **The strip has no hit test and no click verb, and that is deliberate.** Nothing in it is
// clickable today, and the obvious candidate — click-to-caret in the command line — is a
// question about one-line TEXT FIELDS, not about the strip: config's search box (C5b) is the
// same widget with the same Doc and the same painter, and giving one a caret the other lacks
// is the asymmetry C3 refused for focus-follows-click. If it lands it lands for both at once.
//
// **The modeline is three anchored labels, not a row**, and the declaration says so. Left at
// the pad, right at the far pad, and the project root centred IN THE STRIP — independent of
// the other two, which a left-to-right row cannot express: three grown thirds stop being
// thirds the moment one label outgrows its share, and the root would drift off centre as the
// file name changed. So each is a floating child attached to its own corner of the strip,
// which is what those three `text_draw` calls always meant. `clipTo = .AttachedParent` keeps
// them inside the strip's scissor, which a floating child does NOT get by default — it is
// hoisted to the root's floating list and would otherwise paint over the panes.
//
// The command line and the conflict prompt ARE rows (prompt → field → hint; message → keys),
// so those are declared as rows, with the strip's padding doing the margins.

// The strip's left/right margin in logical pixels — the value every one of its three modes
// has always used, and the only number in the file that is not a colour or a cell count.
STRIP_PAD :: 8

// Which of the three things the strip is showing. Pure, and pulled out of render's if/else
// chain for the usual reason: it is a decision with a precedence in it (an open command line
// beats a pending conflict, because the conflict's own answer is typed INTO that line), and a
// precedence buried in an if/else inside a GL proc is a precedence nothing can assert.
Strip_Mode :: enum {
    Status,
    Command,
    Conflict,
}

strip_mode :: proc(a: ^App) -> Strip_Mode {
    if a.cl_active {
        return .Command
    }
    if a.focus == .Editor && a.main == .Text && len(a.editor.buffers) > 0 && editor_current(&a.editor).conflict {
        return .Conflict
    }
    return .Status
}

// The strip's geometry: the region itself and the margin, in the units Clay wants them. There
// is no inset — the strip has no focus ring, since it is never a pane you can focus — so this
// is thinner than the pane geoms. It exists anyway, for their reason: every phase sizes itself
// from one call, and `pad` is used by three modes and a test.
strip_geom :: proc(strip: Rect, scale: f32) -> (area: Rect, pad: u16) {
    return strip, u16(max(0.0, STRIP_PAD * scale))
}

// A label pinned to one corner of the strip, out of the flow — see the header for why the
// modeline is three of these rather than a row. The offset is the margin: a floating child
// attaches to its parent's BOX, not its content box, so the parent's padding does not reach it.
@(private = "file")
strip_slot :: proc(at: clay.FloatingAttachPointType, dx: f32) -> clay.ElementDeclaration {
    return {
        layout = {childAlignment = {y = .Center}},
        floating = {
            attachTo = .Parent,
            attachment = {element = at, parent = at},
            offset = {dx, 0},
            clipTo = .AttachedParent,
            pointerCaptureMode = .Passthrough,
        },
    }
}

// What the command line's Custom needs to paint itself: the one-line Doc and the frame's
// timestamp, for the caret blink. Handed to the bridge as `customData`, so it lives in the
// frame's temp arena and outlives EndLayout.
Strip_Edit :: struct {
    doc: ^Doc,
    now: f64,
}

// The editable half of the command line: the typed runes, a selection span per cursor, and a
// caret per cursor. A caret is an OVER-quad (text.odin) — it must land above the glyphs, which
// a Clay Rectangle cannot do, since the bridge maps those to `fill` and everything queued in a
// scissor group paints under the text. So the field takes the escape hatch, exactly as config's
// search box does, and this painter is that one with the prompt offset removed: the box Clay
// resolved IS the text origin now.
strip_paint_cl :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    e := (^Strip_Edit)(user)
    if e == nil || e.doc == nil || len(e.doc.lines) == 0 {
        return
    }
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    ox := f32(r.x)
    ty := f32(r.y) + (f32(r.h) - lh) / 2
    y := i32(ty) // selection and caret share the glyph cell's top

    line := &e.doc.lines[0] // the command line is one line
    for c in e.doc.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(t, Rect{i32(ox + cw * f32(lo.col)), y, i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
        }
    }
    text_draw_runes(t, line.text[:], ox, ty, th.fg)
    if caret_blink_on(a, e.now) {
        for c in e.doc.cursors {
            caret(t, Rect{i32(ox + cw * f32(c.head.col)), y, i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
    // The painter owns its region and ends with its own flush (the ClayCustom contract);
    // `clip` arrives already intersected with the box, so this is the whole obligation.
    flush_pane(t, clip, win_w, win_h)
}

// Declare the strip into the window's tree. Reads App, writes only Clay — no mutation, no GL.
//
// The tree is:
//   st_pane   the strip itself, floating at its rect, clipping its own content, and the ONE
//             element in the file that paints a background: there is no panel() down here,
//             so the fill render's chrome pass used to lay down is this element's own
//     .Command   st_prompt  the "> ", muted
//                st_edit    the typed line, as a Custom — runes, selection spans, carets
//                st_hint    the ghosted argument hint, one cell past the text
//                (a border on st_pane while an injected line is still pristine)
//     .Conflict  st_msg     "<file> changed on disk - ", in the alert colour
//                st_keys    what to type, muted
//                (a border on st_pane, always)
//     .Status    st_left    the modified marker + file name, pinned left
//                st_root    the project root, pinned to the strip's centre
//                st_right   language / caret / line count / cursors / scroll, pinned right
strip_declare :: proc(a: ^App, f: ^Font, strip: Rect, now: f64 = 0) {
    th := &a.theme
    area, pad := strip_geom(strip, a.scale)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := f.cell_w
    lh := i32(f.line_height)
    mode := strip_mode(a)

    // The strip is rung in the alert colour when it is holding something that wants an answer:
    // a pending conflict, or an injected command line the user has not touched yet ("review
    // this before Enter"). Any edit bumps doc.version past the mark and the ring clears itself,
    // which is why there is no per-edit hook — the same trick the hand-drawn `outline` used,
    // now expressed as the element's own border rather than four fills over the top of it.
    ring := mode == .Conflict || (mode == .Command && a.cl.injected && a.cl.doc.version == a.cl.inject_ver)
    bw := u16(2 * a.scale)

    box := clay_pane_box(area)
    box.layout.layoutDirection = .LeftToRight
    box.layout.padding = {left = pad, right = pad}
    box.layout.childAlignment = {y = .Center}
    box.backgroundColor = clay_rgb(th.border_light)
    if ring {
        box.border = {color = clay_rgb(th.cl_inject), width = {left = bw, right = bw, top = bw, bottom = bw}}
    }

    if clay.UI(clay.ID("st_pane"))(box) {
        switch mode {
        case .Command:
            strip_declare_command(a, cw, lh, now)
        case .Conflict:
            strip_declare_conflict(a, lh)
        case .Status:
            strip_declare_status(a, lh, pad)
        }
    }
}

// The command line: prompt, field, hint, left to right and touching. The field is sized to the
// typed text PLUS ONE CELL, which is not padding — it is the caret column. A caret sits at
// col == len(text) when you are typing at the end of the line, i.e. exactly one cell past the
// last glyph, and a box sized to the runes alone would clip it away at precisely the moment it
// matters most. That extra cell is also where the hint has always started (`ox + cw * (len +
// 1)`), so the hint follows the field with no gap and lands on the same pixel it always did.
@(private = "file")
strip_declare_command :: proc(a: ^App, cw: f32, lh: i32, now: f64) {
    PROMPT :: "> "
    th := &a.theme
    if len(a.cl.lines) == 0 {
        return // a command line that was never cl_init'd has no line to show
    }
    l := &a.cl.lines[0]

    if clay.UI(clay.ID("st_prompt"))({layout = {sizing = {width = clay.SizingFixed(cw * f32(len(PROMPT)))}}}) {
        clay.Text(PROMPT, clay_text_config(th.muted, lh))
    }

    ed := new(Strip_Edit, context.temp_allocator)
    ed^ = Strip_Edit{doc = &a.cl.doc, now = now}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = strip_paint_cl, user = ed}
    if clay.UI(clay.ID("st_edit"))(
        {
            layout = {sizing = {clay.SizingFixed(cw * f32(len(l.text) + 1)), clay.SizingGrow()}},
            custom = {customData = cu},
        },
    ) {}

    // Ghosted per-command argument hint (e.g. `reload` -> "(y/n)"), until an argument is
    // entered. cl_ghost_hint is the extensible registry and stays where it is.
    if hint := cl_ghost_hint(line_string(l, context.temp_allocator)); hint != "" {
        if clay.UI(clay.ID("st_hint"))({layout = {childAlignment = {y = .Center}}}) {
            clay.Text(hint, clay_text_config(th.muted, lh))
        }
    }
}

// The unsaved-edits-vs-disk-change hint, in the strip because the answer is a COMMAND: run
// `reload y` (re-read, losing edits) or `reload n` (keep + cache, stops asking until the file
// changes again). Shown while the conflict is pending and the CL is closed — e.g. you
// cancelled the auto-staged `reload ` line — and it stays up until answered or saved.
@(private = "file")
strip_declare_conflict :: proc(a: ^App, lh: i32) {
    th := &a.theme
    name := filepath.base(editor_current(&a.editor).path)
    if clay.UI(clay.ID("st_msg"))({layout = {childAlignment = {y = .Center}}}) {
        clay.Text(fmt.tprintf("%s changed on disk - ", name), clay_text_config(th.urgent, lh))
    }
    if clay.UI(clay.ID("st_keys"))({layout = {childAlignment = {y = .Center}}}) {
        clay.Text("run: reload y (lose edits) / reload n (keep mine)", clay_text_config(th.muted, lh))
    }
}

// The idle modeline: an emacs-style readout of the document pane. Three anchored labels — see
// the header for why they are anchored rather than laid out in a row.
//
// The right-hand readout is assembled as one string rather than as several elements because it
// is one THING (a status line), it is one colour, and splitting it would put four elements and
// three gaps in the tree to express what "   " already says.
@(private = "file")
strip_declare_status :: proc(a: ^App, lh: i32, pad: u16) {
    th := &a.theme
    dx := f32(pad)

    // No editor on screen (Full on the aux surface): just name the aux pane there. The root
    // and the right-hand readout are about a document, and there is no document up.
    if !panes_visible(a).editor {
        if clay.UI(clay.ID("st_left"))(strip_slot(.LeftCenter, dx)) {
            clay.Text(aux_mode_name(a.aux_mode), clay_text_config(th.muted, lh))
        }
        return
    }

    left, right: string
    left_col: [3]f32
    if a.main == .Image {
        // The main pane shows media, not a buffer, so the modeline reports the image: name,
        // pixel dimensions, zoom%. Nothing here has a line:col to report.
        m := &a.media
        left = fmt.tprintf("  %s", m.path == "" ? "(no image)" : filepath.base(m.path))
        left_col = th.muted
        right = fmt.tprintf("image   %dx%d   %d%%", m.w, m.h, int(m.zoom * 100 + 0.5))
    } else {
        b := editor_current(&a.editor)
        name := b.path == "" ? "untitled" : filepath.base(b.path)
        left = fmt.tprintf("%s %s", b.dirty ? "*" : " ", name) // a dirty buffer reads brighter
        left_col = b.dirty ? th.fg : th.muted
        head := b.cursors[b.primary].head
        nlines := len(b.lines)
        cursors := len(b.cursors) > 1 ? fmt.tprintf("   %d cursors", len(b.cursors)) : ""
        right = fmt.tprintf(
            "%s   L%d:%d   %d lines%s   %s",
            status_lang(a, b.path), head.line + 1, head.col + 1, nlines, cursors,
            scroll_label(head.line, nlines),
        )
    }

    if clay.UI(clay.ID("st_left"))(strip_slot(.LeftCenter, dx)) {
        clay.Text(left, clay_text_config(left_col, lh))
    }
    if clay.UI(clay.ID("st_right"))(strip_slot(.RightCenter, -dx)) {
        clay.Text(right, clay_text_config(th.muted, lh))
    }

    // Centre: the project root (~-abbreviated), so the `cd`-captured root the tools and `tu`
    // use is visible whenever the command line is not.
    if root := home_abbrev(a.project_root, context.temp_allocator); root != "" {
        if clay.UI(clay.ID("st_root"))(strip_slot(.CenterCenter, 0)) {
            clay.Text(root, clay_text_config(th.muted, lh))
        }
    }
}

// The strip alone in a window, as a command list: the test-facing wrapper (see
// filetree_layout for why every declared surface keeps one).
strip_layout :: proc(a: ^App, f: ^Font, strip: Rect, win_w, win_h: i32, now: f64 = 0) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        strip_declare(a, f, strip, now)
    }
    return clay.EndLayout(0)
}

// The strip's per-frame entry point. Shorter than any pane's, because a surface with no list,
// no viewport and no click has nothing to do before it declares itself — the template's first
// three phases are all about resolving a pointer against rows, and there are none here.
strip_frame :: proc(t: ^Text, a: ^App, strip: Rect, now: f64) {
    strip_declare(a, &t.font, strip, now)
}

// Abbreviate a leading $HOME to ~ for display (e.g. /home/me/src -> ~/src). Returns a borrowed
// slice of `path` when nothing changes, else a fresh string in `alloc`. Moved here from
// render.odin with the modeline that is its only caller.
@(private = "file")
home_abbrev :: proc(path: string, alloc := context.allocator) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && strings.has_prefix(path, home) {
        return strings.concatenate({"~", path[len(home):]}, alloc)
    }
    return path
}

// Modeline language label: the registry's name for the file's extension, else the bare
// extension, else "text" (unnamed / extension-less buffers).
@(private = "file")
status_lang :: proc(a: ^App, path: string) -> string {
    ext := strings.trim_prefix(filepath.ext(path), ".")
    if ext == "" {
        return "text"
    }
    if name, ok := grammar_for_ext(a.grammars, ext); ok {
        return name
    }
    return ext
}

// Emacs-style scroll indicator from the caret line: Top / Bot / All, else percent through the
// buffer.
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
