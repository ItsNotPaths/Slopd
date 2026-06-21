package libvterm

// Odin bindings for leonerd's libvterm (github.com/neovim/libvterm) — the
// editor-standard VT state machine Vim/Neovim embed. It is a PURE parser: no PTY,
// no curses, no I/O. We feed it output bytes (input_write) and read back a cell
// grid (screen_get_cell); Slopd owns the PTY and the rendering itself. Only the
// handful of entry points Slopd actually calls are bound here.
//
// These bindings are first-party SOURCE (libvterm ships none of its own), so they
// live in bindings/ and are tracked in git — unlike vendor/, which holds only
// downloaded/built artifacts and is gitignored. download-deps.sh clones the C
// sources and builds the dependency-free static archive (cc + ar, no libtool/
// ncurses) into vendor/libvterm/.libs/libvterm.a; the foreign import below reaches
// it by relative path, so `odin build src` picks it up transitively (as the
// tree-sitter runtime archive does).

import "core:c"

when ODIN_OS == .Windows {
    #panic("libvterm bindings are POSIX-only (Slopd owns the PTY via core:sys/posix)")
} else {
    foreign import vt "../../vendor/libvterm/.libs/libvterm.a"
}

// ABI-fixed: a cell holds one printing character plus up to five combining marks.
MAX_CHARS_PER_CELL :: 6

// Opaque handles owned by libvterm. A VTerm owns one Screen and one State, both
// obtained from it and freed with it.
VTerm  :: distinct rawptr
Screen :: distinct rawptr
State  :: distinct rawptr

Pos :: struct {
    row: c.int,
    col: c.int,
}

// Keyboard modifier bitmask (VTermModifier). Slopd keeps Alt global, so only
// Shift/Ctrl ever reach a focused terminal.
Modifier  :: distinct c.int
MOD_NONE  :: Modifier(0x00)
MOD_SHIFT :: Modifier(0x01)
MOD_ALT   :: Modifier(0x02)
MOD_CTRL  :: Modifier(0x04)

// Named non-text keys (VTermKey). Values mirror the header's enum order; we bind
// only the keys an editor sends (the function/keypad block is unused).
Key :: enum c.int {
    None = 0,
    Enter,
    Tab,
    Backspace,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Ins,
    Del,
    Home,
    End,
    PageUp,
    PageDown,
}

// Colour type bits packed into Color.type (the C tagged-union discriminator). The
// low bit is RGB(0)/indexed(1); the next two flag the default fg/bg, set when the
// app made no SGR colour request — render maps those onto the theme.
COLOR_TYPE_MASK  :: 0x01
COLOR_DEFAULT_FG :: 0x02
COLOR_DEFAULT_BG :: 0x04

// A tagged union in C. The first byte (`type`) discriminates and carries the
// default-fg/bg flags; for an RGB colour red/green/blue are valid, for an indexed
// colour the palette index lives in the `red` byte. convert_color_to_rgb()
// normalises any colour to RGB in place.
Color :: struct {
    type:             u8,
    red, green, blue: u8,
}

color_is_default_fg :: proc(col: Color) -> bool {return col.type & COLOR_DEFAULT_FG != 0}
color_is_default_bg :: proc(col: Color) -> bool {return col.type & COLOR_DEFAULT_BG != 0}

// Per-cell rendering attributes (a C bit-field over one unsigned int). Slopd acts
// only on `reverse` for v1; the rest are bound so the struct layout matches the
// ABI exactly when read by value.
ScreenCellAttrs :: bit_field c.uint {
    bold:      bool   | 1,
    underline: c.uint | 2,
    italic:    bool   | 1,
    blink:     bool   | 1,
    reverse:   bool   | 1,
    conceal:   bool   | 1,
    strike:    bool   | 1,
    font:      c.uint | 4,
    dwl:       bool   | 1,
    dhl:       c.uint | 2,
    small:     bool   | 1,
    baseline:  c.uint | 2,
}

ScreenCell :: struct {
    chars:  [MAX_CHARS_PER_CELL]u32,
    width:  c.char,
    attrs:  ScreenCellAttrs,
    fg, bg: Color,
}

// Output callback: libvterm hands us the bytes it generates in reply to the app
// (query responses, etc.); Slopd writes them straight to the PTY master.
Output_Callback :: #type proc "c" (s: [^]u8, len: c.size_t, user: rawptr)

// A chunk of an OSC/DCS string payload. The payload can arrive in pieces: `initial`
// marks the first, `final` the last. The three sub-fields are a C bit-field packed
// into one size_t, after the str pointer.
StringFragment :: struct {
    str:        [^]u8,
    using bits: bit_field c.size_t {
        len:     uint | 30,
        initial: bool | 1,
        final:   bool | 1,
    },
}

// OSC fallback: called for OSC sequences libvterm doesn't handle itself. Slopd uses
// a private OSC to carry shell-command exit codes (see the command-line chain
// runner). `command` is the numeric prefix (697 for `OSC 697 ; ...`), `frag` the rest.
OSC_Callback :: #type proc "c" (command: c.int, frag: StringFragment, user: rawptr) -> c.int

// Unrecognised-sequence fallbacks. Slopd uses only `osc`; the rest stay nil (they
// are function pointers, so rawptr matches the ABI for an unset slot).
StateFallbacks :: struct {
    control: rawptr,
    csi:     rawptr,
    osc:     OSC_Callback,
    dcs:     rawptr,
    apc:     rawptr,
    pm:      rawptr,
    sos:     rawptr,
}

// Scrollback hand-off. libvterm holds only the live grid; the app keeps the
// history. sb_pushline fires when a line scrolls off the top (its cells handed to
// us to stash); sb_popline lets us feed a stashed line back when the screen grows
// taller (we fill `cells`, return 1, or return 0 to decline). cells is a [^] of
// exactly `cols` entries. Slopd implements these two plus settermprop — the rest of
// the VTermScreenCallbacks slots stay nil (rawptr matches the ABI for an unset func ptr).
SB_Pushline_Callback :: #type proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int
SB_Popline_Callback  :: #type proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int

// settermprop reports terminal property changes (cursor visibility, title, ...). Slopd
// reads only PROP_ALTSCREEN, to know when a full-screen TUI is on its own alt buffer
// (then it owns scrolling — PageUp passes through to it, not Slopd's scrollback). `val`
// points at a VTermValue union; for the bool props its first int is the boolean.
Settermprop_Callback :: #type proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int

PROP_ALTSCREEN :: 3 // VTERM_PROP_ALTSCREEN (CURSORVISIBLE=1, CURSORBLINK=2, ALTSCREEN=3)
PROP_MOUSE     :: 8 // VTERM_PROP_MOUSE: 0 = off, else the active mouse tracking mode

// VTermScreenCallbacks, field order ABI-fixed to the header. All entries are
// function pointers; the ones Slopd ignores (damage/moverect/movecursor/bell/resize/
// sb_clear) stay rawptr-nil.
ScreenCallbacks :: struct {
    damage:      rawptr,
    moverect:    rawptr,
    movecursor:  rawptr,
    settermprop: Settermprop_Callback,
    bell:        rawptr,
    resize:      rawptr,
    sb_pushline: SB_Pushline_Callback,
    sb_popline:  SB_Popline_Callback,
    sb_clear:    rawptr,
}

@(default_calling_convention = "c", link_prefix = "vterm_")
foreign vt {
    new                 :: proc(rows, cols: c.int) -> VTerm ---
    free                :: proc(term: VTerm) ---
    set_utf8            :: proc(term: VTerm, is_utf8: c.int) ---
    set_size            :: proc(term: VTerm, rows, cols: c.int) ---
    input_write         :: proc(term: VTerm, bytes: [^]u8, len: c.size_t) -> c.size_t ---
    obtain_screen       :: proc(term: VTerm) -> Screen ---
    obtain_state        :: proc(term: VTerm) -> State ---
    output_set_callback :: proc(term: VTerm, func: Output_Callback, user: rawptr) ---
    keyboard_unichar    :: proc(term: VTerm, cp: u32, mod: Modifier) ---
    keyboard_key        :: proc(term: VTerm, key: Key, mod: Modifier) ---
    // Mouse input -> the app via the output callback, encoded to the TUI's active mouse
    // protocol. Wheel is button 4 (up) / 5 (down); Slopd uses only the wheel, to scroll
    // a focused full-screen TUI (its scrollback is its own — see the terminal selector).
    mouse_move          :: proc(term: VTerm, row, col: c.int, mod: Modifier) ---
    mouse_button        :: proc(term: VTerm, button: c.int, pressed: bool, mod: Modifier) ---

    screen_reset                :: proc(screen: Screen, hard: c.int) ---
    screen_enable_altscreen     :: proc(screen: Screen, altscreen: c.int) ---
    screen_get_cell             :: proc(screen: Screen, pos: Pos, cell: ^ScreenCell) -> c.int ---
    screen_flush_damage         :: proc(screen: Screen) ---
    screen_convert_color_to_rgb :: proc(screen: Screen, col: ^Color) ---
    screen_set_default_colors   :: proc(screen: Screen, default_fg, default_bg: ^Color) ---
    screen_set_unrecognised_fallbacks :: proc(screen: Screen, fallbacks: ^StateFallbacks, user: rawptr) ---
    screen_set_callbacks :: proc(screen: Screen, callbacks: ^ScreenCallbacks, user: rawptr) ---

    state_get_cursorpos :: proc(state: State, cursorpos: ^Pos) ---
}
