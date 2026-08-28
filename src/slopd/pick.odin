package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Slopd as somebody else's file dialog.
//
// A caller starts us with `--pick=<mode> --pick-out=<file>`, we browse as usual, and `:return`
// writes the chosen paths to that file and quits. One absolute path per line. No file, or an
// empty one, means the person cancelled — so Esc, `:q`, a closed window and a kill all cancel
// without a line of code here.
//
// Nothing in this file knows who asked. A D-Bus portal, a kipp consumer and a shell script
// drive it identically, which is the whole point of the answer being a path in a file.

Pick_Mode :: enum {
    None,
    Open, // one existing file, or several with `multiple`
    Save, // one path, which need not exist yet
    Dir,  // one directory
}

Pick :: struct {
    mode:     Pick_Mode,
    out:      string, // owned; where the answer is written
    title:    string, // owned; who is asking, for the strip
    multiple: bool,
}

pick_live :: proc(a: ^App) -> bool {
    return a.pick.mode != .None
}

pick_destroy :: proc(p: ^Pick) {
    delete(p.out)
    delete(p.title)
    p^ = {}
}

pick_mode_parse :: proc(s: string) -> Pick_Mode {
    switch s {
    case "open":
        return .Open
    case "save":
        return .Save
    case "dir", "directory":
        return .Dir
    }
    return .None
}

// Full on the file pane, like --util, plus the staged line a save already knows the answer to.
pick_begin :: proc(a: ^App, args: Launch_Args) {
    a.pick = {
        mode     = args.pick,
        out      = strings.clone(args.pick_out),
        title    = strings.clone(args.pick_title),
        multiple = args.pick_multi,
    }
    a.view = .Full
    a.focus = .Aux
    set_aux(a, .FileTree)

    // A save was told the name to suggest, so the line is ready before a key is pressed: edit
    // the tail and press Enter. This is the whole gesture in the common case.
    if a.pick.mode == .Save && args.pick_name != "" {
        full := filepath.join({a.tree.dir, args.pick_name}, context.temp_allocator) or_else args.pick_name
        pick_stage(a, {full})
    }
}

// What the strip says instead of the aux pane's name while a dialog is up.
pick_label :: proc(a: ^App) -> string {
    verb: string
    switch a.pick.mode {
    case .None:
        return ""
    case .Open:
        verb = a.pick.multiple ? "OPEN FILES" : "OPEN FILE"
    case .Save:
        verb = "SAVE AS"
    case .Dir:
        verb = "CHOOSE FOLDER"
    }
    if a.pick.title == "" {
        return fmt.tprintf("%s   ^Enter returns the row", verb)
    }
    return fmt.tprintf("%s   %s   ^Enter returns the row", verb, a.pick.title)
}

// Stage `:return <paths>` for review. The alert colour and the Enter that runs it are the
// command line's own, so editing `image.png` into `image-2.png` before committing is free.
pick_stage :: proc(a: ^App, paths: []string) {
    if len(paths) == 0 {
        return
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, ":return")
    for p in paths {
        strings.write_byte(&b, ' ')
        strings.write_string(&b, cl_quote_arg(p, context.temp_allocator))
    }
    cl_inject(a, strings.to_string(b))
}

// Shift+Enter's target, and the default `:return` with no arguments takes the same set: the
// marks if there are any, else the row under the cursor. A folder mode ignores both and answers
// with the folder being browsed, since that is what was asked for.
pick_targets :: proc(a: ^App, alloc := context.temp_allocator) -> []string {
    if a.pick.mode == .Dir {
        one := make([]string, 1, alloc)
        one[0] = a.tree.dir
        return one
    }
    return filetree_targets(&a.tree, len(a.tree.marks) > 0, alloc)
}

// `:return [path...]`. With no path it takes pick_targets. `:return!` overwrites an existing
// file in save mode, the same bang `:w!` carries.
cl_return :: proc(a: ^App, force: bool, args: string) {
    if !pick_live(a) {
        cl_echo(a, ":return: nothing asked for a path")
        return
    }
    paths := args == "" ? pick_targets(a) : cl_arg_list(a, args, context.temp_allocator)
    if msg := pick_refusal(a, paths, force); msg != "" {
        cl_echo(a, msg)
        return
    }
    if !pick_write(a.pick.out, paths) {
        cl_echo(a, fmt.tprintf(":return: could not write %s", a.pick.out))
        return
    }
    a.quit = true
}

// Every way the answer can be wrong, in one pure function so the rules are readable and
// testable together. "" means it is fine.
pick_refusal :: proc(a: ^App, paths: []string, force: bool) -> string {
    if len(paths) == 0 {
        return ":return: no path — point at a row, or type one"
    }
    switch a.pick.mode {
    case .None:
        return ":return: nothing asked for a path"
    case .Dir:
        if len(paths) > 1 {
            return ":return: one folder was asked for"
        }
        if !os.is_dir(paths[0]) {
            return fmt.tprintf(":return: %s is not a folder", paths[0])
        }
    case .Open:
        if len(paths) > 1 && !a.pick.multiple {
            return ":return: one file was asked for"
        }
        for p in paths {
            if !os.exists(p) {
                return fmt.tprintf(":return: no such file: %s", p)
            }
            if os.is_dir(p) {
                return fmt.tprintf(":return: %s is a folder, not a file", p)
            }
        }
    case .Save:
        if len(paths) > 1 {
            return ":return: one path was asked for"
        }
        p := paths[0]
        if os.is_dir(p) {
            return fmt.tprintf(":return: %s is a folder, not a file", p)
        }
        if dir := filepath.dir(p); !os.is_dir(dir) {
            return fmt.tprintf(":return: no such folder: %s", dir)
        }
        if os.exists(p) && !force {
            return fmt.tprintf(":return: %s exists — `:return!` overwrites it", p)
        }
    }
    return ""
}

// One absolute path per line. Relative arguments are resolved against the browsed folder before
// they land, so the caller never has to know where we were.
pick_write :: proc(out: string, paths: []string) -> bool {
    if out == "" {
        return false
    }
    b := strings.builder_make(context.temp_allocator)
    for p in paths {
        strings.write_string(&b, p)
        strings.write_byte(&b, '\n')
    }
    return os.write_entire_file(out, transmute([]byte)strings.to_string(b)) == nil
}

// A command line's arguments as a list, honouring the same quoting a staged line writes. Each
// is resolved to an absolute path.
cl_arg_list :: proc(a: ^App, args: string, alloc := context.temp_allocator) -> []string {
    context.allocator = alloc // cl_resolve_path allocates its answer
    out := make([dynamic]string, 0, 4)
    rest := strings.trim_space(args)
    for rest != "" {
        raw, value := first_arg(rest)
        if raw == "" {
            break
        }
        append(&out, cl_resolve_path(a, value))
        rest = strings.trim_space(rest[len(raw):])
    }
    return out[:]
}
