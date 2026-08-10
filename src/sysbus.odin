package main

import "core:c"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "vendor:glfw"

// Sysbus — ONE worker thread behind all four device panes (see "Threading" in plan.txt).
// It owns both bus connections and every ObjectManager tree, and the main thread never
// touches a socket.
//
// Threading model (procmon.odin's sampler and terminal.odin's reader, plus one thing):
//   - The worker blocks in poll() on [wake pipe, system fd, session fd]. D-Bus is
//     signal-driven, so unlike procmon there is NO poll loop: the panes are live and the
//     app still idles at 0%. The only timer is a 1s tick, armed only while a pane wanting
//     a live graph is on screen (sysbus_set_ticking).
//   - Incoming signals update the worker's authoritative trees. Anything that moves is
//     snapshotted heap-owned, handed off as `pending` under `lock`, and PostEmptyEvent
//     wakes the main loop. sysbus_drain installs it into `cur` each frame. `cur` is
//     MAIN-THREAD-ONLY, so draw needs no lock.
//
// THE ONE ADDITION — a REQUEST QUEUE the other way. procmon's single action (posix.kill)
// is instant, so it runs on the main thread. A D-Bus Connect() can block for thirty
// seconds, so actions cannot: the main thread pushes a request and writes a wake byte, and
// the worker performs the call and reports the outcome in the next snapshot. The row
// renders in-flight in the meantime — the worker publishes a snapshot as soon as it picks
// a request up, BEFORE it blocks on the call, precisely so that state is visible. A
// permission failure (the polkit-gated ops on iwd and BlueZ) is carried as an error name
// ON THE RESULT, because the user asked for this action and, unlike procmon's silent
// EPERM no-op, it has to be legible.
//
// Requests are performed one at a time, in order. A hung daemon therefore delays the
// requests queued behind it (bounded by DBUS_CALL_TIMEOUT) but never the UI, which is
// drawing a snapshot and does not wait on anything.
//
// Testing: sysbus_open and sysbus_step are the whole worker minus the blocking poll, and
// both are synchronous. Attach scripted connections with sysbus_attach and a test drives
// the entire thing on one thread with no daemon and no timing (src/tests/sysbus_test.odin).

SYS_TICK_MS :: 1000 // the graph beat, armed only while a pane wants it
SYS_RESULTS_KEEP :: 32 // finished results retained for the panes to read back

// What a pane asks sysbus to track: one ObjectManager, on one bus, filtered to the
// interfaces that pane actually reads.
Sys_Watch :: struct {
    bus:     Dbus_Bus,
    service: string, // owned
    root:    string, // owned
    filter:  []string, // owned
}

Sys_Req_State :: enum {
    In_Flight, // picked up by the worker; the call has not answered yet
    Ok,
    Failed,
}

// A queued action. Strings and args are OWNED clones — the main thread builds these from
// borrowed row data, and the worker reads them after that data is long gone.
Sys_Request :: struct {
    id:          u64,
    bus:         Dbus_Bus,
    destination: string,
    path:        string,
    iface:       string,
    member:      string,
    sig:         string,
    args:        []Dbus_Value,
}

// How a request ended, as the row draws it. `error_name` is the dotted D-Bus name
// (org.freedesktop.DBus.Error.AccessDenied and friends); `error_msg` its human text.
Sys_Result :: struct {
    id:         u64,
    state:      Sys_Req_State,
    error_name: string, // owned
    error_msg:  string, // owned
}

// One tracked service as the main thread sees it. `tree` is a private copy, owned by the
// snapshot and freed with it.
Sys_Service :: struct {
    service: string, // owned
    present: bool,
    tree:    ^Dbus_Om, // owned
}

// The drawn state, swapped wholesale. Everything here is heap-owned and freed by
// sys_snapshot_free.
Sys_Snapshot :: struct {
    services: []Sys_Service,
    results:  []Sys_Result,
    ticks:    u64, // 1s beats since start; the heartbeat a live graph samples on
}

@(private = "file")
Sys_Tree :: struct {
    bus: Dbus_Bus,
    om:  ^Dbus_Om,
}

Sysbus :: struct {
    // main thread
    worker:  ^thread.Thread,
    running: bool,
    next_id: u64,
    cur:     Sys_Snapshot, // main-thread-only (drawn without a lock)

    // shared, lock-guarded
    lock:        sync.Mutex,
    pending:     Sys_Snapshot,
    has_pending: bool,
    queue:       [dynamic]Sys_Request, // main -> worker
    ticking:     bool,

    // The wake pipe: writing one byte breaks the worker out of poll(), which is how a
    // request is delivered promptly and how stopping is not a wait for the next timeout.
    wake_r: posix.FD,
    wake_w: posix.FD,

    // set before start, read by the worker
    watches: [dynamic]Sys_Watch,

    // worker-private (the main thread only touches these before start / after join)
    conns:   [Dbus_Bus]^Dbus_Conn,
    trees:   [dynamic]Sys_Tree,
    results: [dynamic]Sys_Result,
    ticks:   u64,
}

// --- lifecycle (main thread) ---

// ok=false only if the wake pipe can't be made, in which case the worker is never started
// and every pane reads an empty snapshot — "unavailable", not a hang.
sysbus_init :: proc(sb: ^Sysbus) -> bool {
    sb.wake_r, sb.wake_w = -1, -1
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK {
        return false
    }
    sb.wake_r, sb.wake_w = fds[0], fds[1]
    return true
}

// Registers a tree to track. Call before sysbus_start: the worker reads `watches` once, at
// startup, since connecting and taking the first snapshot is exactly the blocking work
// that must not happen on the main thread.
sysbus_watch :: proc(sb: ^Sysbus, bus: Dbus_Bus, service, root: string, filter: []string = nil) {
    w := Sys_Watch {
        bus     = bus,
        service = strings.clone(service),
        root    = strings.clone(root),
    }
    if filter != nil {
        keep := make([]string, len(filter))
        for f, i in filter {
            keep[i] = strings.clone(f)
        }
        w.filter = keep
    }
    append(&sb.watches, w)
}

sysbus_start :: proc(sb: ^Sysbus) {
    if sb.wake_r < 0 || sb.running {
        return
    }
    sb.running = true
    sb.worker = thread.create(sysbus_worker_proc)
    if sb.worker == nil {
        sb.running = false
        return
    }
    sb.worker.data = sb
    // The worker allocates every snapshot and the main thread frees it, so the two must
    // agree on the allocator — without this the worker would run under the default context
    // and hand back memory allocated somewhere the caller's allocator has never heard of.
    // Its TEMP allocator is a different matter and is replaced with a private arena inside
    // the worker proc, since that one genuinely must not be shared.
    sb.worker.init_context = context
    thread.start(sb.worker)
}

// Stops the worker and joins it. The wake byte is the whole reason this returns promptly:
// the worker is parked in a poll() with no timeout whenever nothing is ticking.
sysbus_stop :: proc(sb: ^Sysbus) {
    if !sb.running {
        return
    }
    sb.running = false
    sysbus_wake(sb)
    if sb.worker != nil {
        thread.join(sb.worker)
        thread.destroy(sb.worker)
        sb.worker = nil
    }
}

sysbus_destroy :: proc(sb: ^Sysbus) {
    sysbus_stop(sb) // after this the worker is gone, so its private state is ours to free

    for &t in sb.trees {
        dbus_om_destroy(t.om)
    }
    delete(sb.trees)
    for bus in Dbus_Bus {
        dbus_close(sb.conns[bus])
        sb.conns[bus] = nil
    }
    for &w in sb.watches {
        delete(w.service)
        delete(w.root)
        for f in w.filter {
            delete(f)
        }
        delete(w.filter)
    }
    delete(sb.watches)
    for &r in sb.queue {
        sys_request_free(&r)
    }
    delete(sb.queue)
    for &r in sb.results {
        delete(r.error_name)
        delete(r.error_msg)
    }
    delete(sb.results)

    sys_snapshot_free(&sb.cur)
    if sb.has_pending {
        sys_snapshot_free(&sb.pending)
    }
    if sb.wake_r >= 0 {
        posix.close(sb.wake_r)
    }
    if sb.wake_w >= 0 {
        posix.close(sb.wake_w)
    }
    sb.wake_r, sb.wake_w = -1, -1
}

sys_snapshot_free :: proc(s: ^Sys_Snapshot) {
    for &svc in s.services {
        delete(svc.service)
        dbus_om_destroy(svc.tree)
    }
    delete(s.services)
    for &r in s.results {
        delete(r.error_name)
        delete(r.error_msg)
    }
    delete(s.results)
    s^ = {}
}

@(private = "file")
sys_request_free :: proc(r: ^Sys_Request) {
    delete(r.destination)
    delete(r.path)
    delete(r.iface)
    delete(r.member)
    delete(r.sig)
    for a in r.args {
        dbus_value_free(a)
    }
    delete(r.args)
    r^ = {}
}

// --- main-thread API ---

// Each frame: move a freshly published snapshot into `cur`. Returns whether anything
// changed, so a pane can rebuild its rows only when it must. Cheap (an early return) the
// rest of the time.
sysbus_drain :: proc(sb: ^Sysbus) -> bool {
    sync.mutex_lock(&sb.lock)
    if !sb.has_pending {
        sync.mutex_unlock(&sb.lock)
        return false
    }
    snap := sb.pending
    sb.has_pending = false
    sync.mutex_unlock(&sb.lock)

    sys_snapshot_free(&sb.cur)
    sb.cur = snap
    return true
}

// Queues an action and returns its id. The row keeps that id and reads the outcome back
// out of later snapshots with sysbus_result; nothing here blocks.
sysbus_request :: proc(
    sb: ^Sysbus,
    bus: Dbus_Bus,
    destination, path, iface, member: string,
    sig: string = "",
    args: []Dbus_Value = nil,
) -> u64 {
    sb.next_id += 1
    req := Sys_Request {
        id          = sb.next_id,
        bus         = bus,
        destination = strings.clone(destination),
        path        = strings.clone(path),
        iface       = strings.clone(iface),
        member      = strings.clone(member),
        sig         = strings.clone(sig),
    }
    if args != nil {
        owned := make([]Dbus_Value, len(args))
        for a, i in args {
            owned[i] = dbus_value_clone(a)
        }
        req.args = owned
    }

    sync.mutex_lock(&sb.lock)
    append(&sb.queue, req)
    sync.mutex_unlock(&sb.lock)
    sysbus_wake(sb)
    return sb.next_id
}

// The outcome of a request as of the current snapshot. Absent means the worker hasn't
// picked it up yet — still queued, which a row draws the same as in-flight.
sysbus_result :: proc(sb: ^Sysbus, id: u64) -> (res: Sys_Result, ok: bool) {
    for r in sb.cur.results {
        if r.id == id {
            return r, true
        }
    }
    return {}, false
}

// A tracked service out of the current snapshot. present=false is the pane's cue to draw
// "unavailable" rather than an empty list.
sysbus_service :: proc(sb: ^Sysbus, service: string) -> (svc: Sys_Service, ok: bool) {
    for s in sb.cur.services {
        if s.service == service {
            return s, true
        }
    }
    return {}, false
}

// Arms or disarms the 1s tick. On only while a pane wanting a live graph is visible —
// procmon's `wanted` gating, and the reason an idle Slopd stays at 0% with four live
// panes registered.
sysbus_set_ticking :: proc(sb: ^Sysbus, on: bool) {
    sync.mutex_lock(&sb.lock)
    changed := sb.ticking != on
    sb.ticking = on
    sync.mutex_unlock(&sb.lock)
    if changed {
        sysbus_wake(sb) // re-enter poll() with the new timeout instead of waiting one out
    }
}

@(private = "file")
sysbus_wake :: proc(sb: ^Sysbus) {
    if sb.wake_w < 0 {
        return
    }
    b := [1]u8{1}
    posix.write(sb.wake_w, raw_data(b[:]), 1)
}

// --- the worker ---

@(private = "file")
sysbus_worker_proc :: proc(th: ^thread.Thread) {
    sb := (^Sysbus)(th.data)
    // A private growing arena: the default temp allocator is not safe to share with the
    // main thread, and everything under dbus_call marshals through temp.
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil {
        return
    }
    defer virtual.arena_destroy(&arena)
    context.temp_allocator = virtual.arena_allocator(&arena)

    sysbus_open(sb) // connect + first snapshot; the blocking work, off the main thread
    glfw.PostEmptyEvent()
    free_all(context.temp_allocator)

    for sb.running {
        ticked := sysbus_wait(sb)
        if !sb.running {
            break
        }
        // A tick is news in itself — it is the beat a live graph samples on, and without
        // passing it through, an armed timer would advance a counter nobody ever sees.
        if sysbus_step(sb, ticked) {
            glfw.PostEmptyEvent()
        }
        free_all(context.temp_allocator)
    }
}

// Opens the connections the watches need, starts their trees, and publishes the first
// snapshot. Runs once, on the worker, because dbus_open plus a GetManagedObjects round
// trip is exactly the blocking work the main thread must never do. A bus that won't open,
// or a service that isn't running, is not an error: the tree stays empty and
// present=false, and the NameOwnerChanged match dbus_om_start registered brings it to life
// if the daemon shows up later.
sysbus_open :: proc(sb: ^Sysbus) {
    for w in sb.watches {
        om := dbus_om_make(w.service, w.root, w.filter)
        append(&sb.trees, Sys_Tree{bus = w.bus, om = om})
        if conn := sysbus_conn(sb, w.bus); conn != nil {
            dbus_om_start(om, conn)
        }
    }
    sysbus_publish(sb)
}

// One pass of the worker's work, minus the blocking wait: run the queue, drain the buses,
// re-fetch anything that came back, publish what moved. `ticked` says the wait ended on
// the 1s beat, which counts as something moving. Returns whether a snapshot was published.
//
// Public and synchronous on purpose — this IS the worker, and a test drives it directly
// against scripted connections with no thread involved.
sysbus_step :: proc(sb: ^Sysbus, ticked: bool = false) -> bool {
    sync.mutex_lock(&sb.lock)
    reqs := slice.clone(sb.queue[:], context.temp_allocator) // ownership moves to us
    clear(&sb.queue)
    sync.mutex_unlock(&sb.lock)

    published := false
    if ticked {
        sb.ticks += 1
    }

    // Picked up: publish BEFORE performing, so the row renders in-flight rather than
    // looking untouched for as long as the daemon takes to answer.
    if len(reqs) > 0 {
        for r in reqs {
            sysbus_result_set(sb, r.id, .In_Flight, "", "")
        }
        sysbus_publish(sb)
        published = true
    }
    for &r in reqs {
        sysbus_perform(sb, &r)
        sys_request_free(&r)
    }

    changed := len(reqs) > 0 || ticked
    if sysbus_read(sb) {
        changed = true
    }
    if sysbus_refetch(sb) {
        changed = true
    }
    if changed {
        sysbus_publish(sb)
        published = true
    }
    return published
}

// Blocks until something happens: a signal on either bus, a wake byte (a new request, a
// ticking change, or a stop), or the 1s beat when it is armed. Returns whether it was the
// beat that ended the wait.
@(private = "file")
sysbus_wait :: proc(sb: ^Sysbus) -> (ticked: bool) {
    if sb.wake_r < 0 {
        return false
    }
    fds: [1 + len(Dbus_Bus)]posix.pollfd
    n := 0
    fds[n] = posix.pollfd {
        fd     = sb.wake_r,
        events = {.IN},
    }
    n += 1
    for bus in Dbus_Bus {
        conn := sb.conns[bus]
        if conn != nil && conn.fd >= 0 {
            fds[n] = posix.pollfd {
                fd     = conn.fd,
                events = {.IN},
            }
            n += 1
        }
    }

    sync.mutex_lock(&sb.lock)
    ticking := sb.ticking
    sync.mutex_unlock(&sb.lock)

    timeout: c.int = ticking ? SYS_TICK_MS : -1
    if posix.poll(&fds[0], posix.nfds_t(n), timeout) == 0 {
        return true // a timeout IS the beat; sysbus_step counts it
    }
    if .IN in fds[0].revents {
        drain: [64]u8 // however many wakes coalesced, one read clears them
        posix.read(sb.wake_r, raw_data(drain[:]), len(drain))
    }
    return false
}

// Reads everything waiting on both buses into the trees. Messages parked by dbus_call
// while it waited for a reply come first — they arrived first.
@(private = "file")
sysbus_read :: proc(sb: ^Sysbus) -> bool {
    changed := false
    for bus in Dbus_Bus {
        conn := sb.conns[bus]
        if conn == nil {
            continue
        }
        for &m in conn.inbox {
            if sysbus_dispatch(sb, bus, &m) {
                changed = true
            }
            dbus_msg_free(&m)
        }
        clear(&conn.inbox)

        for dbus_readable(conn) {
            m, ok := dbus_read_msg(conn)
            if !ok {
                break // a dead socket or a malformed frame; the trees keep what they have
            }
            if sysbus_dispatch(sb, bus, &m) {
                changed = true
            }
            dbus_msg_free(&m)
        }
    }
    return changed
}

// Offers one message to every tree on that bus. A tree that doesn't recognise the sender,
// the path or the shape ignores it (dbus_om_apply checks all three), so this stays a plain
// broadcast no matter how many services share a connection.
//
// Phase 3 seam: a Method_Call addressed to one of OUR exported objects (the wifi
// passphrase and BlueZ pairing agents) gets parked here as a pending request instead —
// same queue, running the other way. Nothing exports an object yet, so nothing does.
@(private = "file")
sysbus_dispatch :: proc(sb: ^Sysbus, bus: Dbus_Bus, m: ^Dbus_Message) -> bool {
    changed := false
    for &t in sb.trees {
        if t.bus != bus {
            continue
        }
        if dbus_om_apply(t.om, m) {
            changed = true
        }
    }
    return changed
}

// A service that just (re)appeared has an empty tree and a `refetch` flag; this is where
// the new snapshot is taken. ONE attempt per appearance — the flag is cleared either way,
// because retrying it on every later message would mean a call per signal against a daemon
// that has already shown it won't answer. Its next restart sets the flag again.
@(private = "file")
sysbus_refetch :: proc(sb: ^Sysbus) -> bool {
    changed := false
    for &t in sb.trees {
        if !t.om.refetch {
            continue
        }
        t.om.refetch = false
        conn := sb.conns[t.bus]
        if conn == nil {
            continue
        }
        if dbus_om_fetch(t.om, conn) {
            changed = true
        }
    }
    return changed
}

// Performs one queued call and records how it ended. A failure is kept, not swallowed:
// polkit refusing a connect is the answer to something the user asked for.
@(private = "file")
sysbus_perform :: proc(sb: ^Sysbus, req: ^Sys_Request) {
    conn := sb.conns[req.bus]
    if conn == nil {
        sysbus_result_set(
            sb,
            req.id,
            .Failed,
            "org.freedesktop.DBus.Error.Disconnected",
            "no connection to the bus",
        )
        return
    }
    reply, ok := dbus_call(
        conn,
        req.destination,
        req.path,
        req.iface,
        req.member,
        req.sig,
        req.args,
    )
    if ok {
        dbus_msg_free(&reply)
        sysbus_result_set(sb, req.id, .Ok, "", "")
        return
    }
    // No reply at all is its own failure; an error reply names itself and usually carries
    // one string of human text.
    name, text := "org.freedesktop.DBus.Error.NoReply", "no reply from the daemon"
    if reply.type == .Error {
        name = reply.error_name
        if args, aok := dbus_msg_args(&reply); aok && len(args) >= 1 {
            if s, sok := dbus_as_string(args[0]); sok {
                text = s
            }
        }
    }
    sysbus_result_set(sb, req.id, .Failed, name, text) // clones before the buffer goes
    if reply.type != .Invalid {
        dbus_msg_free(&reply)
    }
}

// Records or updates a result, keeping the list bounded: once it is full the oldest
// FINISHED entry is dropped, never an in-flight one — that would lose a row's only handle
// on a call still running.
@(private = "file")
sysbus_result_set :: proc(sb: ^Sysbus, id: u64, state: Sys_Req_State, name, text: string) {
    for &r in sb.results {
        if r.id == id {
            delete(r.error_name)
            delete(r.error_msg)
            r.state = state
            r.error_name = strings.clone(name)
            r.error_msg = strings.clone(text)
            return
        }
    }
    append(
        &sb.results,
        Sys_Result {
            id         = id,
            state      = state,
            error_name = strings.clone(name),
            error_msg  = strings.clone(text),
        },
    )
    for len(sb.results) > SYS_RESULTS_KEEP {
        drop := -1
        for r, i in sb.results {
            if r.state != .In_Flight {
                drop = i
                break
            }
        }
        if drop < 0 {
            break
        }
        delete(sb.results[drop].error_name)
        delete(sb.results[drop].error_msg)
        ordered_remove(&sb.results, drop)
    }
}

// Clones the worker's state into a fresh snapshot and hands it off, dropping any the main
// thread hasn't consumed yet (the newer one supersedes it — procmon's rule).
@(private = "file")
sysbus_publish :: proc(sb: ^Sysbus) {
    snap: Sys_Snapshot
    snap.ticks = sb.ticks

    services := make([]Sys_Service, len(sb.trees))
    for &t, i in sb.trees {
        services[i] = Sys_Service {
            service = strings.clone(t.om.service),
            present = dbus_om_present(t.om),
            tree    = dbus_om_clone(t.om),
        }
        t.om.dirty = false
    }
    snap.services = services

    results := make([]Sys_Result, len(sb.results))
    for r, i in sb.results {
        results[i] = Sys_Result {
            id         = r.id,
            state      = r.state,
            error_name = strings.clone(r.error_name),
            error_msg  = strings.clone(r.error_msg),
        }
    }
    snap.results = results

    sync.mutex_lock(&sb.lock)
    if sb.has_pending {
        sys_snapshot_free(&sb.pending)
    }
    sb.pending = snap
    sb.has_pending = true
    sync.mutex_unlock(&sb.lock)
}

// Opens a bus on demand, once. Returns nil when the bus isn't reachable at all (a
// container with no system bus, a session with no DBUS_SESSION_BUS_ADDRESS).
@(private = "file")
sysbus_conn :: proc(sb: ^Sysbus, bus: Dbus_Bus) -> ^Dbus_Conn {
    if sb.conns[bus] == nil {
        if conn, ok := dbus_open(bus); ok {
            sb.conns[bus] = conn
        }
    }
    return sb.conns[bus]
}

// Installs a connection the worker would otherwise open itself. The scripted-transport
// hook (dbus_conn_fake): with one attached, sysbus_open finds a connection already in
// place and never touches a socket.
sysbus_attach :: proc(sb: ^Sysbus, bus: Dbus_Bus, conn: ^Dbus_Conn) {
    dbus_close(sb.conns[bus])
    sb.conns[bus] = conn
}
