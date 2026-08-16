package main

import "vendor:glfw"

// Binds — the key table, and the ONE place a chord is written down. Every verb Slopd has is an
// Action (action.odin); this says which keystroke reaches which one, and nothing else. Nothing
// here knows what a verb does, and nothing in action.odin knows which key ran it.
//
// **A chord is looked up in exactly two tables**: `Global`, and the one context the surface with
// the keys is in. That is the whole context system, and it is as small as an editor can make it:
//
//   Global    always searched, and searched first. The Alt chords, the font zoom, Escape.
//   Text      an editable has the keys — the buffer, the command line, the browser's path line,
//             a config row. A bare key TYPES here, so only chords can live in this table.
//   Surface   a list, a browser or an image. Bare keys are free.
//   Terminal  a live session. The only context where a MISS means something: the keystroke
//             goes to the job. Every bind here is a key stolen from every program you run.
//   Shell     not a table at all. An alt-screen program's plain keys, which are never ours.
//
// The contexts do NOT say which pane acts — that is the action's job, and most actions are
// answered by whichever surface has the keys (see nav_run). They say only where a chord is
// allowed to MEAN something, which is why there are four of them rather than one per pane.
//
// Phase 1 of the input rework: the table below is the default and the only source. Reading a
// `[binds]` block over it is the next step, and nothing above this line has to change for it.

// The modifiers a chord can carry. Super is not one (a compositor owns it), and the lock bits
// are masked off — CapsLock down must not stop every bind in the program from matching.
CHORD_MODS :: glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT

// A physical key plus the modifiers that qualify it. PHYSICAL: `Alt+;` is KEY_SEMICOLON as GLFW
// reports it, which is a different glyph on a different layout.
Chord :: struct {
    key:  i32,
    mods: i32,
}

Bind_Ctx :: enum u8 {
    Global,
    Text,
    Surface,
    Terminal,
    Shell, // no bind carries this: it is the "nothing of ours" answer from bind_ctx
}

Bind_Ctxs :: bit_set[Bind_Ctx;u8]

// One row of the table. `run` lets a single row cover a RUN of consecutive keys — Alt+1..9 is
// one bind, not nine — and the action is handed the offset, so the row stays one line.
Bind :: struct {
    ctx:   Bind_Ctxs,
    chord: Chord,
    act:   Action,
    run:   i32,
}

@(private = "file") MC :: glfw.MOD_CONTROL
@(private = "file") MS :: glfw.MOD_SHIFT
@(private = "file") MA :: glfw.MOD_ALT

@(private = "file") GL :: Bind_Ctxs{.Global}
@(private = "file") TX :: Bind_Ctxs{.Text}
@(private = "file") SF :: Bind_Ctxs{.Surface}
@(private = "file") TS :: Bind_Ctxs{.Text, .Surface}
@(private = "file") EV :: Bind_Ctxs{.Text, .Surface, .Terminal}
@(private = "file") TM :: Bind_Ctxs{.Terminal}

// The default binds. First match wins, so a chord must not appear twice in one context.
//
// **Shift is not usually written here.** A Shift-qualified chord that matches nothing exactly
// retries without it, and the action runs with `extend` set — which is what Shift means
// everywhere in Slopd: the same verb, extending. So `Shift+Down` sweeps marks, `^Shift+D`
// deletes the marked set, `Shift+Enter` opens in the desktop app, and `^Shift+C` copies (it is
// `^C`, extending nothing). Shift is written out only where it names a DIFFERENT verb.
@(rodata)
BINDS := [?]Bind {
    // --- global: focus, panes and the command line ---
    {GL, {glfw.KEY_LEFT, MA}, .Focus_Editor, 0},
    {GL, {glfw.KEY_RIGHT, MA}, .Focus_Aux, 0},
    {GL, {glfw.KEY_E, MA}, .Focus_Editor, 0},
    {GL, {glfw.KEY_F, MA}, .Aux_Filetree, 0},
    {GL, {glfw.KEY_T, MA}, .Aux_Terminal, 0},
    {GL, {glfw.KEY_R, MA}, .Aux_Grep, 0},
    {GL, {glfw.KEY_C, MA}, .Cl_Open, 0},
    {GL, {glfw.KEY_SEMICOLON, MA}, .Cl_Open_Builtin, 0},
    {GL, {glfw.KEY_W, MA}, .Cl_Open_Jump, 0},
    {GL, {glfw.KEY_G, MA}, .Git_Tool, 0},
    {GL, {glfw.KEY_ENTER, MA}, .Follow, 0},
    {GL, {glfw.KEY_KP_ENTER, MA}, .Follow, 0},
    {GL, {glfw.KEY_LEFT_BRACKET, MA}, .Split_Shrink, 0},
    {GL, {glfw.KEY_RIGHT_BRACKET, MA}, .Split_Grow, 0},
    {GL, {glfw.KEY_ESCAPE, 0}, .Escape, 0},

    // --- global: terminal sessions (the pane, not the job) ---
    {GL, {glfw.KEY_1, MA}, .Term_Goto, 8}, // Alt+1..9, i3-style
    {GL, {glfw.KEY_N, MA}, .Term_New, 0},
    {GL, {glfw.KEY_Q, MA}, .Term_Close, 0},
    {GL, {glfw.KEY_L, MA}, .Term_Lock, 0},
    {GL, {glfw.KEY_UP, MA}, .Term_Prev, 0},
    {GL, {glfw.KEY_DOWN, MA}, .Term_Next, 0},

    // --- global: the font. Window-level, so it reaches past an open command line ---
    {GL, {glfw.KEY_EQUAL, MC}, .Font_Grow, 0},
    {GL, {glfw.KEY_KP_ADD, MC}, .Font_Grow, 0},
    {GL, {glfw.KEY_MINUS, MC}, .Font_Shrink, 0},
    {GL, {glfw.KEY_KP_SUBTRACT, MC}, .Font_Shrink, 0},
    {GL, {glfw.KEY_0, MC}, .Font_Reset, 0},
    {GL, {glfw.KEY_KP_0, MC}, .Font_Reset, 0},

    // --- what the focused surface answers --- The arrows, Enter and the clipboard are ONE bind
    // each: every pane implements them, so binding them per pane would be the same key written
    // out six times. The terminal answers the clipboard too, and declines when it has no
    // selection — which is how ^C stays the interrupt with nothing to copy.
    {TS, {glfw.KEY_UP, 0}, .Nav_Up, 0},
    {TS, {glfw.KEY_DOWN, 0}, .Nav_Down, 0},
    {TS, {glfw.KEY_LEFT, 0}, .Nav_Left, 0},
    {TS, {glfw.KEY_RIGHT, 0}, .Nav_Right, 0},
    {TS, {glfw.KEY_ENTER, 0}, .Activate, 0},
    {TS, {glfw.KEY_KP_ENTER, 0}, .Activate, 0},
    {EV, {glfw.KEY_C, MC}, .Clip_Copy, 0},
    {EV, {glfw.KEY_X, MC}, .Clip_Cut, 0},
    {EV, {glfw.KEY_V, MC}, .Clip_Paste, 0},

    // --- text: an editable has the keys --- The two multi-cursor chords are here rather than in
    // Global because they act on WHATEVER editable has the keys, the command line included.
    {TX, {glfw.KEY_A, MA}, .Cursor_Drop, 0},
    {TX, {glfw.KEY_M, MA}, .Move_All, 0},
    {TX, {glfw.KEY_LEFT, MC}, .Move_Word_Left, 0},
    {TX, {glfw.KEY_RIGHT, MC}, .Move_Word_Right, 0},
    {TX, {glfw.KEY_HOME, 0}, .Move_Home, 0},
    {TX, {glfw.KEY_END, 0}, .Move_End, 0},
    {TX, {glfw.KEY_A, MC}, .Move_Home, 0}, // readline
    {TX, {glfw.KEY_E, MC}, .Move_End, 0},
    {TX, {glfw.KEY_UP, MC}, .Jump_Up, 0},
    {TX, {glfw.KEY_DOWN, MC}, .Jump_Down, 0},
    {TX, {glfw.KEY_BACKSPACE, 0}, .Delete_Back, 0},
    {TX, {glfw.KEY_DELETE, 0}, .Delete_Forward, 0},
    {TX, {glfw.KEY_BACKSPACE, MC}, .Delete_Word_Back, 0},
    {TX, {glfw.KEY_DELETE, MC}, .Delete_Word_Forward, 0},
    {TX, {glfw.KEY_TAB, 0}, .Indent, 0},
    {TX, {glfw.KEY_ENTER, MC}, .Fold_Toggle, 0},
    {TX, {glfw.KEY_KP_ENTER, MC}, .Fold_Toggle, 0},
    {TX, {glfw.KEY_S, MC}, .Save, 0},
    {TX, {glfw.KEY_Z, MC}, .Undo, 0},
    {TX, {glfw.KEY_Z, MC | MS}, .Redo, 0}, // a DIFFERENT verb from ^Z, so Shift is written out
    {TX, {glfw.KEY_Y, MC}, .Redo, 0},

    // --- surface: the file pane's ops, shared by the listing and the browser ---
    {SF, {glfw.KEY_Y, MC}, .File_Mark, 0},
    {SF, {glfw.KEY_U, MC}, .File_Marks_Clear, 0},
    {SF, {glfw.KEY_D, MC}, .File_Delete, 0},
    {SF, {glfw.KEY_W, MC}, .File_Copy_Path, 0},
    {SF, {glfw.KEY_I, MC}, .File_Props, 0},
    {SF, {glfw.KEY_H, MC}, .File_Workspace, 0},
    {SF, {glfw.KEY_O, MC}, .File_Edit, 0},
    {SF, {glfw.KEY_BACKSPACE, 0}, .Parent, 0},

    // --- surface: the browser's top bar and sidebar ---
    {SF, {glfw.KEY_LEFT, MC}, .Browse_Back, 0},
    {SF, {glfw.KEY_RIGHT, MC}, .Browse_Forward, 0},
    {SF, {glfw.KEY_R, MC}, .Browse_Reload, 0},
    {SF, {glfw.KEY_G, MC}, .Browse_View, 0},
    {SF, {glfw.KEY_1, MC}, .Browse_Place, 8}, // ^1..^9

    // --- surface: the image viewer. Bare keys, which only a surface with no text can have ---
    {SF, {glfw.KEY_EQUAL, 0}, .Media_Zoom_In, 0},
    {SF, {glfw.KEY_KP_ADD, 0}, .Media_Zoom_In, 0},
    {SF, {glfw.KEY_MINUS, 0}, .Media_Zoom_Out, 0},
    {SF, {glfw.KEY_KP_SUBTRACT, 0}, .Media_Zoom_Out, 0},
    {SF, {glfw.KEY_0, 0}, .Media_Fit, 0},
    {SF, {glfw.KEY_KP_0, 0}, .Media_Fit, 0},
    {SF, {glfw.KEY_F, 0}, .Media_Fit, 0},

    // --- terminal: the copy cursor. Everything else here reaches the job ---
    {TM, {glfw.KEY_PAGE_UP, 0}, .Term_Sel_Up, 0},
    {TM, {glfw.KEY_PAGE_DOWN, 0}, .Term_Sel_Down, 0},
    {TM, {glfw.KEY_UP, MC | MA}, .Term_Sel_Up, 0},
    {TM, {glfw.KEY_DOWN, MC | MA}, .Term_Sel_Down, 0},
    {TM, {glfw.KEY_UP, MS | MA}, .Term_Sel_Up, 0}, // Alt+Shift: extend, per the Shift rule
    {TM, {glfw.KEY_DOWN, MS | MA}, .Term_Sel_Down, 0},
}

// The context a keystroke is looked up in, alongside Global. Not a mode — a question about the
// surface with the keys, asked fresh on every press.
bind_ctx :: proc(a: ^App, chord: Chord) -> Bind_Ctx {
    if kind, _ := active_editable(a); kind != .None {
        return .Text
    }
    if ts := term_sel_target(a); ts != nil {
        // On the ALT SCREEN a full-screen program owns the plain keys: PageUp pages ITS buffer,
        // not our scrollback. Only a Ctrl- or Alt-rooted chord is still ours there. Global is
        // searched whatever this returns, so Escape and the Alt chords survive the exception.
        if ts.on_altscreen && chord.mods & ~i32(MS) == 0 {
            return .Shell
        }
        return .Terminal
    }
    return .Surface
}

// The bind a keystroke lands on. Two sweeps of the one table: an EXACT match first, then — when
// Shift was down — a retry without it. That second sweep is the whole of "Shift extends", and it
// is why a Shift-qualified chord written out in the table (^Shift+Z) always wins over it.
bind_find :: proc(chord: Chord, ctx: Bind_Ctx) -> (Bind, bool) {
    if b, ok := bind_scan(chord, ctx); ok {
        return b, true
    }
    if chord.mods & MS != 0 {
        return bind_scan({chord.key, chord.mods & ~i32(MS)}, ctx)
    }
    return {}, false
}

@(private = "file")
bind_scan :: proc(chord: Chord, ctx: Bind_Ctx) -> (Bind, bool) {
    for b in BINDS {
        if b.ctx & {.Global, ctx} == {} || b.chord.mods != chord.mods {
            continue
        }
        if chord.key >= b.chord.key && chord.key <= b.chord.key + b.run {
            return b, true
        }
    }
    return {}, false
}
