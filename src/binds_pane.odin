package main

import "core:fmt"
import "core:strings"

// The binds pane — one row per Action, its chords beside it. **Its own keys are hardcoded**
// (binds_pane_key, input.odin) and never come from the table it edits: unbinding `nav.down` must
// not lock you out of the pane that fixes it, and `ctrl+s` is a Text bind a Surface pane would
// never see.
//
// TWO WAYS TO EDIT, on the pane's top toggle:
//   Fill     Enter stages `:rebind 0 nav.down ` in the command line for you to finish and read.
//            The staged line is the confirm, as with every other command Slopd puts up.
//   Capture  Enter waits, and the next keystroke IS the chord. A chord already held asks first,
//            since there is no line to read here.
//
// Edits land in `working`, not the live table, so rebinding an arrow does not change the pane
// under your fingers. Ctrl+S writes the block and applies them.

Bind_Edit :: enum {
    Fill,
    Capture,
}

// Capture's own state; `.None` throughout in Fill mode.
Bind_Capture :: enum {
    None,
    Add, // a new chord for the selected action
    Rebind, // replace the highlighted one
    Confirm, // the captured chord is taken; Enter steals it, Esc backs out
    Rejected, // the chord cannot hold this action; `fault` says why
}

BindsPane :: struct {
    sel:             int, // selected navigable row
    chord:           int, // which of the row's chords is highlighted (Left/Right)
    scroll:          int,
    scroll_detached: f64,
    hover:           int, // display row under the pointer, or -1
    mode:            Bind_Edit,
    capture:         Bind_Capture,
    pending:         Chord, // the captured chord, waiting on a steal confirm
    pending_add:     bool, // ...and whether it was an add
    steal:           Action, // who holds it
    fault:           Bind_Fault, // why a Rejected capture was refused
    working:         [dynamic]Bind, // the edit copy; Ctrl+S applies it
    errs:            [dynamic]Bind_Error, // refused lines, owned; save is blocked while any stand
    dirty:           bool,
}

// The three buttons, then the refused lines, then one row per Action (bar .None).
ROW_BINDS_MODE :: 0
ROW_BINDS_OPEN :: 1
ROW_BINDS_SAVE :: 2
ROW_BINDS_ERRS :: 3

// Its own copy of the live table and of whatever the loader refused, so the pane never edits
// state somebody else owns.
binds_pane_init :: proc(bp: ^BindsPane, binds: []Bind, errs: []Bind_Error) {
    bp.hover = -1
    append(&bp.working, ..binds)
    for e in errs {
        append(&bp.errs, Bind_Error{e.line, strings.clone(e.text), e.why})
    }
}

binds_pane_destroy :: proc(bp: ^BindsPane) {
    delete(bp.working)
    for e in bp.errs {
        delete(e.text)
    }
    delete(bp.errs)
}

binds_pane_rows :: proc(bp: ^BindsPane) -> int {
    return ROW_BINDS_ERRS + len(bp.errs) + len(Action) - 1 // every action but .None
}

// The Action at row r, or (_, false) for a button or an error row.
binds_pane_action :: proc(bp: ^BindsPane, r: int) -> (Action, bool) {
    i := r - (ROW_BINDS_ERRS + len(bp.errs))
    if i < 0 || i >= len(Action) - 1 {
        return .None, false
    }
    return Action(i + 1), true // .None is member 0 and has no row
}

binds_pane_err :: proc(bp: ^BindsPane, r: int) -> (^Bind_Error, bool) {
    i := r - ROW_BINDS_ERRS
    if i < 0 || i >= len(bp.errs) {
        return nil, false
    }
    return &bp.errs[i], true
}

// Where `act`'s chords sit in `working`, in table order. Temp-allocated.
binds_of :: proc(bp: ^BindsPane, act: Action, alloc := context.temp_allocator) -> []int {
    out := make([dynamic]int, 0, 4, alloc)
    for b, i in bp.working {
        if b.act == act {
            append(&out, i)
        }
    }
    return out[:]
}

binds_pane_move :: proc(bp: ^BindsPane, delta: int) {
    bp.sel = clamp(bp.sel + delta, 0, max(0, binds_pane_rows(bp) - 1))
    bp.chord = 0
    bp.capture = .None
}

// Left/Right walk the chords ON the selected action's row — with ^C and ^Y both on clip.copy,
// this is what picks which of the two a delete or a rebind acts on.
binds_pane_cycle :: proc(bp: ^BindsPane, delta: int) {
    act, ok := binds_pane_action(bp, bp.sel)
    if !ok {
        return
    }
    if n := len(binds_of(bp, act)); n > 0 {
        bp.chord = (bp.chord + delta + n) % n
    }
}

// --- the edits, shared by the pane and the `:rebind` builtin ---

// Put `c` on `act`: at slot `n` when replacing, beside what is there when adding. Whoever else
// held it in a context they share loses it, and is named back — the typed line was the confirm.
bind_set :: proc(
    bp: ^BindsPane,
    act: Action,
    n: int,
    c: Chord,
    add: bool,
) -> (
    took: Action,
    why: Bind_Fault,
    ok: bool,
) {
    if .Text in bind_ctxs(act) && chord_types_text(c) {
        return .None, .Bare_In_Text, false // the loader refuses this too
    }
    at := binds_of(bp, act)
    if !add && (n < 0 || n >= len(at)) {
        return .None, .Already_Bound, false // no such slot to replace
    }
    took, _ = bind_holder(bp.working[:], c, act)
    for i := len(bp.working) - 1; i >= 0; i -= 1 {
        if bp.working[i].act != act && bind_clash(bp.working[i], Bind{c, act}) {
            ordered_remove(&bp.working, i)
        }
    }
    at = binds_of(bp, act) // the removals above may have shifted them
    if add {
        bp.chord = len(at)
        append(&bp.working, Bind{c, act})
    } else {
        bp.working[at[n]] = {c, act}
        bp.chord = n
    }
    bp.dirty = true
    return took, {}, true
}

// Drop `act`'s nth chord. An action may end up with none, which leaves it keyboard-unreachable.
bind_clear :: proc(bp: ^BindsPane, act: Action, n: int) -> bool {
    at := binds_of(bp, act)
    if n < 0 || n >= len(at) {
        return false
    }
    ordered_remove(&bp.working, at[n])
    bp.chord = max(0, min(bp.chord, len(at) - 2))
    bp.dirty = true
    return true
}

// --- capture --- The direct path: the pane waits, and the next keystroke is the chord.

binds_pane_capture :: proc(bp: ^BindsPane, add: bool) {
    if _, ok := binds_pane_action(bp, bp.sel); ok {
        bp.capture = add ? .Add : .Rebind
    }
}

// A captured chord. Applies it, or — when something else in a shared context holds it — asks
// first, since capture has no staged line to read before it happens.
binds_pane_take :: proc(bp: ^BindsPane, c: Chord) {
    act, ok := binds_pane_action(bp, bp.sel)
    if !ok || (bp.capture != .Add && bp.capture != .Rebind) {
        return
    }
    add := bp.capture == .Add
    for i in binds_of(bp, act) {
        if bp.working[i].chord == c {
            bp.capture = .None // already on this action: nothing to do, and no duplicate row
            return
        }
    }
    if held, taken := bind_holder(bp.working[:], c, act); taken {
        bp.pending, bp.pending_add, bp.steal = c, add, held
        bp.capture = .Confirm
        return
    }
    if _, why, applied := bind_set(bp, act, bp.chord, c, add); !applied {
        bp.pending, bp.fault, bp.capture = c, why, .Rejected
        return
    }
    bp.capture = .None
}

// Enter at the confirm: take the chord from whoever had it.
binds_pane_confirm :: proc(bp: ^BindsPane) {
    if bp.capture != .Confirm {
        return
    }
    if act, ok := binds_pane_action(bp, bp.sel); ok {
        bind_set(bp, act, bp.chord, bp.pending, bp.pending_add)
    }
    bp.capture = .None
}

// The line Enter stages: the highlighted slot, ready for a chord typed onto the end.
rebind_line :: proc(bp: ^BindsPane, act: Action, add: bool, alloc := context.allocator) -> string {
    if add {
        return fmt.aprintf(":rebind + %s ", action_name(act), allocator = alloc)
    }
    return fmt.aprintf(":rebind %d %s ", bp.chord, action_name(act), allocator = alloc)
}

// Backspace / Alt+-: drop the highlighted chord, or acknowledge a refused line. A line dropped
// here is gone from the file on the next save, which is what unblocks the save at all.
binds_pane_delete :: proc(bp: ^BindsPane) {
    if e, ok := binds_pane_err(bp, bp.sel); ok {
        delete(e.text)
        ordered_remove(&bp.errs, bp.sel - ROW_BINDS_ERRS)
        bp.sel = clamp(bp.sel, 0, max(0, binds_pane_rows(bp) - 1))
        bp.dirty = true
        return
    }
    if act, ok := binds_pane_action(bp, bp.sel); ok {
        bind_clear(bp, act, bp.chord)
    }
}

// Ctrl+S. Refused while a line is still in error — the block is rewritten wholesale, so an
// unacknowledged line would vanish without you having read it.
binds_pane_save :: proc(a: ^App) -> bool {
    bp := &a.binds_pane
    if !config_binds_write(bp.working[:], bp.errs[:]) {
        return false
    }
    clear(&a.binds)
    append(&a.binds, ..bp.working[:])
    bind_errors_destroy(a.bind_errors)
    a.bind_errors = nil
    bp.dirty = false
    return true
}

// Enter / a double click. On an action row it stages the command, or waits for a keystroke —
// whichever the top toggle says.
binds_pane_activate :: proc(a: ^App, add := false) {
    bp := &a.binds_pane
    switch {
    case bp.capture == .Confirm:
        binds_pane_confirm(bp)
    case bp.sel == ROW_BINDS_MODE:
        bp.mode = bp.mode == .Fill ? .Capture : .Fill
        bp.capture = .None
    case bp.sel == ROW_BINDS_OPEN:
        config_open_binds(a)
    case bp.sel == ROW_BINDS_SAVE:
        binds_pane_save(a)
    case:
        if e, ok := binds_pane_err(bp, bp.sel); ok {
            config_open_binds(a, e.line) // the raw line, at its place in the file
        } else if act, is_act := binds_pane_action(bp, bp.sel); is_act {
            if bp.mode == .Capture {
                binds_pane_capture(bp, add)
            } else {
                cl_inject(a, rebind_line(bp, act, add, context.temp_allocator))
            }
        }
    }
}
