package main

import "core:math"
import clay "../bindings/clay"

// C1: the renderer bridge. Clay solves a declared tree into a flat list of render
// commands with resolved bounding boxes; this file turns that list into the calls
// text.odin already exposes — `fill` for rectangles and borders, `text_draw` for
// glyphs, `image_push` for textures, `flush_pane` for the scissor groups. Nothing
// here decides layout; it is the last mile between Clay's output and the GL batches,
// and it is the ONLY place that knows Clay's command shape. See docs/clay-refactor.md.
//
// Two properties of the existing renderer leak through, and both are load-bearing
// enough to state rather than discover later:
//
//   1. Within one scissor group, quads always paint UNDER glyphs. flush_pane
//      composites under-quads -> images -> glyphs -> over-quads, so a Rectangle
//      declared after a Text still lands behind it. Chrome is already built this way
//      (a row's background, then its label), but an element meant to OCCLUDE text —
//      a dropdown over a list — needs its own scissor group, which is exactly what
//      Clay's clip elements emit.
//
//   2. Alpha is a visibility bit, not a blend factor. The quad shader writes
//      vec4(v_color, 1.0), so a colour either paints opaque or does not paint at all;
//      clay_color reports that as `visible`. Real translucency would mean a fourth
//      component through push_quad and the shader — a renderer change, not a bridge
//      concern, so it is not smuggled in here.

// How deep clip elements may nest before the bridge stops tracking. Clay clip groups
// map to GL scissors, which do not stack in hardware — we intersect them ourselves,
// and this is the depth of that stack. Chrome nests two or three deep (pane -> scrolled
// content -> overlay); beyond the cap a group simply inherits its parent's clip instead
// of narrowing, which under-clips rather than corrupting the paint order. The push/pop
// counter keeps counting past the cap so an overflowed group still ends where it began.
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

// A text config for chrome. `line_h` is the box height Clay lays the string out in —
// pass the font's line height and let the row's childAlignment centre it, rather than
// stretching the text box to the row. Chrome never wraps: rows are single-line and the
// pane code elides them, so Words wrapping would only ever be a surprise.
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

// Text measurement, monospace: width is the RUNE count times the cell advance, which is
// not the byte count — a file name with an accent or a box-drawing character would
// otherwise measure wide by exactly the bytes UTF-8 spends on it. Height is the config's
// line height when set, else the font's. Pure, and the reason clay_measure below is a
// three-line shim: this is the part worth testing. `contextless` because Clay calls the
// shim on its own C stack — and measuring allocates nothing, so there is no reason to
// stand up a default context per call on a path Clay hits for every string it lays out.
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

// A surface Clay lays out but does not paint: the editor text body, the terminal cell
// grid, the media surface. Clay reserves the box, we paint inside
// it with the existing per-glyph painters. The declaring pane owns the struct and passes
// it as `custom.customData` — it must outlive EndLayout, so it lives on App or in the
// frame's temp arena, never on a stack frame that has already returned.
//
// Contract: the bridge flushes everything queued so far under the CURRENT clip before
// calling `paint`, so the painter starts with empty batches and owns its region outright
// — including its own flush_pane, exactly as editor_paint_body and terminal_paint_grid end.
// Anything it leaves queued would be drawn later under a different clip.
//
// A BOX IS NOT A CLIP, which is why `paint` takes both. `r` is where the surface starts —
// glyphs and bars are positioned from it — while `clip` is how much of it may actually
// reach the screen. A row half off the bottom of a scrolling list still has a full-height
// box, so a painter that scissored to `r` would draw outside the body it was declared in.
// The bridge already tracks the clip in force on its stack and hands it over intersected
// with the box, so `flush_pane(t, clip, ...)` is the whole of a painter's obligation; no
// Custom can derive this for itself, and every Custom needs it (found by C5b's search
// field, which had to carry its own copy — see docs/clay-refactor.md).
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
            // Clay draws borders INSIDE the element box, one width per edge, so this is
            // four bars rather than render.odin's uniform `outline`. The fifth width,
            // betweenChildren, never reaches here: Clay emits those separators as plain
            // Rectangle commands (clay.h:2852), which the case above already paints.
            //
            // Each edge is skipped when its width is zero. That is not just thrift: a
            // single-edge border is a normal thing to want (grep's accent rail on the
            // match line is a left border and nothing else), and four zero-area quads per
            // such element would be four sixths of the vertex budget spent on nothing.
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
        // Clay's dim-behind-a-modal tint. Slopd's overlays (the terminal switcher, the
        // filetree chord bar) draw their own backdrop from the palette, and the quad
        // shader cannot blend a translucent wash anyway (see the header). Ignored, not
        // forgotten — wiring it up means giving the renderer alpha first.
        }
    }

    flush_pane(t, clip, win_w, win_h)
}
