package main

import "core:path/filepath"
import "core:strings"
import "../txt"
import "../edit"

// Ctrl+/ over the lines the cursors touch. The token comes from the extension, the way a grammar
// does; a file we have no token for is left alone rather than guessed at.
//
// Uncomment only when every line holding text is already commented — the rule every editor uses,
// so a half-commented block goes fully commented on the first press and bare on the second.

// Line openers only. A block comment would not survive being toggled twice, and reversibility is
// the whole point. `exts` is comma-wrapped at both ends so a lookup is one substring test, and a
// token may take more than one row where the list would run long.
@(rodata)
COMMENT_TOKENS := [?]struct {
    token: string,
    exts:  string,
} {
    {"//", ",odin,c,h,cpp,cc,cxx,hpp,hh,js,jsx,mjs,cjs,ts,tsx,jai,"},
    {"//", ",go,rs,java,kt,kts,swift,scala,cs,php,zig,v,dart,glsl,vert,frag,"},
    {"#", ",py,rb,sh,bash,zsh,fish,pl,pm,r,nix,ps1,tf,cmake,"},
    {"#", ",yaml,yml,toml,ini,cfg,conf,mk,makefile,dockerfile,gitignore,"},
    {"--", ",lua,sql,hs,elm,adb,ads,vhd,vhdl,"},
    {";", ",lisp,clj,cljs,el,scm,ss,rkt,asm,"},
    {"%", ",tex,latex,erl,"},
    {`"`, ",vim,vimrc,"},
}

// The extension, or the whole name when there is none — `Makefile` and `Dockerfile` are named,
// not suffixed. "" and false when nothing claims it.
comment_token :: proc(path: string) -> (string, bool) {
    name := filepath.base(path)
    ext := strings.trim_prefix(filepath.ext(name), ".")
    if ext == "" {
        ext = name
    }
    lower := strings.to_lower(ext, context.temp_allocator)
    key := strings.concatenate({",", lower, ","}, context.temp_allocator)
    for row in COMMENT_TOKENS {
        if strings.contains(row.exts, key) {
            return row.token, true
        }
    }
    return "", false
}

// The toggle itself. False when the language has no token, or the lines hold no text.
buffer_comment_toggle :: proc(b: ^edit.Buffer) -> bool {
    token, known := comment_token(b.path)
    if !known {
        return false
    }
    d := &b.doc
    lines := txt.doc_cursor_lines(d)

    // One pass for both questions: is every line with text already commented, and how far in does
    // the shallowest one start? The token goes at that column, so a block keeps its shape.
    commented, found := true, false
    col := max(int)
    for line in lines {
        src := txt.doc_line(d, line)
        lead := txt.line_indent_cols(src)
        if lead == len(src) {
            continue // blank
        }
        found = true
        col = min(col, lead)
        if !strings.has_prefix(string(src[lead:]), token) {
            commented = false
        }
    }
    if !found {
        return false
    }

    edits := make([dynamic]txt.Edit, 0, len(lines), context.temp_allocator)
    deltas := make([]int, len(lines), context.temp_allocator)
    opener := strings.concatenate({token, " "}, context.temp_allocator)
    for line, i in lines {
        src := txt.doc_line(d, line)
        lead := txt.line_indent_cols(src)
        if lead == len(src) {
            continue
        }
        anchor, _ := txt.line_span(d, line)
        start := txt.doc_off(d, anchor)
        if commented {
            // The token, and the one space a comment pass put after it.
            n := len(token)
            if lead + n < len(src) && src[lead + n] == ' ' {
                n += 1
            }
            append(&edits, txt.Edit{start + lead, start + lead + n, "", 0})
            deltas[i] = -n
        } else {
            append(&edits, txt.Edit{start + col, start + col, opener, 0})
            deltas[i] = len(opener)
        }
    }
    changed := txt.doc_line_commit(d, edits[:], lines, deltas)
    b.dirty |= changed
    return changed
}
