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
// A pane appends its quads + glyphs, then calls flush_pane to composite and clip them in one go
// (under-quads -> glyphs -> carets). Nothing is hand-drawn here: every surface is declared by
// its own *_ui.odin file into the ONE Clay tree window_frame paints. What is left is the window
// background, the two pane backdrops with their focus rings, and the frame's order.

aux_mode_name :: proc(m: AuxMode) -> string {
    switch m {
    case .FileTree:
        return "filetree"
    case .Terminal:
        return "terminal"
    case .Config:
        return "config"
    case .Grep:
        return "grep"
    case .Binds:
        return "binds"
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

    // The window's own pointer verbs (divider drag, focus-follows-click) run BEFORE the layout
    // is solved, because what they write is what compute_layout reads: `a.split` is its input
    // and focus decides which panes exist. They resolve against `a.lay`, the last frame's.
    window_pointer(a, win_w)

    lay := compute_layout(win_w, win_h, a, now)
    a.lay = lay // pointer events arriving before the next frame route against these rects

    // Clay gets this frame's pointer before anything is declared: SetPointerState resolves
    // against the tree Clay already holds, so feeding it afterwards hit-tests a frame late.
    mouse_feed_clay(a)

    // Chrome: both pane backgrounds and their focus rings, composited in one flush. The
    // strip has no panel() — the element that owns that region paints it (strip_ui.odin).
    panel(t, lay.editor, th.bg, th.accent, focus_ring(a, lay.vis, .Editor), a.scale)
    panel(t, lay.aux, th.bg, th.accent, focus_ring(a, lay.vis, .Aux), a.scale)
    flush_pane(t, Rect{0, 0, win_w, win_h}, win_w, win_h)

    // Every live pane claims its click, moves its viewport and declares itself into ONE
    // tree, painted in one pass. "Which panes exist this frame" is the window frame's
    // question; asking it in two places is how the two answers drift.
    window_frame(t, a, lay, win_w, win_h, now)

    // A press nobody claimed dies here. Clicks are offered to the panes as they draw
    // (mouse_take_click), and one that hit nothing must not survive into the next frame, where
    // the pointer may be over something else — a click is an event at a place, not a mode.
    a.mouse.click = false
    a.mouse.rclick = false // the right press is an event at a place too (contextmenu.odin)

    // A drag whose button has come up has now had the extra frame it was owed (drag.odin).
    // Also the one place a capture can end without a release: a pane that stopped drawing
    // mid-gesture never sees its last frame, and this still reaps it once the button is up.
    drag_sweep(a)
}

// The focused/unfocused text rule, shared by every pane's declaration.
focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// Whether `who` takes the focus ring this frame. The ring disambiguates which of TWO panes the
// arrows go to. Zen's editor never rings: focusing it starts the aux pane RETRACTING, and for
// that slide both are visible, so `vis.editor && vis.aux` alone would ring the whole window.
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

// The backdrop of the row under the pointer (`hover: on|off`, App.hover_on). Every list pane
// reads this one proc, so the whole chrome agrees on it. It MIXES rather than blends: the quad
// shader writes opaque, so a translucent wash must be baked into the colour (clay_render.odin).
hover_bg :: proc(th: ^Theme) -> [3]f32 {
    return th.bg + (th.separator - th.bg) * HOVER_MIX
}

// Each pane's geometry, hit-testing and paint live together in its own *_ui.odin file:
// editor_ui, terminal_ui, filetree_ui, grep_ui, config_ui, media_ui, strip_ui, and the two
// overlays in overlay_ui. smooth_scroll is scroll.odin's, beside the policy it animates.
