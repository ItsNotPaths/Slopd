package tests

import "../system"
import "core:fmt"
import "core:testing"

// Sysbus tests — layer 2 of the three-layer model (see plan.txt): SIMULATED. A Dbus_Conn
// with fd < 0 records what it was asked to write and answers from a scripted queue, the
// same shape as the fake-pty Terminal, so the whole worker runs here on ONE thread with no
// daemon, no root, and no timing: sysbus_open and sysbus_step are the worker minus its
// blocking poll, and these call them directly.
//
// Scripted serials are deterministic. A fake connection never says Hello, so the first
// call it is asked to send is serial 1, and a scripted reply names the call it answers by
// stamping that serial as its reply_serial. The startup sequence is therefore fixed:
//   1,2,3  AddMatch  (ObjectManager, PropertiesChanged, NameOwnerChanged)
//   4      GetNameOwner
//   5      GetManagedObjects

// A method return answering `to`. Heap-allocated: dbus_script_push takes ownership, and
// the message the worker decodes from it frees it like any other off the wire.
@(private = "file")
sys_return :: proc(to: u32, sig: string = "", args: []system.Dbus_Value = nil) -> []u8 {
    return(
        system.dbus_msg_build(
            .Method_Return,
            1000 + to,
            reply_serial = to,
            body_sig = sig,
            args = args,
        ) or_else nil \
    )
}

@(private = "file")
sys_error :: proc(to: u32, name, text: string) -> []u8 {
    return(
        system.dbus_msg_build(
            .Error,
            1000 + to,
            error_name = name,
            reply_serial = to,
            body_sig = "s",
            args = []system.Dbus_Value{system.Dbus_String(text)},
        ) or_else nil \
    )
}

@(private = "file")
sys_signal_raw :: proc(
    path, iface, member, sender, body_sig: string,
    args: []system.Dbus_Value,
) -> []u8 {
    return(
        system.dbus_msg_build(
            .Signal,
            900,
            path = path,
            iface = iface,
            member = member,
            sender = sender,
            body_sig = body_sig,
            args = args,
        ) or_else nil \
    )
}

@(private = "file")
IWD_FILTER := []string {
    "net.connman.iwd.Adapter",
    "net.connman.iwd.Device",
    "net.connman.iwd.Station",
}

// The five replies a successful startup consumes. `owner` empty means the service isn't
// running, which is answered the way the daemon answers it: an error, not a name.
@(private = "file")
script_startup :: proc(conn: ^system.Dbus_Conn, owner: string) {
    system.dbus_script_push(conn, sys_return(1))
    system.dbus_script_push(conn, sys_return(2))
    system.dbus_script_push(conn, sys_return(3))
    if owner == "" {
        system.dbus_script_push(
            conn,
            sys_error(4, "org.freedesktop.DBus.Error.NameHasNoOwner", "no such name"),
        )
        return
    }
    system.dbus_script_push(conn, sys_return(4, "s", []system.Dbus_Value{system.Dbus_String(owner)}))
    system.dbus_script_push(
        conn,
        sys_return(5, "a{oa{sa{sv}}}", []system.Dbus_Value{dv_managed_fixture()}),
    )
}

// A sysbus wired to one scripted system-bus connection, watching iwd, already opened.
@(private = "file")
fake_sysbus :: proc(owner: string = ":1.7") -> (sb: ^system.Sysbus, conn: ^system.Dbus_Conn) {
    sb = new(system.Sysbus)
    system.sysbus_init(sb)
    conn = system.dbus_conn_fake()
    system.sysbus_attach(sb, .System, conn)
    system.sysbus_watch(sb, .System, "net.connman.iwd", "/", IWD_FILTER)
    script_startup(conn, owner)
    system.sysbus_open(sb)
    return
}

@(private = "file")
fake_sysbus_free :: proc(sb: ^system.Sysbus) {
    system.sysbus_destroy(sb) // closes the attached connection too
    free(sb)
}

// --- startup ---

@(test)
test_sysbus_open_sequence :: proc(t: ^testing.T) {
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    // Subscribe BEFORE resolving the owner and BEFORE the snapshot: match rules are keyed
    // by name, so registering early is what lets a daemon that starts after us be seen at
    // all, and it means nothing changing mid-fetch is missed.
    want := []struct {
        member, iface: string,
    } {
        {"AddMatch", "org.freedesktop.DBus"},
        {"AddMatch", "org.freedesktop.DBus"},
        {"AddMatch", "org.freedesktop.DBus"},
        {"GetNameOwner", "org.freedesktop.DBus"},
        {"GetManagedObjects", "org.freedesktop.DBus.ObjectManager"},
    }
    testing.expect_value(t, len(conn.sent), len(want))
    for w, i in want {
        m, ok := system.dbus_sent_msg(conn, i)
        if !testing.expectf(t, ok, "call %d should decode", i) {
            continue
        }
        testing.expect_value(t, m.member, w.member)
        testing.expect_value(t, m.iface, w.iface)
        testing.expect_value(t, m.type, system.Dbus_Msg_Type.Method_Call)
    }

    // The last one is the snapshot call, and it goes to the service's own manager root.
    last, lok := system.dbus_sent_msg(conn, 4)
    testing.expect(t, lok)
    testing.expect_value(t, last.destination, "net.connman.iwd")
    testing.expect_value(t, last.path, "/")

    // The scripted reply built the tree, filtered to what the watch asked for. Opening
    // publishes the first snapshot, so it is there to drain already.
    testing.expect(t, system.sysbus_drain(sb))
    svc, sok := system.sysbus_service(sb, "net.connman.iwd")
    testing.expect(t, sok, "the watched service should be in the snapshot")
    if !sok {
        return
    }
    testing.expect(t, svc.present)
    state, stok := system.dbus_om_string(
        svc.tree,
        IWD_DEVICE,
        "net.connman.iwd.Station",
        "State",
    )
    testing.expect(t, stok)
    testing.expect_value(t, state, "connected")
    testing.expect(
        t,
        !system.dbus_om_has(svc.tree, IWD_ADAPTER, "org.freedesktop.DBus.Properties"),
        "the watch's filter should have held",
    )
}

@(test)
test_sysbus_absent_service_comes_back :: proc(t: ^testing.T) {
    // iwd starting AFTER Slopd is the ordinary case on a fresh boot, so an absent service
    // must not be a dead end: the matches are already registered, and NameOwnerChanged is
    // what brings the tree to life.
    sb, conn := fake_sysbus(owner = "")
    defer fake_sysbus_free(sb)

    testing.expect_value(t, len(conn.sent), 4) // 3 AddMatch + the refused GetNameOwner
    testing.expect(t, system.sysbus_drain(sb))
    svc, sok := system.sysbus_service(sb, "net.connman.iwd")
    testing.expect(t, sok, "an absent service is still a tracked one")
    testing.expect(t, !svc.present, "present=false is the pane's cue to draw unavailable")

    // The daemon appears. The signal sets the owner and asks for a re-fetch; the worker's
    // next step issues GetManagedObjects and the scripted reply fills the tree.
    system.dbus_script_push(
        conn,
        sys_signal_raw(
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
        ),
    )
    system.dbus_script_push(
        conn,
        sys_return(5, "a{oa{sa{sv}}}", []system.Dbus_Value{dv_managed_fixture()}),
    )
    testing.expect(t, system.sysbus_step(sb), "a service appearing should publish")

    fetch, fok := system.dbus_sent_msg(conn, 4)
    testing.expect(t, fok)
    testing.expect_value(t, fetch.member, "GetManagedObjects")

    testing.expect(t, system.sysbus_drain(sb))
    back, bok := system.sysbus_service(sb, "net.connman.iwd")
    testing.expect(t, bok)
    testing.expect(t, back.present)
    name, nok := system.dbus_om_string(back.tree, IWD_DEVICE, "net.connman.iwd.Device", "Name")
    testing.expect(t, nok)
    testing.expect_value(t, name, "wlp61s0")
}

// --- signals ---

@(test)
test_sysbus_signal_updates_snapshot :: proc(t: ^testing.T) {
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    system.dbus_script_push(
        conn,
        sys_signal_raw(
            IWD_DEVICE,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            ":1.7",
            "sa{sv}as",
            []system.Dbus_Value {
                system.Dbus_String("net.connman.iwd.Station"),
                dv_props(dv_prop("State", "s", system.Dbus_String("disconnected"))),
                dv_strs(),
            },
        ),
    )
    testing.expect(t, system.sysbus_step(sb), "a signal that moves a tree should publish")
    testing.expect(t, system.sysbus_drain(sb))

    svc, sok := system.sysbus_service(sb, "net.connman.iwd")
    testing.expect(t, sok)
    if !sok {
        return
    }
    state, stok := system.dbus_om_string(svc.tree, IWD_DEVICE, "net.connman.iwd.Station", "State")
    testing.expect(t, stok)
    testing.expect_value(t, state, "disconnected")

    // A signal nothing recognises costs a read and nothing else — no snapshot, so no
    // needless wake of the main loop.
    system.dbus_script_push(
        conn,
        sys_signal_raw(
            "/org/bluez/hci0",
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            ":1.9",
            "sa{sv}as",
            []system.Dbus_Value {
                system.Dbus_String("org.bluez.Adapter1"),
                dv_props(dv_prop("Powered", "b", true)),
                dv_strs(),
            },
        ),
    )
    testing.expect(t, !system.sysbus_step(sb), "a foreign signal must not publish")
    testing.expect(t, !system.sysbus_drain(sb), "and must not leave a snapshot to drain")
}

// --- the request queue ---

@(test)
test_sysbus_request_ok :: proc(t: ^testing.T) {
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    // What a row does when the user hits Enter on a known network.
    id := system.sysbus_request(
        sb,
        .System,
        "net.connman.iwd",
        IWD_DEVICE,
        "net.connman.iwd.Station",
        "Disconnect",
    )
    testing.expect_value(t, id, u64(1))

    // Queued only: the main thread never touched the socket.
    testing.expect_value(t, len(conn.sent), 5)

    system.dbus_script_push(conn, sys_return(6))
    testing.expect(t, system.sysbus_step(sb))

    sent, sok := system.dbus_sent_msg(conn, 5)
    testing.expect(t, sok, "the worker should have sent the call")
    if sok {
        testing.expect_value(t, sent.destination, "net.connman.iwd")
        testing.expect_value(t, sent.path, IWD_DEVICE)
        testing.expect_value(t, sent.iface, "net.connman.iwd.Station")
        testing.expect_value(t, sent.member, "Disconnect")
        testing.expect_value(t, sent.signature, "")
    }

    testing.expect(t, system.sysbus_drain(sb))
    res, rok := system.sysbus_result(sb, id)
    testing.expect(t, rok, "the outcome rides the snapshot")
    testing.expect_value(t, res.state, system.Sys_Req_State.Ok)
}

@(test)
test_sysbus_request_carries_args :: proc(t: ^testing.T) {
    // An action with a body — the shape every real verb takes (iwd's KnownNetwork.Forget
    // is bare, but NetworkManager's and BlueZ's are not). The args are cloned into the
    // queue, so the row data they came from can be long gone by the time this is sent.
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    id := system.sysbus_request(
        sb,
        .System,
        "net.connman.iwd",
        IWD_DEVICE,
        "net.connman.iwd.Station",
        "ConnectHiddenNetwork",
        "s",
        []system.Dbus_Value{system.Dbus_String("Smith")},
    )
    system.dbus_script_push(conn, sys_return(6))
    testing.expect(t, system.sysbus_step(sb))

    sent, sok := system.dbus_sent_msg(conn, 5)
    testing.expect(t, sok)
    if !sok {
        return
    }
    testing.expect_value(t, sent.member, "ConnectHiddenNetwork")
    testing.expect_value(t, sent.signature, "s")
    args, aok := system.dbus_msg_args(&sent)
    testing.expect(t, aok && len(args) == 1)
    if aok && len(args) == 1 {
        ssid, ok := system.dbus_as_string(args[0])
        testing.expect(t, ok)
        testing.expect_value(t, ssid, "Smith")
    }

    testing.expect(t, system.sysbus_drain(sb))
    res, rok := system.sysbus_result(sb, id)
    testing.expect(t, rok)
    testing.expect_value(t, res.state, system.Sys_Req_State.Ok)
}

@(test)
test_sysbus_request_failure_is_legible :: proc(t: ^testing.T) {
    // The polkit case. The user asked for this, so the refusal has to survive all the way
    // to the row.
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    id := system.sysbus_request(
        sb,
        .System,
        "net.connman.iwd",
        IWD_DEVICE,
        "net.connman.iwd.Station",
        "Disconnect",
    )
    system.dbus_script_push(
        conn,
        sys_error(6, "org.freedesktop.DBus.Error.AccessDenied", "permission denied"),
    )
    testing.expect(t, system.sysbus_step(sb))
    testing.expect(t, system.sysbus_drain(sb))

    res, rok := system.sysbus_result(sb, id)
    testing.expect(t, rok)
    testing.expect_value(t, res.state, system.Sys_Req_State.Failed)
    testing.expect_value(t, res.error_name, "org.freedesktop.DBus.Error.AccessDenied")
    testing.expect_value(t, res.error_msg, "permission denied")

    // A daemon that says nothing at all is its own failure, not a silent success.
    id2 := system.sysbus_request(
        sb,
        .System,
        "net.connman.iwd",
        IWD_DEVICE,
        "net.connman.iwd.Station",
        "Scan",
    )
    testing.expect(t, system.sysbus_step(sb))
    testing.expect(t, system.sysbus_drain(sb))
    res2, rok2 := system.sysbus_result(sb, id2)
    testing.expect(t, rok2)
    testing.expect_value(t, res2.state, system.Sys_Req_State.Failed)
    testing.expect_value(t, res2.error_name, "org.freedesktop.DBus.Error.NoReply")
}

@(test)
test_sysbus_request_without_bus :: proc(t: ^testing.T) {
    // Nothing is attached to the session bus here, and nothing opens one in a test. A
    // request against it must fail on the row rather than disappear.
    sb, _ := fake_sysbus()
    defer fake_sysbus_free(sb)

    id := system.sysbus_request(
        sb,
        .Session,
        "org.mpris.MediaPlayer2.x",
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        "PlayPause",
    )
    testing.expect(t, system.sysbus_step(sb))
    testing.expect(t, system.sysbus_drain(sb))

    res, rok := system.sysbus_result(sb, id)
    testing.expect(t, rok)
    testing.expect_value(t, res.state, system.Sys_Req_State.Failed)
    testing.expect_value(t, res.error_name, "org.freedesktop.DBus.Error.Disconnected")
}

@(test)
test_sysbus_results_stay_bounded :: proc(t: ^testing.T) {
    // Results are kept so a row can read its outcome back, which means the list has to be
    // bounded or a long session grows one entry per action forever.
    sb, conn := fake_sysbus()
    defer fake_sysbus_free(sb)

    last: u64
    for i in 0 ..< system.SYS_RESULTS_KEEP + 8 {
        last = system.sysbus_request(
            sb,
            .System,
            "net.connman.iwd",
            IWD_DEVICE,
            "net.connman.iwd.Station",
            "Scan",
        )
        system.dbus_script_push(conn, sys_return(u32(6 + i)))
        system.sysbus_step(sb)
    }
    testing.expect(t, system.sysbus_drain(sb))
    testing.expect_value(t, len(sb.cur.results), system.SYS_RESULTS_KEEP)

    // The newest survives; the oldest is what went.
    _, newest := system.sysbus_result(sb, last)
    testing.expect(t, newest, "the most recent outcome must still be readable")
    _, oldest := system.sysbus_result(sb, 1)
    testing.expect(t, !oldest, "the oldest finished result is the one dropped")
}

// --- live bus (layer 3) ---

@(test)
test_sysbus_live_iwd :: proc(t: ^testing.T) {
    // The same worker code against the real daemon, driven synchronously: a REAL
    // connection attached where a scripted one goes, so sysbus_open does its actual
    // startup conversation and the snapshot is built from a foreign encoder's bytes.
    // Read-only, and it skips when the bus or the service isn't there.
    //
    // What this deliberately does NOT do is start the worker thread: that shell is a
    // poll() and a wake pipe around these same two procs, and starting it here would drag
    // GLFW's event loop into a headless test for no added coverage.
    conn, ok := system.dbus_open(.System)
    if !ok {
        fmt.println("[skip] no system bus reachable; see sysbus_test.odin")
        return
    }
    sb := new(system.Sysbus)
    defer fake_sysbus_free(sb) // closes the real connection too
    system.sysbus_init(sb)
    system.sysbus_attach(sb, .System, conn)
    system.sysbus_watch(sb, .System, "net.connman.iwd", "/", IWD_FILTER)
    system.sysbus_open(sb)

    testing.expect(t, system.sysbus_drain(sb), "opening publishes the first snapshot")
    svc, sok := system.sysbus_service(sb, "net.connman.iwd")
    testing.expect(t, sok, "a watched service is in the snapshot whether or not it is running")
    if !sok || !svc.present {
        fmt.println("[skip] net.connman.iwd is not on the system bus")
        return
    }
    adapters := system.dbus_om_paths(svc.tree, "net.connman.iwd.Adapter")
    testing.expectf(t, len(adapters) > 0, "iwd running should mean at least one adapter")
}

// --- handoff ---

@(test)
test_sysbus_drain_is_cheap_when_idle :: proc(t: ^testing.T) {
    sb, _ := fake_sysbus()
    defer fake_sysbus_free(sb)

    testing.expect(t, system.sysbus_drain(sb), "the first drain takes the snapshot")
    testing.expect(t, !system.sysbus_drain(sb), "a second one has nothing to take")

    // A step with nothing waiting publishes nothing, which is what keeps an idle Slopd
    // with four panes registered at 0%.
    testing.expect(t, !system.sysbus_step(sb))
    testing.expect(t, !system.sysbus_drain(sb))
}

@(test)
test_sysbus_tick_reaches_the_main_thread :: proc(t: ^testing.T) {
    // The 1s beat is the only thing a live graph advances on, and with no bus traffic it
    // is the ONLY thing happening — so a tick that merely bumps a worker-side counter is
    // a timer nobody can see. It has to publish.
    sb, _ := fake_sysbus()
    defer fake_sysbus_free(sb)
    testing.expect(t, system.sysbus_drain(sb))
    testing.expect_value(t, sb.cur.ticks, u64(0))

    testing.expect(t, system.sysbus_step(sb, true), "a beat must publish")
    testing.expect(t, system.sysbus_drain(sb))
    testing.expect_value(t, sb.cur.ticks, u64(1))
}
