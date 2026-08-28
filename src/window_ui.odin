package main

import clay "../bindings/clay"
import "gfx"
import "ui"

// One Clay tree per frame, with the panes as floating siblings of a single `win_root` at their
// own rects. Clay holds exactly one tree, so a per-pane tree would leave PointerOver answering
// about whichever pane declared last. Three properties follow:
//
//   1. A pane's clip is its own element's. The root clip is the whole window, so a pane that
//      declares none paints its long filetree header into the editor.
//   2. Ids share a namespace, so every pane prefixes (`ft_`, `gp_`, `cf_`, `ed_`, `term_`).
//   3. Paint order is declaration order, after zIndex — what the overlays spend.
//
// compute_layout stays in layout.odin: `a.lay` must exist BEFORE the frame is declared, because
// the wheel, the drag machine and the scheduler ask it where the panes are between frames.

// Logical pixels either side of the gutter. 2px is fine to look at and unreasonable to hit, so
// the band is widened into each pane's inset — which is why it gets first refusal.
DIVIDER_GRAB :: 4

// A click on a divider must do nothing; without a threshold the split would snap to whatever
// pixel the press landed on, up to DIVIDER_GRAB away.
DIVIDER_DRAG_PX :: 3

// The gap IS the predicate: compute_layout leaves `gutter` px between side-by-side panes, zero
// in Zen, nothing when one is hidden. So Zen's boundary is not draggable.
divider_band :: proc(lay: Layout, scale: f32) -> (gfx.Rect, bool) {
    if !lay.vis.editor || !lay.vis.aux {
        return {}, false
    }
    right := lay.editor.x + lay.editor.w
    gap := lay.aux.x - right
    if gap <= 0 || lay.editor.h <= 0 {
        return {}, false
    }
    slop := max(i32(1), i32(DIVIDER_GRAB * scale))
    return gfx.Rect{right - slop, lay.editor.y, gap + 2 * slop, lay.editor.h}, true
}

// The inverse of compute_layout's `i32(f32(win_w) * split)`, clamped to Alt+[ / Alt+]'s range:
// a mouse must not reach a width the keyboard cannot.
divider_split_at :: proc(mx, win_w: i32) -> f32 {
    if win_w <= 0 {
        return SPLIT_MIN
    }
    return clampf(f32(mx) / f32(win_w), SPLIT_MIN, SPLIT_MAX)
}

// Taken before any pane declares: the band overlaps both panes' edges, so a divider asking
// second would be reachable only in the 2px of gutter it was widened to escape.
divider_click :: proc(a: ^App, lay: Layout) {
    u := ctx_of(a)
    if !a.mouse_on || !a.mouse.known {
        return
    }
    band, ok := divider_band(lay, a.scale)
    if !ok || !gfx.rect_hit(band, a.mouse.x, a.mouse.y) {
        return
    }
    if _, took := ui.mouse_take_click(u); !took {
        return
    }
    // No noun and no anchor: the press captured a single number, and there is no second grade
    // of "move the divider".
    ui.drag_begin(u, .Split, 0, 1, {}, 0)
}

// The frame's last word on `a.split`, hence before compute_layout. Snapped, not eased:
// SPLIT_DUR exists for Alt+[ / Alt+]'s 0.02 steps, and easing a drag would trail the cursor.
divider_drag :: proc(a: ^App, win_w: i32) {
    u := ctx_of(a)
    // drag_sweep buries a capture when the toggle goes off, but it runs at the END of a frame
    // and a config change arrives before one. Every per-frame drag verb asks this.
    if !a.mouse_on || !ui.drag_live(u, .Split, 0) {
        return
    }
    if !ui.drag_moved(u, DIVIDER_DRAG_PX) {
        return // still a click, which does nothing on a divider
    }
    a.split = divider_split_at(a.mouse.x, win_w)
    a.split_anim = ui.Anim {
        to = a.split,
    }
}

// ok=false for the gutter, the strip, or outside the window. wheel_target's twin: which pane a
// press landed in is a question the rects answer on their own.
click_focus_target :: proc(lay: Layout, mx, my: i32) -> (who: ui.Focus, ok: bool) {
    if gfx.rect_hit(lay.editor, mx, my) {
        return .Editor, true
    }
    if gfx.rect_hit(lay.aux, mx, my) {
        return .Aux, true
    }
    return .Editor, false
}

// Through set_focus, the choke point for the per-view-mode invariants. The press is not
// consumed: focusing and the pane's own verb are two things one press means. Gated on the focus
// changing, because set_focus re-stats the document.
focus_follows_click :: proc(a: ^App, lay: Layout) {
    if !a.mouse_on || !a.mouse.known || !a.mouse.click {
        return
    }
    who, ok := click_focus_target(lay, a.mouse.x, a.mouse.y)
    if !ok || a.focus == who {
        return
    }
    set_focus(a, who)
}

// In the order they have to run: the divider takes its press before any pane can, moves the
// split, then whatever is left decides which pane has the arrows. Called before compute_layout,
// on the pane rects it produced last frame.
window_pointer :: proc(a: ^App, win_w: i32) {
    // The popup takes only presses that MISS it: a click outside an open menu closes it and is
    // spent doing so. Inside its box the press falls through to ctxmenu_click.
    ctxmenu_dismiss_click(a)
    divider_click(a, a.lay)
    divider_drag(a, win_w)
    focus_follows_click(a, a.lay)
}

// A full-window container with no background, so it emits no command. Named once because the
// frame and each `<p>_layout` wrapper both declare it.
WIN_ROOT :: "win_root"



// The two must not be separated: Clay solves at the dimensions it currently holds, so a resize
// applied after BeginLayout lands a frame late.
clay_window_begin :: proc(win_w, win_h: i32) {
    ui.clay_resize(win_w, win_h)
    clay.BeginLayout()
}

// Shared with each `<p>_layout` wrapper, so tests declare the root the app declares.
clay_window_root :: proc(win_w, win_h: i32) -> clay.ElementDeclaration {
    return {layout = {sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))}}}
}

// Every live pane claims its click, moves its viewport and declares itself into one tree. The
// editor goes first so a press over the boundary is offered to it first.
window_frame :: proc(t: ^gfx.Text, a: ^App, lay: Layout, win_w, win_h: i32, now: f64) {
    clay_window_begin(win_w, win_h)

    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        switch a.main {
        case .Text:
            editor_frame(t, a, lay.editor, now)
        case .Image:
            media_frame(t, a, lay.editor)
        }
        switch a.aux_mode {
        case .FileTree:
            // Two presentations over one FileTree, so a branch here rather than a second
            // AuxMode: Alt+F and `:ls` reach the pane without knowing which is up.
            switch a.file_pane {
            case .Ls:
                filetree_frame(t, a, lay.aux, now)
            case .Browser:
                filebrowser_frame(t, a, lay.aux, now)
            }
        case .Config:
            config_frame(t, a, lay.aux, now)
        case .Terminal:
            terminal_frame(t, a, lay.aux, now)
        case .Grep:
            grep_frame(t, a, lay.aux)
        case .Binds:
            binds_frame(t, a, lay.aux)
        case .Color:
            color_frame(t, a, lay.aux)
        }
        strip_frame(t, a, lay.strip, now)
        // The popup outranks the overlays in turn, and is the only surface placed by the
        // pointer rather than the layout — hence no pane rect.
        ctxmenu_frame(t, a, win_w, win_h)
    }

    cmds := clay.EndLayout(0)
    ui.clay_paint(t, a, &cmds, gfx.Rect{0, 0, win_w, win_h}, win_w, win_h)
}
