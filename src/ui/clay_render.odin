package ui

import "core:math"
import clay "../../bindings/clay"
import "../gfx"

// The renderer bridge: Clay's flat command list turned into the calls src/gfx exposes —
// `fill`, `text_draw`, `image_push`, `flush_pane`. Nothing here decides layout, and it is the
// only place that knows Clay's command shape. Two renderer properties leak through:
//
//   1. Within one scissor group quads paint UNDER glyphs, so a Rectangle declared after a Text
//      still lands behind it. An element meant to occlude text needs its own scissor group.
//   2. Alpha is a visibility bit, not a blend factor: the quad shader writes vec4(v_color, 1.0),
//      so a colour either paints opaque or not at all.

// GL scissors do not stack, so nested clips are intersected here. Beyond the cap a group
// inherits its parent's clip — it under-clips, never corrupts order.
CLAY_CLIP_DEPTH :: 8

// `visible` is false for a fully transparent colour, Clay's default for an unset
// backgroundColor — painting those would make every unstyled container a black box.
clay_color :: proc(c: clay.Color) -> (col: [3]f32, visible: bool) {
    return {c.r / 255, c.g / 255, c.b / 255}, c.a > 0
}

// The other direction, opaque.
clay_rgb :: proc(c: [3]f32) -> clay.Color {
    return {c.r * 255, c.g * 255, c.b * 255, 255}
}

// `line_h` is the box height Clay lays the string out in: pass the font's line height and let
// the row's childAlignment centre it. Chrome never wraps — the pane code elides.
clay_text_config :: proc(color: [3]f32, line_h: i32) -> clay.TextElementConfig {
    return {textColor = clay_rgb(color), lineHeight = u16(max(0, line_h)), wrapMode = .None}
}

// Round the EDGES, not the origin and size independently: two rects sharing a boundary at
// x=100.5 must round to the same pixel from both sides, or the seam shows.
clay_rect :: proc(b: clay.BoundingBox) -> gfx.Rect {
    x0 := i32(math.round(b.x))
    y0 := i32(math.round(b.y))
    x1 := i32(math.round(b.x + b.width))
    y1 := i32(math.round(b.y + b.height))
    return gfx.Rect{x0, y0, x1 - x0, y1 - y0}
}

// GL's scissor is a single rect, so nesting is intersection.
clay_isect :: proc(a, b: gfx.Rect) -> gfx.Rect {
    x0, y0 := max(a.x, b.x), max(a.y, b.y)
    x1 := min(a.x + a.w, b.x + b.w)
    y1 := min(a.y + a.h, b.y + b.h)
    return gfx.Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

// Monospace: the RUNE count times the cell advance, not the byte count, or a box-drawing
// character measures wide. `contextless` because Clay calls the shim on its own C stack.
clay_measure_dims :: proc "contextless" (face: ^gfx.Face, s: string, line_h: u16) -> (w, h: f32) {
    if face == nil {
        return 0, 0
    }
    n := 0
    for _ in s {
        n += 1
    }
    h = line_h > 0 ? f32(line_h) : face.line_height
    return f32(n) * face.cell_w, h
}

// `userData` is the live ^Face, so a re-baked atlas is picked up without re-registering.
// Clay caches measurements, hence clay_font_changed.
@(private = "file")
clay_measure :: proc "c" (
    text: clay.StringSlice,
    config: ^clay.TextElementConfig,
    userData: rawptr,
) -> clay.Dimensions {
    line_h: u16 = config != nil ? config.lineHeight : 0
    w, h := clay_measure_dims((^gfx.Face)(userData), string(text.chars[:text.length]), line_h)
    return {width = w, height = h}
}

// Against a face that outlives the program. Once, after the backend is up.
clay_use_face :: proc(face: ^gfx.Face) {
    clay.SetMeasureTextFunction(clay_measure, face)
}

// The atlas was re-baked, so every cached width is wrong. Clay cannot notice on its own.
clay_font_changed :: proc() {
    clay.ResetMeasureTextCache()
}

// As render() re-points the GL viewport on resize.
clay_resize :: proc(w, h: i32) {
    clay.SetLayoutDimensions({f32(w), f32(h)})
}

// A surface Clay lays out but does not paint. Passed as `custom.customData`, so it must outlive
// EndLayout. The bridge flushes first and hands over `r` (where the surface starts) and `clip`
// (what may reach the screen); the painter ends with its own flush_pane.
ClayCustom :: struct {
    // `host` is whatever clay_paint was handed — the front-end's own state, opaque here. A
    // painter casts it back to what it knows it is, the same trade `user` already makes. It is
    // what keeps the bridge from naming any one application.
    paint: proc(t: ^gfx.Draw, r, clip: gfx.Rect, win_w, win_h: i32, host: rawptr, user: rawptr),
    user:  rawptr,
}

// `root` is the clip outside any clip element: a pane rect, or the whole window.
clay_paint :: proc(
    t: ^gfx.Draw,
    host: rawptr,
    cmds: ^clay.ClayArray(clay.RenderCommand),
    root: gfx.Rect,
    win_w, win_h: i32,
) {
    stack: [CLAY_CLIP_DEPTH]gfx.Rect
    depth := 0 // counts past CLAY_CLIP_DEPTH on purpose
    clip := root

    for i in 0 ..< cmds.length {
        cmd := clay.RenderCommandArray_Get(cmds, i)
        r := clay_rect(cmd.boundingBox)

        switch cmd.commandType {
        case .Rectangle:
            if col, ok := clay_color(cmd.renderData.rectangle.backgroundColor); ok {
                gfx.fill(t, r, col)
            }

        case .Border:
            // Borders draw INSIDE the box, one width per edge, so four bars. betweenChildren
            // never reaches here — Clay emits those as plain Rectangles.
            b := cmd.renderData.border
            if col, ok := clay_color(b.color); ok {
                if b.width.top > 0 {
                    gfx.fill(t, gfx.Rect{r.x, r.y, r.w, i32(b.width.top)}, col)
                }
                if b.width.bottom > 0 {
                    gfx.fill(t, gfx.Rect{r.x, r.y + r.h - i32(b.width.bottom), r.w, i32(b.width.bottom)}, col)
                }
                if b.width.left > 0 {
                    gfx.fill(t, gfx.Rect{r.x, r.y, i32(b.width.left), r.h}, col)
                }
                if b.width.right > 0 {
                    gfx.fill(t, gfx.Rect{r.x + r.w - i32(b.width.right), r.y, i32(b.width.right), r.h}, col)
                }
            }

        case .Text:
            d := cmd.renderData.text
            col, ok := clay_color(d.textColor)
            if ok && d.stringContents.length > 0 {
                // text_draw adds the baseline offset itself. The slice points into Clay's
                // arena and is valid until the next BeginLayout.
                s := string(d.stringContents.chars[:d.stringContents.length])
                gfx.text_draw(t, s, f32(r.x), f32(r.y), col)
            }

        case .Image:
            // The pane points imageData at its own gfx.Image, which outlives EndLayout.
            if img := (^gfx.Image)(cmd.renderData.image.imageData); img != nil {
                gfx.image_push(t, img^, r)
            }

        case .Custom:
            cu := (^ClayCustom)(cmd.renderData.custom.customData)
            if cu != nil && cu.paint != nil {
                gfx.flush_pane(t, clip, win_w, win_h) // hand the painter empty batches
                cu.paint(t, r, clay_isect(r, clip), win_w, win_h, host, cu.user)
            }

        case .ScissorStart:
            gfx.flush_pane(t, clip, win_w, win_h) // what is queued belongs to the OUTER clip
            if depth < CLAY_CLIP_DEPTH {
                stack[depth] = clip
                clip = clay_isect(clip, r)
            }
            depth += 1

        case .ScissorEnd:
            gfx.flush_pane(t, clip, win_w, win_h)
            if depth > 0 {
                depth -= 1
                if depth < CLAY_CLIP_DEPTH {
                    clip = stack[depth]
                }
            }

        case .None:
        // Clay's zero value; never emitted for a real element.

        case .OverlayColorStart, .OverlayColorEnd:
        // Clay's dim-behind-a-modal tint. Our overlays draw their own backdrop, and the quad
        // shader cannot blend a translucent wash — wiring it up means renderer alpha first.
        }
    }

    gfx.flush_pane(t, clip, win_w, win_h)
}
