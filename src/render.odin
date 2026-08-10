package main

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
// What is LEFT here is the media surface, the only thing in the program still hand-drawn: a
// panned and zoomed image sits at an arbitrary rect inside its pane, which is a floating child
// rather than a laid-out one, and that is C8d's decision to make. It paints after window_frame,
// which is the order it was drawn in before. The status strip went in C8b (strip_ui.odin) and
// the terminal switcher and filetree chord bar in C8c (overlay_ui.odin), where they are
// declared by the panes they cover rather than painted over the top of them.

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

    // Chrome: both pane backgrounds and their focus rings, composited in one flush. The
    // strip's own fill went with it into the tree (C8b): there is no panel() down there, so
    // the element that owns the region paints it.
    panel(t, lay.editor, th.bg, th.accent, focus_ring(a, lay.vis, .Editor), a.scale)
    panel(t, lay.aux, th.bg, th.accent, focus_ring(a, lay.vis, .Aux), a.scale)
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

    // The two overlays went into the tree in C8c (overlay_ui.odin): each is declared by the
    // pane it covers, so the switcher and the chord bar are painted by window_frame above,
    // above their pane and inside its clip. Nothing is drawn after it here any more except
    // the media surface, which overlaps nothing.

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

// The command line, the idle modeline and the conflict prompt all moved to strip_ui.odin in
// C8b, with `home_abbrev`, `status_lang` and `scroll_label`, which only the modeline used. The
// strip is declared in Clay now — the last surface in the program that was not, and the one
// that had to wait for C8a's single tree, since a strip declared while every pane held its own
// would have ended each frame holding the tree the panes hit-test against.

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

// filetree_frame lives in filetree_ui.odin: the filetree is declared in Clay (C3), so its
// geometry, its hit-testing and its paint are one tree rather than three copies of the
// same arithmetic. Its Ctrl-chord overlay went with C8c and is declared by the pane itself.

// grep_frame lives in grep_ui.odin: the results pane is declared in Clay (C5a), and its
// display-row flattening moved to grep.odin, where the model it flattens already lives.

// procmon_frame lives in procmon_ui.odin: the process monitor is declared in Clay (C5c),
// with its graph band and its live filter bar as the first Custom surfaces outside the
// editor and the terminal.

// terminal_frame lives in terminal_ui.odin: the cell grid is declared in Clay (C7b) as one
// Custom, with the pointer either forwarded to a mouse-tracking TUI or driving our own copy
// cursor. Its Alt-held switcher overlay went with C8c and is declared by the pane itself.

// draw_term_overlay and draw_filetree_overlay are overlay_ui.odin's `switcher_declare` and
// `chord_declare` since C8c — the last two hand-drawn surfaces that were not the media
// viewer. Both are declared INSIDE the pane they cover, which is what gives them the pane's
// clip and a scissor group of their own; see that file's header for why a clip group is what
// an overlay is, in a renderer where quads paint under glyphs within one.
