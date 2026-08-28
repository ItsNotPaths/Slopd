package gfx

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Half-open on the far edges, so two rects sharing a boundary never both claim a pixel. A
// zero-sized rect never hits, so hit-testing needs no hidden-pane check.
rect_hit :: proc(r: Rect, x, y: i32) -> bool {
    return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// The overlap, empty when they do not meet. What a scissor does to a pane's batch, and what a
// grid backend has to do by hand.
rect_isect :: proc(a, b: Rect) -> Rect {
    x0, y0 := max(a.x, b.x), max(a.y, b.y)
    x1 := min(a.x + a.w, b.x + b.w)
    y1 := min(a.y + a.h, b.y + b.h)
    return Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}
