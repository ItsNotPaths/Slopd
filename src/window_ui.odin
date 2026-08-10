package main

import clay "../bindings/clay"

// The window frame — C8a, and the checkpoint that retires the refactor's most annoying rule.
//
// Until here, EVERY PANE DECLARED ITS OWN TREE: six `<p>_layout` procs, each opening with
// BeginLayout and closing with EndLayout, each painted by its own clay_paint. Clay holds
// exactly one tree, so the last one declared is the only one that survives the frame — and
// SetPointerState (fed at the top of render, before anything is declared) resolves against
// whatever that was. The list panes worked because the aux pane happened to declare LAST;
// the editor drew first, asked Clay, and got `false` for every element it owned, forever.
// That was rule 11 in docs/clay-refactor.md, and it was a rule about DRAW ORDER masquerading
// as a rule about hit-testing.
//
// Now there is one tree per frame and PointerOver means what it looks like it means. The
// panes are FLOATING siblings of a single `win_root`, each attached to the root at its own
// rect — which is also what finally deletes the "full-window container padded by the pane's
// origin" trick every pane carried, with a comment apologising for it and pointing here.
//
// Three consequences worth stating, because each replaces something a pane used to do:
//
//   1. **A pane's clip is now the pane element's own.** clay_paint used to be handed the
//      pane rect as its root clip, which is what kept a long filetree header from painting
//      into the editor. With one paint over the whole window that root is the window, so
//      each pane declares `clip` on its own box. Same scissor, same pixels, stated where the
//      box is instead of at the call site.
//   2. **Ids share a namespace.** Six trees could not collide; one can. Every pane already
//      prefixes (`ft_`, `gp_`, `cf_`, `pm_`, `ed_`, `term_`), and at most two panes are
//      declared per frame anyway — but it is now a property to keep rather than a freebie.
//   3. **Paint order is declaration order.** Floating elements sort by zIndex and then by
//      declaration, so the editor is declared before the aux pane and both before anything
//      at a higher z. The panes never overlap, so this buys nothing today; it is what the
//      overlays (C8c) are going to spend.
//
// What did NOT move: compute_layout. The window's ARITHMETIC is still layout.odin's, because
// `a.lay` has to exist before the frame is declared — the wheel, the drag machine and the
// scheduler all ask it where the panes are, and they ask between frames. Clay places the
// panes where compute_layout put them; it does not decide where that is. A genuinely
// declarative split is a different job, and it is not one this refactor needs.

// The root every pane attaches to: a full-window container with no background, so it emits
// no command of its own. Named once because both the frame below and each pane's test-facing
// `<p>_layout` wrapper declare it, and a floating child with no root to attach to is not laid
// out at all.
WIN_ROOT :: "win_root"

// A pane's placement in the window tree: floating at its own rect, attached to the root by
// the top-left corner so the offset IS the pane's origin in framebuffer pixels.
//
// Passthrough, deliberately: panes do not occlude each other (compute_layout leaves a gutter
// between them and gives a hidden pane a zero rect), so nothing is gained by having one
// swallow the pointer, and a pane that captured would stop the root answering for the gutter.
// Capture is the OVERLAYS' tool — an overlay's whole job is to stop what it covers from
// answering — and it is spent there, in C8c.
clay_pane_float :: proc(area: Rect) -> clay.FloatingElementConfig {
    return {
        attachTo = .Root,
        offset = {f32(area.x), f32(area.y)},
        attachment = {element = .LeftTop, parent = .LeftTop},
        pointerCaptureMode = .Passthrough,
    }
}

// The pane box every `<p>_declare` opens with: fixed to the pane's content area, floating at
// its origin, clipping its own content, stacking children downward. Six panes agreeing about
// this by construction is the same argument as `<p>_geom` — one call, no way to disagree.
clay_pane_box :: proc(area: Rect) -> clay.ElementDeclaration {
    return {
        layout = {
            sizing = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
            layoutDirection = .TopToBottom,
        },
        floating = clay_pane_float(area),
        clip = {horizontal = true, vertical = true},
    }
}

// Open a frame: track the framebuffer, then start the tree. Two lines, but they are the two
// that must not be separated — Clay solves the tree it is about to be given at the dimensions
// it currently holds, so a resize applied after BeginLayout lands one frame late.
clay_window_begin :: proc(win_w, win_h: i32) {
    clay_resize(win_w, win_h)
    clay.BeginLayout()
}

// The root declaration. Shared with each pane's test-facing `<p>_layout` wrapper, which
// declares ONE pane alone in a window: a floating child with no root to attach to is not laid
// out at all, so the wrapper cannot simply skip it, and the root the tests declare had better
// be the root the app declares.
clay_window_root :: proc(win_w, win_h: i32) -> clay.ElementDeclaration {
    return {layout = {sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))}}}
}

// The frame: every live pane claims its click, moves its viewport and declares itself into
// ONE tree, which is then painted in one pass.
//
// The per-pane order inside each `<p>_frame` is the template's and is unchanged (geom → claim
// the click → move the viewport → declare). What changed is that the DECLARATIONS now share a
// tree, and that is invisible to the panes: PointerOver answers from the layout the previous
// EndLayout produced, which is now the whole window rather than whichever pane went last.
//
// The editor is declared before the aux pane so a press over the boundary is offered to it
// first, exactly as render's draw order used to decide. The media surface is NOT here: it is
// still hand-drawn (render.odin), and it becomes an Image element when C8d gives it pan and
// zoom — an image that is panned and zoomed sits at an arbitrary rect inside its pane, which
// is a floating child rather than a laid-out one, and that is a decision for the checkpoint
// that needs it.
window_frame :: proc(t: ^Text, a: ^App, lay: Layout, win_w, win_h: i32, now: f64) {
    clay_window_begin(win_w, win_h)

    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        if a.main == .Text {
            editor_frame(t, a, lay.editor, now)
        }
        switch a.aux_mode {
        case .FileTree:
            filetree_frame(t, a, lay.aux)
        case .Config:
            config_frame(t, a, lay.aux, now)
        case .Terminal:
            terminal_frame(t, a, lay.aux)
        case .Grep:
            grep_frame(t, a, lay.aux)
        case .Procmon:
            procmon_frame(t, a, lay.aux, now)
        }
    }

    cmds := clay.EndLayout(0)
    clay_paint(t, a, &cmds, Rect{0, 0, win_w, win_h}, win_w, win_h)
}
