package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// D-Bus — a from-scratch wire client (see "System panes" in plan.txt). We speak the
// protocol directly rather than binding libdbus-1: it is the transport every system pane
// rides on, so it must never be the one dependency we can't degrade from, and — the real
// win — marshalling is a pure function over bytes, so all of it unit-tests headless with
// no bus, no daemon (src/tests/dbus_test.odin).
//
// The protocol, in full:
//   - A connection is a unix socket. The address comes from the environment
//     (DBUS_SESSION_BUS_ADDRESS) or the well-known system path.
//   - Auth is a line protocol: a leading NUL byte, then `AUTH EXTERNAL <uid-in-hex>`,
//     then BEGIN. After BEGIN the stream is binary and never goes back.
//   - A message is a 12-byte fixed header, an `a(yv)` array of header fields, padding to
//     the next 8-byte boundary, then the body marshalled per its signature.
//   - Every type has a fixed alignment and is written at an offset that is a multiple of
//     it, counting from the START OF THE MESSAGE. That single rule is the whole format.
//
// Ownership: decoded messages BORROW. dbus_msg_decode returns strings that alias the
// buffer you handed it, and dbus_msg_args parses the body into an allocator you choose
// (temp, per frame). Nothing here clones — clone what you keep (same trap as os.dir).
//
// Not implemented (deliberately, until something needs it): unix-fd passing ('h' is
// carried as the u32 index it is on the wire, but no fds ride the control message), and
// the serve-side vtable dispatcher. The reply CONSTRUCTORS that dispatcher needs are
// here (dbus_msg_return / dbus_msg_error), so exporting an object is additive.

DBUS_SYSTEM_PATH :: "/run/dbus/system_bus_socket" // the well-known system bus socket
DBUS_PROTOCOL_VERSION :: 1
DBUS_MAX_MESSAGE :: 134217728 // the spec's hard ceiling (128 MiB); a sanity bound on reads

Dbus_Bus :: enum {
    Session,
    System,
}

Dbus_Msg_Type :: enum u8 {
    Invalid       = 0,
    Method_Call   = 1,
    Method_Return = 2,
    Error         = 3,
    Signal        = 4,
}

// Header field codes. Each is carried as a (byte, variant) pair in the header array.
Dbus_Field :: enum u8 {
    Invalid      = 0,
    Path         = 1, // o
    Interface    = 2, // s
    Member       = 3, // s
    Error_Name   = 4, // s
    Reply_Serial = 5, // u
    Destination  = 6, // s
    Sender       = 7, // s
    Signature    = 8, // g
    Unix_Fds     = 9, // u
}

// Message flags (only the two we ever set).
DBUS_NO_REPLY_EXPECTED :: 0x1
DBUS_NO_AUTO_START :: 0x2

// The three string-ish types are distinct so a union can tell them apart: they marshal
// differently ('s'/'o' take a u32 length, 'g' a single byte) and mixing them up is a
// wire error the daemon rejects, not something to discover at runtime.
Dbus_String :: distinct string
Dbus_Path :: distinct string
Dbus_Signature :: distinct string

Dbus_Array :: struct {
    sig:   string, // the ELEMENT signature ("s" for as, "{sv}" for a{sv})
    items: []Dbus_Value,
}

Dbus_Struct :: struct {
    fields: []Dbus_Value,
}

Dbus_Entry :: struct {
    key, val: ^Dbus_Value,
}

Dbus_Variant :: struct {
    sig: string, // the contained type's signature
    val: ^Dbus_Value,
}

// One marshalled value. Containers nest through slices/pointers, so the union stays a
// fixed size. `bool` is stored as Odin's bool (the wire form is a u32 0/1).
Dbus_Value :: union {
    u8,
    bool,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    f64,
    Dbus_String,
    Dbus_Path,
    Dbus_Signature,
    Dbus_Array,
    Dbus_Struct,
    Dbus_Entry,
    Dbus_Variant,
}

// A decoded message. Every string BORROWS from `raw` (see the ownership note above);
// the body is left unparsed until dbus_msg_args is called with an allocator.
Dbus_Message :: struct {
    type:         Dbus_Msg_Type,
    flags:        u8,
    serial:       u32,
    reply_serial: u32,
    big:          bool, // the sender's byte order (we always WRITE little-endian)
    path:         string,
    iface:        string,
    member:       string,
    error_name:   string,
    destination:  string,
    sender:       string,
    signature:    string, // the body's signature ("" for an empty body)
    body:         []u8, // the body slice within raw
    raw:          []u8, // the whole message; owned by whoever produced it
}

// --- signatures ---

// Byte alignment of the type `c` introduces. Every marshalled value sits at an offset
// that is a multiple of this, measured from the start of the message.
dbus_align_of :: proc(ch: u8) -> int {
    switch ch {
    case 'y', 'g', 'v':
        return 1
    case 'n', 'q':
        return 2
    case 'b', 'i', 'u', 's', 'o', 'a', 'h':
        return 4
    case 'x', 't', 'd', '(', ')', '{', '}', 'r', 'e':
        return 8
    }
    return 0 // not a type code
}

// Alignment of the first complete type in `sig` (0 when sig is empty/invalid).
dbus_sig_align :: proc(sig: string) -> int {
    return len(sig) > 0 ? dbus_align_of(sig[0]) : 0
}

// Length in bytes of the FIRST complete type in `sig`, or 0 if it is malformed. A basic
// type is one byte; `a` prefixes another complete type; `(`/`{` run to their match. This
// is the one primitive every container walk is built from.
dbus_sig_next :: proc(sig: string) -> int {
    if len(sig) == 0 {
        return 0
    }
    switch sig[0] {
    case 'a':
        n := dbus_sig_next(sig[1:])
        return n == 0 ? 0 : 1 + n
    case '(', '{':
        opener := sig[0]
        closer := opener == '(' ? byte(')') : byte('}')
        depth := 0
        for i in 0 ..< len(sig) {
            if sig[i] == opener {
                depth += 1
            } else if sig[i] == closer {
                depth -= 1
                if depth == 0 {
                    return i + 1
                }
            }
        }
        return 0 // unterminated
    case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h':
        return 1
    }
    return 0
}

// Splits a signature into its complete types ("sa{sv}u" -> ["s", "a{sv}", "u"]). Returns
// ok=false on a malformed signature so a bad reply can't be walked as if it parsed.
dbus_sig_split :: proc(sig: string, alloc := context.temp_allocator) -> (out: []string, ok: bool) {
    parts := make([dynamic]string, 0, 4, alloc)
    rest := sig
    for len(rest) > 0 {
        n := dbus_sig_next(rest)
        if n == 0 {
            return nil, false
        }
        append(&parts, rest[:n])
        rest = rest[n:]
    }
    return parts[:], true
}

// --- writer ---

// Marshals into a growing buffer. Alignment is computed from len(buf), so a writer must
// start at an offset congruent to the message start mod 8 — which every caller here does
// (the message builder writes in place; a standalone body is appended at an 8-boundary).
Dbus_Writer :: struct {
    buf: [dynamic]u8,
}

dbus_writer_destroy :: proc(w: ^Dbus_Writer) {
    delete(w.buf)
}

// Pads to the next multiple of `align` with NULs. The spec requires the padding be zero.
dbus_pad :: proc(w: ^Dbus_Writer, align: int) {
    if align <= 1 {
        return
    }
    for len(w.buf) % align != 0 {
        append(&w.buf, 0)
    }
}

// Appends `n` little-endian bytes of `v`. We always write little-endian and advertise it
// in the header, so no caller ever chooses a byte order.
@(private = "file")
put_le :: proc(w: ^Dbus_Writer, v: u64, n: int) {
    for i in 0 ..< n {
        append(&w.buf, u8(v >> uint(8 * i)))
    }
}

// Patches an already-written little-endian u32 (used to backfill array byte lengths).
@(private = "file")
patch_u32 :: proc(w: ^Dbus_Writer, at: int, v: u32) {
    for i in 0 ..< 4 {
        w.buf[at + i] = u8(v >> uint(8 * i))
    }
}

// s/o: aligned u32 length (excluding the terminator) + bytes + NUL.
@(private = "file")
put_string :: proc(w: ^Dbus_Writer, s: string) {
    dbus_pad(w, 4)
    put_le(w, u64(len(s)), 4)
    append(&w.buf, s)
    append(&w.buf, 0)
}

// g: single-byte length + bytes + NUL, no alignment. Signatures are capped at 255 bytes
// by the format itself.
@(private = "file")
put_sig :: proc(w: ^Dbus_Writer, s: string) -> bool {
    if len(s) > 255 {
        return false
    }
    append(&w.buf, u8(len(s)))
    append(&w.buf, s)
    append(&w.buf, 0)
    return true
}

// Marshals one value as `sig`. Returns false if the value's type doesn't match the
// signature — strict on purpose: a mismatch is a bug on our side, and the daemon would
// only reject it later with a far less useful message.
dbus_marshal_one :: proc(w: ^Dbus_Writer, sig: string, v: Dbus_Value) -> bool {
    if len(sig) == 0 {
        return false
    }
    switch sig[0] {
    case 'y':
        x := v.(u8) or_return
        append(&w.buf, x)
    case 'b':
        x := v.(bool) or_return
        dbus_pad(w, 4)
        put_le(w, x ? 1 : 0, 4)
    case 'n':
        x := v.(i16) or_return
        dbus_pad(w, 2)
        put_le(w, u64(u16(x)), 2)
    case 'q':
        x := v.(u16) or_return
        dbus_pad(w, 2)
        put_le(w, u64(x), 2)
    case 'i':
        x := v.(i32) or_return
        dbus_pad(w, 4)
        put_le(w, u64(u32(x)), 4)
    case 'u', 'h':
        x := v.(u32) or_return
        dbus_pad(w, 4)
        put_le(w, u64(x), 4)
    case 'x':
        x := v.(i64) or_return
        dbus_pad(w, 8)
        put_le(w, u64(x), 8)
    case 't':
        x := v.(u64) or_return
        dbus_pad(w, 8)
        put_le(w, x, 8)
    case 'd':
        x := v.(f64) or_return
        dbus_pad(w, 8)
        put_le(w, transmute(u64)x, 8)
    case 's':
        x := v.(Dbus_String) or_return
        put_string(w, string(x))
    case 'o':
        x := v.(Dbus_Path) or_return
        put_string(w, string(x))
    case 'g':
        x := v.(Dbus_Signature) or_return
        put_sig(w, string(x)) or_return
    case 'v':
        x := v.(Dbus_Variant) or_return
        put_sig(w, x.sig) or_return
        if x.val == nil {
            return false
        }
        dbus_marshal_one(w, x.sig, x.val^) or_return
    case 'a':
        x := v.(Dbus_Array) or_return
        elem := sig[1:]
        if dbus_sig_next(elem) != len(elem) || len(elem) == 0 {
            return false // an array's element must be exactly one complete type
        }
        // The length is the byte count of the ELEMENTS ONLY: the padding between the
        // length word and the first element is not counted. Getting this wrong is the
        // classic D-Bus bug, and it only shows up on 8-aligned element types.
        dbus_pad(w, 4)
        len_at := len(w.buf)
        put_le(w, 0, 4)
        dbus_pad(w, dbus_sig_align(elem))
        start := len(w.buf)
        for item in x.items {
            dbus_marshal_one(w, elem, item) or_return
        }
        patch_u32(w, len_at, u32(len(w.buf) - start))
    case '(':
        x := v.(Dbus_Struct) or_return
        n := dbus_sig_next(sig)
        if n < 2 {
            return false
        }
        fields := dbus_sig_split(sig[1:n - 1]) or_return
        if len(fields) != len(x.fields) {
            return false
        }
        dbus_pad(w, 8)
        for f, i in fields {
            dbus_marshal_one(w, f, x.fields[i]) or_return
        }
    case '{':
        x := v.(Dbus_Entry) or_return
        n := dbus_sig_next(sig)
        if n < 2 {
            return false
        }
        kv := dbus_sig_split(sig[1:n - 1]) or_return
        if len(kv) != 2 || x.key == nil || x.val == nil {
            return false
        }
        dbus_pad(w, 8)
        dbus_marshal_one(w, kv[0], x.key^) or_return
        dbus_marshal_one(w, kv[1], x.val^) or_return
    case:
        return false
    }
    return true
}

// Marshals `args` as the complete-type sequence `sig`.
dbus_marshal :: proc(w: ^Dbus_Writer, sig: string, args: []Dbus_Value) -> bool {
    types := dbus_sig_split(sig) or_return
    if len(types) != len(args) {
        return false
    }
    for t, i in types {
        dbus_marshal_one(w, t, args[i]) or_return
    }
    return true
}

// Convenience: marshal a standalone body into fresh bytes. Safe to append at any
// 8-aligned offset, since every alignment divides 8.
dbus_marshal_bytes :: proc(
    sig: string,
    args: []Dbus_Value,
    alloc := context.temp_allocator,
) -> (
    out: []u8,
    ok: bool,
) {
    w := Dbus_Writer{buf = make([dynamic]u8, 0, 64, alloc)}
    dbus_marshal(&w, sig, args) or_return
    return w.buf[:], true
}

// --- reader ---

// Reads from a message buffer. `pos` is an offset INTO THE WHOLE MESSAGE, because that
// is what alignment is measured from — so the header array (which starts at offset 12,
// not an 8-boundary) and the body both decode correctly with one reader.
Dbus_Reader :: struct {
    data: []u8,
    pos:  int,
    big:  bool, // the sender's byte order
}

@(private = "file")
take :: proc(r: ^Dbus_Reader, n: int) -> (out: []u8, ok: bool) {
    if n < 0 || r.pos + n > len(r.data) {
        return nil, false
    }
    out = r.data[r.pos:r.pos + n]
    r.pos += n
    return out, true
}

// Skips to the next multiple of `align`. Padding bytes are not validated to be zero —
// lenient on read, strict on write, per the usual robustness split.
@(private = "file")
skip_pad :: proc(r: ^Dbus_Reader, align: int) -> bool {
    if align <= 1 {
        return true
    }
    for r.pos % align != 0 {
        if r.pos >= len(r.data) {
            return false
        }
        r.pos += 1
    }
    return true
}

@(private = "file")
get_uint :: proc(r: ^Dbus_Reader, n: int) -> (v: u64, ok: bool) {
    skip_pad(r, n) or_return
    b := take(r, n) or_return
    if r.big {
        for i in 0 ..< n {
            v = v << 8 | u64(b[i])
        }
    } else {
        for i := n - 1; i >= 0; i -= 1 {
            v = v << 8 | u64(b[i])
        }
    }
    return v, true
}

// s/o: u32 length + bytes + NUL. The returned string ALIASES the message buffer.
@(private = "file")
get_string :: proc(r: ^Dbus_Reader) -> (s: string, ok: bool) {
    n := get_uint(r, 4) or_return
    if n > u64(len(r.data)) {
        return "", false // reject an absurd length before it becomes a huge take
    }
    b := take(r, int(n)) or_return
    take(r, 1) or_return // the NUL terminator
    return string(b), true
}

// g: byte length + bytes + NUL. Aliases the message buffer.
@(private = "file")
get_sig :: proc(r: ^Dbus_Reader) -> (s: string, ok: bool) {
    b := take(r, 1) or_return
    body := take(r, int(b[0])) or_return
    take(r, 1) or_return
    return string(body), true
}

// Reads one value of type `sig`. Container slices come from `alloc`; strings alias the
// buffer. Returns false on any truncation, bad length, or malformed signature — this is
// untrusted input from the bus, so every read is bounds-checked.
dbus_unmarshal_one :: proc(
    r: ^Dbus_Reader,
    sig: string,
    alloc := context.temp_allocator,
) -> (
    v: Dbus_Value,
    ok: bool,
) {
    if len(sig) == 0 {
        return nil, false
    }
    switch sig[0] {
    case 'y':
        b := take(r, 1) or_return
        return b[0], true
    case 'b':
        x := get_uint(r, 4) or_return
        return x != 0, true
    case 'n':
        x := get_uint(r, 2) or_return
        return i16(u16(x)), true
    case 'q':
        x := get_uint(r, 2) or_return
        return u16(x), true
    case 'i':
        x := get_uint(r, 4) or_return
        return i32(u32(x)), true
    case 'u', 'h':
        x := get_uint(r, 4) or_return
        return u32(x), true
    case 'x':
        x := get_uint(r, 8) or_return
        return i64(x), true
    case 't':
        x := get_uint(r, 8) or_return
        return x, true
    case 'd':
        x := get_uint(r, 8) or_return
        return transmute(f64)x, true
    case 's':
        s := get_string(r) or_return
        return Dbus_String(s), true
    case 'o':
        s := get_string(r) or_return
        return Dbus_Path(s), true
    case 'g':
        s := get_sig(r) or_return
        return Dbus_Signature(s), true
    case 'v':
        inner := get_sig(r) or_return
        if dbus_sig_next(inner) != len(inner) || len(inner) == 0 {
            return nil, false
        }
        val := new(Dbus_Value, alloc)
        val^ = dbus_unmarshal_one(r, inner, alloc) or_return
        return Dbus_Variant{sig = inner, val = val}, true
    case 'a':
        elem := sig[1:]
        if dbus_sig_next(elem) != len(elem) || len(elem) == 0 {
            return nil, false
        }
        n := get_uint(r, 4) or_return
        skip_pad(r, dbus_sig_align(elem)) or_return
        if n > DBUS_MAX_MESSAGE || r.pos + int(n) > len(r.data) {
            return nil, false
        }
        end := r.pos + int(n)
        items := make([dynamic]Dbus_Value, 0, 8, alloc)
        for r.pos < end {
            item := dbus_unmarshal_one(r, elem, alloc) or_return
            append(&items, item)
        }
        if r.pos != end {
            return nil, false // an element ran past the declared array length
        }
        return Dbus_Array{sig = elem, items = items[:]}, true
    case '(':
        n := dbus_sig_next(sig)
        if n < 2 {
            return nil, false
        }
        types := dbus_sig_split(sig[1:n - 1], alloc) or_return
        skip_pad(r, 8) or_return
        fields := make([]Dbus_Value, len(types), alloc)
        for t, i in types {
            fields[i] = dbus_unmarshal_one(r, t, alloc) or_return
        }
        return Dbus_Struct{fields = fields}, true
    case '{':
        n := dbus_sig_next(sig)
        if n < 2 {
            return nil, false
        }
        kv := dbus_sig_split(sig[1:n - 1], alloc) or_return
        if len(kv) != 2 {
            return nil, false
        }
        skip_pad(r, 8) or_return
        key := new(Dbus_Value, alloc)
        val := new(Dbus_Value, alloc)
        key^ = dbus_unmarshal_one(r, kv[0], alloc) or_return
        val^ = dbus_unmarshal_one(r, kv[1], alloc) or_return
        return Dbus_Entry{key = key, val = val}, true
    }
    return nil, false
}

// Reads the complete-type sequence `sig` as an argument list.
dbus_unmarshal :: proc(
    r: ^Dbus_Reader,
    sig: string,
    alloc := context.temp_allocator,
) -> (
    out: []Dbus_Value,
    ok: bool,
) {
    types := dbus_sig_split(sig, alloc) or_return
    args := make([]Dbus_Value, len(types), alloc)
    for t, i in types {
        args[i] = dbus_unmarshal_one(r, t, alloc) or_return
    }
    return args, true
}

// --- messages ---

// Builds a complete message. `body_sig`/`args` may be empty for a no-argument call. The
// header fields are written in place (they start at offset 12, which is why marshalling
// is offset-aware), then padded to 8 before the body is appended.
dbus_msg_build :: proc(
    type: Dbus_Msg_Type,
    serial: u32,
    flags: u8 = 0,
    path: string = "",
    iface: string = "",
    member: string = "",
    destination: string = "",
    error_name: string = "",
    reply_serial: u32 = 0,
    body_sig: string = "",
    args: []Dbus_Value = nil,
    alloc := context.allocator,
) -> (
    out: []u8,
    ok: bool,
) {
    body := dbus_marshal_bytes(body_sig, args, context.temp_allocator) or_return

    w := Dbus_Writer{buf = make([dynamic]u8, 0, 128 + len(body), alloc)}
    append(&w.buf, 'l') // we always emit little-endian
    append(&w.buf, u8(type))
    append(&w.buf, flags)
    append(&w.buf, DBUS_PROTOCOL_VERSION)
    put_le(&w, u64(len(body)), 4)
    put_le(&w, u64(serial), 4)

    // The header field array, a(yv). Written by hand rather than through a Dbus_Array so
    // the variants don't each need a heap cell for one string.
    len_at := len(w.buf)
    put_le(&w, 0, 4)
    dbus_pad(&w, 8) // (yv) is a struct: 8-aligned
    start := len(w.buf)
    put_field_str :: proc(w: ^Dbus_Writer, f: Dbus_Field, type_sig, val: string) {
        if val == "" {
            return
        }
        dbus_pad(w, 8)
        append(&w.buf, u8(f))
        put_sig(w, type_sig)
        if type_sig == "g" {
            put_sig(w, val)
        } else {
            put_string(w, val)
        }
    }
    put_field_str(&w, .Path, "o", path)
    put_field_str(&w, .Interface, "s", iface)
    put_field_str(&w, .Member, "s", member)
    put_field_str(&w, .Error_Name, "s", error_name)
    if reply_serial != 0 {
        dbus_pad(&w, 8)
        append(&w.buf, u8(Dbus_Field.Reply_Serial))
        put_sig(&w, "u")
        dbus_pad(&w, 4)
        put_le(&w, u64(reply_serial), 4)
    }
    put_field_str(&w, .Destination, "s", destination)
    put_field_str(&w, .Signature, "g", body_sig)
    patch_u32(&w, len_at, u32(len(w.buf) - start))

    dbus_pad(&w, 8) // the body always starts on an 8-boundary
    append(&w.buf, ..body)
    return w.buf[:], true
}

// A method call. Serial must be nonzero and unique on the connection (dbus_next_serial).
dbus_msg_call :: proc(
    serial: u32,
    destination, path, iface, member: string,
    body_sig: string = "",
    args: []Dbus_Value = nil,
    alloc := context.allocator,
) -> (
    out: []u8,
    ok: bool,
) {
    return dbus_msg_build(
        .Method_Call,
        serial,
        destination = destination,
        path = path,
        iface = iface,
        member = member,
        body_sig = body_sig,
        args = args,
        alloc = alloc,
    )
}

// A successful reply to `to`. The serve-side primitive: an exported object answers a
// call with this (see the agent work in the plan's Phase 3).
dbus_msg_return :: proc(
    serial: u32,
    to: ^Dbus_Message,
    body_sig: string = "",
    args: []Dbus_Value = nil,
    alloc := context.allocator,
) -> (
    out: []u8,
    ok: bool,
) {
    return dbus_msg_build(
        .Method_Return,
        serial,
        flags = DBUS_NO_REPLY_EXPECTED,
        destination = to.sender,
        reply_serial = to.serial,
        body_sig = body_sig,
        args = args,
        alloc = alloc,
    )
}

// An error reply to `to`. `name` is a dotted D-Bus error name; `msg` its human text.
dbus_msg_error :: proc(
    serial: u32,
    to: ^Dbus_Message,
    name, msg: string,
    alloc := context.allocator,
) -> (
    out: []u8,
    ok: bool,
) {
    text := Dbus_Value(Dbus_String(msg))
    return dbus_msg_build(
        .Error,
        serial,
        flags = DBUS_NO_REPLY_EXPECTED,
        destination = to.sender,
        error_name = name,
        reply_serial = to.serial,
        body_sig = "s",
        args = []Dbus_Value{text},
        alloc = alloc,
    )
}

// Total wire length of the message starting at `data`, or 0 if the 16-byte prefix isn't
// there yet / the header is nonsense. Lets a reader size one message before taking it.
dbus_msg_size :: proc(data: []u8) -> int {
    if len(data) < 16 {
        return 0
    }
    if data[0] != 'l' && data[0] != 'B' {
        return 0
    }
    big := data[0] == 'B'
    rd := func_u32(data[4:8], big) // body length
    hf := func_u32(data[12:16], big) // header-field array length
    total := 16 + int(hf)
    total = (total + 7) & ~int(7) // the body starts on an 8-boundary
    total += int(rd)
    if rd > DBUS_MAX_MESSAGE || hf > DBUS_MAX_MESSAGE || total < 16 {
        return 0
    }
    return total
}

@(private = "file")
func_u32 :: proc(b: []u8, big: bool) -> u32 {
    if big {
        return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
    }
    return u32(b[3]) << 24 | u32(b[2]) << 16 | u32(b[1]) << 8 | u32(b[0])
}

// Decodes a whole message. Strings in the result ALIAS `data`; the body is left raw
// (parse it with dbus_msg_args). Header fields are walked with the temp allocator and
// only their string slices are kept, so decoding allocates nothing lasting.
dbus_msg_decode :: proc(data: []u8) -> (msg: Dbus_Message, ok: bool) {
    total := dbus_msg_size(data)
    if total == 0 || total > len(data) {
        return {}, false
    }
    m := Dbus_Message {
        big    = data[0] == 'B',
        type   = Dbus_Msg_Type(data[1]),
        flags  = data[2],
        raw    = data[:total],
    }
    if data[3] != DBUS_PROTOCOL_VERSION {
        return {}, false
    }
    body_len := int(func_u32(data[4:8], m.big))
    m.serial = func_u32(data[8:12], m.big)

    // The header fields are a(yv) beginning at offset 12 — decoded through the normal
    // reader so the offset-relative alignment is the same code path as everything else.
    r := Dbus_Reader {
        data = data[:total],
        pos  = 12,
        big  = m.big,
    }
    fields := dbus_unmarshal_one(&r, "a(yv)", context.temp_allocator) or_return
    arr := fields.(Dbus_Array) or_return
    for item in arr.items {
        st := item.(Dbus_Struct) or_return
        if len(st.fields) != 2 {
            return {}, false
        }
        code := st.fields[0].(u8) or_return
        va := st.fields[1].(Dbus_Variant) or_return
        if va.val == nil {
            return {}, false
        }
        // Every string-ish field reads the same way, so pull it once; the numeric ones
        // assert their own type. A field carrying the wrong type is a malformed message.
        text, is_text := dbus_as_string(va.val^)
        switch Dbus_Field(code) {
        case .Path:
            m.path = text
        case .Interface:
            m.iface = text
        case .Member:
            m.member = text
        case .Error_Name:
            m.error_name = text
        case .Destination:
            m.destination = text
        case .Sender:
            m.sender = text
        case .Signature:
            m.signature = text
        case .Reply_Serial:
            m.reply_serial = va.val.(u32) or_return
            is_text = true
        case .Unix_Fds: // carried, but we pass no fds — see the file header
            is_text = true
        case .Invalid:
            return {}, false
        }
        if !is_text {
            return {}, false
        }
    }

    body_at := (r.pos + 7) & ~int(7)
    if body_at + body_len > total {
        return {}, false
    }
    m.body = data[body_at:body_at + body_len]
    return m, true
}

// Parses the body into its arguments, allocating container slices from `alloc` (temp,
// per frame, is the intended use). Strings alias the message.
dbus_msg_args :: proc(
    msg: ^Dbus_Message,
    alloc := context.temp_allocator,
) -> (
    out: []Dbus_Value,
    ok: bool,
) {
    if msg.signature == "" {
        return nil, true
    }
    // The reader spans the WHOLE message so body offsets keep their alignment; body is a
    // slice of raw, so its start is the offset to seek to.
    r := Dbus_Reader {
        data = msg.raw,
        pos  = len(msg.raw) - len(msg.body),
        big  = msg.big,
    }
    return dbus_unmarshal(&r, msg.signature, alloc)
}

// --- address + auth (pure; the socket work is below) ---

// Picks the bus address from the environment, falling back to the well-known system
// path. Returns the RAW address string (still to be parsed by dbus_parse_address).
dbus_bus_address :: proc(bus: Dbus_Bus, alloc := context.temp_allocator) -> string {
    switch bus {
    case .Session:
        if v := os.get_env("DBUS_SESSION_BUS_ADDRESS", alloc); v != "" {
            return v
        }
        // The systemd-era default when the variable is unset.
        return fmt.aprintf("unix:path=/run/user/%d/bus", os.get_uid(), allocator = alloc)
    case .System:
        if v := os.get_env("DBUS_SYSTEM_BUS_ADDRESS", alloc); v != "" {
            return v
        }
        return strings.clone("unix:path=" + DBUS_SYSTEM_PATH, alloc)
    }
    return ""
}

// Parses a D-Bus address into a unix socket path. An address is a `;`-separated list of
// `transport:key=value,key=value` entries; we take the first unix entry we understand.
// Values are %XX-escaped. `abstract` selects Linux's abstract namespace (a leading NUL
// in sun_path rather than a filesystem path).
dbus_parse_address :: proc(
    addr: string,
    alloc := context.temp_allocator,
) -> (
    path: string,
    abstract: bool,
    ok: bool,
) {
    rest := addr
    for len(rest) > 0 {
        entry := rest
        if semi := strings.index_byte(rest, ';'); semi >= 0 {
            entry = rest[:semi]
            rest = rest[semi + 1:]
        } else {
            rest = ""
        }
        colon := strings.index_byte(entry, ':')
        if colon < 0 || entry[:colon] != "unix" {
            continue
        }
        for kv in strings.split_iterator(&entry, ",") {
            // The transport prefix rides on the first pair ("unix:path=/tmp/x").
            pair := kv
            if c := strings.index_byte(pair, ':'); c >= 0 && c < strings.index_byte(pair, '=') {
                pair = pair[c + 1:]
            }
            eq := strings.index_byte(pair, '=')
            if eq < 0 {
                continue
            }
            key, val := pair[:eq], dbus_unescape(pair[eq + 1:], alloc)
            switch key {
            case "path":
                return val, false, true
            case "abstract":
                return val, true, true
            }
        }
    }
    return "", false, false
}

// Decodes the %XX escapes an address value may carry.
dbus_unescape :: proc(s: string, alloc := context.temp_allocator) -> string {
    if !strings.contains(s, "%") {
        return s
    }
    b := strings.builder_make(alloc)
    for i := 0; i < len(s); i += 1 {
        if s[i] == '%' && i + 2 < len(s) {
            if v, vok := strconv.parse_int(s[i + 1:i + 3], 16); vok {
                strings.write_byte(&b, u8(v))
                i += 2
                continue
            }
        }
        strings.write_byte(&b, s[i])
    }
    return strings.to_string(b)
}

// The AUTH line for EXTERNAL: the credential is our uid, written in decimal and then
// hex-encoded as ASCII (uid 1000 -> "31303030"). The kernel supplies the real identity
// over the socket; this string only has to agree with it.
dbus_auth_line :: proc(uid: int, alloc := context.temp_allocator) -> string {
    HEX := "0123456789abcdef"
    b := strings.builder_make(alloc)
    strings.write_string(&b, "AUTH EXTERNAL ")
    dec := strings.builder_make(context.temp_allocator)
    strings.write_int(&dec, uid)
    for ch in transmute([]u8)strings.to_string(dec) {
        strings.write_byte(&b, HEX[ch >> 4])
        strings.write_byte(&b, HEX[ch & 0xf])
    }
    strings.write_string(&b, "\r\n")
    return strings.to_string(b)
}

// --- connection ---

Dbus_Conn :: struct {
    fd:     posix.FD,
    serial: u32, // last serial handed out; serials start at 1
    unique: string, // our unique name from Hello (":1.42"), owned
    inbox:  [dynamic]Dbus_Message, // messages read while awaiting a reply (signals, calls to us)
}

// Opens, authenticates, and says Hello. Returns nil when the bus isn't reachable — every
// caller treats that as "this stack is unavailable" and degrades, never as fatal.
dbus_open :: proc(bus: Dbus_Bus) -> (conn: ^Dbus_Conn, ok: bool) {
    addr := dbus_bus_address(bus)
    path, abstract := dbus_parse_address(addr) or_return
    fd := dbus_socket_connect(path, abstract) or_return

    c := new(Dbus_Conn)
    c.fd = fd
    if !dbus_auth(c) {
        dbus_close(c)
        return nil, false
    }
    // Hello is mandatory and must be the first message: the reply is our unique name.
    reply, rok := dbus_call(
        c,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
    )
    if !rok {
        dbus_close(c)
        return nil, false
    }
    defer dbus_msg_free(&reply)
    if args, aok := dbus_msg_args(&reply); aok && len(args) == 1 {
        if s, sok := args[0].(Dbus_String); sok {
            c.unique = strings.clone(string(s))
        }
    }
    return c, true
}

dbus_close :: proc(c: ^Dbus_Conn) {
    if c == nil {
        return
    }
    if c.fd > 0 {
        posix.close(c.fd)
    }
    for &m in c.inbox {
        dbus_msg_free(&m)
    }
    delete(c.inbox)
    delete(c.unique)
    free(c)
}

// Frees a message's backing buffer. Only messages produced by dbus_read_msg own theirs;
// decoding a borrowed slice does not, so don't free those.
dbus_msg_free :: proc(m: ^Dbus_Message) {
    delete(m.raw)
    m^ = {}
}

// Next serial. Serial 0 is reserved, so the counter skips it on wrap.
dbus_next_serial :: proc(c: ^Dbus_Conn) -> u32 {
    c.serial += 1
    if c.serial == 0 {
        c.serial = 1
    }
    return c.serial
}

@(private = "file")
dbus_socket_connect :: proc(path: string, abstract: bool) -> (fd: posix.FD, ok: bool) {
    if len(path) == 0 || len(path) > 106 {
        return 0, false
    }
    sock := posix.socket(.UNIX, .STREAM)
    if sock < 0 {
        return 0, false
    }
    sa: posix.sockaddr_un
    sa.sun_family = .UNIX
    // Abstract sockets live in a namespace keyed by a leading NUL, so the name starts at
    // sun_path[1] and the length must be given exactly (no terminator).
    off := abstract ? 1 : 0
    for i in 0 ..< len(path) {
        sa.sun_path[off + i] = c.char(path[i])
    }
    n := size_of(posix.sa_family_t) + off + len(path) + (abstract ? 0 : 1)
    if posix.connect(sock, cast(^posix.sockaddr)&sa, posix.socklen_t(n)) != .OK {
        posix.close(sock)
        return 0, false
    }
    return sock, true
}

@(private = "file")
write_all :: proc(fd: posix.FD, data: []u8) -> bool {
    sent := 0
    for sent < len(data) {
        left := len(data) - sent
        n := posix.send(fd, raw_data(data[sent:]), c.size_t(left), {})
        if n <= 0 {
            return false
        }
        sent += int(n)
    }
    return true
}

// Reads exactly len(buf) bytes, or fails. `timeout_ms` < 0 blocks indefinitely.
@(private = "file")
read_all :: proc(fd: posix.FD, buf: []u8, timeout_ms: int) -> bool {
    got := 0
    for got < len(buf) {
        pfd := posix.pollfd {
            fd     = fd,
            events = {.IN},
        }
        if posix.poll(&pfd, 1, c.int(timeout_ms)) <= 0 {
            return false // timed out, or the socket died
        }
        left := len(buf) - got
        n := posix.recv(fd, raw_data(buf[got:]), c.size_t(left), {})
        if n <= 0 {
            return false
        }
        got += int(n)
    }
    return true
}

// Reads one CRLF-terminated auth line. Byte-at-a-time on purpose: the auth phase shares
// the stream with the binary protocol that follows, so we must not read past the CRLF.
@(private = "file")
read_line :: proc(fd: posix.FD, alloc := context.temp_allocator) -> (line: string, ok: bool) {
    b := strings.builder_make(alloc)
    ch: [1]u8
    for _ in 0 ..< 4096 {
        read_all(fd, ch[:], DBUS_AUTH_TIMEOUT) or_return
        if ch[0] == '\n' {
            s := strings.to_string(b)
            return strings.trim_suffix(s, "\r"), true
        }
        strings.write_byte(&b, ch[0])
    }
    return "", false
}

DBUS_AUTH_TIMEOUT :: 5000 // ms; the handshake is local and instant when it works at all
DBUS_CALL_TIMEOUT :: 25000 // ms; matches libdbus's default reply timeout

// The SASL handshake: a leading NUL byte (it carries the credentials on some transports
// and is required on all), AUTH EXTERNAL, then BEGIN. We also send NEGOTIATE_UNIX_FD and
// discard the answer — we pass no fds, but asking keeps us on the same path as every
// other client, and a daemon that refuses is not an error for us.
@(private = "file")
dbus_auth :: proc(c: ^Dbus_Conn) -> bool {
    nul := [1]u8{0}
    write_all(c.fd, nul[:]) or_return
    write_all(c.fd, transmute([]u8)dbus_auth_line(os.get_uid())) or_return
    line := read_line(c.fd) or_return
    if !strings.has_prefix(line, "OK") {
        return false
    }
    negotiate := "NEGOTIATE_UNIX_FD\r\n"
    write_all(c.fd, transmute([]u8)negotiate) or_return
    read_line(c.fd) or_return // AGREE_UNIX_FD or ERROR; either is fine
    begin := "BEGIN\r\n"
    write_all(c.fd, transmute([]u8)begin) or_return
    return true
}

// Reads one whole message off the wire. The 16-byte prefix tells us the total size, so
// there is never a partial message left in a buffer between calls. The returned message
// OWNS its bytes (dbus_msg_free).
dbus_read_msg :: proc(c: ^Dbus_Conn, timeout_ms := DBUS_CALL_TIMEOUT) -> (msg: Dbus_Message, ok: bool) {
    head: [16]u8
    read_all(c.fd, head[:], timeout_ms) or_return
    total := dbus_msg_size(head[:])
    if total == 0 {
        return {}, false
    }
    raw := make([]u8, total)
    copy(raw[:16], head[:])
    if !read_all(c.fd, raw[16:], timeout_ms) {
        delete(raw)
        return {}, false
    }
    m, dok := dbus_msg_decode(raw)
    if !dok {
        delete(raw)
        return {}, false
    }
    return m, true
}

// Sends a method call and waits for its reply, queueing anything else that arrives first
// (signals, calls addressed to us) in c.inbox for the caller to drain.
//
// ok=false means "no method return": either the call failed on the wire, or the daemon
// answered with an error — in which case the ERROR message is still returned, so
// reply.error_name is the thing to read. Always dbus_msg_free the result when ok is true
// or the message came back with a type.
dbus_call :: proc(
    c: ^Dbus_Conn,
    destination, path, iface, member: string,
    body_sig: string = "",
    args: []Dbus_Value = nil,
    timeout_ms := DBUS_CALL_TIMEOUT,
) -> (
    reply: Dbus_Message,
    ok: bool,
) {
    serial := dbus_next_serial(c)
    out := dbus_msg_call(
        serial,
        destination,
        path,
        iface,
        member,
        body_sig,
        args,
        context.temp_allocator,
    ) or_return
    write_all(c.fd, out) or_return

    // Bounded so a chatty bus can't spin here forever while our reply never comes.
    for _ in 0 ..< 1024 {
        m := dbus_read_msg(c, timeout_ms) or_return
        if m.reply_serial == serial && (m.type == .Method_Return || m.type == .Error) {
            return m, m.type == .Method_Return
        }
        append(&c.inbox, m)
    }
    return {}, false
}

// Registers a signal match rule with the daemon (the "tell me about these" call every
// pane makes before it starts listening). `rule` is the usual comma-separated form:
// "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'".
dbus_add_match :: proc(c: ^Dbus_Conn, rule: string) -> bool {
    arg := Dbus_Value(Dbus_String(rule))
    reply, ok := dbus_call(
        c,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "AddMatch",
        "s",
        []Dbus_Value{arg},
    )
    if reply.type != .Invalid {
        dbus_msg_free(&reply)
    }
    return ok
}

// --- value accessors (the shapes the panes actually read) ---

// The string inside a value, whether it was marshalled as s, o, or g. ok=false for
// anything else — including a variant, which must be unwrapped first.
dbus_as_string :: proc(v: Dbus_Value) -> (s: string, ok: bool) {
    #partial switch t in v {
    case Dbus_String:
        return string(t), true
    case Dbus_Path:
        return string(t), true
    case Dbus_Signature:
        return string(t), true
    }
    return "", false
}

// Unwraps a variant one level; any other value passes through unchanged. Property reads
// come back as variants, so nearly every lookup starts here.
dbus_unwrap :: proc(v: Dbus_Value) -> Dbus_Value {
    if va, ok := v.(Dbus_Variant); ok && va.val != nil {
        return va.val^
    }
    return v
}

// Looks a key up in a marshalled dictionary (a{s*}), returning the value UNWRAPPED —
// so a a{sv} property bag hands back the property itself, not its variant shell.
dbus_dict_get :: proc(v: Dbus_Value, key: string) -> (out: Dbus_Value, ok: bool) {
    arr := v.(Dbus_Array) or_return
    for item in arr.items {
        e := item.(Dbus_Entry) or_continue
        if e.key == nil || e.val == nil {
            continue
        }
        k := dbus_as_string(e.key^) or_continue
        if k == key {
            return dbus_unwrap(e.val^), true
        }
    }
    return nil, false
}

// Convenience for the overwhelmingly common case: a string property out of a a{sv}.
dbus_dict_string :: proc(v: Dbus_Value, key: string) -> (s: string, ok: bool) {
    val := dbus_dict_get(v, key) or_return
    return dbus_as_string(val)
}
