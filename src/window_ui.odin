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
//      at a higher z. The panes never overlap, so this buys nothing between THEM — it is
//      what C8c's overlays spend: each is a floating child of the pane it covers, at
//      OVERLAY_Z, so it outranks the strip declared after it as well (overlay_ui.odin).
//
// What did NOT move: compute_layout. The window's ARITHMETIC is still layout.odin's, because
// `a.lay` has to exist before the frame is declared — the wheel, the drag machine and the
// scheduler all ask it where the panes are, and they ask between frames. Clay places the
// panes where compute_layout put them; it does not decide where that is. A genuinely
// declarative split is a different job, and it is not one this refactor needs.

// How far either side of the gutter counts as the divider, in logical pixels. The gutter
// itself is 2px (compute_layout), which is a fine thing to LOOK at and an unreasonable thing
// to hit, so the grab band is widened symmetrically and eats a couple of pixels of each
// pane's focus-ring inset. That overlap is why the divider gets first refusal on a press
// (window_pointer): a band that overlapped a pane and asked second would be unreachable
// wherever the pane claimed first.
DIVIDER_GRAB :: 4

// How far a press must travel before it is a DRAG rather than a click on the divider. The
// editor and the terminal need no such number — a zero-length drag there re-derives what the
// click already set — but a click on a divider must do NOTHING, and without this the split
// would snap to whatever pixel a press happened to land on, which is up to DIVIDER_GRAB
// pixels from where the divider actually is. C7c named this as the one client that would
// want a threshold, and it is the one client that has one.
DIVIDER_DRAG_PX :: 3

// The band a press has to land in to grab the divider, in framebuffer pixels, and whether
// there is a divider at all. Pure — App is not consulted, only the layout the last frame
// painted and the DPI scale — which is what makes the routing a headless test.
//
// **The gap IS the predicate.** A divider exists exactly where two panes sit side by side
// with window background between them, and that is a question the rects already answer:
// compute_layout leaves `gutter` px between them in the Split arrangement, zero in Zen (where
// the aux pane slides OVER the editor rather than beside it) and nothing at all when one pane
// is hidden and carries a zero rect. So there is no view-mode check here, and adding one
// would be a second copy of what the arrangement already says.
//
// Zen is the case worth stating outright: its panes touch, so `gap <= 0` and the boundary is
// not draggable. That is the correct answer rather than a limitation — in Zen the aux pane is
// a transient reveal over a full-width editor, and the thing under that boundary is the
// editor's own text, which a press belongs to.
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

// Where the divider's centre would put the split, from a pointer x. The inverse of
// compute_layout's `i32(f32(win_w) * split)`: the editor's right edge is that many pixels in
// and the gutter straddles it, so the split the pointer is asking for is simply its fraction
// of the window. Clamped to the same range Alt+`[` / Alt+`]` clamp to, because it is the same
// setting and a mouse must not be able to reach a width the keyboard cannot.
divider_split_at :: proc(mx, win_w: i32) -> f32 {
    if win_w <= 0 {
        return SPLIT_MIN
    }
    return clampf(f32(mx) / f32(win_w), SPLIT_MIN, SPLIT_MAX)
}

// Claim a press on the divider. Taken BEFORE any pane declares (window_pointer), which is
// the only order that works: the grab band overlaps both panes' edges, so a divider that
// asked second would be reachable only in the 2px of gutter it was widened to escape.
//
// It claims on a real hit only, like every other click verb — a press in the gutter ABOVE the
// panes (there is none: the band is the panes' own height) or anywhere else is left for
// whoever else is drawing.
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
    // No noun to resolve and no anchor to store: what the press captured is the divider, and
    // the divider is a single number. The count goes in unread, because there is no second
    // grade of "move the divider" for a double click to mean.
    drag_begin(a, .Split, 0, 1, {}, 0)
}

// Move the split to follow a live divider drag. The frame's LAST word on `a.split`, and it
// runs before compute_layout for that reason — see window_pointer.
//
// **The split is SNAPPED, not eased**, which is the one thing here that differs from every
// other writer of this field. SPLIT_DUR exists because Alt+`[` / Alt+`]` step by 0.02 and a
// stepped adjustment that jumped would read as a stutter. A drag is already continuous, so
// easing it would make the divider trail the cursor by an animation — the one thing direct
// manipulation must never do. Re-aiming the tween at its own destination is what stops
// compute_layout starting an ease of its own on the next frame.
divider_drag :: proc(a: ^App, win_w: i32) {
    // The `mouse_on` guard is belt to drag_sweep's braces: the sweep buries a capture the
    // moment the toggle goes off, but it runs at the END of a frame, and a config change
    // arrives before one. Every other per-frame drag verb asks the same question.
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

// Which pane a pending press would focus, or ok=false for a press that belongs to neither —
// the gutter, the status strip, or outside the window. Pure, and the twin of wheel_target:
// a click resolves to a ROW only once a pane draws, but which PANE it landed in is a
// question the rects answer on their own.
click_focus_target :: proc(lay: Layout, mx, my: i32) -> (who: Focus, ok: bool) {
    if rect_hit(lay.editor, mx, my) {
        return .Editor, true
    }
    if rect_hit(lay.aux, mx, my) {
        return .Aux, true
    }
    return .Editor, false
}

// Focus follows the click — C8d, and the last of C3's deliberate deferrals. Clicking a
// filetree row selected it without moving focus, so the arrows went on going wherever they
// were already going; doing it for one pane back then would have made one pane grab focus
// while five did not, and asymmetry is worse than absence. Every pane is declared now, so it
// lands for all of them at once, through `set_focus` (app.odin) — still the single choke
// point, because focus has invariants per view mode that nothing else should be re-deriving.
//
// **The press is not CONSUMED here.** Focus and the pane's own verb are two different things
// that one press means: clicking a filetree row focuses the tree AND selects the row, in that
// order, in one frame. So this reads `a.mouse.click` and leaves it pending for
// `mouse_take_click`.
//
// **A press over the gutter changes nothing**, which is what makes the divider's own claim
// (above, and first) enough to keep a resize from stealing focus — the band is mostly gutter,
// and where it overlaps a pane the press has already been taken.
//
// Gated on the focus actually CHANGING, and not for thrift: set_focus re-stats the focused
// document for external edits, and firing that on every click inside the pane that already
// has focus would put a disk stat on the click path.
//
// The wheel deliberately does not do this (C2): a notch over an unfocused pane scrolls it and
// leaves the arrows where they were, because no wheel anywhere should steal focus.
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
// before any pane can, moves the split, and then whatever press is left decides which pane
// has the arrows.
//
// **Called before compute_layout, and that placement is the substance of it.** A pane's click
// verb runs INSIDE the frame because it acts on the pane's contents; the divider's acts on the
// pane RECTS, which are compute_layout's output — so a drag applied after the layout was
// solved would paint one frame behind the pointer, every frame, for the whole gesture. It
// resolves against `a.lay`, the layout the last frame PAINTED, which is the same tree every
// other pointer path hit-tests against and the one the user was actually looking at when they
// pressed (mouse.odin, trap 2).
//
// Focus rides along for the same reason rather than as a convenience: `panes_visible` reads
// focus, so a focus change decided after the layout was computed would show up a frame late
// in Zen — where focusing the editor is what starts the aux pane retracting.
window_pointer :: proc(a: ^App, win_w: i32) {
    divider_click(a, a.lay)
    divider_drag(a, win_w)
    focus_follows_click(a, a.lay)
}

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
        attachTo           = .Root,
        offset             = {f32(area.x), f32(area.y)},
        attachment         = {element = .LeftTop, parent = .LeftTop},
        pointerCaptureMode = .Passthrough,
    }
}

// The pane box every `<p>_declare` opens with: fixed to the pane's content area, floating at
// its origin, clipping its own content, stacking children downward. Six panes agreeing about
// this by construction is the same argument as `<p>_geom` — one call, no way to disagree.
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
// first, exactly as render's draw order used to decide. The MEDIA surface is here too since
// C8d: it was the last thing in the program painted by hand, and it joined the tree in the
// checkpoint that first let the pointer move it — an image that is panned and zoomed sits at
// an arbitrary rect inside its pane, which is a floating child rather than a laid-out one,
// and there was nothing to say about that rect until something could change it
// (media_ui.odin).
//
// The two main surfaces are a `switch` rather than two `if`s because they are alternatives:
// MainSurface says which KIND of document the left pane is showing, and exactly one of them
// is on screen.
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
            filetree_frame(t, a, lay.aux, now)
        case .Config:
            config_frame(t, a, lay.aux, now)
        case .Terminal:
            terminal_frame(t, a, lay.aux, now)
        case .Grep:
            grep_frame(t, a, lay.aux)
        case .Procmon:
            procmon_frame(t, a, lay.aux, now)
        }
        // The strip declares LAST, which since C8a is an ordering and not a hazard — see
        // strip_ui.odin's header for what it was before.
        strip_frame(t, a, lay.strip, now)
    }

    cmds := clay.EndLayout(0)
    clay_paint(t, a, &cmds, Rect{0, 0, win_w, win_h}, win_w, win_h)
}
