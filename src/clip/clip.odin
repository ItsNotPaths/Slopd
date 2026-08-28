package clip

import "core:os"
import "core:strings"

// The system clipboard by way of whatever the platform ships, which is what Helix and Neovim do
// and for the same reason: a terminal program is not a display client, so it asks one.
//
// Resolved ONCE, in order, and then it is whichever it found. Nothing here falls back per-call:
// a clipboard that silently changes which half of the system it is talking to is worse than one
// that does not work.
//
//   wl-copy / wl-paste   Wayland, and the only one that reads back under it
//   xclip, xsel          X11, either
//   pbcopy / pbpaste     macOS
//
// Not found is the normal answer over SSH, where none of these exist and none of them would help
// if they did: the clipboard that matters is on the machine at the other end of the terminal.
// The caller uses OSC 52 there.

Provider :: struct {
    set: []string, // argv; the text goes to its stdin
    get: []string, // argv; the text comes from its stdout
}

@(private)
resolved: bool
@(private)
found: Provider

// Ordered by how well they work rather than by how common they are. wl-clipboard first, because
// under Wayland xclip may exist and be useless (XWayland has its own selection).
@(private)
CANDIDATES := [][2][]string {
    {{"wl-copy"}, {"wl-paste", "--no-newline"}},
    {{"xclip", "-selection", "clipboard"}, {"xclip", "-selection", "clipboard", "-o"}},
    {{"xsel", "--clipboard", "--input"}, {"xsel", "--clipboard", "--output"}},
    {{"pbcopy"}, {"pbpaste"}},
}

// False when the platform has nothing, which is the answer to whether OSC 52 is needed.
available :: proc() -> bool {
    resolve()
    return found.set != nil
}

@(private)
resolve :: proc() {
    if resolved {
        return
    }
    resolved = true
    for pair in CANDIDATES {
        if on_path(pair[0][0]) {
            found = Provider{set = pair[0], get = pair[1]}
            return
        }
    }
}

// PATH, by hand: there is no exec that reports "not found" without also running the thing.
@(private)
on_path :: proc(name: string) -> bool {
    path := os.get_env("PATH", context.temp_allocator)
    for dir in strings.split_iterator(&path, ":") {
        if dir == "" {
            continue
        }
        full := strings.concatenate({dir, "/", name}, context.temp_allocator)
        if info, err := os.stat(full, context.temp_allocator); err == nil && info.type != .Directory {
            return true
        }
    }
    return false
}

// Text to the system clipboard. Silent on failure: a clipboard tool that is installed but broken
// is not something the editor can do anything about mid-keystroke.
set :: proc(text: string) -> bool {
    resolve()
    if found.set == nil {
        return false
    }
    r, w, perr := os.pipe()
    if perr != nil {
        return false
    }
    defer os.close(w)

    p, err := os.process_start({command = found.set, stdin = r})
    os.close(r) // the child owns it now; ours must go or the child never sees EOF
    if err != nil {
        return false
    }
    os.write(w, transmute([]u8)text)
    os.close(w) // EOF: wl-copy reads to the end before it commits
    _, _ = os.process_wait(p)
    return true
}

// "" when there is no provider or it returned nothing. The caller decides what an empty
// clipboard means; here it is only ever "not this way".
get :: proc(allocator := context.temp_allocator) -> string {
    resolve()
    if found.get == nil {
        return ""
    }
    _, sout, _, err := os.process_exec({command = found.get}, allocator)
    if err != nil {
        return ""
    }
    return string(sout)
}
