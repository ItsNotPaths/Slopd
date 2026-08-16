package tests

import "../system"
import "core:fmt"
import "core:slice"
import "core:testing"

// ObjectManager-tree tests. Layer 1 (PURE) plus one live check, same split as
// dbus_test.odin. dbus_om_apply takes a DECODED message, so the entire live half of the
// tree — a service appearing, an object arriving, a property churning, a daemon dying —
// is exercised here with no bus and no daemon: the signals are built with dbus_msg_build
// and put through dbus_msg_decode, so each test travels the real wire path.
//
// The one thing that cannot be seen by reading the tree is the ownership contract, since
// a borrowed string and an owned one look identical. test_dbus_value_clone_outlives_msg
// settles it by scribbling over the message buffer before reading the clone back.

// --- value builders (the tree's input, spelled readably) ---

dv_variant :: proc(sig: string, v: system.Dbus_Value) -> system.Dbus_Value {
    p := new(system.Dbus_Value, context.temp_allocator)
    p^ = v
    return system.Dbus_Variant{sig = sig, val = p}
}

dv_entry :: proc(key, val: system.Dbus_Value) -> system.Dbus_Value {
    k := new(system.Dbus_Value, context.temp_allocator)
    v := new(system.Dbus_Value, context.temp_allocator)
    k^, v^ = key, val
    return system.Dbus_Entry{key = k, val = v}
}

// `sig` is the ELEMENT signature, matching Dbus_Array.
dv_arr :: proc(sig: string, items: ..system.Dbus_Value) -> system.Dbus_Value {
    return system.Dbus_Array{sig = sig, items = slice.clone(items, context.temp_allocator)}
}

dv_strs :: proc(items: ..string) -> system.Dbus_Value {
    out := make([dynamic]system.Dbus_Value, 0, len(items), context.temp_allocator)
    for s in items {
        append(&out, system.Dbus_String(s))
    }
    return system.Dbus_Array{sig = "s", items = out[:]}
}

// One `{sv}` property entry, and the `a{sv}` bag they go in.
dv_prop :: proc(name, sig: string, v: system.Dbus_Value) -> system.Dbus_Value {
    return dv_entry(system.Dbus_String(name), dv_variant(sig, v))
}

dv_props :: proc(items: ..system.Dbus_Value) -> system.Dbus_Value {
    return system.Dbus_Array{sig = "{sv}", items = slice.clone(items, context.temp_allocator)}
}

// One `{sa{sv}}` interface entry, and the `a{sa{sv}}` dict of them.
dv_iface :: proc(name: string, bag: system.Dbus_Value) -> system.Dbus_Value {
    return dv_entry(system.Dbus_String(name), bag)
}

dv_ifaces :: proc(items: ..system.Dbus_Value) -> system.Dbus_Value {
    return system.Dbus_Array{sig = "{sa{sv}}", items = slice.clone(items, context.temp_allocator)}
}

// Builds a signal and decodes it, exactly as one arrives off the bus. Temp-allocated, so
// the caller neither frees nor keeps it.
dv_signal :: proc(
    path, iface, member, sender, body_sig: string,
    args: []system.Dbus_Value,
) -> (
    msg: system.Dbus_Message,
    ok: bool,
) {
    raw := system.dbus_msg_build(
        .Signal,
        7,
        path = path,
        iface = iface,
        member = member,
        sender = sender,
        body_sig = body_sig,
        args = args,
        alloc = context.temp_allocator,
    ) or_return
    return system.dbus_msg_decode(raw)
}

// The iwd shape, trimmed to two objects: an adapter and the station device under it.
// Shared with sysbus_test.odin, which scripts it as a GetManagedObjects reply.
IWD_ADAPTER :: "/net/connman/iwd/0"
IWD_DEVICE :: "/net/connman/iwd/0/4"

dv_managed_fixture :: proc() -> system.Dbus_Value {
    return system.Dbus_Array {
        sig = "{oa{sa{sv}}}",
        items = slice.clone(
            []system.Dbus_Value {
                dv_entry(
                    system.Dbus_Path(IWD_ADAPTER),
                    dv_ifaces(
                        dv_iface(
                            "net.connman.iwd.Adapter",
                            dv_props(
                                dv_prop("Powered", "b", true),
                                dv_prop("Name", "s", system.Dbus_String("phy0")),
                                dv_prop("SupportedModes", "as", dv_strs("station", "ap")),
                            ),
                        ),
                        dv_iface("org.freedesktop.DBus.Properties", dv_props()),
                    ),
                ),
                dv_entry(
                    system.Dbus_Path(IWD_DEVICE),
                    dv_ifaces(
                        dv_iface(
                            "net.connman.iwd.Device",
                            dv_props(
                                dv_prop("Name", "s", system.Dbus_String("wlp61s0")),
                                dv_prop("Adapter", "o", system.Dbus_Path(IWD_ADAPTER)),
                            ),
                        ),
                        dv_iface(
                            "net.connman.iwd.Station",
                            dv_props(dv_prop("State", "s", system.Dbus_String("connected"))),
                        ),
                    ),
                ),
            },
            context.temp_allocator,
        ),
    }
}

// A tree loaded with the fixture, keeping only iwd's own interfaces.
@(private = "file")
loaded_om :: proc() -> ^system.Dbus_Om {
    om := system.dbus_om_make(
        "net.connman.iwd",
        "/",
        []string{"net.connman.iwd.Adapter", "net.connman.iwd.Device", "net.connman.iwd.Station"},
    )
    system.dbus_om_load(om, dv_managed_fixture())
    om.dirty = false
    return om
}

// --- clone / free ---

@(test)
test_dbus_value_clone_outlives_msg :: proc(t: ^testing.T) {
    // A decoded value BORROWS the message buffer — every string, and every container's
    // signature, points into it. The tree outlives the message, so this is the contract
    // the whole file rests on: after cloning, the original bytes must not matter.
    raw, bok := system.dbus_msg_build(
        .Signal,
        1,
        path = "/x",
        iface = "t.T",
        member = "M",
        body_sig = "a{sv}",
        args = []system.Dbus_Value {
            dv_props(
                dv_prop("Name", "s", system.Dbus_String("wlp61s0")),
                dv_prop("Modes", "as", dv_strs("station", "ap")),
                dv_prop("Rssi", "n", i16(-62)),
            ),
        },
    )
    testing.expect(t, bok, "build should succeed")
    defer delete(raw)

    msg, dok := system.dbus_msg_decode(raw)
    testing.expect(t, dok, "decode should succeed")
    args, aok := system.dbus_msg_args(&msg)
    testing.expect(t, aok && len(args) == 1)
    if !aok || len(args) != 1 {
        return
    }

    clone := system.dbus_value_clone(args[0])
    defer system.dbus_value_free(clone)

    // Scribble over the source. Anything still aliasing it now reads garbage.
    for &b in raw {
        b = 0xAA
    }

    name, nok := system.dbus_dict_string(clone, "Name")
    testing.expect(t, nok, "the cloned dict should still resolve Name")
    testing.expect_value(t, name, "wlp61s0")

    modes, mok := system.dbus_dict_get(clone, "Modes")
    testing.expect(t, mok)
    if list, lok := modes.(system.Dbus_Array); lok {
        testing.expect_value(t, list.sig, "s") // the SIGNATURE aliased the buffer too
        testing.expect_value(t, len(list.items), 2)
        if len(list.items) == 2 {
            s0, _ := system.dbus_as_string(list.items[0])
            s1, _ := system.dbus_as_string(list.items[1])
            testing.expect_value(t, s0, "station")
            testing.expect_value(t, s1, "ap")
        }
    } else {
        testing.expect(t, false, "Modes should have cloned as an array")
    }

    rssi, rok := system.dbus_dict_get(clone, "Rssi")
    testing.expect(t, rok)
    n, iok := system.dbus_as_int(rssi)
    testing.expect(t, iok, "an i16 property should widen")
    testing.expect_value(t, n, i64(-62))
}

@(test)
test_dbus_as_int :: proc(t: ^testing.T) {
    // Panes read "the number", not "the u16": every integer code widens, and nothing else
    // does — a string that silently became 0 would draw as a plausible reading.
    for c in ([]struct {
        v:    system.Dbus_Value,
        want: i64,
    } {
        {u8(200), 200},
        {i16(-62), -62}, // BlueZ's RSSI
        {u16(1), 1},
        {i32(-5), -5},
        {u32(5240), 5240}, // iwd's frequency
        {i64(-1 << 40), -1 << 40},
        {u64(1 << 40), 1 << 40},
    }) {
        n, ok := system.dbus_as_int(c.v)
        testing.expectf(t, ok, "%v should widen", c.v)
        testing.expect_value(t, n, c.want)
    }

    _, ok5 := system.dbus_as_int(system.Dbus_String("7"))
    testing.expect(t, !ok5, "a string must not pass as a number")
    _, ok6 := system.dbus_as_int(true)
    testing.expect(t, !ok6, "a bool is not an integer here")
    _, ok7 := system.dbus_as_int(nil)
    testing.expect(t, !ok7)
}

// --- loading + filtering ---

@(test)
test_dbus_om_load :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    testing.expect_value(t, len(om.objects), 2)
    testing.expect(t, system.dbus_om_has(om, IWD_ADAPTER, "net.connman.iwd.Adapter"))
    testing.expect(t, system.dbus_om_has(om, IWD_DEVICE, "net.connman.iwd.Station"))

    powered, pok := system.dbus_om_bool(om, IWD_ADAPTER, "net.connman.iwd.Adapter", "Powered")
    testing.expect(t, pok)
    testing.expect(t, powered)

    name, nok := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Device", "Name")
    testing.expect(t, nok)
    testing.expect_value(t, name, "wlp61s0")

    // An object path property keeps its type but reads as a string.
    adapter, aok := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Device", "Adapter")
    testing.expect(t, aok)
    testing.expect_value(t, adapter, IWD_ADAPTER)

    // Misses are misses, not zero values.
    _, missing := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Device", "NoSuchProp")
    testing.expect(t, !missing)
    _, no_iface := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Adapter", "Name")
    testing.expect(t, !no_iface)
    _, no_obj := system.dbus_om_string(om, "/nope", "net.connman.iwd.Device", "Name")
    testing.expect(t, !no_obj)
}

@(test)
test_dbus_om_filter :: proc(t: ^testing.T) {
    // The filter is what keeps iwd's dozen bookkeeping interfaces (and their property
    // churn) from being cloned at all — dropped before the copy, not after.
    om := loaded_om()
    defer system.dbus_om_destroy(om)
    testing.expect(
        t,
        !system.dbus_om_has(om, IWD_ADAPTER, "org.freedesktop.DBus.Properties"),
        "a filtered-out interface must not be stored",
    )

    // A nil filter keeps everything.
    all := system.dbus_om_make("net.connman.iwd", "/")
    defer system.dbus_om_destroy(all)
    system.dbus_om_load(all, dv_managed_fixture())
    testing.expect(t, system.dbus_om_has(all, IWD_ADAPTER, "org.freedesktop.DBus.Properties"))

    // An object whose every interface is filtered away never appears.
    none := system.dbus_om_make("net.connman.iwd", "/", []string{"net.connman.iwd.Nothing"})
    defer system.dbus_om_destroy(none)
    system.dbus_om_load(none, dv_managed_fixture())
    testing.expect_value(t, len(none.objects), 0)
}

@(test)
test_dbus_om_paths :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    // Sorted, because map order is arbitrary and a list that reshuffles every frame is
    // unusable. Object paths sort into the daemon's own hierarchy for free.
    all := system.dbus_om_paths(om)
    testing.expect_value(t, len(all), 2)
    testing.expect_value(t, all[0], IWD_ADAPTER)
    testing.expect_value(t, all[1], IWD_DEVICE)

    stations := system.dbus_om_paths(om, "net.connman.iwd.Station")
    testing.expect_value(t, len(stations), 1)
    testing.expect_value(t, stations[0], IWD_DEVICE)

    testing.expect_value(t, len(system.dbus_om_paths(om, "net.connman.iwd.Absent")), 0)
}

// --- the live signals ---

@(test)
test_dbus_om_interfaces_added :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    net_path :: "/net/connman/iwd/0/4/536d697468_psk"
    msg, mok := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesAdded",
        "",
        "oa{sa{sv}}",
        []system.Dbus_Value {
            system.Dbus_Path(net_path),
            dv_ifaces(
                dv_iface(
                    "net.connman.iwd.Network",
                    dv_props(
                        dv_prop("Name", "s", system.Dbus_String("Smith")),
                        dv_prop("Connected", "b", false),
                    ),
                ),
            ),
        },
    )
    testing.expect(t, mok, "the signal should decode")

    // Not in the filter: the network is ignored outright.
    testing.expect(t, !system.dbus_om_apply(om, &msg))
    testing.expect_value(t, len(om.objects), 2)

    wide := system.dbus_om_make("net.connman.iwd", "/", []string{"net.connman.iwd.Network"})
    defer system.dbus_om_destroy(wide)
    testing.expect(t, system.dbus_om_apply(wide, &msg), "a kept interface should be taken")
    testing.expect(t, wide.dirty, "a mutation must mark the tree dirty")
    name, nok := system.dbus_om_string(wide, net_path, "net.connman.iwd.Network", "Name")
    testing.expect(t, nok)
    testing.expect_value(t, name, "Smith")

    // A second announce REPLACES that interface's bag rather than merging into it — a
    // property that quietly survived a re-announce would be a stale reading on a row.
    again, aok := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesAdded",
        "",
        "oa{sa{sv}}",
        []system.Dbus_Value {
            system.Dbus_Path(net_path),
            dv_ifaces(
                dv_iface(
                    "net.connman.iwd.Network",
                    dv_props(dv_prop("Connected", "b", true)),
                ),
            ),
        },
    )
    testing.expect(t, aok)
    testing.expect(t, system.dbus_om_apply(wide, &again))
    conn, cok := system.dbus_om_bool(wide, net_path, "net.connman.iwd.Network", "Connected")
    testing.expect(t, cok)
    testing.expect(t, conn)
    _, stale := system.dbus_om_string(wide, net_path, "net.connman.iwd.Network", "Name")
    testing.expect(t, !stale, "the replaced bag must not keep the old property")
}

@(test)
test_dbus_om_interfaces_removed :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    // One interface off an object with two: the object stays.
    one, ok1 := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesRemoved",
        "",
        "oas",
        []system.Dbus_Value{system.Dbus_Path(IWD_DEVICE), dv_strs("net.connman.iwd.Station")},
    )
    testing.expect(t, ok1)
    testing.expect(t, system.dbus_om_apply(om, &one))
    testing.expect(t, !system.dbus_om_has(om, IWD_DEVICE, "net.connman.iwd.Station"))
    testing.expect(t, system.dbus_om_has(om, IWD_DEVICE, "net.connman.iwd.Device"))
    testing.expect_value(t, len(om.objects), 2)

    // Its last interface: the object goes with it, which is how the spec says "gone".
    rest, ok2 := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesRemoved",
        "",
        "oas",
        []system.Dbus_Value{system.Dbus_Path(IWD_DEVICE), dv_strs("net.connman.iwd.Device")},
    )
    testing.expect(t, ok2)
    testing.expect(t, system.dbus_om_apply(om, &rest))
    testing.expect_value(t, len(om.objects), 1)
    testing.expect(t, !system.dbus_om_has(om, IWD_DEVICE, "net.connman.iwd.Device"))

    // Removing what was never there changes nothing.
    testing.expect(t, !system.dbus_om_apply(om, &rest))
}

@(test)
test_dbus_om_properties_changed :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    msg, mok := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "",
        "sa{sv}as",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd.Station"),
            dv_props(
                dv_prop("State", "s", system.Dbus_String("disconnected")),
                dv_prop("Scanning", "b", true),
            ),
            dv_strs(),
        },
    )
    testing.expect(t, mok)
    testing.expect(t, system.dbus_om_apply(om, &msg))
    testing.expect(t, om.dirty)

    state, sok := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Station", "State")
    testing.expect(t, sok)
    testing.expect_value(t, state, "disconnected") // replaced, and the old string freed
    scanning, cok := system.dbus_om_bool(om, IWD_DEVICE, "net.connman.iwd.Station", "Scanning")
    testing.expect(t, cok && scanning, "a property first seen here should be added")

    // Invalidated properties are DROPPED, not blanked: the daemon said it changed but not
    // to what, so absent is the only honest state until a Get.
    inv, iok := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "",
        "sa{sv}as",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd.Station"),
            dv_props(),
            dv_strs("State"),
        },
    )
    testing.expect(t, iok)
    testing.expect(t, system.dbus_om_apply(om, &inv))
    _, still := system.dbus_om_string(om, IWD_DEVICE, "net.connman.iwd.Station", "State")
    testing.expect(t, !still, "an invalidated property must be gone")

    // An interface we never saw announced is not invented from a property update, and an
    // unknown object is not either — the tree's contents come from the manager alone.
    ghost_iface, gok := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "",
        "sa{sv}as",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd.NeverAnnounced"),
            dv_props(dv_prop("X", "b", true)),
            dv_strs(),
        },
    )
    testing.expect(t, gok)
    testing.expect(t, !system.dbus_om_apply(om, &ghost_iface))

    ghost_obj, ook := dv_signal(
        "/net/connman/iwd/9/9",
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "",
        "sa{sv}as",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd.Station"),
            dv_props(dv_prop("State", "s", system.Dbus_String("connected"))),
            dv_strs(),
        },
    )
    testing.expect(t, ook)
    testing.expect(t, !system.dbus_om_apply(om, &ghost_obj))
    testing.expect_value(t, len(om.objects), 2)
}

@(test)
test_dbus_om_name_owner_changed :: proc(t: ^testing.T) {
    om := loaded_om()
    defer system.dbus_om_destroy(om)
    system.dbus_om_set_owner(om, "") // dbus_om_make leaves it empty; be explicit about it

    // Somebody else's name change is not ours.
    other, ok1 := dv_signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "org.freedesktop.DBus",
        "sss",
        []system.Dbus_Value {
            system.Dbus_String("org.bluez"),
            system.Dbus_String(""),
            system.Dbus_String(":1.9"),
        },
    )
    testing.expect(t, ok1)
    testing.expect(t, !system.dbus_om_apply(om, &other))
    testing.expect_value(t, len(om.objects), 2)

    // The service dies: every path we hold is meaningless, so the tree resets and the pane
    // has something honest to draw ("unavailable", not an empty list).
    gone, ok2 := dv_signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "org.freedesktop.DBus",
        "sss",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd"),
            system.Dbus_String(":1.7"),
            system.Dbus_String(""),
        },
    )
    testing.expect(t, ok2)
    testing.expect(t, system.dbus_om_apply(om, &gone))
    testing.expect_value(t, len(om.objects), 0)
    testing.expect(t, !system.dbus_om_present(om))
    testing.expect(t, !om.refetch, "a dead service has nothing to re-fetch")

    // It comes back under a new unique name: the tree stays empty but asks for a snapshot.
    back, ok3 := dv_signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "org.freedesktop.DBus",
        "sss",
        []system.Dbus_Value {
            system.Dbus_String("net.connman.iwd"),
            system.Dbus_String(""),
            system.Dbus_String(":1.44"),
        },
    )
    testing.expect(t, ok3)
    testing.expect(t, system.dbus_om_apply(om, &back))
    testing.expect(t, system.dbus_om_present(om))
    testing.expect_value(t, om.owner, ":1.44")
    testing.expect(t, om.refetch, "a restarted service needs GetManagedObjects again")
}

// --- everything that must be refused ---

@(test)
test_dbus_om_sender_scope :: proc(t: ^testing.T) {
    // Signals are stamped with the sender's UNIQUE name, so matching the well-known name
    // alone would drop every real one. Anything from a third party is ignored.
    om := loaded_om()
    defer system.dbus_om_destroy(om)
    system.dbus_om_set_owner(om, ":1.7")

    body := []system.Dbus_Value {
        system.Dbus_String("net.connman.iwd.Station"),
        dv_props(dv_prop("State", "s", system.Dbus_String("scanning"))),
        dv_strs(),
    }

    from_owner, ok1 := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        ":1.7",
        "sa{sv}as",
        body,
    )
    testing.expect(t, ok1)
    testing.expect(t, system.dbus_om_apply(om, &from_owner), "the unique name is the real sender")

    from_wellknown, ok2 := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "net.connman.iwd",
        "sa{sv}as",
        body,
    )
    testing.expect(t, ok2)
    testing.expect(t, system.dbus_om_apply(om, &from_wellknown), "the well-known name is accepted too")

    imposter, ok3 := dv_signal(
        IWD_DEVICE,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        ":1.99",
        "sa{sv}as",
        body,
    )
    testing.expect(t, ok3)
    testing.expect(t, !system.dbus_om_apply(om, &imposter), "another peer must not write our tree")
}

@(test)
test_dbus_om_rejects_malformed :: proc(t: ^testing.T) {
    // All of this arrives from another process, so every field is checked before it is
    // believed. None of these may mutate the tree.
    om := loaded_om()
    defer system.dbus_om_destroy(om)

    // A method call, not a signal.
    call_raw, cok := system.dbus_msg_build(
        .Method_Call,
        1,
        path = "/",
        iface = "org.freedesktop.DBus.ObjectManager",
        member = "InterfacesRemoved",
        body_sig = "oas",
        args = []system.Dbus_Value{system.Dbus_Path(IWD_DEVICE), dv_strs("net.connman.iwd.Station")},
        alloc = context.temp_allocator,
    )
    testing.expect(t, cok)
    call, dok := system.dbus_msg_decode(call_raw)
    testing.expect(t, dok)
    testing.expect(t, !system.dbus_om_apply(om, &call))

    // Right member, wrong body signature — unmarshalling this as if it were the real
    // shape is how a malformed signal becomes a crash.
    wrong_sig, wok := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesRemoved",
        "",
        "os",
        []system.Dbus_Value{system.Dbus_Path(IWD_DEVICE), system.Dbus_String("net.connman.iwd.Station")},
    )
    testing.expect(t, wok)
    testing.expect(t, !system.dbus_om_apply(om, &wrong_sig))

    // An ObjectManager signal from some OTHER manager on the same connection.
    wrong_root, rok := dv_signal(
        "/net/connman/iwd",
        "org.freedesktop.DBus.ObjectManager",
        "InterfacesRemoved",
        "",
        "oas",
        []system.Dbus_Value{system.Dbus_Path(IWD_DEVICE), dv_strs("net.connman.iwd.Station")},
    )
    testing.expect(t, rok)
    testing.expect(t, !system.dbus_om_apply(om, &wrong_root))

    // A member we don't handle.
    unknown, uok := dv_signal(
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "SomethingElse",
        "",
        "",
        nil,
    )
    testing.expect(t, uok)
    testing.expect(t, !system.dbus_om_apply(om, &unknown))

    testing.expect_value(t, len(om.objects), 2)
    testing.expect(t, system.dbus_om_has(om, IWD_DEVICE, "net.connman.iwd.Station"))
    testing.expect(t, !om.dirty, "nothing above may have touched the tree")
}

@(test)
test_dbus_om_scope :: proc(t: ^testing.T) {
    // A manager rooted below "/" only owns what lives under it — and "/net/connman/iwdX"
    // is NOT under "/net/connman/iwd", however much it looks it.
    om := system.dbus_om_make("net.connman.iwd", "/net/connman/iwd", []string{"t.T"})
    defer system.dbus_om_destroy(om)

    accept := system.dbus_om_put(
        om,
        "/net/connman/iwd/0",
        dv_ifaces(dv_iface("t.T", dv_props(dv_prop("X", "b", true)))),
    )
    testing.expect(t, accept)

    self := system.dbus_om_put(
        om,
        "/net/connman/iwd",
        dv_ifaces(dv_iface("t.T", dv_props(dv_prop("X", "b", true)))),
    )
    testing.expect(t, self, "the root object itself is in scope")

    for bad in ([]string{"/net/connman/iwdX", "/net/connman", "/", "relative", ""}) {
        testing.expectf(
            t,
            !system.dbus_om_put(om, bad, dv_ifaces(dv_iface("t.T", dv_props()))),
            "%q must be out of scope",
            bad,
        )
    }
    testing.expect_value(t, len(om.objects), 2)
}

// --- live bus (layer 3) ---

@(test)
test_dbus_om_live_iwd :: proc(t: ^testing.T) {
    // The real thing: a real daemon's real GetManagedObjects, decoded and filtered into
    // the tree. iwd is this dev box's wifi stack; on a machine without it the test skips,
    // the same convention as the rest of the suite. Read-only — nothing here touches
    // device state.
    conn, ok := system.dbus_open(.System)
    if !ok {
        fmt.println("[skip] no system bus reachable; see dbus_om_test.odin")
        return
    }
    defer system.dbus_close(conn)

    om := system.dbus_om_make(
        "net.connman.iwd",
        "/",
        []string{"net.connman.iwd.Adapter", "net.connman.iwd.Device", "net.connman.iwd.Station"},
    )
    defer system.dbus_om_destroy(om)

    if !system.dbus_om_start(om, conn) {
        fmt.println("[skip] net.connman.iwd is not on the system bus")
        return
    }
    testing.expect(t, system.dbus_om_present(om))
    testing.expectf(t, om.owner[0] == ':', "the owner should be a unique name, got %q", om.owner)

    adapters := system.dbus_om_paths(om, "net.connman.iwd.Adapter")
    testing.expectf(t, len(adapters) > 0, "iwd running should mean at least one adapter")
    if len(adapters) == 0 {
        return
    }
    // Powered is a plain bool property on every adapter iwd publishes — proof the whole
    // chain (call, decode, filter, clone, query) survived a foreign encoder.
    _, pok := system.dbus_om_bool(om, adapters[0], "net.connman.iwd.Adapter", "Powered")
    testing.expect(t, pok, "an adapter should carry Powered")

    // The filter held against a daemon that publishes far more than we asked for.
    for path in system.dbus_om_paths(om) {
        obj, fok := system.dbus_om_object(om, path)
        testing.expect(t, fok)
        for name in obj.ifaces {
            testing.expectf(
                t,
                name == "net.connman.iwd.Adapter" ||
                name == "net.connman.iwd.Device" ||
                name == "net.connman.iwd.Station",
                "%s carries unfiltered interface %s",
                path,
                name,
            )
        }
    }
}
