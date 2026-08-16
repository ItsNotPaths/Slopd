package main

import "core:os"
import "core:path/filepath"
import "core:strings"

// Omarchy desktop theming.
//
// Omarchy v4 resolves the active desktop theme down to ONE palette file, and rewrites it in
// place on every `omarchy theme set`:
//
//     ~/.local/state/omarchy/current/theme/colors.toml
//
// Slopd reads that file directly. There is no template to install into someone else's config
// folder, no theme-set hook, and no subprocess: the next load takes whatever the desktop is
// wearing. The path is $HOME-relative and NOT an XDG variable, because that is how Omarchy
// writes it (see omarchy-theme-set) — an XDG lookup would find nothing.
OMARCHY_COLORS :: ".local/state/omarchy/current/theme/colors.toml"

// The theme token that means "follow the desktop". RESERVED: it never resolves to
// themes/omarchy.theme, so a file of that name cannot shadow the live palette.
OMARCHY_THEME :: "omarchy"

// The active palette file, or "" when the environment has no $HOME. Returned whether or not
// it exists — omarchy_available is the existence test. Caller owns the result.
omarchy_colors_file :: proc(allocator := context.allocator) -> string {
    // install.odin keeps its own file-private $HOME helper. Read it here rather than widen
    // that one: no $HOME means "" both places, and "" is a path no caller reads or writes.
    home := os.get_env("HOME", context.temp_allocator)
    if home == "" {
        return strings.clone("", allocator)
    }
    return filepath.join({home, OMARCHY_COLORS}, allocator) or_else strings.clone("", allocator)
}

// Whether a desktop theme is applied and readable. The test is the FILE, not os-release: a
// distro ID says which system this is, the file says a palette is actually there. Slopd also
// runs under Omarchy's Hyprland from a plain Arch install, where os-release says "arch".
omarchy_available :: proc() -> bool {
    p := omarchy_colors_file(context.temp_allocator)
    return p != "" && os.exists(p)
}

// Builds a Theme from an Omarchy colors.toml. It starts from the baked-in default, so a key
// the palette cannot supply keeps a usable colour instead of going black. ok is false when
// the file is unreadable or holds no colour at all, which leaves that default standing.
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

// The mapping itself, split from the file read so the suite can put a palette in without
// touching disk. Same contract as omarchy_theme.
omarchy_theme_from_src :: proc(src: string) -> (Theme, bool) {
    t := default_theme()
    pal := omarchy_palette(src)
    if len(pal) == 0 {
        return t, false
    }
    omarchy_apply(pal, &t)
    return t, true
}

// Reads the flat `key = "#rrggbb"` subset of TOML that colors.toml is written in. Section
// headers, comments and any value that is not a 6-digit hex colour are dropped: that covers
// `mode = "dark"` and the rgba()/8-digit forms a third-party theme can carry. The keys point
// into `content`, so both live exactly as long as it does.
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
        // Take what is between the quotes first. That way a trailing ` # note` on the line
        // falls outside them, and the '#' of the colour itself does not read as a comment.
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

// The first of `keys` the palette actually defines, else `def`. The chains at the call site
// mirror Omarchy's own cascade (omarchy-theme-color): a theme written before the semantic
// palette defines only the ANSI color0..color15 names, and Omarchy derives the rest.
@(private = "file")
pick :: proc(pal: map[string][3]f32, def: [3]f32, keys: ..string) -> [3]f32 {
    for k in keys {
        if c, ok := pal[k]; ok {
            return c
        }
    }
    return def
}

// Linear blend: `amount` of b over a. The same operation Omarchy's template engine offers as
// {{ mix a b 30% }}, for the Slopd keys that no palette carries a source colour for.
@(private = "file")
mix :: proc(a, b: [3]f32, amount: f32) -> [3]f32 {
    return a + (b - a) * amount
}

// Maps a parsed palette onto the Theme keys. Every colour is either a palette key or a blend
// of two of them, so a light theme comes out light without a mode branch.
@(private = "file")
omarchy_apply :: proc(pal: map[string][3]f32, t: ^Theme) {
    bg := pick(pal, t.bg, "background", "color0")
    fg := pick(pal, t.fg, "foreground", "color7")

    // `muted` reads dark_foreground FIRST, ahead of Omarchy's own `muted` key. That key is a
    // background-weight fill (Aether sets it to #46413e), while Slopd's muted is body text
    // one step down from fg. dark_foreground, or the ANSI color8 behind it, is that tone.
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

    // Chrome. A real palette key when there is one, else a blend off bg.
    t.border_light = pick(pal, mix(bg, fg, 0.20), "lighter_background")
    t.border_dark = pick(pal, mix(bg, {0, 0, 0}, 0.25), "dark_background")
    t.separator = mix(bg, fg, 0.12)

    // Omarchy's `selection` is a terminal selection BACKGROUND, and a theme pairs it with a
    // selection_foreground for the text on top. Slopd draws the SAME fg over it, so the
    // palette colour is blended into bg rather than used flat: a lift, not a swap.
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

    // A staged command line must read LOUDER than `urgent`. Many themes set bright_red equal
    // to red (Aether does), which would flatten the two into one colour. Pulling halfway to
    // pure red raises the saturation instead of the lightness, so this stays an alarm colour
    // on a light theme too, where a lighter red would wash out against the background.
    t.cl_inject = mix(pick(pal, red, "bright_red", "color9"), {1, 0, 0}, 0.5)

    // Editor guides. No palette carries these, so they are blends off bg: the whitespace dots
    // and the indent rail sit just above the background, and the rail of the cursor's scope
    // takes enough accent to be picked out without competing with the code.
    t.whitespace = mix(bg, fg, 0.10)
    t.indent_guide = mix(bg, fg, 0.10)
    t.indent_guide_active = mix(bg, accent, 0.55)

    // The search marks, on the same principle: yellow off bg, at two strengths. The pair has to
    // stay apart on a page holding both, so the current hit takes three times the lift — and
    // both stay near the background, since the text is drawn over them and not recoloured.
    t.find_match = mix(bg, yellow, 0.20)
    t.find_current = mix(bg, yellow, 0.60)
}
