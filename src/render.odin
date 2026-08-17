package main

import gl "vendor:OpenGL"

// Solid-colour quads plus glyph text, batched per pane (text.odin). Every colour comes from
// a.theme; the palette maps to UI usage as:
//   border_dark -> window gutter / overlay bg   bg -> pane background
//   accent      -> focus outline / active item  border_light -> status strip
//   fg / muted  -> text (active / dim)           selection -> selected text
//   line_highlight -> current-line bar           separator -> filetree selection
//   code_return_type -> filetree directory rows  urgent -> ringed-file marker
//
// A pane appends its quads and glyphs, then flush_pane composites and clips them in one go.
// Every surface is declared by its own *_ui.odin into the ONE Clay tree window_frame paints;
// what is left here is the window background, the pane backdrops, and the frame's order.

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
    case .Color:
        return "color"
    }
    return ""
}

inset :: proc(r: Rect, by: i32) -> Rect {
    return Rect{r.x + by, r.y + by, r.w - 2 * by, r.h - 2 * by}
}

// Four edge bars of `w` thickness just inside `r`, leaving the middle untouched.
outline :: proc(t: ^Text, r: Rect, color: [3]f32, w: i32) {
    fill(t, Rect{r.x, r.y, r.w, w}, color)                 // top
    fill(t, Rect{r.x, r.y + r.h - w, r.w, w}, color)       // bottom
    fill(t, Rect{r.x, r.y, w, r.h}, color)                 // left
    fill(t, Rect{r.x + r.w - w, r.y, w, r.h}, color)       // right
}

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
    // Must track the framebuffer or the shaders distort on resize.
    gl.Viewport(0, 0, win_w, win_h)

    // Shows through the inter-pane gutter the panels leave.
    gl.Disable(gl.SCISSOR_TEST)
    gl.ClearColor(th.border_dark.r, th.border_dark.g, th.border_dark.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    // Before the layout is solved, because what they write is what compute_layout reads:
    // `a.split` is its input and focus decides which panes exist. Resolves against `a.lay`.
    window_pointer(a, win_w)

    lay := compute_layout(win_w, win_h, a, now)
    a.lay = lay // pointer events before the next frame route against these

    // Before anything is declared: SetPointerState resolves against the tree Clay already
    // holds, so feeding it afterwards hit-tests a frame late.
    mouse_feed_clay(a)

    // Both pane backgrounds and rings in one flush. The strip has no panel(): the element
    // owning that region paints it (strip_ui.odin).
    panel(t, lay.editor, th.bg, th.accent, focus_ring(a, lay.vis, .Editor), a.scale)
    panel(t, lay.aux, th.bg, th.accent, focus_ring(a, lay.vis, .Aux), a.scale)
    flush_pane(t, Rect{0, 0, win_w, win_h}, win_w, win_h)

    // Every live pane claims its click, moves its viewport and declares itself into one tree,
    // painted in one pass.
    window_frame(t, a, lay, win_w, win_h, now)

    // A press nobody claimed dies here: a click is an event at a place, not a mode, and the
    // pointer may be over something else next frame.
    a.mouse.click = false
    a.mouse.rclick = false

    // The extra frame a released drag was owed (drag.odin). Also the one place a capture can
    // end without a release: a pane that stopped drawing mid-gesture never sees its last frame.
    drag_sweep(a)
}

focus_fg :: proc(a: ^App, who: Focus) -> [3]f32 {
    return a.focus == who ? a.theme.fg : a.theme.muted
}

// The ring says which of two panes the arrows go to. Zen's editor never rings: focusing it
// starts the aux pane retracting, and both are visible for that slide.
focus_ring :: proc(a: ^App, vis: Pane_Vis, who: Focus) -> bool {
    if !vis.editor || !vis.aux || a.focus != who {
        return false
    }
    return !(a.view == .Zen && who == .Editor)
}

// How far the hover tint travels from the background toward the selection bar. Well short on
// purpose: the pointer resting somewhere is not a selection.
HOVER_MIX :: 0.35

// The row under the pointer (`hover: on|off`). Mixes rather than blends: the quad shader
// writes opaque, so a translucent wash has to be baked into the colour.
hover_bg :: proc(th: ^Theme) -> [3]f32 {
    return th.bg + (th.separator - th.bg) * HOVER_MIX
}

// Each pane's geometry, hit-testing and paint live in its own *_ui.odin file.
