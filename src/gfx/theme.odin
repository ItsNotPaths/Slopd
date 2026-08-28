package gfx

import "core:os"
import "core:strconv"
import "core:strings"

// Theme — a Prawk-compatible colour palette. Theme files use Prawk's
// `key: #rrggbb` format (so they're interchangeable with Prawk); the loader parses the
// same keys plus a few extensions for tree-sitter, and ignores unknown keys.
// Colours are stored as [3]f32 (0..1) for direct use by the renderer.
Theme :: struct {
    bg, fg, accent, muted, urgent:                                [3]f32,
    border_light, border_dark, separator:                         [3]f32,
    selection, line_highlight:                                     [3]f32,
    code_keyword, code_string, code_comment, code_number:         [3]f32,
    code_operator, code_type, code_return_type, cl_inject:        [3]f32,
    // Syntax extensions (tree-sitter), Gruvbox Material source:
    code_function, code_variable, code_constant, code_punctuation: [3]f32,
    // Editor whitespace + indent guides (the dim leading-space dots / tab marks,
    // the per-level indent guide rail, and the brighter rail of the cursor's scope).
    whitespace, indent_guide, indent_guide_active:                [3]f32,
    // The live `:f` search marks: a bar behind every hit, and the brighter one behind the hit
    // the caret is on. Both sit under the glyphs, so they have to stay dark enough to read on.
    find_match, find_current:                                     [3]f32,
}

// Embedded so the baked-in fallback always matches the shipped default.theme.
DEFAULT_THEME_SRC := string(#load("../../themes/default.theme"))

default_theme :: proc() -> Theme {
    t: Theme
    parse_theme(DEFAULT_THEME_SRC, &t)
    return t
}

// Loads a theme file over the baked-in default (missing keys keep their default),
// falling back entirely to the default if the path is empty or unreadable.
load_theme :: proc(path: string) -> Theme {
    t := default_theme()
    if path != "" {
        if src, _ := os.read_entire_file_from_path(path, context.temp_allocator); src != nil {
            parse_theme(string(src), &t)
        }
    }
    return t
}

parse_theme :: proc(content: string, t: ^Theme) {
    rest := content
    for line in strings.split_lines_iterator(&rest) {
        s := strings.trim_space(line)
        if len(s) == 0 || s[0] == '#' {
            continue
        }
        colon := strings.index_byte(s, ':')
        if colon <= 0 {
            continue
        }
        key := strings.trim_space(s[:colon])
        col, ok := parse_hex_color(strings.trim_space(s[colon + 1:]))
        if !ok {
            continue
        }
        switch key {
        case "bg":               t.bg = col
        case "fg":               t.fg = col
        case "accent":           t.accent = col
        case "muted":            t.muted = col
        case "urgent":           t.urgent = col
        case "border_light":     t.border_light = col
        case "border_dark":      t.border_dark = col
        case "separator":        t.separator = col
        case "selection":        t.selection = col
        case "line_highlight":   t.line_highlight = col
        case "code_keyword":     t.code_keyword = col
        case "code_string":      t.code_string = col
        case "code_comment":     t.code_comment = col
        case "code_number":      t.code_number = col
        case "code_operator":    t.code_operator = col
        case "code_type":        t.code_type = col
        case "code_return_type": t.code_return_type = col
        case "cl_inject":        t.cl_inject = col
        case "code_function":    t.code_function = col
        case "code_variable":    t.code_variable = col
        case "code_constant":    t.code_constant = col
        case "code_punctuation": t.code_punctuation = col
        case "whitespace":           t.whitespace = col
        case "indent_guide":         t.indent_guide = col
        case "indent_guide_active":  t.indent_guide_active = col
        case "find_match":           t.find_match = col
        case "find_current":         t.find_current = col
        }
    }
}

parse_hex_color :: proc(s: string) -> (col: [3]f32, ok: bool) {
    hex := strings.trim(s, "#")
    if len(hex) != 6 {
        return {}, false
    }
    v, pok := strconv.parse_int(hex, 16)
    if !pok {
        return {}, false
    }
    return {f32((v >> 16) & 0xff) / 255, f32((v >> 8) & 0xff) / 255, f32(v & 0xff) / 255}, true
}
