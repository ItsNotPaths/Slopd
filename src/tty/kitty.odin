package tty

import "core:unicode/utf8"

// The kitty keyboard protocol, which is the only input scheme that can carry what Slopd's binds
// need. The legacy encoding cannot express Ctrl+Enter, Ctrl+Shift+Z or Ctrl+digit, and it never
// reports a bare modifier at all — and Alt-held driving the terminal switcher, Ctrl-held driving
// the filetree chord bar, are the whole shape of the keyboard here.
//
// Flags asked for, and what each one buys:
//   1   disambiguate escape codes    Escape is distinguishable from the start of a sequence
//   2   report event types           releases, without which a held Alt never lets go
//   8   report all keys as escape codes   bare modifier presses arrive at all
//  16   report associated text       what to INSERT, since 8 stops printable keys arriving raw
//
// Pushed onto the terminal's stack rather than set outright, so leaving restores whatever the
// shell had rather than whatever we assumed it had.
KITTY_FLAGS :: 1 | 2 | 8 | 16
KITTY_PUSH :: "\e[>27u"
KITTY_POP :: "\e[<1u"

// Modifier bits, as the protocol reports them (it sends the field as 1 + this).
MOD_SHIFT :: 1
MOD_ALT :: 2
MOD_CTRL :: 4
MOD_SUPER :: 8

// The private-use codepoints for keys that have no character. Only the ones Slopd binds; the
// protocol defines many more and an unmapped one is dropped rather than guessed at.
KEY_LEFT_SHIFT :: 57441
KEY_LEFT_CTRL :: 57442
KEY_LEFT_ALT :: 57443
KEY_LEFT_SUPER :: 57444
KEY_RIGHT_SHIFT :: 57447
KEY_RIGHT_CTRL :: 57448
KEY_RIGHT_ALT :: 57449
KEY_RIGHT_SUPER :: 57450

Key_Kind :: enum u8 {
    Press   = 1,
    Repeat  = 2,
    Release = 3,
}

// Which shape the terminal used, because the number means a different thing in each: a codepoint
// after `u`, a functional-key number before `~`, and the final byte itself for the letter forms
// (arrows, Home, End). Keeping the shape means the mapping never has to guess which space a
// number came from.
Key_Form :: enum u8 {
    Codepoint, // CSI code u
    Tilde,     // CSI number ~
    Letter,    // CSI 1 ; mods LETTER
}

Key_Event :: struct {
    form: Key_Form,
    code: i32,
    mods: i32, // MOD_* bits, already decoded from the protocol's +1
    kind: Key_Kind,
    text: rune, // what to insert, 0 for none
}

Parse_Result :: enum {
    None,        // nothing usable at the front of the buffer
    Event,       // `ev` is filled and `n` bytes are consumed
    Paste_Begin, // the terminal is about to send clipboard content, not keystrokes
    Paste_End,
    Incomplete,  // a sequence has begun but has not finished arriving
}

// The terminal wraps a paste in these when ?2004h is on. Everything between them is CONTENT:
// a newline in it is a line break rather than Enter, and a `:` does not open the command line.
PASTE_BEGIN :: "\e[200~"
PASTE_END :: "\e[201~"

// One event off the front of `buf`. Bytes that are not an escape sequence decode as text, which
// is what a terminal that ignores the flags above still sends, and what bracketed paste is made
// of.
parse :: proc(buf: []u8) -> (ev: Key_Event, n: int, res: Parse_Result) {
    if len(buf) == 0 {
        return {}, 0, .None
    }
    if buf[0] != 0x1b {
        return parse_text(buf)
    }
    if len(buf) == 1 {
        // A lone ESC. Ambiguous only if the terminal ignored the disambiguate flag; with it, a
        // real Escape arrives as CSI 27 u and this is the leading byte of something unfinished.
        return {}, 0, .Incomplete
    }
    if buf[1] == '[' {
        for m in ([]struct{want: string, res: Parse_Result}{{PASTE_BEGIN, .Paste_Begin}, {PASTE_END, .Paste_End}}) {
            switch match(buf, m.want) {
            case .Full:
                return {}, len(m.want), m.res
            case .Partial:
                return {}, 0, .Incomplete
            case .Miss:
            }
        }
    }
    if buf[1] != '[' {
        return {}, 1, .None // an escape sequence we do not speak; drop the ESC and resync
    }
    return parse_csi(buf)
}

// The Unicode private use areas, which is where the protocol encodes keys that are not
// characters. Nothing in them is ever text.
@(private = "file")
is_private_use :: proc(c: i32) -> bool {
    return (c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0x10FFFD)
}

@(private = "file")
Match :: enum {
    Miss,
    Partial, // as far as it goes, it matches; the rest has not arrived
    Full,
}

// Partial is not a miss. A paste marker split across two reads would otherwise be handed to the
// CSI parser, which would eat it and hand the content to the bind table. `\e[20` is a prefix of
// both `\e[200~` and F9's `\e[20~`, so one more byte is genuinely needed to tell them apart.
@(private = "file")
match :: proc(buf: []u8, want: string) -> Match {
    n := min(len(buf), len(want))
    if string(buf[:n]) != want[:n] {
        return .Miss
    }
    return n == len(want) ? .Full : .Partial
}

@(private = "file")
parse_text :: proc(buf: []u8) -> (ev: Key_Event, n: int, res: Parse_Result) {
    r, size := utf8.decode_rune(buf)
    if r == utf8.RUNE_ERROR && size <= 1 {
        // Either a truncated multi-byte rune, or a stray byte. One byte of buffer cannot tell
        // them apart, so wait; a full buffer is drained by the caller either way.
        return {}, 0, .Incomplete
    }
    return Key_Event{form = .Codepoint, code = i32(r), kind = .Press, text = r}, size, .Event
}

// CSI params are `a:b;c:d;e`, and every field and subfield is optional.
@(private = "file")
parse_csi :: proc(buf: []u8) -> (ev: Key_Event, n: int, res: Parse_Result) {
    fields: [3][2]i32 // [field][subfield], -1 for absent
    for &f in fields {
        f = {-1, -1}
    }
    fi, si := 0, 0
    seen := false

    i := 2
    for ; i < len(buf); i += 1 {
        c := buf[i]
        switch {
        case c >= '0' && c <= '9':
            if fields[fi][si] < 0 {
                fields[fi][si] = 0
            }
            fields[fi][si] = fields[fi][si] * 10 + i32(c - '0')
            seen = true
        case c == ':':
            if si == 1 {
                return {}, 0, .None // a third subfield is not a shape we read
            }
            si = 1
        case c == ';':
            if fi == 2 {
                return {}, i + 1, .None // more fields than the format has
            }
            fi += 1
            si = 0
        case:
            return finish_csi(fields, seen, c, i + 1)
        }
    }
    return {}, 0, .Incomplete
}

@(private = "file")
finish_csi :: proc(fields: [3][2]i32, seen: bool, final: u8, n: int) -> (Key_Event, int, Parse_Result) {
    ev := Key_Event {
        mods = max(0, fields[1][0] - 1), // the protocol sends 1 + the bitfield
        kind = .Press,
    }
    if k := fields[1][1]; k >= 1 && k <= 3 {
        ev.kind = Key_Kind(k)
    }
    if t := fields[2][0]; t > 0 {
        ev.text = rune(t)
    }

    switch final {
    case 'u':
        if !seen {
            return {}, n, .None
        }
        ev.form = .Codepoint
        ev.code = fields[0][0] // kitty protocol exclusions
        if ev.text == 0 && ev.mods == 0 && ev.code >= 32 && !is_private_use(ev.code) {
            ev.text = rune(ev.code)
        }
    case '~':
        if !seen {
            return {}, n, .None
        }
        ev.form = .Tilde
        ev.code = fields[0][0]
    case 'A', 'B', 'C', 'D', 'H', 'F', 'P', 'Q', 'R', 'S':
        ev.form = .Letter
        ev.code = i32(final)
    case:
        return {}, n, .None // some other csi, mouse report, status reply
    }
    return ev, n, .Event
}
