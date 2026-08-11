package main

import "core:fmt"
import "core:slice"
import "core:strings"

// D-Bus ObjectManager — the live object tree, written ONCE (see "System panes" in
// plan.txt). Every consumer the device panes have — NetworkManager, iwd, BlueZ, Mutter's
// DisplayConfig, MPRIS, login1 — is the same shape: GetManagedObjects hands back
// {path -> {interface -> {property -> variant}}}, and InterfacesAdded / InterfacesRemoved
// / PropertiesChanged keep it current. So the tree lives here and each pane is a thin
// mapping from it onto rows. Do not write four object-tree walkers.
//
// Ownership INVERTS dbus.odin's rule. A decoded message borrows its buffer, but this tree
// outlives the message that filled it, so everything landing in it is deep-cloned
// (dbus_value_clone) and freed on the way out. That is the whole point of the file:
// dbus.odin hands you bytes that expire, this keeps them. What comes back OUT of the
// queries below is borrowed again — tree-owned, valid until the next apply.
//
// Everything except dbus_om_start / dbus_om_watch / dbus_om_fetch is PURE: dbus_om_apply
// takes a DECODED message and mutates the tree, so the entire live half tests headless
// off hand-built signals with no bus and no daemon (src/tests/dbus_om_test.odin).

DBUS_OM_IFACE :: "org.freedesktop.DBus.ObjectManager"
DBUS_PROPS_IFACE :: "org.freedesktop.DBus.Properties"
DBUS_BUS_IFACE :: "org.freedesktop.DBus"
DBUS_BUS_NAME :: "org.freedesktop.DBus"
DBUS_BUS_PATH :: "/org/freedesktop/DBus"

// One interface on one object: its property bag. Keys and values are owned clones.
Dbus_Om_Iface :: struct {
    props: map[string]Dbus_Value,
}

// One object. The path is the key it is stored under, so it isn't repeated here.
Dbus_Om_Object :: struct {
    ifaces: map[string]Dbus_Om_Iface,
}

Dbus_Om :: struct {
    service: string, // owned; the well-known name we track ("net.connman.iwd")
    owner:   string, // owned; the unique name that actually stamps its signals (":1.7")
    root:    string, // owned; the object path the ObjectManager sits on ("/")
    filter:  []string, // owned; interfaces to keep. nil keeps everything
    objects: map[string]Dbus_Om_Object, // owned path keys
    dirty:   bool, // mutated since the consumer last cleared it (sysbus snapshots on this)
    refetch: bool, // the service (re)appeared: the tree is empty, GetManagedObjects must rerun
}

// Builds an empty tree. Touches no bus — a pane can construct its tree before deciding
// whether the daemon behind it even exists. `filter` is the set of interfaces worth
// keeping (nil = keep all): iwd alone publishes a dozen we never read, and filtering here
// means the property churn from them is never cloned in the first place.
dbus_om_make :: proc(service, root: string, filter: []string = nil) -> ^Dbus_Om {
    om := new(Dbus_Om)
    om.service = strings.clone(service)
    om.root = strings.clone(root)
    if filter != nil {
        keep := make([]string, len(filter))
        for f, i in filter {
            keep[i] = strings.clone(f)
        }
        om.filter = keep
    }
    return om
}

dbus_om_destroy :: proc(om: ^Dbus_Om) {
    if om == nil {
        return
    }
    dbus_om_clear(om)
    delete(om.objects)
    delete(om.service)
    delete(om.owner)
    delete(om.root)
    for f in om.filter {
        delete(f)
    }
    delete(om.filter)
    free(om)
}

// A deep copy of the CONTENTS — no connection, no live wiring. This is what the sysbus
// worker hands the main thread each time something moves, so drawing needs no lock: the
// same heap-owned handoff as ProcSnapshot.
dbus_om_clone :: proc(om: ^Dbus_Om) -> ^Dbus_Om {
    out := dbus_om_make(om.service, om.root, om.filter)
    dbus_om_set_owner(out, om.owner)
    out.dirty, out.refetch = om.dirty, om.refetch
    for path, &obj in om.objects {
        dst := om_object_ensure(out, path)
        for name, &ifc in obj.ifaces {
            dst_ifc := om_iface_ensure(dst, name)
            for prop, val in ifc.props {
                om_prop_set(dst_ifc, prop, val)
            }
        }
    }
    return out
}

// Drops every object, keeping the tree's identity (service, root, filter).
dbus_om_clear :: proc(om: ^Dbus_Om) {
    for path, &obj in om.objects {
        om_object_free(&obj)
        delete(path)
    }
    clear(&om.objects)
}

// Is the service on the bus at all? False means the pane draws "unavailable" rather than
// an empty list.
dbus_om_present :: proc(om: ^Dbus_Om) -> bool {
    return om.owner != ""
}

// The owning unique name has exactly one setter: it is the identity check every incoming
// signal is measured against, and it is owned storage that has to be freed on the way out.
dbus_om_set_owner :: proc(om: ^Dbus_Om, owner: string) {
    delete(om.owner)
    om.owner = strings.clone(owner)
}

// --- live wiring (the only three procs here that touch a socket) ---

// Subscribes, resolves the owner, then takes the snapshot — IN THAT ORDER, and the order
// is the point.
//
// Matches FIRST, before we even know whether the service exists. Match rules are keyed by
// name, not by owner, so registering early costs nothing and is the only way to hear a
// daemon that starts after we do (iwd coming up after Slopd is the ordinary case on a
// fresh boot). It also means nothing changing mid-fetch is missed: whatever races the
// GetManagedObjects reply lands in conn.inbox and applies after it, which is the right
// sequence — older snapshot first, then the newer signals on top.
//
// ok=false means the service isn't running (or refused us). That is NOT a failure to
// recover from: the tree stays empty, dbus_om_present stays false, and the NameOwnerChanged
// match already registered above is what wakes it up later.
dbus_om_start :: proc(om: ^Dbus_Om, c: ^Dbus_Conn) -> bool {
    dbus_om_watch(om, c) or_return
    om_resolve_owner(om, c)
    if !dbus_om_present(om) {
        return false
    }
    return dbus_om_fetch(om, c)
}

// The three match rules the tree runs on. Scoped to the service so a busy system bus
// doesn't wake our worker for traffic we'd only throw away.
dbus_om_watch :: proc(om: ^Dbus_Om, c: ^Dbus_Conn) -> bool {
    dbus_add_match(
        c,
        fmt.tprintf(
            "type='signal',sender='%s',interface='%s',path='%s'",
            om.service,
            DBUS_OM_IFACE,
            om.root,
        ),
    ) or_return
    dbus_add_match(
        c,
        fmt.tprintf(
            "type='signal',sender='%s',interface='%s',member='PropertiesChanged'",
            om.service,
            DBUS_PROPS_IFACE,
        ),
    ) or_return
    // The daemon, not the service, sends this one — it is how we learn the service died
    // or came back, and neither event produces any other traffic.
    return dbus_add_match(
        c,
        fmt.tprintf(
            "type='signal',sender='%s',interface='%s',member='NameOwnerChanged',arg0='%s'",
            DBUS_BUS_NAME,
            DBUS_BUS_IFACE,
            om.service,
        ),
    )
}

// GetManagedObjects, applied wholesale. Merges rather than replaces, so a re-fetch after
// the service restarts costs nothing extra; call dbus_om_clear first if a hard reset is
// wanted (dbus_om_apply already does that on NameOwnerChanged).
//
// ok reports whether the CALL succeeded, not whether anything landed: a daemon that is
// running with nothing to manage yet (iwd with no adapter, BlueZ with no dongle) is a
// working daemon and an empty list, not an unavailable one. Whether the tree actually
// moved is `dirty`.
dbus_om_fetch :: proc(om: ^Dbus_Om, c: ^Dbus_Conn) -> bool {
    reply, ok := dbus_call(c, om.service, om.root, DBUS_OM_IFACE, "GetManagedObjects")
    if !ok {
        if reply.type != .Invalid {
            dbus_msg_free(&reply) // an error reply still owns its bytes
        }
        return false
    }
    defer dbus_msg_free(&reply)
    args := dbus_msg_args(&reply) or_return
    if len(args) != 1 {
        return false
    }
    om.refetch = false
    dbus_om_load(om, args[0])
    return true
}

@(private = "file")
om_resolve_owner :: proc(om: ^Dbus_Om, c: ^Dbus_Conn) {
    dbus_om_set_owner(om, "")
    arg := Dbus_Value(Dbus_String(om.service))
    reply, ok := dbus_call(
        c,
        DBUS_BUS_NAME,
        DBUS_BUS_PATH,
        DBUS_BUS_IFACE,
        "GetNameOwner",
        "s",
        {arg},
    )
    if !ok {
        if reply.type != .Invalid {
            dbus_msg_free(&reply) // NameHasNoOwner: the service simply isn't running
        }
        return
    }
    defer dbus_msg_free(&reply)
    if args, aok := dbus_msg_args(&reply); aok && len(args) == 1 {
        if s, sok := dbus_as_string(args[0]); sok {
            dbus_om_set_owner(om, s)
        }
    }
}

// --- applying (pure: decoded message in, tree mutated) ---

// Feeds one decoded message to the tree. Returns true when it was consumed AND changed
// something, so a worker owning several trees can offer each message to each in turn and
// snapshot only when one of them says yes. Everything arriving here came from another
// process, so every field is checked before it is believed: type, sender, path, member,
// and the body signature.
dbus_om_apply :: proc(om: ^Dbus_Om, m: ^Dbus_Message) -> bool {
    if m.type != .Signal {
        return false
    }
    if m.iface == DBUS_BUS_IFACE && m.member == "NameOwnerChanged" {
        return om_name_owner_changed(om, m)
    }
    if !om_from_service(om, m) {
        return false
    }
    switch {
    case m.iface == DBUS_OM_IFACE && m.member == "InterfacesAdded":
        if m.path != om.root {
            return false // some other manager on the same connection
        }
        args := om_args(m, "oa{sa{sv}}") or_return
        path := dbus_as_string(args[0]) or_return
        return dbus_om_put(om, path, args[1])

    case m.iface == DBUS_OM_IFACE && m.member == "InterfacesRemoved":
        if m.path != om.root {
            return false
        }
        args := om_args(m, "oas") or_return
        path := dbus_as_string(args[0]) or_return
        return dbus_om_drop(om, path, args[1])

    case m.iface == DBUS_PROPS_IFACE && m.member == "PropertiesChanged":
        args := om_args(m, "sa{sv}as") or_return
        iface := dbus_as_string(args[0]) or_return
        return dbus_om_changed(om, m.path, iface, args[1], args[2])
    }
    return false
}

// Loads a whole a{oa{sa{sv}}} — the GetManagedObjects reply body, and the one shape every
// backend starts from.
dbus_om_load :: proc(om: ^Dbus_Om, managed: Dbus_Value) -> bool {
    arr := managed.(Dbus_Array) or_return
    changed := false
    for item in arr.items {
        e := item.(Dbus_Entry) or_continue
        if e.key == nil || e.val == nil {
            continue
        }
        path := dbus_as_string(e.key^) or_continue
        if dbus_om_put(om, path, e.val^) {
            changed = true
        }
    }
    return changed
}

// Merges one object's a{sa{sv}} interface dict. An interface named here is REPLACED
// wholesale, not merged: InterfacesAdded (and GetManagedObjects) are authoritative for
// the interfaces they name, and a stale property surviving a re-announce would be a
// silent lie on a row.
dbus_om_put :: proc(om: ^Dbus_Om, path: string, ifaces: Dbus_Value) -> bool {
    if !om_in_scope(om, path) {
        return false
    }
    arr := ifaces.(Dbus_Array) or_return
    changed := false
    for item in arr.items {
        e := item.(Dbus_Entry) or_continue
        if e.key == nil || e.val == nil {
            continue
        }
        name := dbus_as_string(e.key^) or_continue
        if !om_keeps(om, name) {
            continue
        }
        obj := om_object_ensure(om, path)
        ifc := om_iface_ensure(obj, name)
        om_iface_clear(ifc)
        om_props_load(ifc, e.val^)
        changed = true
    }
    if changed {
        om.dirty = true
    }
    return changed
}

// Removes the named interfaces from an object; the object itself goes when its last one
// does, which is how the spec spells "this object is gone".
dbus_om_drop :: proc(om: ^Dbus_Om, path: string, names: Dbus_Value) -> bool {
    obj := om_object_find(om, path) or_return
    arr := names.(Dbus_Array) or_return
    changed := false
    for item in arr.items {
        name := dbus_as_string(item) or_continue
        if !(name in obj.ifaces) {
            continue
        }
        key, ifc := delete_key(&obj.ifaces, name)
        om_iface_free(&ifc)
        delete(key)
        changed = true
    }
    if len(obj.ifaces) == 0 {
        pkey, dead := delete_key(&om.objects, path)
        om_object_free(&dead)
        delete(pkey)
        changed = true
    }
    if changed {
        om.dirty = true
    }
    return changed
}

// Applies a PropertiesChanged body. An unknown object or an interface we never saw
// announced is ignored rather than invented: the tree's contents come from
// GetManagedObjects and InterfacesAdded, and a property update for something outside that
// is either filtered out or not ours.
dbus_om_changed :: proc(
    om: ^Dbus_Om,
    path, iface: string,
    changed, invalidated: Dbus_Value,
) -> bool {
    obj := om_object_find(om, path) or_return
    ifc, ok := &obj.ifaces[iface]
    if !ok {
        return false
    }
    touched := false
    if arr, aok := changed.(Dbus_Array); aok {
        for item in arr.items {
            e := item.(Dbus_Entry) or_continue
            if e.key == nil || e.val == nil {
                continue
            }
            name := dbus_as_string(e.key^) or_continue
            om_prop_set(ifc, name, dbus_unwrap(e.val^))
            touched = true
        }
    }
    // Invalidated properties are dropped, not blanked: the daemon is saying "this changed
    // but I won't say to what", so the only honest state is absent until a Get.
    if arr, aok := invalidated.(Dbus_Array); aok {
        for item in arr.items {
            name := dbus_as_string(item) or_continue
            if !(name in ifc.props) {
                continue
            }
            key, val := delete_key(&ifc.props, name)
            dbus_value_free(val)
            delete(key)
            touched = true
        }
    }
    if touched {
        om.dirty = true
    }
    return touched
}

// The service came, went, or restarted. Either way every path we hold is meaningless, so
// the tree resets and `refetch` tells the worker to take a fresh snapshot.
@(private = "file")
om_name_owner_changed :: proc(om: ^Dbus_Om, m: ^Dbus_Message) -> bool {
    args := om_args(m, "sss") or_return
    name := dbus_as_string(args[0]) or_return
    if name != om.service {
        return false
    }
    new_owner := dbus_as_string(args[2]) or_else ""
    dbus_om_set_owner(om, new_owner)
    dbus_om_clear(om)
    om.refetch = new_owner != ""
    om.dirty = true
    return true
}

// Signals are stamped by the daemon with the sender's UNIQUE name, so the well-known name
// alone won't match once we're live. An unstamped message (a peer connection, or a
// synthesized one in a test) is taken at face value — there is no daemon to have stamped it.
@(private = "file")
om_from_service :: proc(om: ^Dbus_Om, m: ^Dbus_Message) -> bool {
    if m.sender == "" || om.service == "" {
        return true
    }
    return m.sender == om.service || m.sender == om.owner
}

// Body arguments, but only if the signature is exactly what this member is defined to
// carry. Guards every apply path: a mismatched signature means the peer is not speaking
// the interface we think it is, and unmarshalling it as if it were is how a malformed
// signal becomes a crash.
@(private = "file")
om_args :: proc(m: ^Dbus_Message, sig: string) -> (args: []Dbus_Value, ok: bool) {
    if m.signature != sig {
        return nil, false
    }
    args = dbus_msg_args(m) or_return
    return args, len(args) == om_sig_count(sig)
}

// How many complete types `sig` is: walking it with dbus_sig_next IS the count.
@(private = "file")
om_sig_count :: proc(sig: string) -> int {
    n, pos := 0, 0
    for pos < len(sig) {
        step := dbus_sig_next(sig[pos:])
        if step <= 0 {
            return 0
        }
        pos += step
        n += 1
    }
    return n
}

// Is this path ours? Objects live at or under the manager's root.
@(private = "file")
om_in_scope :: proc(om: ^Dbus_Om, path: string) -> bool {
    if len(path) == 0 || path[0] != '/' {
        return false
    }
    if om.root == "" || om.root == "/" {
        return true
    }
    if !strings.has_prefix(path, om.root) {
        return false
    }
    // "/net/connman/iwdX" is not under "/net/connman/iwd".
    return len(path) == len(om.root) || path[len(om.root)] == '/'
}

@(private = "file")
om_keeps :: proc(om: ^Dbus_Om, iface: string) -> bool {
    if om.filter == nil {
        return true
    }
    for f in om.filter {
        if f == iface {
            return true
        }
    }
    return false
}

// --- queries (borrowed: valid until the next apply) ---

dbus_om_object :: proc(om: ^Dbus_Om, path: string) -> (obj: ^Dbus_Om_Object, ok: bool) {
    return om_object_find(om, path)
}

dbus_om_has :: proc(om: ^Dbus_Om, path, iface: string) -> bool {
    obj := om_object_find(om, path) or_return
    return iface in obj.ifaces
}

dbus_om_prop :: proc(om: ^Dbus_Om, path, iface, name: string) -> (v: Dbus_Value, ok: bool) {
    obj := om_object_find(om, path) or_return
    ifc, has := &obj.ifaces[iface]
    if !has {
        return nil, false
    }
    val := ifc.props[name] or_return
    return val, true
}

dbus_om_string :: proc(om: ^Dbus_Om, path, iface, name: string) -> (s: string, ok: bool) {
    v := dbus_om_prop(om, path, iface, name) or_return
    return dbus_as_string(v)
}

dbus_om_bool :: proc(om: ^Dbus_Om, path, iface, name: string) -> (b: bool, ok: bool) {
    v := dbus_om_prop(om, path, iface, name) or_return
    return v.(bool)
}

dbus_om_int :: proc(om: ^Dbus_Om, path, iface, name: string) -> (n: i64, ok: bool) {
    v := dbus_om_prop(om, path, iface, name) or_return
    return dbus_as_int(v)
}

// Every path carrying `iface`, sorted — the row order a pane draws. Sorted because map
// iteration order is arbitrary and a list that reshuffles itself every frame is unusable;
// object paths sort into the daemon's own hierarchy for free ("/net/connman/iwd/0/4/...").
// `iface` empty returns every path.
dbus_om_paths :: proc(
    om: ^Dbus_Om,
    iface: string = "",
    alloc := context.temp_allocator,
) -> []string {
    out := make([dynamic]string, 0, len(om.objects), alloc)
    for path, &obj in om.objects {
        if iface == "" || iface in obj.ifaces {
            append(&out, path)
        }
    }
    slice.sort(out[:])
    return out[:]
}

// --- tree internals ---

@(private = "file")
om_object_find :: proc(om: ^Dbus_Om, path: string) -> (obj: ^Dbus_Om_Object, ok: bool) {
    obj, ok = &om.objects[path]
    return
}

@(private = "file")
om_object_ensure :: proc(om: ^Dbus_Om, path: string) -> ^Dbus_Om_Object {
    if obj, ok := &om.objects[path]; ok {
        return obj
    }
    om.objects[strings.clone(path)] = Dbus_Om_Object{}
    return &om.objects[path]
}

@(private = "file")
om_iface_ensure :: proc(obj: ^Dbus_Om_Object, name: string) -> ^Dbus_Om_Iface {
    if ifc, ok := &obj.ifaces[name]; ok {
        return ifc
    }
    obj.ifaces[strings.clone(name)] = Dbus_Om_Iface{}
    return &obj.ifaces[name]
}

@(private = "file")
om_props_load :: proc(ifc: ^Dbus_Om_Iface, props: Dbus_Value) {
    arr, ok := props.(Dbus_Array)
    if !ok {
        return
    }
    for item in arr.items {
        e := item.(Dbus_Entry) or_continue
        if e.key == nil || e.val == nil {
            continue
        }
        name := dbus_as_string(e.key^) or_continue
        om_prop_set(ifc, name, dbus_unwrap(e.val^))
    }
}

// Stores a deep clone, replacing (and freeing) whatever was there. The key is cloned only
// on first insert — a property that updates every second must not leak a key each time.
@(private = "file")
om_prop_set :: proc(ifc: ^Dbus_Om_Iface, name: string, v: Dbus_Value) {
    if old, ok := &ifc.props[name]; ok {
        dbus_value_free(old^)
        old^ = dbus_value_clone(v)
        return
    }
    ifc.props[strings.clone(name)] = dbus_value_clone(v)
}

@(private = "file")
om_iface_clear :: proc(ifc: ^Dbus_Om_Iface) {
    for name, val in ifc.props {
        dbus_value_free(val)
        delete(name)
    }
    clear(&ifc.props)
}

@(private = "file")
om_iface_free :: proc(ifc: ^Dbus_Om_Iface) {
    om_iface_clear(ifc)
    delete(ifc.props)
    ifc^ = {}
}

@(private = "file")
om_object_free :: proc(obj: ^Dbus_Om_Object) {
    for name, &ifc in obj.ifaces {
        om_iface_free(&ifc)
        delete(name)
    }
    delete(obj.ifaces)
    obj^ = {}
}

// --- deep clone / free ---
//
// The pair that makes keeping a decoded value legal. dbus.odin's values BORROW the
// message buffer (strings alias it, containers live in whatever allocator parsed them),
// so anything outliving the message has to be copied out whole — including the `sig`
// strings inside arrays and variants, which alias the buffer just like the data does.
// Free mirrors clone exactly; never free a value you did not clone.

dbus_value_clone :: proc(v: Dbus_Value, alloc := context.allocator) -> Dbus_Value {
    #partial switch t in v {
    case Dbus_String:
        return Dbus_String(strings.clone(string(t), alloc))
    case Dbus_Path:
        return Dbus_Path(strings.clone(string(t), alloc))
    case Dbus_Signature:
        return Dbus_Signature(strings.clone(string(t), alloc))
    case Dbus_Array:
        items := make([]Dbus_Value, len(t.items), alloc)
        for item, i in t.items {
            items[i] = dbus_value_clone(item, alloc)
        }
        return Dbus_Array{sig = strings.clone(t.sig, alloc), items = items}
    case Dbus_Struct:
        fields := make([]Dbus_Value, len(t.fields), alloc)
        for f, i in t.fields {
            fields[i] = dbus_value_clone(f, alloc)
        }
        return Dbus_Struct{fields = fields}
    case Dbus_Entry:
        e := Dbus_Entry {
            key = new(Dbus_Value, alloc),
            val = new(Dbus_Value, alloc),
        }
        if t.key != nil {
            e.key^ = dbus_value_clone(t.key^, alloc)
        }
        if t.val != nil {
            e.val^ = dbus_value_clone(t.val^, alloc)
        }
        return e
    case Dbus_Variant:
        va := Dbus_Variant {
            sig = strings.clone(t.sig, alloc),
            val = new(Dbus_Value, alloc),
        }
        if t.val != nil {
            va.val^ = dbus_value_clone(t.val^, alloc)
        }
        return va
    }
    return v // scalars and nil carry no allocation
}

dbus_value_free :: proc(v: Dbus_Value, alloc := context.allocator) {
    #partial switch t in v {
    case Dbus_String:
        delete(string(t), alloc)
    case Dbus_Path:
        delete(string(t), alloc)
    case Dbus_Signature:
        delete(string(t), alloc)
    case Dbus_Array:
        for item in t.items {
            dbus_value_free(item, alloc)
        }
        delete(t.items, alloc)
        delete(t.sig, alloc)
    case Dbus_Struct:
        for f in t.fields {
            dbus_value_free(f, alloc)
        }
        delete(t.fields, alloc)
    case Dbus_Entry:
        if t.key != nil {
            dbus_value_free(t.key^, alloc)
            free(t.key, alloc)
        }
        if t.val != nil {
            dbus_value_free(t.val^, alloc)
            free(t.val, alloc)
        }
    case Dbus_Variant:
        if t.val != nil {
            dbus_value_free(t.val^, alloc)
            free(t.val, alloc)
        }
        delete(t.sig, alloc)
    }
}
