package main
import "ui"


// The redraw scheduler: what the App has pending, and the caret blink read through it.

// -1 to block until the next event, or seconds to wake by. Each animated subsystem reports
// here; the soonest deadline wins.
app_next_wake :: proc(a: ^App, now: f64) -> f64 {
    wake := f64(-1)
    // Both axes under one gate: either tween moving is the same obligation to redraw.
    if eb := editor_current(&a.editor); ui.anim_active(&eb.scroll_anim, now) || ui.anim_active(&eb.hscroll_anim, now) {
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    // Both presentations share `tree.scroll_anim` because they share the viewport. Gated on
    // the aux mode: a tween nothing is drawing must not spin the loop.
    if a.aux_mode == .FileTree && ui.anim_active(&a.tree.scroll_anim, now) {
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    // A tween of its own, gated on the same predicate its draw site uses.
    if wsfind_shown(a) && ui.anim_active(&a.wsfind.scroll_anim, now) {
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    if a.view == .Zen && ui.anim_active(&a.zen_anim, now) { // aux-pane slide
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    if a.view == .Split && ui.anim_active(&a.split_anim, now) { // the split widen/narrow
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    // Gated on the same predicates their draw sites use (overlay_ui.odin): a copy would drift,
    // and the loop would wake at vsync to animate a render refusing to draw.
    if switcher_shown(a) && ui.anim_active(&a.switcher_anim, now) {
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    if chord_shown(a) && ui.anim_active(&a.chord_anim, now) {
        wake = ui.sched_min(wake, ui.frame_budget)
    }
    if caret_shown(a) { // wake at the next on/off edge
        wake = ui.sched_min(wake, blink_next_edge(a, now))
    }
    // `:grep` runs its search once typing pauses; without this the pause would have to be
    // broken to see the result.
    if a.cl_preview.pending {
        wake = ui.sched_min(wake, max(0, a.cl_preview.due - now))
    }
    if a.font_save_at > 0 { // flush the debounced font-zoom save
        wake = ui.sched_min(wake, max(0, a.font_save_at - now))
    }
    if a.focus == .Editor { // re-stat the focused view pane for external edits
        wake = ui.sched_min(wake, max(0, a.disk_poll_at - now))
    }
    // The only pointer path needing a wake: a drag parked off the pane bottom emits no events
    // and must keep scrolling. Paces DRAG_SCROLL_S, not fps.
    if w := drag_next_wake(a, now); w >= 0 {
        wake = ui.sched_min(wake, w)
    }
    return wake
}

// The wait the scheduler needs to flip the caret.
blink_next_edge :: proc(a: ^App, now: f64) -> f64 {
    k := int((now - a.blink_base) / ui.BLINK_HALF) + 1
    return a.blink_base + f64(k) * ui.BLINK_HALF - now
}

// So the loop knows to keep blinking.
caret_shown :: proc(a: ^App) -> bool {
    if a.cl_active || filebrowser_path_live(a) || wsfind_live(a) {
        return true
    }
    if a.focus == .Aux && a.aux_mode == .Config {
        return config_caret_live(a)
    }
    return panes_visible(a).editor
}
