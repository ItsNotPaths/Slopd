package main

import "core:math"
import clay "../bindings/clay"

// The renderer bridge. Clay solves a declared tree into a flat list of render commands with
// resolved bounding boxes; this file turns that list into the calls text.odin already exposes —
// `fill` for rectangles and borders, `text_draw` for glyphs, `image_push` for textures,
// `flush_pane` for the scissor groups. Nothing here decides layout, and it is the ONLY place
// that knows Clay's command shape.
//
// Two properties of the renderer leak through, and both are load-bearing:
//
//   1. Within one scissor group, quads always paint UNDER glyphs — flush_pane composites
//      under-quads -> images -> glyphs -> over-quads, so a Rectangle declared after a Text
//      still lands behind it. An element meant to OCCLUDE text needs its own scissor group,
//      which is what Clay's clip elements emit.
//   2. Alpha is a visibility bit, not a blend factor. The quad shader writes vec4(v_color, 1.0),
//      so a colour either paints opaque or not at all; clay_color reports that as `visible`.

// How deep clip elements may nest before the bridge stops tracking. Clay clip groups map to GL
// scissors, which do not stack in hardware, so we intersect them ourselves. Beyond the cap a
// group inherits its parent's clip (under-clips, never corrupts order); the counter keeps going.
CLAY_CLIP_DEPTH :: 8

// Clay colours are 0..255 RGBA; the palette is 0..1 RGB. `visible` is false for a fully
// transparent colour, which is Clay's default for an unset backgroundColor — painting
// those would turn every unstyled container into a black box.
clay_color :: proc(c: clay.Color) -> (col: [3]f32, visible: bool) {
    return {c.r / 255, c.g / 255, c.b / 255}, c.a > 0
}

// The other direction: a Theme slot as a Clay colour, opaque. The palette stays the flat
// typed struct it is — no cascade, no colour names crossing into Clay.
clay_rgb :: proc(c: [3]f32) -> clay.Color {
    return {c.r * 255, c.g * 255, c.b * 255, 255}
}

// A text config for chrome. `line_h` is the box height Clay lays the string out in — pass the
// font's line height and let the row's childAlignment centre it, rather than stretching the box
// to the row. Chrome never wraps: rows are single-line and the pane code elides them.
clay_text_config :: proc(color: [3]f32, line_h: i32) -> clay.TextElementConfig {
    return {textColor = clay_rgb(color), lineHeight = u16(max(0, line_h)), wrapMode = .None}
}

// Clay solves in floats, the renderer draws on whole pixels. Round the EDGES, not the
// origin and size independently: two rects sharing a boundary at x=100.5 must round to
// the same pixel from both sides, or the seam shows as a gap or an overlap.
clay_rect :: proc(b: clay.BoundingBox) -> Rect {
    x0 := i32(math.round(b.x))
    y0 := i32(math.round(b.y))
    x1 := i32(math.round(b.x + b.width))
    y1 := i32(math.round(b.y + b.height))
    return Rect{x0, y0, x1 - x0, y1 - y0}
}

// Rect intersection, clamped to non-negative. A nested clip group must not paint outside
// its parent, and GL's scissor is a single rect, so nesting is intersection.
clay_isect :: proc(a, b: Rect) -> Rect {
    x0, y0 := max(a.x, b.x), max(a.y, b.y)
    x1 := min(a.x + a.w, b.x + b.w)
    y1 := min(a.y + a.h, b.y + b.h)
    return Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

// Text measurement, monospace: width is the RUNE count times the cell advance, not the byte
// count — an accent or a box-drawing character would otherwise measure wide by the bytes UTF-8
// spends on it. `contextless` because Clay calls the shim on its own C stack, allocating nothing.
clay_measure_dims :: proc "contextless" (f: ^Font, s: string, line_h: u16) -> (w, h: f32) {
    if f == nil {
        return 0, 0
    }
    n := 0
    for _ in s {
        n += 1
    }
    h = line_h > 0 ? f32(line_h) : f.line_height
    return f32(n) * f.cell_w, h
}

// Clay's measure hook. `userData` is the live ^Font, so a re-baked atlas (font zoom, DPI
// change) is picked up without re-registering — but Clay CACHES measurements, hence
// clay_font_changed below.
@(private = "file")
clay_measure :: proc "c" (
    text: clay.StringSlice,
    config: ^clay.TextElementConfig,
    userData: rawptr,
) -> clay.Dimensions {
    line_h: u16 = config != nil ? config.lineHeight : 0
    w, h := clay_measure_dims((^Font)(userData), string(text.chars[:text.length]), line_h)
    return {width = w, height = h}
}

// Register the measure hook against a font that outlives the program (Text.font, owned by
// main). Called once, after text_init.
clay_use_font :: proc(f: ^Font) {
    clay.SetMeasureTextFunction(clay_measure, f)
}

// The atlas was re-baked at a new size: every cached string width is now wrong by the
// ratio of the cell advances. Clay has no way to notice, so tell it.
clay_font_changed :: proc() {
    clay.ResetMeasureTextCache()
}

// Track the framebuffer, the same way render() re-points the GL viewport on resize.
clay_resize :: proc(w, h: i32) {
    clay.SetLayoutDimensions({f32(w), f32(h)})
}

// A surface Clay lays out but does not paint (editor body, terminal grid, media); the struct is
// `custom.customData` and must outlive EndLayout. The bridge flushes first and hands over both
// `r` (where the surface starts) and `clip` (what may reach the screen); `flush_pane` ends it.
ClayCustom :: struct {
    paint: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr),
    user:  rawptr,
}

// Walk one frame's command list and paint it. `root` is the clip in force outside any
// clip element — the pane rect for a pane-scoped declaration, the whole window for a
// full-frame one.
clay_paint :: proc(
    t: ^Text,
    a: ^App,
    cmds: ^clay.ClayArray(clay.RenderCommand),
    root: Rect,
    win_w, win_h: i32,
) {
    stack: [CLAY_CLIP_DEPTH]Rect
    depth := 0 // counts past CLAY_CLIP_DEPTH on purpose; see the constant's comment
    clip := root

    for i in 0 ..< cmds.length {
        cmd := clay.RenderCommandArray_Get(cmds, i)
        r := clay_rect(cmd.boundingBox)

        switch cmd.commandType {
        case .Rectangle:
            if col, ok := clay_color(cmd.renderData.rectangle.backgroundColor); ok {
                fill(t, r, col)
            }

        case .Border:
            // Clay draws borders INSIDE the element box, one width per edge, so this is four
            // bars. betweenChildren never reaches here — Clay emits those as plain Rectangles
            // (clay.h:2852). Zero-width edges are skipped: a single-edge border is normal.
            b := cmd.renderData.border
            if col, ok := clay_color(b.color); ok {
                if b.width.top > 0 {
                    fill(t, Rect{r.x, r.y, r.w, i32(b.width.top)}, col)
                }
                if b.width.bottom > 0 {
                    fill(t, Rect{r.x, r.y + r.h - i32(b.width.bottom), r.w, i32(b.width.bottom)}, col)
                }
                if b.width.left > 0 {
                    fill(t, Rect{r.x, r.y, i32(b.width.left), r.h}, col)
                }
                if b.width.right > 0 {
                    fill(t, Rect{r.x + r.w - i32(b.width.right), r.y, i32(b.width.right), r.h}, col)
                }
            }

        case .Text:
            d := cmd.renderData.text
            col, ok := clay_color(d.textColor)
            if ok && d.stringContents.length > 0 {
                // The box top: text_draw adds the baseline offset itself. The slice points
                // into Clay's arena and is valid until the next BeginLayout — we draw now.
                s := string(d.stringContents.chars[:d.stringContents.length])
                text_draw(t, s, f32(r.x), f32(r.y), col)
            }

        case .Image:
            // The declaring pane stuffs its GL texture name into the imageData pointer;
            // there is nothing to point AT, the name is the whole payload.
            image_push(t, u32(uintptr(cmd.renderData.image.imageData)), r)

        case .Custom:
            cu := (^ClayCustom)(cmd.renderData.custom.customData)
            if cu != nil && cu.paint != nil {
                flush_pane(t, clip, win_w, win_h) // hand the painter empty batches
                cu.paint(t, r, clay_isect(r, clip), win_w, win_h, a, cu.user)
            }

        case .ScissorStart:
            flush_pane(t, clip, win_w, win_h) // everything queued belongs to the OUTER clip
            if depth < CLAY_CLIP_DEPTH {
                stack[depth] = clip
                clip = clay_isect(clip, r)
            }
            depth += 1

        case .ScissorEnd:
            flush_pane(t, clip, win_w, win_h)
            if depth > 0 {
                depth -= 1
                if depth < CLAY_CLIP_DEPTH {
                    clip = stack[depth]
                }
            }

        case .None:
        // Clay's zero value; never emitted for a real element.

        case .OverlayColorStart, .OverlayColorEnd:
        // Clay's dim-behind-a-modal tint. Slopd's overlays draw their own backdrop from
        // the palette, and the quad shader cannot blend a translucent wash anyway (see the
        // header). Ignored, not forgotten — wiring it up means renderer alpha first.
        }
    }

    flush_pane(t, clip, win_w, win_h)
}
