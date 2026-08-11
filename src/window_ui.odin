package main

import clay "../bindings/clay"

// The window frame: ONE Clay tree per frame, with the panes as FLOATING siblings of a single
// `win_root`, each attached to the root at its own rect. Clay holds exactly one tree, so a
// per-pane tree would leave PointerOver answering about whichever pane declared last.
//
// Three properties that follow, each of which a pane depends on:
//
//   1. **A pane's clip is the pane element's own.** The root clip is the whole window, so each
//      pane declares `clip` on its own box or a long filetree header paints into the editor.
//   2. **Ids share a namespace.** Every pane prefixes (`ft_`, `gp_`, `cf_`, `ed_`, `term_`).
//   3. **Paint order is declaration order**, after zIndex — what the overlays spend: each is a
//      floating child of the pane it covers at OVERLAY_Z, so it outranks the strip declared
//      after it (overlay_ui.odin).
//
// compute_layout stays in layout.odin: `a.lay` must exist BEFORE the frame is declared, because
// the wheel, the drag machine and the scheduler all ask it where the panes are, between frames.

// How far either side of the gutter counts as the divider, in logical pixels. The gutter is 2px
// — fine to LOOK at, unreasonable to hit — so the grab band is widened symmetrically and eats a
// couple of pixels of each pane's inset, which is why it gets first refusal (window_pointer).
DIVIDER_GRAB :: 4

// How far a press must travel before it is a DRAG rather than a click on the divider. A
// click on a divider must do NOTHING; without this the split would snap to whatever pixel
// the press landed on, up to DIVIDER_GRAB pixels from where the divider actually is.
DIVIDER_DRAG_PX :: 3

// The band a press has to land in to grab the divider, and whether there is one at all. **The
// gap IS the predicate**: compute_layout leaves `gutter` px between side-by-side panes, zero in
// Zen, nothing when one is hidden. So Zen's boundary is not draggable — under it is the editor.
divider_band :: proc(lay: Layout, scale: f32) -> (Rect, bool) {
    if !lay.vis.editor || !lay.vis.aux {
        return {}, false
    }
    right := lay.editor.x + lay.editor.w
    gap := lay.aux.x - right
    if gap <= 0 || lay.editor.h <= 0 {
        return {}, false
    }
    slop := max(i32(1), i32(DIVIDER_GRAB * scale))
    return Rect{right - slop, lay.editor.y, gap + 2 * slop, lay.editor.h}, true
}

// Where the divider's centre would put the split, from a pointer x — the inverse of
// compute_layout's `i32(f32(win_w) * split)`. Clamped to the range Alt+`[` / Alt+`]` clamp
// to: same setting, and a mouse must not reach a width the keyboard cannot.
divider_split_at :: proc(mx, win_w: i32) -> f32 {
    if win_w <= 0 {
        return SPLIT_MIN
    }
    return clampf(f32(mx) / f32(win_w), SPLIT_MIN, SPLIT_MAX)
}

// Claim a press on the divider. Taken BEFORE any pane declares (window_pointer), the only
// order that works: the grab band overlaps both panes' edges, so a divider that asked second
// would be reachable only in the 2px of gutter it was widened to escape.
divider_click :: proc(a: ^App, lay: Layout) {
    if !a.mouse_on || !a.mouse.known {
        return
    }
    band, ok := divider_band(lay, a.scale)
    if !ok || !rect_hit(band, a.mouse.x, a.mouse.y) {
        return
    }
    if _, took := mouse_take_click(a); !took {
        return
    }
    // No noun to resolve and no anchor to store: the press captured a single number. The
    // count goes in unread — there is no second grade of "move the divider".
    drag_begin(a, .Split, 0, 1, {}, 0)
}

// Move the split to follow a live divider drag — the frame's last word on `a.split`, hence
// before compute_layout. **SNAPPED, not eased**: SPLIT_DUR exists because Alt+`[`/`]` step by
// 0.02; easing a drag would trail the cursor, so the tween is re-aimed at its own destination.
divider_drag :: proc(a: ^App, win_w: i32) {
    // The `mouse_on` guard is belt to drag_sweep's braces: the sweep buries a capture when
    // the toggle goes off, but it runs at the END of a frame and a config change arrives
    // before one. Every per-frame drag verb asks the same question.
    if !a.mouse_on || !drag_live(a, .Split, 0) {
        return
    }
    if !drag_moved(a, DIVIDER_DRAG_PX) {
        return // still a click, and a click on a divider does nothing at all
    }
    a.split = divider_split_at(a.mouse.x, win_w)
    a.split_anim = Anim {
        to = a.split,
    }
}

// Which pane a pending press would focus, or ok=false for the gutter, the strip, or outside
// the window. The twin of wheel_target: a click resolves to a ROW only once a pane draws,
// but which PANE it landed in is a question the rects answer on their own.
click_focus_target :: proc(lay: Layout, mx, my: i32) -> (who: Focus, ok: bool) {
    if rect_hit(lay.editor, mx, my) {
        return .Editor, true
    }
    if rect_hit(lay.aux, mx, my) {
        return .Aux, true
    }
    return .Editor, false
}

// Focus follows the click, through `set_focus` (app.odin), the single choke point for focus's
// per-view-mode invariants. **The press is not CONSUMED** — focusing and the pane's own verb
// are two things one press means. Gated on the focus CHANGING: set_focus re-stats the document.
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

// The window's own pointer verbs, in the order they have to run: the divider takes its press
// before any pane can, moves the split, then whatever press is left decides which pane has the
// arrows. **Called before compute_layout** — these act on the pane RECTS, which are its output.
window_pointer :: proc(a: ^App, win_w: i32) {
    // The popup gets first refusal on a press, and takes only the ones that MISS it: a click
    // outside an open menu closes it and is spent doing so, or the same press would also select
    // a row under a menu the user was only dismissing. Inside its box the press falls through to
    // ctxmenu_click, which is declared last and hit-tests its own items.
    ctxmenu_dismiss_click(a)
    divider_click(a, a.lay)
    divider_drag(a, win_w)
    focus_follows_click(a, a.lay)
}

// The root every pane attaches to: a full-window container with no background, so it emits no
// command of its own. Named once because the frame and each `<p>_layout` wrapper both declare
// it, and a floating child with no root is not laid out at all.
WIN_ROOT :: "win_root"

// A pane's placement in the window tree: floating at its own rect, attached to the root by the
// top-left corner so the offset IS the pane's origin in framebuffer pixels. Passthrough: panes
// do not occlude each other, and one that captured would stop the root answering for the gutter.
clay_pane_float :: proc(area: Rect) -> clay.FloatingElementConfig {
    return {
        attachTo           = .Root,
        offset             = {f32(area.x), f32(area.y)},
        attachment         = {element = .LeftTop, parent = .LeftTop},
        pointerCaptureMode = .Passthrough,
    }
}

// The pane box every `<p>_declare` opens with: fixed to the pane's content area, floating at
// its origin, clipping its own content, stacking children downward. One call, so the six
// panes cannot disagree about it.
clay_pane_box :: proc(area: Rect) -> clay.ElementDeclaration {
    return {
        layout = {
            sizing          = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
            layoutDirection = .TopToBottom,
        },
        floating = clay_pane_float(area),
        clip     = {horizontal = true, vertical = true},
    }
}

// Open a frame: track the framebuffer, then start the tree. The two must not be separated —
// Clay solves the tree at the dimensions it currently holds, so a resize applied after
// BeginLayout lands one frame late.
clay_window_begin :: proc(win_w, win_h: i32) {
    clay_resize(win_w, win_h)
    clay.BeginLayout()
}

// The root declaration, shared with each `<p>_layout` wrapper — the root the tests declare
// had better be the root the app declares.
clay_window_root :: proc(win_w, win_h: i32) -> clay.ElementDeclaration {
    return {layout = {sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))}}}
}

// The frame: every live pane claims its click, moves its viewport and declares itself into ONE
// tree, painted in one pass. The editor is declared before the aux pane so a press over the
// boundary is offered to it first; the main surfaces are a `switch` — exactly one is on screen.
window_frame :: proc(t: ^Text, a: ^App, lay: Layout, win_w, win_h: i32, now: f64) {
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
            // One aux mode, two presentations (config `file_pane`) over the same FileTree —
            // which is why this is a branch here rather than a fifth AuxMode: Alt+F, the `ls`
            // builtin and --util all reach the pane without knowing which one is up.
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
        }
        // The strip declares last; the overlays outrank it by zIndex (overlay_ui.odin).
        strip_frame(t, a, lay.strip, now)
        // Except the popup, which outranks the overlays in turn and is the only surface placed
        // by the POINTER rather than by the layout — hence a window-level declaration with no
        // pane rect to be handed (contextmenu_ui.odin).
        ctxmenu_frame(t, a, win_w, win_h)
    }

    cmds := clay.EndLayout(0)
    clay_paint(t, a, &cmds, Rect{0, 0, win_w, win_h}, win_w, win_h)
}
