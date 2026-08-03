package tests

import app ".."
import "core:fmt"
import "core:strings"
import "core:testing"

// D-Bus wire tests. Layer 1 of the three-layer model (see plan.txt): PURE — no socket,
// no daemon, no bus. Marshalling is a function from values to bytes, so the vectors here
// are hand-computed from the spec rather than captured from our own encoder: a
// round-trip test alone would pass happily with a symmetric bug on both sides.
//
// The layout of every expectation is spelled out in a comment, because "why is there a
// 4-byte hole here" is the only hard question in this format.

@(private = "file")
expect_bytes :: proc(t: ^testing.T, got: []u8, want: []u8, label: string) {
    if len(got) != len(want) {
        testing.expectf(t, false, "%s: length %d, want %d\n got:  %s\n want: %s",
            label, len(got), len(want), hex(got), hex(want))
        return
    }
    for b, i in got {
        if b != want[i] {
            testing.expectf(t, false, "%s: byte %d is 0x%02x, want 0x%02x\n got:  %s\n want: %s",
                label, i, b, want[i], hex(got), hex(want))
            return
        }
    }
}

@(private = "file")
hex :: proc(b: []u8) -> string {
    sb := strings.builder_make(context.temp_allocator)
    for x, i in b {
        if i > 0 && i % 8 == 0 {
            strings.write_byte(&sb, ' ')
        }
        fmt.sbprintf(&sb, "%02x", x)
    }
    return strings.to_string(sb)
}

// Marshals and asserts the exact bytes.
@(private = "file")
expect_marshal :: proc(t: ^testing.T, sig: string, args: []app.Dbus_Value, want: []u8, label: string) {
    got, ok := app.dbus_marshal_bytes(sig, args)
    if !testing.expectf(t, ok, "%s: marshal failed", label) {
        return
    }
    expect_bytes(t, got, want, label)
}

// --- signatures ---

@(test)
test_dbus_sig_next :: proc(t: ^testing.T) {
    testing.expect_value(t, app.dbus_sig_next("s"), 1)
    testing.expect_value(t, app.dbus_sig_next("su"), 1) // only the FIRST complete type
    testing.expect_value(t, app.dbus_sig_next("as"), 2)
    testing.expect_value(t, app.dbus_sig_next("aas"), 3)
    testing.expect_value(t, app.dbus_sig_next("a{sv}"), 5)
    testing.expect_value(t, app.dbus_sig_next("(ii)"), 4)
    testing.expect_value(t, app.dbus_sig_next("(i(us))x"), 7) // nested, stops at its own close
    testing.expect_value(t, app.dbus_sig_next("a{oa{sa{sv}}}"), 13) // the ObjectManager shape

    // Malformed input must report 0, never a length that would walk off the end.
    testing.expect_value(t, app.dbus_sig_next(""), 0)
    testing.expect_value(t, app.dbus_sig_next("("), 0)
    testing.expect_value(t, app.dbus_sig_next("(ii"), 0)
    testing.expect_value(t, app.dbus_sig_next("a"), 0) // an array with no element type
    testing.expect_value(t, app.dbus_sig_next("z"), 0) // not a type code
}

@(test)
test_dbus_sig_split :: proc(t: ^testing.T) {
    parts, ok := app.dbus_sig_split("sa{sv}u")
    testing.expect(t, ok)
    testing.expect_value(t, len(parts), 3)
    if len(parts) == 3 {
        testing.expect_value(t, parts[0], "s")
        testing.expect_value(t, parts[1], "a{sv}")
        testing.expect_value(t, parts[2], "u")
    }

    empty, eok := app.dbus_sig_split("")
    testing.expect(t, eok)
    testing.expect_value(t, len(empty), 0)

    _, bad := app.dbus_sig_split("s(ii")
    testing.expect(t, !bad, "an unterminated struct must not split")
}

@(test)
test_dbus_sig_align :: proc(t: ^testing.T) {
    testing.expect_value(t, app.dbus_sig_align("y"), 1)
    testing.expect_value(t, app.dbus_sig_align("g"), 1)
    testing.expect_value(t, app.dbus_sig_align("v"), 1) // a variant carries its own sig first
    testing.expect_value(t, app.dbus_sig_align("q"), 2)
    testing.expect_value(t, app.dbus_sig_align("u"), 4)
    testing.expect_value(t, app.dbus_sig_align("s"), 4) // the u32 length leads
    testing.expect_value(t, app.dbus_sig_align("as"), 4) // ...as does an array's
    testing.expect_value(t, app.dbus_sig_align("t"), 8)
    testing.expect_value(t, app.dbus_sig_align("d"), 8)
    testing.expect_value(t, app.dbus_sig_align("(yy)"), 8) // structs always, however small
    testing.expect_value(t, app.dbus_sig_align("{sv}"), 8)
}

// --- exact wire vectors ---

@(test)
test_dbus_marshal_basics :: proc(t: ^testing.T) {
    expect_marshal(t, "u", {u32(42)}, {0x2a, 0, 0, 0}, "u32")
    expect_marshal(t, "y", {u8(7)}, {7}, "byte")
    expect_marshal(t, "b", {bool(true)}, {1, 0, 0, 0}, "bool is a u32 on the wire")
    expect_marshal(t, "q", {u16(0x1234)}, {0x34, 0x12}, "u16 little-endian")
    expect_marshal(t, "t", {u64(1)}, {1, 0, 0, 0, 0, 0, 0, 0}, "u64")
    expect_marshal(t, "i", {i32(-2)}, {0xfe, 0xff, 0xff, 0xff}, "negative i32 two's complement")

    // A byte then a u32: the u32 must land on a 4-boundary, so three NULs are inserted.
    expect_marshal(t, "yu", {u8(1), u32(42)}, {1, 0, 0, 0, 0x2a, 0, 0, 0}, "byte then u32 pads to 4")

    // A byte then a u64: seven bytes of padding to reach the 8-boundary.
    expect_marshal(
        t,
        "yt",
        {u8(1), u64(2)},
        {1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0},
        "byte then u64 pads to 8",
    )

    // s: u32 length NOT counting the terminator, then the bytes, then a NUL.
    expect_marshal(t, "s", {app.Dbus_String("abc")}, {3, 0, 0, 0, 'a', 'b', 'c', 0}, "string")
    expect_marshal(t, "s", {app.Dbus_String("")}, {0, 0, 0, 0, 0}, "empty string still has its NUL")

    // g: a SINGLE byte length and no alignment — the one string type that differs.
    expect_marshal(t, "g", {app.Dbus_Signature("a{sv}")}, {5, 'a', '{', 's', 'v', '}', 0}, "signature")

    // o marshals exactly like s, but the type is distinct so the two can't be swapped.
    expect_marshal(t, "o", {app.Dbus_Path("/a")}, {2, 0, 0, 0, '/', 'a', 0}, "object path")
}

@(test)
test_dbus_marshal_array :: proc(t: ^testing.T) {
    // as ["a", "bc"]:
    //   0..3   array byte length = 15
    //   4..9   "a"  (len 1, 'a', NUL)
    //   10,11  padding to the next 4-boundary for the second string's length word
    //   12..18 "bc" (len 2, 'b', 'c', NUL)
    // Length 15 counts bytes 4..18 — the interior padding IS included, being between
    // elements, unlike the leading padding tested below.
    a := app.Dbus_Value(app.Dbus_String("a"))
    b := app.Dbus_Value(app.Dbus_String("bc"))
    arr := app.Dbus_Value(app.Dbus_Array{sig = "s", items = {a, b}})
    expect_marshal(
        t,
        "as",
        {arr},
        {15, 0, 0, 0, 1, 0, 0, 0, 'a', 0, 0, 0, 2, 0, 0, 0, 'b', 'c', 0},
        "array of string",
    )
}

@(test)
test_dbus_marshal_array_padding_not_counted :: proc(t: ^testing.T) {
    // THE classic D-Bus bug, and the reason this test exists on its own. For an array of
    // an 8-aligned type, the first element must start on an 8-boundary — so four bytes of
    // padding follow the length word. Those four bytes are NOT part of the declared
    // length. An encoder that counts them produces a message every daemon rejects.
    //   0..3   length = 8   (one u64, not 12)
    //   4..7   padding, uncounted
    //   8..15  the u64
    one := app.Dbus_Value(u64(1))
    arr := app.Dbus_Value(app.Dbus_Array{sig = "t", items = {one}})
    expect_marshal(
        t,
        "at",
        {arr},
        {8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0},
        "array of u64: leading pad excluded from the length",
    )

    // And the padding is present even when there is nothing to align — an EMPTY array of
    // an 8-aligned type is still eight bytes on the wire, not four.
    empty := app.Dbus_Value(app.Dbus_Array{sig = "t", items = {}})
    expect_marshal(t, "at", {empty}, {0, 0, 0, 0, 0, 0, 0, 0}, "empty array of u64 keeps its pad")

    // A 4-aligned element needs no such padding: the length word already leaves us there.
    e4 := app.Dbus_Value(app.Dbus_Array{sig = "u", items = {}})
    expect_marshal(t, "au", {e4}, {0, 0, 0, 0}, "empty array of u32 is just the length")
}

@(test)
test_dbus_marshal_dict_and_variant :: proc(t: ^testing.T) {
    // a{sv} {"Foo": <7u>} — the property-bag shape every pane reads:
    //   0..3   array length = 16 (bytes 8..23)
    //   4..7   padding to the dict entry's 8-alignment, uncounted
    //   8..15  key "Foo"  (len 3, 'F','o','o', NUL)
    //   16..18 the variant's signature: len 1, 'u', NUL
    //   19     padding to the u32's 4-boundary
    //   20..23 the u32 value 7
    seven := app.Dbus_Value(u32(7))
    key := app.Dbus_Value(app.Dbus_String("Foo"))
    var := app.Dbus_Value(app.Dbus_Variant{sig = "u", val = &seven})
    ent := app.Dbus_Value(app.Dbus_Entry{key = &key, val = &var})
    dict := app.Dbus_Value(app.Dbus_Array{sig = "{sv}", items = {ent}})
    expect_marshal(
        t,
        "a{sv}",
        {dict},
        {16, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 'F', 'o', 'o', 0, 1, 'u', 0, 0, 7, 0, 0, 0},
        "a{sv} property bag",
    )

    // A bare variant holding a string: signature, then the string at ITS alignment.
    //   0..2  len 1, 's', NUL
    //   3     padding to 4
    //   4..   the string
    hi := app.Dbus_Value(app.Dbus_String("hi"))
    v := app.Dbus_Value(app.Dbus_Variant{sig = "s", val = &hi})
    expect_marshal(t, "v", {v}, {1, 's', 0, 0, 2, 0, 0, 0, 'h', 'i', 0}, "variant of string")
}

@(test)
test_dbus_marshal_struct :: proc(t: ^testing.T) {
    // (yu) — a struct aligns to 8 even though its widest member is 4, but at offset 0
    // that costs nothing; the interior byte->u32 padding still applies.
    one := app.Dbus_Value(u8(1))
    two := app.Dbus_Value(u32(2))
    st := app.Dbus_Value(app.Dbus_Struct{fields = {one, two}})
    expect_marshal(t, "(yu)", {st}, {1, 0, 0, 0, 2, 0, 0, 0}, "struct")

    // A byte before a struct proves the 8-alignment: 7 bytes of padding, not 3.
    st2 := app.Dbus_Value(app.Dbus_Struct{fields = {one, two}})
    expect_marshal(
        t,
        "y(yu)",
        {one, st2},
        {1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0},
        "struct forces 8-alignment",
    )
}

@(test)
test_dbus_marshal_rejects_mismatch :: proc(t: ^testing.T) {
    // A value that doesn't match its signature is caught here rather than by the daemon.
    _, ok := app.dbus_marshal_bytes("u", {app.Dbus_String("nope")})
    testing.expect(t, !ok, "string marshalled as u32 must be rejected")

    _, ok2 := app.dbus_marshal_bytes("s", {app.Dbus_Path("/x")})
    testing.expect(t, !ok2, "object path is not interchangeable with string")

    _, ok3 := app.dbus_marshal_bytes("uu", {u32(1)})
    testing.expect(t, !ok3, "argument count must match the signature")

    _, ok4 := app.dbus_marshal_bytes("a", {u32(1)})
    testing.expect(t, !ok4, "an array needs an element type")
}

// --- round trips ---

@(private = "file")
round_trip :: proc(t: ^testing.T, sig: string, args: []app.Dbus_Value) -> []app.Dbus_Value {
    bytes, ok := app.dbus_marshal_bytes(sig, args)
    if !testing.expectf(t, ok, "%s: marshal failed", sig) {
        return nil
    }
    r := app.Dbus_Reader {
        data = bytes,
        pos  = 0,
        big  = false,
    }
    out, uok := app.dbus_unmarshal(&r, sig)
    if !testing.expectf(t, uok, "%s: unmarshal failed", sig) {
        return nil
    }
    testing.expectf(t, r.pos == len(bytes), "%s: %d of %d bytes consumed", sig, r.pos, len(bytes))
    return out
}

@(test)
test_dbus_round_trip_basics :: proc(t: ^testing.T) {
    out := round_trip(
        t,
        "ybnqiuxtdsog",
        {
            u8(0xff),
            bool(true),
            i16(-300),
            u16(65535),
            i32(-70000),
            u32(4000000000),
            i64(-5000000000),
            u64(18000000000000000000),
            f64(3.5),
            app.Dbus_String("str"),
            app.Dbus_Path("/obj/path"),
            app.Dbus_Signature("a{sv}"),
        },
    )
    if len(out) != 12 {
        testing.expectf(t, false, "expected 12 values, got %d", len(out))
        return
    }
    testing.expect_value(t, out[0].(u8), u8(0xff))
    testing.expect_value(t, out[1].(bool), true)
    testing.expect_value(t, out[2].(i16), i16(-300))
    testing.expect_value(t, out[3].(u16), u16(65535))
    testing.expect_value(t, out[4].(i32), i32(-70000))
    testing.expect_value(t, out[5].(u32), u32(4000000000))
    testing.expect_value(t, out[6].(i64), i64(-5000000000))
    testing.expect_value(t, out[7].(u64), u64(18000000000000000000))
    testing.expect_value(t, out[8].(f64), f64(3.5))
    testing.expect_value(t, string(out[9].(app.Dbus_String)), "str")
    testing.expect_value(t, string(out[10].(app.Dbus_Path)), "/obj/path")
    testing.expect_value(t, string(out[11].(app.Dbus_Signature)), "a{sv}")
}

@(test)
test_dbus_round_trip_object_manager :: proc(t: ^testing.T) {
    // a{oa{sa{sv}}} — GetManagedObjects' reply, and the single most important shape in
    // the whole feature: every pane's device tree arrives in it. Built three levels deep
    // here so the nested alignment is exercised for real.
    //   /dev/0 -> { "org.example.Device": { "Name": <"wlan0">, "Powered": <true> } }
    name_v := app.Dbus_Value(app.Dbus_String("wlan0"))
    powered_v := app.Dbus_Value(bool(true))
    name_k := app.Dbus_Value(app.Dbus_String("Name"))
    powered_k := app.Dbus_Value(app.Dbus_String("Powered"))
    name_var := app.Dbus_Value(app.Dbus_Variant{sig = "s", val = &name_v})
    powered_var := app.Dbus_Value(app.Dbus_Variant{sig = "b", val = &powered_v})
    name_e := app.Dbus_Value(app.Dbus_Entry{key = &name_k, val = &name_var})
    powered_e := app.Dbus_Value(app.Dbus_Entry{key = &powered_k, val = &powered_var})
    props := app.Dbus_Value(app.Dbus_Array{sig = "{sv}", items = {name_e, powered_e}})

    iface_k := app.Dbus_Value(app.Dbus_String("org.example.Device"))
    iface_e := app.Dbus_Value(app.Dbus_Entry{key = &iface_k, val = &props})
    ifaces := app.Dbus_Value(app.Dbus_Array{sig = "{sa{sv}}", items = {iface_e}})

    path_k := app.Dbus_Value(app.Dbus_Path("/dev/0"))
    path_e := app.Dbus_Value(app.Dbus_Entry{key = &path_k, val = &ifaces})
    tree := app.Dbus_Value(app.Dbus_Array{sig = "{oa{sa{sv}}}", items = {path_e}})

    out := round_trip(t, "a{oa{sa{sv}}}", {tree})
    if len(out) != 1 {
        return
    }

    // Walk it back out the way a pane would, through the accessors.
    top := out[0].(app.Dbus_Array)
    testing.expect_value(t, len(top.items), 1)
    obj := top.items[0].(app.Dbus_Entry)
    testing.expect_value(t, string(obj.key.(app.Dbus_Path)), "/dev/0")

    dev, dok := app.dbus_dict_get(obj.val^, "org.example.Device")
    testing.expect(t, dok, "interface lookup")
    if !dok {
        return
    }
    n, nok := app.dbus_dict_string(dev, "Name")
    testing.expect(t, nok)
    testing.expect_value(t, n, "wlan0")

    // dbus_dict_get unwraps the variant, so a bool property arrives as a bool.
    p, pok := app.dbus_dict_get(dev, "Powered")
    testing.expect(t, pok)
    testing.expect_value(t, p.(bool), true)

    _, missing := app.dbus_dict_get(dev, "Nope")
    testing.expect(t, !missing, "a missing key must report not-found, not a zero value")
}

@(test)
test_dbus_round_trip_nested_arrays :: proc(t: ^testing.T) {
    // aas — an array of arrays, where the inner arrays' own length words must align.
    a := app.Dbus_Value(app.Dbus_String("x"))
    b := app.Dbus_Value(app.Dbus_String("yy"))
    inner1 := app.Dbus_Value(app.Dbus_Array{sig = "s", items = {a, b}})
    inner2 := app.Dbus_Value(app.Dbus_Array{sig = "s", items = {}})
    outer := app.Dbus_Value(app.Dbus_Array{sig = "as", items = {inner1, inner2}})

    out := round_trip(t, "aas", {outer})
    if len(out) != 1 {
        return
    }
    got := out[0].(app.Dbus_Array)
    testing.expect_value(t, len(got.items), 2)
    testing.expect_value(t, len(got.items[0].(app.Dbus_Array).items), 2)
    testing.expect_value(t, len(got.items[1].(app.Dbus_Array).items), 0)
}

// --- byte order ---

@(test)
test_dbus_unmarshal_big_endian :: proc(t: ^testing.T) {
    // We always WRITE little-endian, but a peer may write big-endian and we must read it.
    // Hand-built here since our own encoder can't produce it.
    be := []u8{0, 0, 0, 42, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9}
    r := app.Dbus_Reader {
        data = be,
        pos  = 0,
        big  = true,
    }
    out, ok := app.dbus_unmarshal(&r, "uqt", context.temp_allocator)
    testing.expect(t, ok)
    if !ok || len(out) != 3 {
        return
    }
    testing.expect_value(t, out[0].(u32), u32(42))
    testing.expect_value(t, out[1].(u16), u16(3))
    testing.expect_value(t, out[2].(u64), u64(9))
}

// --- malformed input ---

@(test)
test_dbus_unmarshal_rejects_malformed :: proc(t: ^testing.T) {
    // Everything here arrives from another process, so truncation and absurd lengths must
    // fail cleanly rather than read past the buffer.
    short := []u8{1, 0}
    r1 := app.Dbus_Reader{data = short, pos = 0}
    _, ok1 := app.dbus_unmarshal(&r1, "u")
    testing.expect(t, !ok1, "a truncated u32 must fail")

    // A string claiming more bytes than the message holds.
    huge := []u8{0xff, 0xff, 0xff, 0x7f, 'a', 0}
    r2 := app.Dbus_Reader{data = huge, pos = 0}
    _, ok2 := app.dbus_unmarshal(&r2, "s")
    testing.expect(t, !ok2, "an over-long string length must fail")

    // An array whose declared length runs past the buffer.
    over := []u8{100, 0, 0, 0, 1, 0, 0, 0}
    r3 := app.Dbus_Reader{data = over, pos = 0}
    _, ok3 := app.dbus_unmarshal(&r3, "au")
    testing.expect(t, !ok3, "an over-long array length must fail")

    // A variant announcing a signature that isn't a single complete type.
    badvar := []u8{2, 'u', 'u', 0, 0, 0, 0, 0}
    r4 := app.Dbus_Reader{data = badvar, pos = 0}
    _, ok4 := app.dbus_unmarshal(&r4, "v")
    testing.expect(t, !ok4, "a variant carrying two types must fail")
}

// --- messages ---

@(test)
test_dbus_msg_round_trip :: proc(t: ^testing.T) {
    arg := app.Dbus_Value(app.Dbus_String("hello"))
    raw, ok := app.dbus_msg_call(
        7,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetNameOwner",
        "s",
        {arg},
        context.temp_allocator,
    )
    testing.expect(t, ok, "build")
    if !ok {
        return
    }

    // Structural invariants of the encoding itself.
    testing.expect_value(t, raw[0], u8('l')) // we emit little-endian
    testing.expect_value(t, raw[1], u8(1)) // METHOD_CALL
    testing.expect_value(t, raw[3], u8(1)) // protocol version
    testing.expect_value(t, app.dbus_msg_size(raw), len(raw))

    msg, dok := app.dbus_msg_decode(raw)
    testing.expect(t, dok, "decode")
    if !dok {
        return
    }
    testing.expect_value(t, msg.type, app.Dbus_Msg_Type.Method_Call)
    testing.expect_value(t, msg.serial, u32(7))
    testing.expect_value(t, msg.path, "/org/freedesktop/DBus")
    testing.expect_value(t, msg.iface, "org.freedesktop.DBus")
    testing.expect_value(t, msg.member, "GetNameOwner")
    testing.expect_value(t, msg.destination, "org.freedesktop.DBus")
    testing.expect_value(t, msg.signature, "s")

    // The body must begin on an 8-boundary measured from the start of the message —
    // if it doesn't, every alignment inside the body is off.
    body_at := len(msg.raw) - len(msg.body)
    testing.expectf(t, body_at % 8 == 0, "body starts at %d, not an 8-boundary", body_at)

    args, aok := app.dbus_msg_args(&msg)
    testing.expect(t, aok, "args")
    if !aok || len(args) != 1 {
        return
    }
    testing.expect_value(t, string(args[0].(app.Dbus_String)), "hello")
}

@(test)
test_dbus_msg_no_body :: proc(t: ^testing.T) {
    // Hello: the mandatory first message, and the no-argument case.
    raw, ok := app.dbus_msg_call(
        1,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
        "",
        nil,
        context.temp_allocator,
    )
    testing.expect(t, ok)
    if !ok {
        return
    }
    msg, dok := app.dbus_msg_decode(raw)
    testing.expect(t, dok)
    if !dok {
        return
    }
    testing.expect_value(t, msg.member, "Hello")
    testing.expect_value(t, msg.signature, "") // no SIGNATURE field for an empty body
    testing.expect_value(t, len(msg.body), 0)

    args, aok := app.dbus_msg_args(&msg)
    testing.expect(t, aok, "an empty body parses to no arguments, not a failure")
    testing.expect_value(t, len(args), 0)
}

@(test)
test_dbus_msg_error_reply :: proc(t: ^testing.T) {
    // The serve-side primitive: an error answering a call carries the caller's serial.
    call, _ := app.dbus_msg_call(
        11,
        "",
        "/slopd/agent",
        "net.connman.iwd.Agent",
        "RequestPassphrase",
        "",
        nil,
        context.temp_allocator,
    )
    incoming, _ := app.dbus_msg_decode(call)

    raw, ok := app.dbus_msg_error(
        12,
        &incoming,
        "net.connman.iwd.Agent.Error.Canceled",
        "user cancelled",
        context.temp_allocator,
    )
    testing.expect(t, ok)
    if !ok {
        return
    }
    reply, dok := app.dbus_msg_decode(raw)
    testing.expect(t, dok)
    if !dok {
        return
    }
    testing.expect_value(t, reply.type, app.Dbus_Msg_Type.Error)
    testing.expect_value(t, reply.reply_serial, u32(11))
    testing.expect_value(t, reply.error_name, "net.connman.iwd.Agent.Error.Canceled")

    args, aok := app.dbus_msg_args(&reply)
    testing.expect(t, aok)
    if aok && len(args) == 1 {
        testing.expect_value(t, string(args[0].(app.Dbus_String)), "user cancelled")
    }
}

@(test)
test_dbus_msg_decode_rejects_junk :: proc(t: ^testing.T) {
    testing.expect_value(t, app.dbus_msg_size({}), 0)
    testing.expect_value(t, app.dbus_msg_size({1, 2, 3}), 0) // shorter than the fixed header

    // A bad endianness byte is the first thing checked.
    bad := make([]u8, 16, context.temp_allocator)
    bad[0] = 'x'
    testing.expect_value(t, app.dbus_msg_size(bad), 0)

    // A valid size but a wrong protocol version.
    raw, _ := app.dbus_msg_call(1, "d", "/p", "i", "m", "", nil, context.temp_allocator)
    raw[3] = 99
    _, ok := app.dbus_msg_decode(raw)
    testing.expect(t, !ok, "an unknown protocol version must be refused")

    // Truncation: a message that claims more than it delivers.
    raw2, _ := app.dbus_msg_call(1, "d", "/p", "i", "m", "", nil, context.temp_allocator)
    _, ok2 := app.dbus_msg_decode(raw2[:len(raw2) - 1])
    testing.expect(t, !ok2, "a truncated message must be refused")
}

// --- address + auth ---

@(test)
test_dbus_parse_address :: proc(t: ^testing.T) {
    // The exact form this dev box exports.
    p, abs, ok := app.dbus_parse_address("unix:path=/tmp/dbus-0F0REzHrmL,guid=4133537ed1")
    testing.expect(t, ok)
    testing.expect_value(t, p, "/tmp/dbus-0F0REzHrmL")
    testing.expect_value(t, abs, false)

    // Linux abstract sockets — no filesystem entry, a leading NUL in sun_path.
    p2, abs2, ok2 := app.dbus_parse_address("unix:abstract=/tmp/dbus-Xy,guid=aa")
    testing.expect(t, ok2)
    testing.expect_value(t, p2, "/tmp/dbus-Xy")
    testing.expect_value(t, abs2, true)

    // %XX escapes in a value.
    p3, _, ok3 := app.dbus_parse_address("unix:path=/tmp/a%20b")
    testing.expect(t, ok3)
    testing.expect_value(t, p3, "/tmp/a b")

    // A `;` list: skip transports we can't speak, take the first unix entry.
    p4, _, ok4 := app.dbus_parse_address("tcp:host=localhost,port=1;unix:path=/run/x")
    testing.expect(t, ok4)
    testing.expect_value(t, p4, "/run/x")

    // Nothing usable.
    _, _, ok5 := app.dbus_parse_address("tcp:host=localhost,port=1")
    testing.expect(t, !ok5)
    _, _, ok6 := app.dbus_parse_address("")
    testing.expect(t, !ok6)
}

@(test)
test_dbus_auth_line :: proc(t: ^testing.T) {
    // EXTERNAL's credential is the uid in DECIMAL, then that ASCII hex-encoded:
    // uid 0 -> "0" -> 0x30 -> "30". Getting the double encoding wrong is the classic
    // reason a hand-written client can't authenticate.
    testing.expect_value(t, app.dbus_auth_line(0), "AUTH EXTERNAL 30\r\n")
    testing.expect_value(t, app.dbus_auth_line(1000), "AUTH EXTERNAL 31303030\r\n")
    testing.expect_value(t, app.dbus_auth_line(42), "AUTH EXTERNAL 3432\r\n")
}

// --- live bus (layer 3) ---
//
// Everything above is pure. These two talk to the REAL daemon, because a hand-written
// encoder and decoder can agree with each other while both being wrong about the wire —
// only a foreign implementation settles it. They SKIP when no bus is reachable (the same
// convention as highlight_test without a grammar), so CI and a bare container stay green.

@(test)
test_dbus_live_session_bus :: proc(t: ^testing.T) {
    conn, ok := app.dbus_open(.Session)
    if !ok {
        fmt.println("[skip] no session bus reachable; see dbus_test.odin")
        return
    }
    defer app.dbus_close(conn)

    // Hello succeeded during open, so the daemon accepted our auth, our header layout and
    // our serial — and handed back the unique name it assigned us.
    testing.expectf(t, strings.has_prefix(conn.unique, ":"), "unique name %q should look like :1.42", conn.unique)

    // ListNames returns "as" — a real array of real strings, decoded from bytes we did
    // not produce.
    reply, rok := app.dbus_call(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
    )
    testing.expect(t, rok, "ListNames should return")
    if !rok {
        return
    }
    defer app.dbus_msg_free(&reply)
    testing.expect_value(t, reply.signature, "as")

    args, aok := app.dbus_msg_args(&reply)
    testing.expect(t, aok)
    if !aok || len(args) != 1 {
        return
    }
    names := args[0].(app.Dbus_Array)
    testing.expectf(t, len(names.items) > 0, "the bus should own at least its own name")

    // The daemon's own name is always present, and ours must be in the list it just sent.
    found_bus, found_self := false, false
    for n in names.items {
        s, sok := app.dbus_as_string(n)
        if !sok {
            continue
        }
        if s == "org.freedesktop.DBus" {
            found_bus = true
        }
        if s == conn.unique {
            found_self = true
        }
    }
    testing.expect(t, found_bus, "org.freedesktop.DBus should be in ListNames")
    testing.expect(t, found_self, "our own unique name should be in ListNames")

    // An error reply must come back as an error, not as a hang or a bogus return.
    bad, berr := app.dbus_call(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NoSuchMethodAtAll",
    )
    testing.expect(t, !berr, "an unknown method must not report success")
    if bad.type != .Invalid {
        testing.expect_value(t, bad.type, app.Dbus_Msg_Type.Error)
        testing.expectf(t, bad.error_name != "", "an error reply should name its error")
        app.dbus_msg_free(&bad)
    }
}

@(test)
test_dbus_live_system_bus :: proc(t: ^testing.T) {
    conn, ok := app.dbus_open(.System)
    if !ok {
        fmt.println("[skip] no system bus reachable; see dbus_test.odin")
        return
    }
    defer app.dbus_close(conn)

    // A call WITH a body, against the system bus: GetNameOwner takes "s" and answers "s".
    // This is the path every pane's method calls take.
    arg := app.Dbus_Value(app.Dbus_String("org.freedesktop.DBus"))
    reply, rok := app.dbus_call(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetNameOwner",
        "s",
        {arg},
    )
    testing.expect(t, rok, "GetNameOwner should return")
    if !rok {
        return
    }
    defer app.dbus_msg_free(&reply)

    args, aok := app.dbus_msg_args(&reply)
    testing.expect(t, aok)
    if aok && len(args) == 1 {
        owner, sok := app.dbus_as_string(args[0])
        testing.expect(t, sok)
        testing.expectf(t, owner != "", "the bus daemon should own its own name (got %q)", owner)
    }

    // AddMatch is the call every pane makes before it listens, and it is the one that
    // fails loudly if our string marshalling is off — the daemon parses the rule.
    testing.expect(
        t,
        app.dbus_add_match(conn, "type='signal',interface='org.freedesktop.DBus'"),
        "AddMatch should be accepted",
    )
}
