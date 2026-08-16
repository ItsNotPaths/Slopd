package main

import "vendor:glfw"

// Binds — the one place a chord is written down. ACTIONS says what a verb is called and where it
// is reachable; BIND_DEFAULTS says which key reaches it, and is the half a config file overrides.
//
// A chord is looked up in two tables: Global, plus the context of the surface with the keys.
//   Global    the Alt chords, the font zoom, Escape. Searched first, always.
//   Text      an editable has the keys, so a bare key TYPES and only chords live here.
//   Surface   a list, a browser or an image. Bare keys are free.
//   Terminal  a live session: a MISS here reaches the job. Every bind steals a key from it.
//   Shell     no table at all — an alt-screen program's plain keys.

CHORD_MODS :: glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT

// A PHYSICAL key plus its modifiers: `alt+;` is KEY_SEMICOLON, a different glyph on another layout.
Chord :: struct {
    key:  i32,
    mods: i32,
}

Bind_Ctx :: enum u8 {
    Global,
    Text,
    Surface,
    Terminal,
    Shell, // no bind carries this; it is bind_ctx's "nothing of ours"
}

Bind_Ctxs :: bit_set[Bind_Ctx;u8]

Bind :: struct {
    chord: Chord,
    act:   Action,
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

Action_Info :: struct {
    name: string,
    ctx:  Bind_Ctxs,
    run:  i32, // extra keys past the first: Alt+1..9 is one bind with run 8
}

// An enumerated array, so Odin refuses the literal with a member left out. The name's prefix is
// the SUBJECT; `ctx` is where the chord works, and they differ where a verb drives a pane from
// outside it (`term.goto` anywhere, `term.sel_up` only inside).
@(rodata)
ACTIONS := [Action]Action_Info {
    .None                = {"none", {}, 0}, // the unbind value; no chord resolves to it
    .Focus_Editor        = {"focus.editor", GL, 0},
    .Focus_Aux           = {"focus.aux", GL, 0},
    .Aux_Filetree        = {"pane.files", GL, 0},
    .Aux_Terminal        = {"pane.terminal", GL, 0},
    .Aux_Grep            = {"pane.grep", GL, 0},
    .Split_Grow          = {"view.split_grow", GL, 0},
    .Split_Shrink        = {"view.split_shrink", GL, 0},
    .Escape              = {"view.escape", GL, 0},
    .Cl_Open             = {"cl.open", GL, 0},
    .Cl_Open_Builtin     = {"cl.builtin", GL, 0},
    .Cl_Open_Jump        = {"cl.jump", GL, 0},
    .Git_Tool            = {"git.tool", GL, 0},
    .Follow              = {"link.follow", GL, 0},
    .Term_Goto           = {"term.goto", GL, 8},
    .Term_New            = {"term.new", GL, 0},
    .Term_Close          = {"term.close", GL, 0},
    .Term_Lock           = {"term.lock", GL, 0},
    .Term_Prev           = {"term.prev", GL, 0},
    .Term_Next           = {"term.next", GL, 0},
    .Term_Sel_Up         = {"term.sel_up", TM, 0},
    .Term_Sel_Down       = {"term.sel_down", TM, 0},
    .Cursor_Drop         = {"cursor.drop", TX, 0},
    .Move_All            = {"cursor.move_all", TX, 0},
    .Font_Grow           = {"font.grow", GL, 0},
    .Font_Shrink         = {"font.shrink", GL, 0},
    .Font_Reset          = {"font.reset", GL, 0},
    .Nav_Up              = {"nav.up", TS, 0},
    .Nav_Down            = {"nav.down", TS, 0},
    .Nav_Left            = {"nav.left", TS, 0},
    .Nav_Right           = {"nav.right", TS, 0},
    .Activate            = {"nav.activate", TS, 0},
    .Clip_Copy           = {"clip.copy", EV, 0},
    .Clip_Cut            = {"clip.cut", EV, 0},
    .Clip_Paste          = {"clip.paste", EV, 0},
    .Move_Word_Left      = {"edit.word_left", TX, 0},
    .Move_Word_Right     = {"edit.word_right", TX, 0},
    .Move_Home           = {"edit.home", TX, 0},
    .Move_End            = {"edit.end", TX, 0},
    .Jump_Up             = {"edit.jump_up", TX, 0},
    .Jump_Down           = {"edit.jump_down", TX, 0},
    .Delete_Back         = {"edit.delete_back", TX, 0},
    .Delete_Forward      = {"edit.delete_forward", TX, 0},
    .Delete_Word_Back    = {"edit.delete_word_back", TX, 0},
    .Delete_Word_Forward = {"edit.delete_word_forward", TX, 0},
    .Indent              = {"edit.indent", TX, 0},
    .Fold_Toggle         = {"edit.fold", TX, 0},
    .Save                = {"edit.save", TX, 0},
    .Undo                = {"edit.undo", TX, 0},
    .Redo                = {"edit.redo", TX, 0},
    .File_Mark           = {"file.mark", SF, 0},
    .File_Marks_Clear    = {"file.unmark_all", SF, 0},
    .File_Delete         = {"file.delete", SF, 0},
    .File_Copy_Path      = {"file.copy_path", SF, 0},
    .File_Props          = {"file.props", SF, 0},
    .File_Workspace      = {"file.workspace", SF, 0},
    .File_Edit           = {"file.edit", SF, 0},
    .Parent              = {"file.parent", SF, 0},
    .Browse_Back         = {"browse.back", SF, 0},
    .Browse_Forward      = {"browse.forward", SF, 0},
    .Browse_Reload       = {"browse.reload", SF, 0},
    .Browse_View         = {"browse.view", SF, 0},
    .Browse_Place        = {"browse.place", SF, 8},
    .Media_Zoom_In       = {"image.zoom_in", SF, 0},
    .Media_Zoom_Out      = {"image.zoom_out", SF, 0},
    .Media_Fit           = {"image.fit", SF, 0},
}

// First match wins, so a chord may not appear twice in one context (bind_clash; the suite checks).
//
// SHIFT IS NOT WRITTEN HERE. A Shift-qualified chord matching nothing exactly retries without it
// and the action runs `extend` — so Shift+Down sweeps marks, ^Shift+D takes the marked set,
// Shift+Enter opens in the desktop app, ^Shift+C copies. Written out only for a DIFFERENT verb.
@(rodata)
BIND_DEFAULTS := [?]Bind {
    // global: focus, panes, the command line
    {{glfw.KEY_LEFT, MA}, .Focus_Editor},
    {{glfw.KEY_RIGHT, MA}, .Focus_Aux},
    {{glfw.KEY_E, MA}, .Focus_Editor},
    {{glfw.KEY_F, MA}, .Aux_Filetree},
    {{glfw.KEY_T, MA}, .Aux_Terminal},
    {{glfw.KEY_R, MA}, .Aux_Grep},
    {{glfw.KEY_C, MA}, .Cl_Open},
    {{glfw.KEY_SEMICOLON, MA}, .Cl_Open_Builtin},
    {{glfw.KEY_W, MA}, .Cl_Open_Jump},
    {{glfw.KEY_G, MA}, .Git_Tool},
    {{glfw.KEY_ENTER, MA}, .Follow},
    {{glfw.KEY_KP_ENTER, MA}, .Follow},
    {{glfw.KEY_LEFT_BRACKET, MA}, .Split_Shrink},
    {{glfw.KEY_RIGHT_BRACKET, MA}, .Split_Grow},
    {{glfw.KEY_ESCAPE, 0}, .Escape},

    // global: terminal sessions (the pane, not the job)
    {{glfw.KEY_1, MA}, .Term_Goto},
    {{glfw.KEY_N, MA}, .Term_New},
    {{glfw.KEY_Q, MA}, .Term_Close},
    {{glfw.KEY_L, MA}, .Term_Lock},
    {{glfw.KEY_UP, MA}, .Term_Prev},
    {{glfw.KEY_DOWN, MA}, .Term_Next},

    // global: the font, window-level, so it reaches past an open command line
    {{glfw.KEY_EQUAL, MC}, .Font_Grow},
    {{glfw.KEY_KP_ADD, MC}, .Font_Grow},
    {{glfw.KEY_MINUS, MC}, .Font_Shrink},
    {{glfw.KEY_KP_SUBTRACT, MC}, .Font_Shrink},
    {{glfw.KEY_0, MC}, .Font_Reset},
    {{glfw.KEY_KP_0, MC}, .Font_Reset},

    // answered by the surface with the keys — one bind each, not one per pane
    {{glfw.KEY_UP, 0}, .Nav_Up},
    {{glfw.KEY_DOWN, 0}, .Nav_Down},
    {{glfw.KEY_LEFT, 0}, .Nav_Left},
    {{glfw.KEY_RIGHT, 0}, .Nav_Right},
    {{glfw.KEY_ENTER, 0}, .Activate},
    {{glfw.KEY_KP_ENTER, 0}, .Activate},
    {{glfw.KEY_C, MC}, .Clip_Copy},
    {{glfw.KEY_X, MC}, .Clip_Cut},
    {{glfw.KEY_V, MC}, .Clip_Paste},

    // text: the multi-cursor chords are here, not Global — they act on the editable, the CL too
    {{glfw.KEY_A, MA}, .Cursor_Drop},
    {{glfw.KEY_M, MA}, .Move_All},
    {{glfw.KEY_LEFT, MC}, .Move_Word_Left},
    {{glfw.KEY_RIGHT, MC}, .Move_Word_Right},
    {{glfw.KEY_HOME, 0}, .Move_Home},
    {{glfw.KEY_END, 0}, .Move_End},
    {{glfw.KEY_A, MC}, .Move_Home}, // readline
    {{glfw.KEY_E, MC}, .Move_End},
    {{glfw.KEY_UP, MC}, .Jump_Up},
    {{glfw.KEY_DOWN, MC}, .Jump_Down},
    {{glfw.KEY_BACKSPACE, 0}, .Delete_Back},
    {{glfw.KEY_DELETE, 0}, .Delete_Forward},
    {{glfw.KEY_BACKSPACE, MC}, .Delete_Word_Back},
    {{glfw.KEY_DELETE, MC}, .Delete_Word_Forward},
    {{glfw.KEY_TAB, 0}, .Indent},
    {{glfw.KEY_ENTER, MC}, .Fold_Toggle},
    {{glfw.KEY_KP_ENTER, MC}, .Fold_Toggle},
    {{glfw.KEY_S, MC}, .Save},
    {{glfw.KEY_Z, MC}, .Undo},
    {{glfw.KEY_Z, MC | MS}, .Redo}, // a different verb from ^Z, so Shift is written out
    {{glfw.KEY_Y, MC}, .Redo},

    // surface: the file ops, identical under both faces
    {{glfw.KEY_Y, MC}, .File_Mark},
    {{glfw.KEY_U, MC}, .File_Marks_Clear},
    {{glfw.KEY_D, MC}, .File_Delete},
    {{glfw.KEY_W, MC}, .File_Copy_Path},
    {{glfw.KEY_I, MC}, .File_Props},
    {{glfw.KEY_H, MC}, .File_Workspace},
    {{glfw.KEY_O, MC}, .File_Edit},
    {{glfw.KEY_BACKSPACE, 0}, .Parent},

    // surface: the browser's top bar and sidebar
    {{glfw.KEY_LEFT, MC}, .Browse_Back},
    {{glfw.KEY_RIGHT, MC}, .Browse_Forward},
    {{glfw.KEY_R, MC}, .Browse_Reload},
    {{glfw.KEY_G, MC}, .Browse_View},
    {{glfw.KEY_1, MC}, .Browse_Place},

    // surface: the image viewer, on bare keys
    {{glfw.KEY_EQUAL, 0}, .Media_Zoom_In},
    {{glfw.KEY_KP_ADD, 0}, .Media_Zoom_In},
    {{glfw.KEY_MINUS, 0}, .Media_Zoom_Out},
    {{glfw.KEY_KP_SUBTRACT, 0}, .Media_Zoom_Out},
    {{glfw.KEY_0, 0}, .Media_Fit},
    {{glfw.KEY_KP_0, 0}, .Media_Fit},
    {{glfw.KEY_F, 0}, .Media_Fit},

    // terminal: the copy cursor. Everything else here reaches the job
    {{glfw.KEY_PAGE_UP, 0}, .Term_Sel_Up},
    {{glfw.KEY_PAGE_DOWN, 0}, .Term_Sel_Down},
    {{glfw.KEY_UP, MC | MA}, .Term_Sel_Up},
    {{glfw.KEY_DOWN, MC | MA}, .Term_Sel_Down},
    {{glfw.KEY_UP, MS | MA}, .Term_Sel_Up},
    {{glfw.KEY_DOWN, MS | MA}, .Term_Sel_Down},
}

bind_ctxs :: proc(act: Action) -> Bind_Ctxs {
    return ACTIONS[act].ctx
}

bind_run :: proc(act: Action) -> i32 {
    return ACTIONS[act].run
}

// Which table a keystroke is looked up in, alongside Global. A question about the surface with
// the keys, asked fresh on every press.
bind_ctx :: proc(a: ^App, chord: Chord) -> Bind_Ctx {
    if kind, _ := active_editable(a); kind != .None {
        return .Text
    }
    if ts := term_sel_target(a); ts != nil {
        // On the alt screen a full-screen program owns the plain keys — PageUp pages ITS buffer.
        if ts.on_altscreen && chord.mods & ~i32(MS) == 0 {
            return .Shell
        }
        return .Terminal
    }
    return .Surface
}

// Exact match first; failing that, a Shift-qualified chord retries without Shift and the action
// runs extending. An exact Shift row therefore always beats the fallback.
bind_find :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx) -> (Bind, bool) {
    if b, ok := bind_scan(binds, chord, ctx); ok {
        return b, true
    }
    if chord.mods & MS != 0 {
        return bind_scan(binds, {chord.key, chord.mods & ~i32(MS)}, ctx)
    }
    return {}, false
}

@(private = "file")
bind_scan :: proc(binds: []Bind, chord: Chord, ctx: Bind_Ctx) -> (Bind, bool) {
    for b in binds {
        if bind_ctxs(b.act) & {.Global, ctx} == {} || b.chord.mods != chord.mods {
            continue
        }
        if chord.key >= b.chord.key && chord.key <= b.chord.key + bind_run(b.act) {
            return b, true
        }
    }
    return {}, false
}

// Same modifiers, overlapping key runs, a context in common. First match wins, so the loader
// refuses the second and the suite holds the defaults to it.
bind_clash :: proc(x, y: Bind) -> bool {
    if bind_ctxs(x.act) & bind_ctxs(y.act) == {} || x.chord.mods != y.chord.mods {
        return false
    }
    return(
        x.chord.key <= y.chord.key + bind_run(y.act) &&
        y.chord.key <= x.chord.key + bind_run(x.act) \
    )
}

// Who already holds `c` in a context `act` would reach. `act`'s own rows do not count: rebinding
// a chord onto the action that has it is a no-op, not a theft.
bind_holder :: proc(binds: []Bind, c: Chord, act: Action) -> (Action, bool) {
    want := Bind{c, act}
    for b in binds {
        if b.act != act && bind_clash(b, want) {
            return b.act, true
        }
    }
    return .None, false
}
