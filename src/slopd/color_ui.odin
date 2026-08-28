package main

import "core:fmt"
import clay "../../bindings/clay"
import "../gfx"
import "../ui"

// A preview swatch over one rail per HSV(A) channel.
//
// Every phase reads `color_row`: the hit test, the drag and the paint take their rects from that
// one proc, so the rail you grab is the rail you see.
//
// The rows are font-sized rather than a fixed 28px: a row is a label line with its rail under
// it, so its height has to follow the line height or the labels grow into the rails.

COLOR_PAD :: 8 // pane margin, in layout units (gfx.pad)
COLOR_GAP :: 10 // preview -> format line -> rails
COLOR_PREVIEW_H :: 36
COLOR_TRACK_H :: 6
COLOR_THUMB_W :: 6
COLOR_LABEL_GAP :: 4 // label line -> its rail
COLOR_ROW_GAP :: 8 // rail -> the next label line
COLOR_CHECKER :: 6 // alpha checkerboard square

color_geom :: proc(pane: gfx.Rect, line_h: f32) -> gfx.Rect {
    return ui.inset(pane, gfx.edge(line_h))
}

color_slider_count :: proc(cp: ^ColorPane) -> int {
    return cp.style.has_alpha ? 4 : 3
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
color_slider_value :: proc(cp: ^ColorPane, i: int) -> f32 {
    if i == 0 {
        return cp.hsva[0] / 360
    }
    return cp.hsva[clamp(i, 0, 3)]
}

color_set_slider :: proc(a: ^App, i: int, v: f32) {
    hsva := a.color.hsva
    hsva[clamp(i, 0, 3)] = i == 0 ? clamp(v, 0, 1) * 360 : clamp(v, 0, 1)
    color_set_hsva(a, hsva)
}

// --- geometry ---

color_preview_rect :: proc(u: ui.UI_Ctx, pane: gfx.Rect) -> gfx.Rect {
    area := color_geom(pane, u.face.line_height)
    p := gfx.pad(u.face.line_height, COLOR_PAD)
    return gfx.Rect{area.x + p, area.y + p, max(0, area.w - 2 * p), gfx.pad(u.face.line_height, COLOR_PREVIEW_H)}
}

// The strip one channel owns: a label line plus the gap under its rail.
color_row_h :: proc(lh: f32) -> i32 {
    // a label line, its rail, and the gap under it
    return i32(lh) + gfx.pad(lh, COLOR_LABEL_GAP + COLOR_ROW_GAP) + max(1, gfx.pad(lh, COLOR_TRACK_H))
}

// `row` is the hit target: a press anywhere on it grabs the rail, which is 6px tall and would
// otherwise be a pixel hunt.
color_row :: proc(u: ui.UI_Ctx, cp: ^ColorPane, pane: gfx.Rect, idx: int, lh: f32) -> (row, track: gfx.Rect) {
    pr := color_preview_rect(u, pane)
    y := pr.y + pr.h + gfx.pad(u.face.line_height, COLOR_GAP)
    if cp.live { // the format line sits between the swatch and the rails
        y += i32(lh) + gfx.pad(u.face.line_height, COLOR_GAP)
    }
    row = gfx.Rect{pr.x, y + i32(idx) * color_row_h(lh), pr.w, color_row_h(lh)}
    track = gfx.Rect{row.x, row.y + i32(lh) + gfx.pad(lh, COLOR_LABEL_GAP), row.w, max(1, gfx.pad(lh, COLOR_TRACK_H))}
    return
}

// --- input ---

color_hit :: proc(u: ui.UI_Ctx, cp: ^ColorPane, pane: gfx.Rect, lh: f32) -> int {
    if !u.mouse_on || !u.mouse.known || !gfx.rect_hit(pane, u.mouse.x, u.mouse.y) {
        return -1
    }
    for i in 0 ..< color_slider_count(cp) {
        if row, _ := color_row(u, cp, pane, i, lh); gfx.rect_hit(row, u.mouse.x, u.mouse.y) {
            return i
        }
    }
    return -1 // the swatch is a readout, not a control
}

color_click :: proc(u: ui.UI_Ctx, a: ^App, pane: gfx.Rect, lh: f32) {
    hit := color_hit(u, &a.color, pane, lh)
    if hit < 0 {
        return
    }
    count, ok := ui.mouse_take_click(u)
    if !ok {
        return
    }
    a.color.sel = hit
    ui.drag_begin(u, .Color_Slider, hit, count, {}, 0)
    color_grab(u, a, pane, hit, lh)
}

// Shared by the press and every frame of the drag, so the two cannot disagree about x.
color_grab :: proc(u: ui.UI_Ctx, a: ^App, pane: gfx.Rect, idx: int, lh: f32) {
    _, track := color_row(u, &a.color, pane, idx, lh)
    if track.w <= 0 {
        return
    }
    color_set_slider(a, idx, clamp(f32(u.mouse.x - track.x) / f32(track.w), 0, 1))
}

// The grabbed channel is drag.odin's `target`, so the release's last motion still lands.
color_drag :: proc(u: ui.UI_Ctx, a: ^App, pane: gfx.Rect, lh: f32) {
    if u.drag.kind != .Color_Slider || u.drag.target >= color_slider_count(&a.color) {
        return
    }
    color_grab(u, a, pane, u.drag.target, lh)
}

color_dragging :: proc(u: ui.UI_Ctx, cp: ^ColorPane, idx: int) -> bool {
    return ui.drag_live(u, .Color_Slider, idx)
}

// --- paint ---

Color_Body :: struct {
    pane: gfx.Rect,
}

// Declare the pane into the window's tree:
//   co_pane  the content area inside the focus ring, clipping its own content
//     co_body  the picker surface, as a Custom — rails are gradients, not Clay rectangles
color_declare :: proc(u: ui.UI_Ctx, cp: ^ColorPane, face: gfx.Face, pane: gfx.Rect) {
    area := color_geom(pane, u.face.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    body := new(Color_Body, context.temp_allocator)
    body^ = Color_Body{pane = pane}
    cu := new(ui.ClayCustom, context.temp_allocator)
    cu^ = ui.ClayCustom{paint = color_paint, user = body}

    if clay.UI(clay.ID("co_pane"))(ui.clay_pane_box(area)) {
        if clay.UI(clay.ID("co_body"))(
            {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = {customData = cu}},
        ) {}
    }
}

// From the pane rect rather than `r`, the box the solver resolved. The two are the same box, and
// taking the pane keeps the paint and the hit test on one geometry.
color_paint :: proc(t: ^gfx.Draw, r, clip: gfx.Rect, win_w, win_h: i32, host: rawptr, user: rawptr) {
    a := (^App)(host)
    b := (^Color_Body)(user)
    if b == nil {
        return
    }
    u, cp := ctx_of(a), &a.color
    cw, lh := gfx.face(t).cell_w, gfx.face(t).line_height
    color_paint_preview(t, u, cp, b.pane, cw, lh)
    for i in 0 ..< color_slider_count(cp) {
        color_paint_row(t, u, cp, b.pane, i, cw, lh)
    }
    gfx.flush_pane(t, clip, win_w, win_h)
}

// The colour, its hex in whichever of black/white reads on it, and the live token's own text
// under it when the picker is writing back into a buffer.
@(private = "file")
color_paint_preview :: proc(t: ^gfx.Draw, u: ui.UI_Ctx, cp: ^ColorPane, pane: gfx.Rect, cw, lh: f32) {
    th := u.theme
    pr := color_preview_rect(u, pane)
    if pr.w <= 0 || pr.h <= 0 {
        return
    }
    col := color_over(cp.rgba, th.bg)
    if cp.style.has_alpha && cp.rgba[3] < 1 {
        color_checker(t, pr, max(1, gfx.pad(u.face.line_height, COLOR_CHECKER)), cp.rgba, th.bg, th.separator)
    } else {
        gfx.fill(t, pr, col)
    }
    outline(t, pr, th.separator, max(1, gfx.hairline(u.face.line_height)))

    hex := color_format(cp.rgba, {kind = .Hex, has_alpha = cp.style.has_alpha}, context.temp_allocator)
    lum := col.r * 0.299 + col.g * 0.587 + col.b * 0.114
    gfx.text_draw(
        t,
        hex,
        f32(pr.x) + (f32(pr.w) - gfx.text_w(hex, cw)) / 2,
        f32(pr.y) + (f32(pr.h) - lh) / 2,
        lum > 0.5 ? {0, 0, 0} : {1, 1, 1},
    )
    if cp.live {
        label := color_format(cp.rgba, cp.style, context.temp_allocator)
        gfx.text_draw(t, label, f32(pr.x), f32(pr.y + pr.h + gfx.pad(u.face.line_height, COLOR_GAP)), th.muted)
    }
}

@(private = "file")
color_paint_row :: proc(t: ^gfx.Draw, u: ui.UI_Ctx, cp: ^ColorPane, pane: gfx.Rect, i: int, cw, lh: f32) {
    th := u.theme
    row, track := color_row(u, cp, pane, i, lh)
    if track.w <= 0 {
        return
    }
    held := color_dragging(u, cp, i)
    val := color_slider_value(cp, i)
    mark := held ? th.accent : cp.sel == i ? th.fg : th.muted // dragged, focused, idle
    vtext := i == 0 ? fmt.tprintf("%.0f°", cp.hsva[0]) : fmt.tprintf("%.0f%%", val * 100)

    gfx.text_draw(t, color_slider_label(i), f32(row.x), f32(row.y), mark)
    gfx.text_draw(t, vtext, f32(row.x + row.w) - gfx.text_w(vtext, cw), f32(row.y), th.muted)
    color_paint_track(t, u, cp, track, i)

    // Centred on the value, kept whole inside the rail's ends, on a bg ring so it stays visible
    // where it matches the gradient under it.
    w := max(1, gfx.pad(u.face.line_height, COLOR_THUMB_W))
    x := clamp(track.x + i32(f32(track.w) * val) - w / 2, track.x, track.x + track.w - w)
    thumb := gfx.Rect{x, track.y - gfx.hairline(u.face.line_height), w, track.h + 2 * gfx.hairline(u.face.line_height)}
    gfx.fill(t, ui.inset(thumb, -max(1, gfx.hairline(u.face.line_height))), th.bg)
    gfx.fill(t, thumb, held ? th.accent : th.fg) // always solid: a dim thumb is a lost one
}

// In slices: it shows the colour you would get by dropping the thumb at each point, so the bar
// is its own legend.
@(private = "file")
color_paint_track :: proc(t: ^gfx.Draw, u: ui.UI_Ctx, cp: ^ColorPane, track: gfx.Rect, i: int) {
    step := max(1, gfx.hairline(u.face.line_height))
    for x := track.x; x < track.x + track.w; x += step {
        pos := f32(x - track.x) / f32(track.w)
        gfx.fill(t, gfx.Rect{x, track.y, min(step, track.x + track.w - x), track.h}, color_track_at(u, cp, i, pos))
    }
}

// Hue runs at full saturation and value: at v = 0 the honest gradient is a black bar, naming
// nothing. The other three show the real result.
color_track_at :: proc(u: ui.UI_Ctx, cp: ^ColorPane, i: int, pos: f32) -> [3]f32 {
    h := cp.hsva
    switch i {
    case 0:
        h = {pos * 360, 1, 1, 1}
    case 1:
        h = {h[0], pos, h[2], 1}
    case 2:
        h = {h[0], h[1], pos, 1}
    case 3:
        h[3] = pos
    }
    return color_over(color_hsva_to_rgba(h), u.theme.bg)
}

// `fill` takes no alpha, so every translucent thing here is blended before it is queued.
color_over :: proc(c: [4]f32, bg: [3]f32) -> [3]f32 {
    return bg * (1 - c[3]) + c.rgb * c[3]
}

// Each square blended separately, so alpha reads as alpha rather than a darker pane.
@(private = "file")
color_checker :: proc(t: ^gfx.Draw, r: gfx.Rect, sz: i32, over: [4]f32, lo, hi: [3]f32) {
    for y := r.y; y < r.y + r.h; y += sz {
        for x := r.x; x < r.x + r.w; x += sz {
            base := ((x - r.x) / sz + (y - r.y) / sz) % 2 == 0 ? lo : hi
            cell := gfx.Rect{x, y, min(sz, r.x + r.w - x), min(sz, r.y + r.h - y)}
            gfx.fill(t, cell, color_over(over, base))
        }
    }
}

// Input runs before the declaration, so a drag lands in the frame it happened.
color_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect) {
    if pane.w <= 0 || pane.h <= 0 {
        return
    }
    u, cp := ctx_of(a), &a.color
    lh := gfx.face(t).line_height
    color_click(u, a, pane, lh)
    color_drag(u, a, pane, lh)
    color_declare(u, cp, gfx.face(t), pane)
}
