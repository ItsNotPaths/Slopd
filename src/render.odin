package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import gl "vendor:OpenGL"

// Rendering: solid-colour quads (fill/caret) plus glyph text, both batched per pane
// (see text.odin). Every colour comes from the active Theme (a.theme); this file maps
// palette slots to UI usage:
//   border_dark -> window gutter / overlay bg   bg -> pane background
//   accent      -> focus outline / active item  border_light -> status strip
//   fg / muted  -> text (active / dim)           selection -> selected text
//   line_highlight -> current-line bar           separator -> filetree selection
//   code_return_type -> filetree directory rows  urgent -> ringed-file marker
//
// A pane appends its quads + glyphs, then calls flush_pane to composite and clip
// them in one go (under-quads -> glyphs -> carets). render() lays down the window
// background and the pane chrome first, then hands the panes to window_frame
// (window_ui.odin), which declares them all into ONE Clay tree and paints it in one pass.
//
// What is LEFT here is what has not been declared yet: the media surface, the two overlays
// and the status strip, each still hand-drawn and each with a C8 sub-checkpoint of its own
// (C8b the strip, C8c the overlays, C8d the media surface). They paint after window_frame,
// which is the order they were drawn in before.

aux_mode_name :: proc(m: AuxMode) -> string {
    switch m {
    case .FileTree:
        return "filetree"
    case .Terminal:
        return "terminal"
    case .Procmon:
        return "procmon"
    case .Config:
        return "config"
    case .Grep:
        return "grep"
    }
    return ""
}

inset :: proc(r: Rect, by: i32) -> Rect {
    return Rect{r.x + by, r.y + by, r.w - 2 * by, r.h - 2 * by}
}

// A hollow rectangle: four edge bars of `w` thickness inset just inside `r`, leaving
// whatever is already drawn there untouched (used for the command-line injection alert).
outline :: proc(t: ^Text, r: Rect, color: [3]f32, w: i32) {
    fill(t, Rect{r.x, r.y, r.w, w}, color)                 // top
    fill(t, Rect{r.x, r.y + r.h - w, r.w, w}, color)       // bottom
    fill(t, Rect{r.x, r.y, w, r.h}, color)                 // left
    fill(t, Rect{r.x + r.w - w, r.y, w, r.h}, color)       // right
}

// A pane: filled with bg, ringed with the focus colour when focused.
panel :: proc(t: ^Text, r: Rect, bg, focus: [3]f32, focused: bool, scale: f32) {
    if focused {
        fill(t, r, focus)
        fill(t, inset(r, i32(2 * scale)), bg)
    } else {
        fill(t, r, bg)
    }
}

render :: proc(a: ^App, t: ^Text, win_w, win_h: i32, now: f64) {
    th := &a.theme
    t.frame_verts = 0 // the perf log tallies this frame's submitted vertices
    // Viewport must track the framebuffer or the shaders (NDC -> viewport) distort
    // on resize.
    gl.Viewport(0, 0, win_w, win_h)

    // Window background — shows through the inter-pane gutter the panels leave.
    gl.Disable(gl.SCISSOR_TEST)
    gl.ClearColor(th.border_dark.r, th.border_dark.g, th.border_dark.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    lay := compute_layout(win_w, win_h, a, now)
    a.lay = lay // pointer events arriving before the next frame route against these rects

    // Clay is handed this frame's pointer before anything is declared — SetPointerState
    // resolves against the tree Clay already holds, so feeding it after the declarations
    // would hit-test one frame late (see docs/clay-refactor.md, C1). That tree is now the
    // whole WINDOW rather than whichever pane happened to declare last, which is what makes
    // every pane's PointerOver answer about itself (C8a).
    //
    // Clay tracks the framebuffer the way the GL viewport above does; window_frame does that
    // as it opens the tree, so it is not repeated here.
    mouse_feed_clay(a)

    // Chrome: both pane backgrounds/rings + the status strip, composited in one flush.
    panel(t, lay.editor, th.bg, th.accent, focus_ring(a, lay.vis, .Editor), a.scale)
    panel(t, lay.aux, th.bg, th.accent, focus_ring(a, lay.vis, .Aux), a.scale)
    fill(t, lay.strip, th.border_light)
    flush_pane(t, Rect{0, 0, win_w, win_h}, win_w, win_h)

    // Every live pane claims its click, moves its viewport and declares itself into ONE
    // tree, painted in one pass — window_ui.odin, C8a. The per-pane dispatch that used to
    // live here went with it, because "which panes exist this frame" is the window frame's
    // question and asking it in two places is how the two answers drift.
    window_frame(t, a, lay, win_w, win_h, now)

    // The media surface is the one pane still painted by hand: an image that is panned and
    // zoomed sits at an arbitrary rect inside its pane, which is a floating child rather
    // than a laid-out one, and that is a decision for C8d, which is where the pointer first
    // gets to move it. It guards on a zero rect internally (hidden under Full on the aux
    // surface) and does not overlap anything window_frame declared.
    if a.main == .Image {
        draw_media(t, lay.editor, win_w, win_h, a)
    }

    // Switcher overlay: plain Alt only. Alt+Ctrl / Alt+Shift drive the terminal
    // copy-cursor, so the switcher stays hidden then.
    if a.alt_held && !a.ctrl_held && !a.shift_held && a.aux_mode == .Terminal {
        draw_term_overlay(t, lay.aux, win_w, win_h, a, now)
    }

    // Filetree bottom overlay: the Ctrl-held chord cheat-sheet, inside the filetree pane
    // so the command-line strip is never co-opted.
    if a.aux_mode == .FileTree && a.ctrl_held && a.focus == .Aux {
        draw_filetree_overlay(t, lay.aux, win_w, win_h, a, now)
    }

    // Bottom status / command strip: the command line while active, else an
    // emacs-style modeline for the editor buffer. (The filetree chord bar is NOT
    // here — it overlays the filetree pane itself, see above.)
    if a.cl_active {
        draw_command_line(t, lay.strip, a, now)
    } else if a.focus == .Editor && a.main == .Text && editor_current(&a.editor).conflict {
        draw_conflict_prompt(t, lay.strip, a) // disk changed under unsaved edits: reload-vs-keep
    } else {
        draw_status(t, lay.strip, a)
    }
    flush_pane(t, lay.strip, win_w, win_h)

    // A press nobody claimed dies here. Clicks are offered to the panes as they draw
    // (mouse_take_click), and one that hit nothing must not survive into the next frame,
    // where the pointer may be over something else entirely — a click is an event at a
    // place, not a mode.
    a.mouse.click = false

    // And a drag whose button has come up has now had the extra frame it was owed, so it is
    // buried here for the same reason (drag.odin). Also the one place a capture can end
    // without a release: a pane that stopped drawing mid-gesture never sees its last frame,
    // and this still reaps it once the button is up.
    drag_sweep(a)
}

// Package-level, not file-private: the *_ui.odin panes declare their own chrome and need
// the same focused/unfocused text rule the hand-drawn panes use (see the tests invariant in
// docs/clay-refactor.md — anything a layout proc touches has to be reachable from tests).
focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// Whether `who` takes the focus ring this frame. The ring's whole job is to disambiguate
// which of TWO panes the arrows go to, so with a single pane on screen it is just a border
// around the window and is dropped. Hidden panes carry a zero rect and the draw guards skip
// them, so this is about what is VISIBLE, not about what exists.
//
// **Zen's editor never rings, and that is the case the plain `vis.editor && vis.aux` test
// gets wrong.** In Zen the aux pane is a transient reveal that is present exactly while it
// holds focus, so focusing the editor starts it RETRACTING — and for the length of that slide
// both panes are still visible while the editor grows toward the full width. Ringing it there
// paints an accent border around the entire window for a few frames, which is precisely the
// full-window border this proc exists to avoid; it just arrives one animation early. There is
// nothing to disambiguate either way, because in Zen the aux pane's presence IS the answer to
// "which pane is focused".
//
// The aux pane still rings in Zen, on the way in: while it slides over the editor the ring is
// what says the arrows now go there, and it is a real two-pane moment.
focus_ring :: proc(a: ^App, vis: Pane_Vis, who: Focus) -> bool {
    if !vis.editor || !vis.aux || a.focus != who {
        return false
    }
    return !(a.view == .Zen && who == .Editor)
}

// How far the hover tint travels from the pane background toward the selection bar. Well
// short of it on purpose: the pointer resting somewhere is not a selection, and a list with
// two equally loud bars in it is a list you have to read twice to find your place in.
HOVER_MIX :: 0.35

// The backdrop of the row under the pointer (open decision 5, settled in C5b: wanted, but
// subtle and toggleable — `hover: on|off`, App.hover_on). Every list pane reads this one
// proc, so the whole chrome agrees on what "the pointer is here" looks like.
//
// It MIXES rather than blending because the quad shader writes opaque: alpha is a
// visibility bit, not a blend factor (clay_render.odin), so a translucent wash has to be
// baked into the colour here or it does not exist at all.
hover_bg :: proc(th: ^Theme) -> [3]f32 {
    return th.bg + (th.separator - th.bg) * HOVER_MIX
}

// smooth_scroll lives in scroll.odin, beside the list viewport policy it animates: C5c's
// procmon pane needs it from procmon_ui.odin, and a layout proc cannot call something
// file-private to render.odin.

// draw_editor and its painters (the indent guides, the whitespace markers, the fold marker,
// the per-glyph colour runs, the gutter's two number helpers) moved to editor_ui.odin in
// C7, with the pane they serve: the body is a Clay `Custom` now, and a Custom's painter
// cannot be file-private to render.odin any more than a layout proc can. The proc itself is
// `editor_frame` since C8a, when the paint moved to the window and the name stopped fitting.

// `label` (a string at a pane's top-left) went with C8a's aux dispatch: it existed for the
// "unmigrated pane" placeholder render used to fall through to, and every aux mode is
// declared now, so the fall-through and its one caller are both gone.

// The command line as it lives in the status strip: prompt, the editable runes,
// a selection highlight, and a caret. Monospace makes every x pure arithmetic.
// The caller flushes the strip region after this returns.
draw_command_line :: proc(t: ^Text, strip: Rect, a: ^App, now: f64) {
    PROMPT :: "> "
    th := &a.theme
    l := &a.cl.lines[0] // the command line is one line
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    // A pristine injected (staged, not user-typed) line rings the strip in the alert
    // colour — "review this before Enter". Any edit bumps doc.version past the mark and
    // the ring clears itself, so no per-edit hook is needed.
    if a.cl.injected && a.cl.doc.version == a.cl.inject_ver {
        outline(t, strip, th.cl_inject, i32(2 * a.scale))
    }

    text_draw(t, PROMPT, f32(strip.x + pad), y, th.muted)
    ox := f32(strip.x + pad) + cw * f32(len(PROMPT)) // text origin, after the prompt

    // Selection spans, then text, then a caret per cursor (single-cursor = one).
    for c in a.cl.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            fill(t, Rect{i32(ox + cw * f32(lo.col)), i32(y), i32(cw * f32(hi.col - lo.col)), i32(lh)}, th.selection)
        }
    }

    text_draw_runes(t, l.text[:], ox, y, th.fg)

    // Ghosted per-command argument hint (e.g. `reload` -> "(y/n)"), one cell past the typed
    // text, until an argument is entered. cl_ghost_hint is the extensible registry.
    if hint := cl_ghost_hint(line_string(l, context.temp_allocator)); hint != "" {
        text_draw(t, hint, ox + cw * f32(len(l.text) + 1), y, th.muted)
    }

    if caret_blink_on(a, now) {
        for c in a.cl.cursors {
            caret(t, Rect{i32(ox + cw * f32(c.head.col)), i32(y), i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
}

// The media viewer: the decoded image fit into the pane (contain letterbox), zoomable
// and pannable. The pane bg + focus ring are already laid down by render's chrome pass,
// so this just blits the texture over it, clipped to the inset content area so a zoomed
// image never paints over the focus ring. The filename/dims/zoom show in the modeline.
@(private = "file")
draw_media :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    m := &a.media
    th := &a.theme
    area := inset(pane, i32(2 * a.scale))
    if area.w <= 0 || area.h <= 0 {
        return
    }
    if m.tex != 0 {
        image_push(t, m.tex, media_fit_rect(area, m.w, m.h, m.zoom, m.pan))
    } else {
        pad := i32(8 * a.scale)
        y := f32(area.y) + (f32(area.h) - t.font.line_height) / 2
        text_draw(t, "(no image)", f32(area.x + pad), y, th.muted)
    }
    flush_pane(t, area, win_w, win_h)
}

// The idle strip: an emacs-style modeline for the editor buffer. File name + a
// modified marker on the left (brighter when dirty); language, caret line:col, line
// count, any multi-cursor count, and a scroll indicator right-aligned. Monospace
// makes the right-alignment pure arithmetic. The caller flushes the strip region.
@(private = "file")
draw_status :: proc(t: ^Text, strip: Rect, a: ^App) {
    th := &a.theme
    cw := t.font.cell_w
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - t.font.line_height) / 2

    // No editor on screen (Full on the aux surface); just name the aux pane there.
    if !panes_visible(a).editor {
        text_draw(t, aux_mode_name(a.aux_mode), f32(strip.x + pad), y, th.muted)
        return
    }

    // Image surface: the main pane shows media, not a buffer — so the modeline reports
    // the image (name, pixel dimensions, zoom%) instead of line:col / language.
    if a.main == .Image {
        m := &a.media
        name := m.path == "" ? "(no image)" : filepath.base(m.path)
        text_draw(t, fmt.tprintf("  %s", name), f32(strip.x + pad), y, th.muted)
        right := fmt.tprintf("image   %dx%d   %d%%", m.w, m.h, int(m.zoom * 100 + 0.5))
        rx := f32(strip.x + strip.w - pad) - cw * f32(len(right))
        text_draw(t, right, rx, y, th.muted)
        root := home_abbrev(a.project_root, context.temp_allocator)
        if root != "" {
            rootx := f32(strip.x) + (f32(strip.w) - cw * f32(len(root))) / 2
            text_draw(t, root, rootx, y, th.muted)
        }
        return
    }

    b := editor_current(&a.editor)

    // Left: modified marker + file name (basename; "untitled" when unnamed).
    name := b.path == "" ? "untitled" : filepath.base(b.path)
    left := fmt.tprintf("%s %s", b.dirty ? "*" : " ", name)
    text_draw(t, left, f32(strip.x + pad), y, b.dirty ? th.fg : th.muted)

    // Right (right-aligned): lang   Lline:col   N lines   [N cursors]   scroll. All
    // ASCII, so the byte length is the cell count for placement.
    head := b.cursors[b.primary].head
    nlines := len(b.lines)
    pos := fmt.tprintf("L%d:%d", head.line + 1, head.col + 1)
    cursors := len(b.cursors) > 1 ? fmt.tprintf("   %d cursors", len(b.cursors)) : ""
    right := fmt.tprintf(
        "%s   %s   %d lines%s   %s",
        status_lang(a, b.path), pos, nlines, cursors, scroll_label(head.line, nlines),
    )
    rx := f32(strip.x + strip.w - pad) - cw * f32(len(right))
    text_draw(t, right, rx, y, th.muted)

    // Center: the project root (~-abbreviated), so the `cd`-captured root the tools
    // and `tu` use is always visible while the command line is idle.
    root := home_abbrev(a.project_root, context.temp_allocator)
    if root != "" {
        rootx := f32(strip.x) + (f32(strip.w) - cw * f32(len(root))) / 2
        text_draw(t, root, rootx, y, th.muted)
    }
}

// The filetree's bottom overlay, sitting INSIDE the filetree pane (never the command
// strip): the Ctrl-held chord cheat-sheet. A filled bar anchored to the pane bottom; the
// chord list left-flows and wraps to as many rows as the (possibly narrow) pane needs.
// Colours fade up from the pane bg via chord_anim, the Ctrl-hold analogue of the terminal
// switcher fade.
@(private = "file")
draw_filetree_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale)) // sit inside the focus outline
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := i32(lh) + i32(6 * a.scale)
    pad := i32(8 * a.scale)

    // Opaque lerp out of the pane bg (so no alpha is needed) as Ctrl is held.
    f := clamp(anim_value(&a.chord_anim, now), 0, 1)
    bar_bg := lerp3(th.bg, th.border_dark, f)
    key_col := lerp3(th.bg, th.accent, f)
    lbl_col := lerp3(th.bg, th.muted, f)

    // Keys carry a "^" so the bar reads as the Ctrl menu; the state readout (paste mode +
    // marked count) is the final flow item, so it wraps with everything else.
    hints := [?][2]string {
        {"^y", "yank"},
        {"^u", "reset"},
        {"^c", "copy"},
        {"^x", "cut"},
        {"^p", "paste"},
        {"^d", "del"},
        {"^D", "del-set"},
        {"^w", "path"},
        {"^W", "dir"},
    }
    mode := a.tree.yank_mode == .Cut ? "cut" : "copy"
    state := fmt.tprintf("[%s · %d marked]", mode, len(a.tree.yanked))

    // Pack items (each "key label", plus the state) into rows of the available width,
    // recording each item's row + start column. cur_x in cells; GAP cells between items.
    GAP :: 2
    maxw := max(1, int(f32(area.w - 2 * pad) / cw))
    item_w: [len(hints) + 1]int
    for h, i in hints {
        item_w[i] = len(h[0]) + 1 + len(h[1]) // key + space + label (ASCII: bytes == cells)
    }
    item_w[len(hints)] = len(state) // "·" is multi-byte but renders one cell — close enough for layout
    row_of: [len(hints) + 1]int
    x_of: [len(hints) + 1]int
    cur_row, cur_x := 0, 0
    for w, i in item_w {
        if cur_x > 0 && cur_x + w > maxw {
            cur_row += 1
            cur_x = 0
        }
        row_of[i] = cur_row
        x_of[i] = cur_x
        cur_x += w + GAP
    }
    nrows := cur_row + 1

    bar_h := i32(nrows) * row_h
    by := area.y + area.h - bar_h
    fill(t, Rect{area.x, by, area.w, bar_h}, bar_bg)

    item_xy :: proc(area: Rect, by, row_h, pad: i32, cw, lh: f32, col, row: int) -> (x, y: f32) {
        return f32(area.x + pad) + cw * f32(col), f32(by + i32(row) * row_h) + (f32(row_h) - lh) / 2
    }
    for h, i in hints {
        x, y := item_xy(area, by, row_h, pad, cw, lh, x_of[i], row_of[i])
        text_draw(t, h[0], x, y, key_col)
        text_draw(t, h[1], x + cw * f32(len(h[0]) + 1), y, lbl_col)
    }
    sx, sy := item_xy(area, by, row_h, pad, cw, lh, x_of[len(hints)], row_of[len(hints)])
    text_draw(t, state, sx, sy, lbl_col)

    flush_pane(t, area, win_w, win_h)
}

// The unsaved-edits-vs-disk-change hint, shown IN the command strip (taking the place of
// the idle modeline) when the conflict is pending but the CL is closed — e.g. you cancelled
// the auto-staged `reload ` line. Rung in the alert colour, it reminds you the answer is a
// command: run `reload y` (re-read, losing edits) or `reload n` (keep + cache, stops asking
// until the file changes again). It stays up until answered or the file is saved. The caller
// flushes the strip region.
@(private = "file")
draw_conflict_prompt :: proc(t: ^Text, strip: Rect, a: ^App) {
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    pad := i32(8 * a.scale)
    y := f32(strip.y) + (f32(strip.h) - lh) / 2

    outline(t, strip, th.cl_inject, i32(2 * a.scale)) // ring it like a staged line — needs a decision

    name := filepath.base(editor_current(&a.editor).path)
    msg := fmt.tprintf("%s changed on disk - ", name) // ASCII only: byte length == cell count for placement
    keys := "run: reload y (lose edits) / reload n (keep mine)"
    text_draw(t, msg, f32(strip.x + pad), y, th.urgent)
    text_draw(t, keys, f32(strip.x + pad) + cw * f32(len(msg)), y, th.muted)
}

// Abbreviate a leading $HOME to ~ for display (e.g. /home/me/src -> ~/src). Returns a
// borrowed slice of `path` when nothing changes, else a fresh string in `alloc`.
@(private = "file")
home_abbrev :: proc(path: string, alloc := context.allocator) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && strings.has_prefix(path, home) {
        return strings.concatenate({"~", path[len(home):]}, alloc)
    }
    return path
}

// Modeline language label: the registry's name for the file's extension, else the
// bare extension, else "text" (unnamed/extension-less buffers).
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

// Emacs-style scroll indicator from the caret line: Top / Bot / All, else percent
// through the buffer.
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

// filetree_frame lives in filetree_ui.odin: the filetree is declared in Clay (C3), so its
// geometry, its hit-testing and its paint are one tree rather than three copies of the
// same arithmetic. Its Ctrl-chord overlay is still hand-drawn and stays here until C8c.

// grep_frame lives in grep_ui.odin: the results pane is declared in Clay (C5a), and its
// display-row flattening moved to grep.odin, where the model it flattens already lives.

// procmon_frame lives in procmon_ui.odin: the process monitor is declared in Clay (C5c),
// with its graph band and its live filter bar as the first Custom surfaces outside the
// editor and the terminal.

// terminal_frame lives in terminal_ui.odin: the cell grid is declared in Clay (C7b) as one
// Custom, with the pointer either forwarded to a mouse-tracking TUI or driving our own copy
// cursor. Its Alt-held switcher overlay is still hand-drawn and stays here until C8c.

// The terminal switcher: a slim i3-style numbered column shown while Alt is held.
// It is inset within the pane's focus outline (so it sits seamlessly inside the
// highlight rather than covering it), two digits wide, and scrolls to keep the
// active session visible. Drawn as its own flush, on top of the aux content.
draw_term_overlay :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App, now: f64) {
    th := &a.theme
    area := inset(pane, i32(2 * a.scale)) // sit inside the focus outline
    if area.w <= 0 || area.h <= 0 {
        return
    }
    cw := t.font.cell_w
    lh := t.font.line_height
    colw := min(i32(cw * 2) + i32(12 * a.scale), area.w) // two digits + padding
    row_h := i32(lh) + i32(6 * a.scale)

    // Fade in from the pane background (opaque lerp, so no alpha needed): every colour
    // tweens out of th.bg as the switcher appears while Alt is held.
    f := clamp(anim_value(&a.switcher_anim, now), 0, 1)
    col_bg := lerp3(th.bg, th.border_dark, f)
    col_active := lerp3(th.bg, th.accent, f)
    col_fg := lerp3(th.bg, th.fg, f)
    col_lock := lerp3(th.bg, th.muted, f) // a locked session's number is greyed (Alt+L)

    // Scroll so the active session stays centered, clamped at the list ends.
    n := term_count(a)
    max_rows := max(1, int(area.h / row_h))
    first := clamp(a.term_active - max_rows / 2, 0, max(0, n - max_rows))
    visible := min(n - first, max_rows)

    fill(t, Rect{area.x, area.y, colw, i32(visible) * row_h}, col_bg)

    for k in 0 ..< visible {
        i := first + k
        y := area.y + i32(k) * row_h
        if i == a.term_active {
            fill(t, Rect{area.x, y, colw, row_h}, col_active)
        }
        buf: [8]u8
        s := strconv.write_int(buf[:], i64(i + 1), 10)
        tx := f32(area.x) + (f32(colw) - cw * f32(len(s))) / 2 // centered
        ty := f32(y) + (f32(row_h) - lh) / 2
        text_draw(t, s, tx, ty, a.terminals[i].locked ? col_lock : col_fg)
    }

    flush_pane(t, area, win_w, win_h)
}
