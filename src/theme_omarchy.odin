package main

import "core:os"
import "core:path/filepath"
import "core:strings"

// Omarchy v4 resolves the active desktop theme to one palette file and rewrites it on every
// `omarchy theme set`. Slopd reads it directly: no template to install, no hook, no subprocess.
// The path is $HOME-relative and not an XDG variable, because that is how Omarchy writes it.
OMARCHY_COLORS :: ".local/state/omarchy/current/theme/colors.toml"

// Reserved: it never resolves to themes/omarchy.theme, so no file can shadow the live palette.
OMARCHY_THEME :: "omarchy"

// "" with no $HOME. Returned existing or not — omarchy_available is the existence test.
omarchy_colors_file :: proc(allocator := context.allocator) -> string {
    // install.odin keeps its own file-private $HOME helper; "" means the same in both.
    home := os.get_env("HOME", context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({home, OMARCHY_COLORS}, allocator) or_else strings.clone("", allocator)
}

// The test is the FILE, not os-release: a distro ID says which system this is, the file says a
// palette is there. Slopd also runs under Omarchy's Hyprland from a plain Arch install.
omarchy_available :: proc() -> bool {
    p := omarchy_colors_file(context.temp_allocator)
    return p != "" && os.exists(p)
}

// Starts from the baked-in default, so a key the palette cannot supply keeps a usable colour.
// ok=false when the file is unreadable or holds no colour, leaving that default standing.
omarchy_theme :: proc(path: string) -> (Theme, bool) {
    if path == "" {
        return default_theme(), false
    }
    src, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    if src == nil {
        return default_theme(), false
    }
    return omarchy_theme_from_src(string(src))
}

// Split from the file read so the suite can pass a palette in. Same contract.
omarchy_theme_from_src :: proc(src: string) -> (Theme, bool) {
    t := default_theme()
    pal := omarchy_palette(src)
    if len(pal) == 0 {
        return t, false
    }
    omarchy_apply(pal, &t)
    return t, true
}

// The flat `key = "#rrggbb"` subset of TOML colors.toml is written in. Headers, comments and
// any value that is not a 6-digit hex colour are dropped. Keys point into `content`.
@(private = "file")
omarchy_palette :: proc(content: string) -> map[string][3]f32 {
    pal := make(map[string][3]f32, 64, context.temp_allocator)
    rest := content
    for line in strings.split_lines_iterator(&rest) {
        s := strings.trim_space(line)
        if len(s) == 0 || s[0] == '#' || s[0] == '[' {
            continue
        }
        eq := strings.index_byte(s, '=')
        if eq <= 0 {
            continue
        }
        key := strings.trim_space(s[:eq])
        val := strings.trim_space(s[eq + 1:])
        // Between the quotes first, so a trailing ` # note` falls outside and the colour's own
        // '#' does not read as a comment.
        if open := strings.index_byte(val, '"'); open >= 0 {
            val = val[open + 1:]
            if end := strings.index_byte(val, '"'); end >= 0 {
                val = val[:end]
            }
        }
        if col, ok := parse_hex_color(val); ok {
            pal[key] = col
        }
    }
    return pal
}

// The first of `keys` the palette defines, else `def`. The chains mirror Omarchy's own cascade:
// a theme predating the semantic palette defines only the ANSI color0..color15 names.
@(private = "file")
pick :: proc(pal: map[string][3]f32, def: [3]f32, keys: ..string) -> [3]f32 {
    for k in keys {
        if c, ok := pal[k]; ok {
            return c
        }
    }
    return def
}

// `amount` of b over a — Omarchy's {{ mix a b 30% }}, for the keys no palette carries.
@(private = "file")
mix :: proc(a, b: [3]f32, amount: f32) -> [3]f32 {
    return a + (b - a) * amount
}

// Every colour is a palette key or a blend of two, so a light theme comes out light with no
// mode branch.
@(private = "file")
omarchy_apply :: proc(pal: map[string][3]f32, t: ^Theme) {
    bg := pick(pal, t.bg, "background", "color0")
    fg := pick(pal, t.fg, "foreground", "color7")

    // dark_foreground FIRST, ahead of Omarchy's own `muted`: that key is a background-weight
    // fill, while ours is body text one step down from fg.
    muted := pick(pal, t.muted, "dark_foreground", "color8", "muted")

    accent := pick(pal, t.accent, "accent", "magenta", "color5")
    red := pick(pal, t.urgent, "red", "color1")
    green := pick(pal, t.code_type, "green", "color2")
    yellow := pick(pal, t.code_string, "yellow", "color3")
    magenta := pick(pal, t.code_keyword, "magenta", "purple", "color5")
    cyan := pick(pal, t.code_return_type, "cyan", "color6")
    orange := pick(pal, yellow, "orange")

    t.bg = bg
    t.fg = fg
    t.muted = muted
    t.accent = accent
    t.urgent = red

    t.border_light = pick(pal, mix(bg, fg, 0.20), "lighter_background")
    t.border_dark = pick(pal, mix(bg, {0, 0, 0}, 0.25), "dark_background")
    t.separator = mix(bg, fg, 0.12)

    // Omarchy's `selection` is a terminal selection background paired with its own foreground.
    // We draw the same fg over it, so the colour is blended into bg: a lift, not a swap.
    t.selection = mix(bg, pick(pal, fg, "selection", "selection_background", "color8"), 0.15)
    t.line_highlight = mix(bg, fg, 0.06)

    t.code_keyword = magenta
    t.code_string = yellow
    t.code_comment = muted
    t.code_number = magenta
    t.code_operator = orange
    t.code_type = green
    t.code_return_type = cyan
    t.code_function = green
    t.code_variable = fg
    t.code_constant = magenta
    t.code_punctuation = muted

    // Must read louder than `urgent`, and many themes set bright_red equal to red. Pulling
    // halfway to pure red raises saturation rather than lightness, so it survives a light
    // theme where a lighter red would wash out.
    t.cl_inject = mix(pick(pal, red, "bright_red", "color9"), {1, 0, 0}, 0.5)

    // No palette carries these, so blends off bg — just above the background, with the active
    // rail taking enough accent to be picked out without competing with the code.
    t.whitespace = mix(bg, fg, 0.10)
    t.indent_guide = mix(bg, fg, 0.10)
    t.indent_guide_active = mix(bg, accent, 0.55)

    // Yellow off bg at two strengths: the current hit takes three times the lift so the pair
    // stays apart, and both stay near the background since the text is drawn over them.
    t.find_match = mix(bg, yellow, 0.20)
    t.find_current = mix(bg, yellow, 0.60)
}
