package main

import "core:fmt"
import clay "../bindings/clay"

// A preview swatch over one rail per HSV(A) channel.
//
// Every phase reads `color_row`: the hit test, the drag and the paint take their rects from that
// one proc, so the rail you grab is the rail you see.
//
// The rows are font-sized rather than a fixed 28px: a row is a label line with its rail under
// it, so its height has to follow the line height or the labels grow into the rails.

COLOR_PAD :: 8 // pane margin
COLOR_GAP :: 10 // preview -> format line -> rails
COLOR_PREVIEW_H :: 36
COLOR_TRACK_H :: 6
COLOR_THUMB_W :: 6
COLOR_LABEL_GAP :: 4 // label line -> its rail
COLOR_ROW_GAP :: 8 // rail -> the next label line
COLOR_CHECKER :: 6 // alpha checkerboard square

color_geom :: proc(pane: Rect, scale: f32) -> Rect {
    return inset(pane, i32(2 * scale))
}

color_slider_count :: proc(a: ^App) -> int {
    return a.color.style.has_alpha ? 4 : 3
}

// HSV's V, under the commoner name: HSB is the same model. Not HSL's lightness.
color_slider_label :: proc(i: int) -> string {
    switch i {
    case 0:
        return "Hue"
    case 1:
        return "Saturation"
    case 2:
        return "Brightness"
    case 3:
        return "Alpha"
    }
    return ""
}

// 0..1, so one rail geometry and one drag serve all four.
color_slider_value :: proc(a: ^App, i: int) -> f32 {
    if i == 0 {
        return a.color.hsva[0] / 360
    }
    return a.color.hsva[clamp(i, 0, 3)]
}

color_set_slider :: proc(a: ^App, i: int, v: f32) {
    hsva := a.color.hsva
    hsva[clamp(i, 0, 3)] = i == 0 ? clampf(v, 0, 1) * 360 : clampf(v, 0, 1)
    color_set_hsva(a, hsva)
}

// --- geometry ---

color_preview_rect :: proc(a: ^App, pane: Rect) -> Rect {
    area := color_geom(pane, a.scale)
    pad := i32(COLOR_PAD * a.scale)
    return Rect{area.x + pad, area.y + pad, max(0, area.w - 2 * pad), i32(COLOR_PREVIEW_H * a.scale)}
}

// The strip one channel owns: a label line plus the gap under its rail.
color_row_h :: proc(lh, scale: f32) -> i32 {
    return i32(lh) + i32((COLOR_LABEL_GAP + COLOR_TRACK_H + COLOR_ROW_GAP) * scale)
}

// `row` is the hit target: a press anywhere on it grabs the rail, which is 6px tall and would
// otherwise be a pixel hunt.
color_row :: proc(a: ^App, pane: Rect, idx: int, lh: f32) -> (row, track: Rect) {
    pr := color_preview_rect(a, pane)
    y := pr.y + pr.h + i32(COLOR_GAP * a.scale)
    if a.color.live { // the format line sits between the swatch and the rails
        y += i32(lh) + i32(COLOR_GAP * a.scale)
    }
    row = Rect{pr.x, y + i32(idx) * color_row_h(lh, a.scale), pr.w, color_row_h(lh, a.scale)}
    track = Rect{row.x, row.y + i32(lh) + i32(COLOR_LABEL_GAP * a.scale), row.w, i32(COLOR_TRACK_H * a.scale)}
    return
}

// --- input ---

color_hit :: proc(a: ^App, pane: Rect, lh: f32) -> int {
    if !a.mouse_on || !a.mouse.known || !rect_hit(pane, a.mouse.x, a.mouse.y) {
        return -1
    }
    for i in 0 ..< color_slider_count(a) {
        if row, _ := color_row(a, pane, i, lh); rect_hit(row, a.mouse.x, a.mouse.y) {
            return i
        }
    }
    return -1 // the swatch is a readout, not a control
}

color_click :: proc(a: ^App, pane: Rect, lh: f32) {
    hit := color_hit(a, pane, lh)
    if hit < 0 {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    a.color.sel = hit
    drag_begin(a, .Color_Slider, hit, count, {}, 0)
    color_grab(a, pane, hit, lh)
}

// Shared by the press and every frame of the drag, so the two cannot disagree about x.
color_grab :: proc(a: ^App, pane: Rect, idx: int, lh: f32) {
    _, track := color_row(a, pane, idx, lh)
    if track.w <= 0 {
        return
    }
    color_set_slider(a, idx, clampf(f32(a.mouse.x - track.x) / f32(track.w), 0, 1))
}

// The grabbed channel is drag.odin's `target`, so the release's last motion still lands.
color_drag :: proc(a: ^App, pane: Rect, lh: f32) {
    if a.drag.kind != .Color_Slider || a.drag.target >= color_slider_count(a) {
        return
    }
    color_grab(a, pane, a.drag.target, lh)
}

color_dragging :: proc(a: ^App, idx: int) -> bool {
    return drag_live(a, .Color_Slider, idx)
}

// --- paint ---

Color_Body :: struct {
    pane: Rect,
}

// Declare the pane into the window's tree:
//   co_pane  the content area inside the focus ring, clipping its own content
//     co_body  the picker surface, as a Custom — rails are gradients, not Clay rectangles
color_declare :: proc(a: ^App, f: ^Font, pane: Rect) {
    area := color_geom(pane, a.scale)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    body := new(Color_Body, context.temp_allocator)
    body^ = Color_Body{pane = pane}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = color_paint, user = body}

    if clay.UI(clay.ID("co_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("co_body"))(
            {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = {customData = cu}},
        ) {}
    }
}

// From the pane rect rather than `r`, the box the solver resolved. The two are the same box, and
// taking the pane keeps the paint and the hit test on one geometry.
color_paint :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    b := (^Color_Body)(user)
    if b == nil {
        return
    }
    cw, lh := t.font.cell_w, t.font.line_height
    color_paint_preview(t, a, b.pane, cw, lh)
    for i in 0 ..< color_slider_count(a) {
        color_paint_row(t, a, b.pane, i, cw, lh)
    }
    flush_pane(t, clip, win_w, win_h)
}

// The colour, its hex in whichever of black/white reads on it, and the live token's own text
// under it when the picker is writing back into a buffer.
@(private = "file")
color_paint_preview :: proc(t: ^Text, a: ^App, pane: Rect, cw, lh: f32) {
    th := &a.theme
    cp := &a.color
    pr := color_preview_rect(a, pane)
    if pr.w <= 0 || pr.h <= 0 {
        return
    }
    col := color_over(cp.rgba, th.bg)
    if cp.style.has_alpha && cp.rgba[3] < 1 {
        color_checker(t, pr, i32(COLOR_CHECKER * a.scale), cp.rgba, th.bg, th.separator)
    } else {
        fill(t, pr, col)
    }
    outline(t, pr, th.separator, i32(max(1, a.scale)))

    hex := color_format(cp.rgba, {kind = .Hex, has_alpha = cp.style.has_alpha}, context.temp_allocator)
    lum := col.r * 0.299 + col.g * 0.587 + col.b * 0.114
    text_draw(
        t,
        hex,
        f32(pr.x) + (f32(pr.w) - text_w(hex, cw)) / 2,
        f32(pr.y) + (f32(pr.h) - lh) / 2,
        lum > 0.5 ? {0, 0, 0} : {1, 1, 1},
    )
    if cp.live {
        txt := color_format(cp.rgba, cp.style, context.temp_allocator)
        text_draw(t, txt, f32(pr.x), f32(pr.y + pr.h + i32(COLOR_GAP * a.scale)), th.muted)
    }
}

@(private = "file")
color_paint_row :: proc(t: ^Text, a: ^App, pane: Rect, i: int, cw, lh: f32) {
    th := &a.theme
    cp := &a.color
    row, track := color_row(a, pane, i, lh)
    if track.w <= 0 {
        return
    }
    held := color_dragging(a, i)
    val := color_slider_value(a, i)
    mark := held ? th.accent : cp.sel == i ? th.fg : th.muted // dragged, focused, idle
    vtext := i == 0 ? fmt.tprintf("%.0f°", cp.hsva[0]) : fmt.tprintf("%.0f%%", val * 100)

    text_draw(t, color_slider_label(i), f32(row.x), f32(row.y), mark)
    text_draw(t, vtext, f32(row.x + row.w) - text_w(vtext, cw), f32(row.y), th.muted)
    color_paint_track(t, a, track, i)

    // Centred on the value, kept whole inside the rail's ends, on a bg ring so it stays visible
    // where it matches the gradient under it.
    w := i32(COLOR_THUMB_W * a.scale)
    x := clamp(track.x + i32(f32(track.w) * val) - w / 2, track.x, track.x + track.w - w)
    thumb := Rect{x, track.y - i32(3 * a.scale), w, track.h + i32(6 * a.scale)}
    fill(t, inset(thumb, -i32(max(1, a.scale))), th.bg)
    fill(t, thumb, held ? th.accent : th.fg) // always solid: a dim thumb is a lost one
}

// In slices: it shows the colour you would get by dropping the thumb at each point, so the bar
// is its own legend.
@(private = "file")
color_paint_track :: proc(t: ^Text, a: ^App, track: Rect, i: int) {
    step := max(1, i32(3 * a.scale))
    for x := track.x; x < track.x + track.w; x += step {
        u := f32(x - track.x) / f32(track.w)
        fill(t, Rect{x, track.y, min(step, track.x + track.w - x), track.h}, color_track_at(a, i, u))
    }
}

// Hue runs at full saturation and value: at v = 0 the honest gradient is a black bar, naming
// nothing. The other three show the real result.
color_track_at :: proc(a: ^App, i: int, u: f32) -> [3]f32 {
    h := a.color.hsva
    switch i {
    case 0:
        h = {u * 360, 1, 1, 1}
    case 1:
        h = {h[0], u, h[2], 1}
    case 2:
        h = {h[0], h[1], u, 1}
    case 3:
        h[3] = u
    }
    return color_over(color_hsva_to_rgba(h), a.theme.bg)
}

// `fill` takes no alpha, so every translucent thing here is blended before it is queued.
color_over :: proc(c: [4]f32, bg: [3]f32) -> [3]f32 {
    return bg * (1 - c[3]) + c.rgb * c[3]
}

// Each square blended separately, so alpha reads as alpha rather than a darker pane.
@(private = "file")
color_checker :: proc(t: ^Text, r: Rect, sz: i32, over: [4]f32, lo, hi: [3]f32) {
    for y := r.y; y < r.y + r.h; y += sz {
        for x := r.x; x < r.x + r.w; x += sz {
            base := ((x - r.x) / sz + (y - r.y) / sz) % 2 == 0 ? lo : hi
            cell := Rect{x, y, min(sz, r.x + r.w - x), min(sz, r.y + r.h - y)}
            fill(t, cell, color_over(over, base))
        }
    }
}

// Input runs before the declaration, so a drag lands in the frame it happened.
color_frame :: proc(t: ^Text, a: ^App, pane: Rect) {
    if pane.w <= 0 || pane.h <= 0 {
        return
    }
    lh := t.font.line_height
    color_click(a, pane, lh)
    color_drag(a, pane, lh)
    color_declare(a, &t.font, pane)
}
