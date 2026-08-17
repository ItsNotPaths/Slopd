package libvterm

// Odin bindings for leonerd's libvterm, the VT state machine Vim/Neovim embed. A PURE parser:
// no PTY, no curses, no I/O. We feed it output bytes and read back a cell grid; Slopd owns the
// PTY and the rendering. Only the entry points Slopd calls are bound.
//
// These bindings are first-party SOURCE — libvterm ships none — so they are tracked in git,
// unlike vendor/. download-deps.sh clones the C sources and builds the dependency-free static
// archive into vendor/libvterm/.libs/libvterm.a, which the foreign import below reaches by
// relative path.

import "core:c"

when ODIN_OS == .Windows {
    #panic("libvterm bindings are POSIX-only (Slopd owns the PTY via core:sys/posix)")
} else {
    foreign import vt "../../vendor/libvterm/.libs/libvterm.a"
}

// ABI-fixed: one printing character plus up to five combining marks.
MAX_CHARS_PER_CELL :: 6

// A VTerm owns one Screen and one State, both obtained from it and freed with it.
VTerm  :: distinct rawptr
Screen :: distinct rawptr
State  :: distinct rawptr

Pos :: struct {
    row: c.int,
    col: c.int,
}

// VTermModifier. Slopd keeps Alt global, so only Shift/Ctrl reach a focused terminal.
Modifier  :: distinct c.int
MOD_NONE  :: Modifier(0x00)
MOD_SHIFT :: Modifier(0x01)
MOD_ALT   :: Modifier(0x02)
MOD_CTRL  :: Modifier(0x04)

// VTermKey, in the header's enum order. Only the keys an editor sends are bound.
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

// The C tagged-union discriminator: the low bit is RGB(0)/indexed(1), the next two flag the
// default fg/bg, set when the app made no SGR colour request.
COLOR_TYPE_MASK  :: 0x01
COLOR_DEFAULT_FG :: 0x02
COLOR_DEFAULT_BG :: 0x04

// A tagged union in C: `type` discriminates and carries the default flags, an RGB colour uses
// red/green/blue, an indexed one puts its palette index in `red`. convert_color_to_rgb()
// normalises either to RGB in place.
Color :: struct {
    type:             u8,
    red, green, blue: u8,
}

color_is_default_fg :: proc(col: Color) -> bool {return col.type & COLOR_DEFAULT_FG != 0}
color_is_default_bg :: proc(col: Color) -> bool {return col.type & COLOR_DEFAULT_BG != 0}

// A C bit-field over one unsigned int. Slopd acts only on `reverse`; the rest are bound so the
// layout matches the ABI when read by value.
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

// The bytes libvterm generates in reply to the app; Slopd writes them to the PTY master.
Output_Callback :: #type proc "c" (s: [^]u8, len: c.size_t, user: rawptr)

// A chunk of an OSC/DCS payload, which can arrive in pieces: `initial` marks the first, `final`
// the last. The three sub-fields are a C bit-field packed into one size_t.
StringFragment :: struct {
    str:        [^]u8,
    using bits: bit_field c.size_t {
        len:     uint | 30,
        initial: bool | 1,
        final:   bool | 1,
    },
}

// For OSC sequences libvterm does not handle itself. Slopd uses a private OSC to carry
// shell-command exit codes; `command` is the numeric prefix, `frag` the rest.
OSC_Callback :: #type proc "c" (command: c.int, frag: StringFragment, user: rawptr) -> c.int

// Slopd uses only `osc`; the rest stay nil, and rawptr matches the ABI for an unset slot.
StateFallbacks :: struct {
    control: rawptr,
    csi:     rawptr,
    osc:     OSC_Callback,
    dcs:     rawptr,
    apc:     rawptr,
    pm:      rawptr,
    sos:     rawptr,
}

// libvterm holds only the live grid; the app keeps the history. sb_pushline fires when a line
// scrolls off the top, handing us its cells to stash; sb_popline lets us feed one back when the
// screen grows taller (fill `cells` and return 1, or return 0 to decline). `cells` holds exactly
// `cols` entries.
SB_Pushline_Callback :: #type proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int
SB_Popline_Callback  :: #type proc "c" (cols: c.int, cells: [^]ScreenCell, user: rawptr) -> c.int

// The four-argument form, carrying the bit the three-argument one drops: whether the line exists
// because the one above it wrapped. Without it a copied soft-wrapped command comes back in two
// pieces.
//
// An ABI-compatible tenth slot, ignored until screen_callbacks_has_pushline4 is called, after
// which it is used INSTEAD of sb_pushline — so an implementation that opts in fills this slot
// and may leave the other nil.
SB_Pushline4_Callback :: #type proc "c" (cols: c.int, cells: [^]ScreenCell, continuation: bool, user: rawptr) -> c.int

// Terminal property changes. Slopd reads PROP_ALTSCREEN, to know when a TUI is on its own alt
// buffer and owns scrolling. `val` points at a VTermValue union, whose first int is the boolean
// for the bool props.
Settermprop_Callback :: #type proc "c" (prop: c.int, val: rawptr, user: rawptr) -> c.int

PROP_ALTSCREEN :: 3 // CURSORVISIBLE=1, CURSORBLINK=2, ALTSCREEN=3
PROP_MOUSE     :: 8 // 0 = off, else the active mouse tracking mode

// Slopd reads only `continuation`, but the whole bit-field is declared so the layout matches the
// ABI when read through a pointer.
LineInfo :: bit_field c.uint {
    doublewidth:  bool   | 1,
    doubleheight: c.uint | 2,
    continuation: bool   | 1, // this line exists because the one above it wrapped
}

// Field order ABI-fixed to the header. All entries are function pointers, and the ones Slopd
// ignores stay rawptr-nil.
//
// sb_pushline4 is the tenth slot and the one Slopd fills. The nine-slot version stays declared
// and nil, since the two are alternatives rather than a pair.
ScreenCallbacks :: struct {
    damage:       rawptr,
    moverect:     rawptr,
    movecursor:   rawptr,
    settermprop:  Settermprop_Callback,
    bell:         rawptr,
    resize:       rawptr,
    sb_pushline:  SB_Pushline_Callback,
    sb_popline:   SB_Popline_Callback,
    sb_clear:     rawptr,
    sb_pushline4: SB_Pushline4_Callback,
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
    // CSI 200~ / CSI 201~ around pasted text. libvterm tracks DECSET 2004 itself, so these
    // emit nothing for a shell that never asked — hence wrapping unconditionally.
    keyboard_start_paste :: proc(term: VTerm) ---
    keyboard_end_paste   :: proc(term: VTerm) ---
    // To the app via the output callback, encoded to the TUI's active mouse protocol. Wheel is
    // button 4 (up) / 5 (down).
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
    // The flag lives on the SCREEN rather than the callbacks struct, which is what makes the
    // tenth slot ABI-compatible — but both must be in place before the first line scrolls off,
    // or that line loses its continuation bit.
    screen_callbacks_has_pushline4 :: proc(screen: Screen) ---

    state_get_cursorpos :: proc(state: State, cursorpos: ^Pos) ---
    // For a LIVE grid row. The scrollback's copy of the same bit arrives through sb_pushline4.
    state_get_lineinfo  :: proc(state: State, row: c.int) -> ^LineInfo ---
}
