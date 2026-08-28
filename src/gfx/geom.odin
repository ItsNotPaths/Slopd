package gfx

Rect :: struct {
    x, y, w, h: i32, // top-left origin, pixels
}

// Half-open on the far edges, so two rects sharing a boundary never both claim a pixel. A
// zero-sized rect never hits, so hit-testing needs no hidden-pane check.
rect_hit :: proc(r: Rect, x, y: i32) -> bool {
    return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}
