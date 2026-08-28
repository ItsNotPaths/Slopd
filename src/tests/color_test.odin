package tests

import app "../slopd"
import "core:testing"
import "core:unicode/utf8"
import "../txt"
import "../edit"

// Reading a colour out of a line and writing it back. The picker edits IN PLACE, so color_at
// and color_format have to be inverses: what the caret was on is the form the buffer keeps.
//
// The tuple form is a heuristic and the scale is the whole of it. Three numbers in brackets
// carry no unit, so the values decide — all of them inside 0..1 means unit floats, anything
// larger means 0..255 bytes. `{1, 0, 0}` is red, not the near-black that 1/255 would give.

@(private = "file")
Case :: struct {
    line:  string,
    at:    int, // rune column of the caret
    want:  [4]f32,
    text:  string, // the span the picker takes over
    alpha: bool,
}

@(private = "file")
at :: proc(line: string, col: int) -> (rgba: [4]f32, lo, hi: int, st: app.Color_Style, ok: bool) {
    return app.color_at(utf8.string_to_runes(line, context.temp_allocator), col)
}

// Everything the editor's own files write a colour as, plus the CSS the picker was built for.
@(test)
test_color_at_reads_every_form :: proc(t: ^testing.T) {
    cases := []Case {
        {"    accent #9253be", 12, {0x92 / 255.0, 0x53 / 255.0, 0xbe / 255.0, 1}, "#9253be", false},
        {"a: #f00;", 4, {1, 0, 0, 1}, "#f00", false},
        {"border: #ff000080", 17, {1, 0, 0, 0.5019608}, "#ff000080", true}, // caret just past it
        {"color: rgb(255, 0, 0);", 12, {1, 0, 0, 1}, "rgb(255, 0, 0)", false},
        {"rgba(12, 34, 56, 0.5)", 0, {12 / 255.0, 34 / 255.0, 56 / 255.0, 0.5}, "rgba(12, 34, 56, 0.5)", true},
        // The tuples. An Odin array literal, a GLSL constructor, a bare CSV tuple, a byte tuple.
        {"fg = [3]f32{1, 0, 0}", 12, {1, 0, 0, 1}, "{1, 0, 0}", false},
        {"col := [4]f32{0.1, 0.2, 0.3, 1}", 15, {0.1, 0.2, 0.3, 1}, "{0.1, 0.2, 0.3, 1}", true},
        {"vec3(0.5, 0.25, 0)", 6, {0.5, 0.25, 0, 1}, "(0.5, 0.25, 0)", false},
        {"[200, 100, 50]", 2, {200 / 255.0, 100 / 255.0, 50 / 255.0, 1}, "[200, 100, 50]", false},
        {"(255, 0, 0, 128)", 2, {1, 0, 0, 128 / 255.0}, "(255, 0, 0, 128)", true},
        // Only `rgb`/`rgba` are the CSS call; any other name keeps its own text and the
        // brackets alone are the colour, which is what makes vec3() and srgb() work at all.
        {"srgb(255, 0, 0)", 6, {1, 0, 0, 1}, "(255, 0, 0)", false},
    }
    for c in cases {
        rgba, lo, hi, st, ok := at(c.line, c.at)
        if !testing.expectf(t, ok, "no colour found in %q at %d", c.line, c.at) {
            continue
        }
        runes := utf8.string_to_runes(c.line, context.temp_allocator)
        got := utf8.runes_to_string(runes[lo:hi], context.temp_allocator)
        testing.expect_value(t, got, c.text)
        testing.expect_value(t, st.has_alpha, c.alpha)
        for k in 0 ..< 4 {
            testing.expectf(
                t,
                abs(rgba[k] - c.want[k]) < 0.002,
                "%q channel %d: got %v, want %v",
                c.line,
                k,
                rgba[k],
                c.want[k],
            )
        }
    }
}

// The round trip. A colour that comes back in another form has rewritten the file, which is
// what the style is carried for — the brackets, the scale and the channel count all survive.
@(test)
test_color_format_puts_back_what_it_took :: proc(t: ^testing.T) {
    lines := []string {
        "#9253be",
        "#ff000080",
        "rgb(255, 0, 0)",
        "rgba(12, 34, 56, 0.5)",
        "{0.1, 0.2, 0.3}",
        "[0.5, 0.25, 0, 1]",
        "(200, 100, 50)",
        "(255, 0, 0, 128)",
    }
    for s in lines {
        rgba, _, _, st, ok := at(s, 1)
        if !testing.expectf(t, ok, "no colour found in %q", s) {
            continue
        }
        back := app.color_format(rgba, st, context.temp_allocator)
        testing.expect_value(t, back, s)
    }
    // A short hex writes back long: #f00 and #ff0000 are the same colour, and the picker has
    // no way to know the file wanted the short one once a drag lands between the two.
    rgba, _, _, st, _ := at("#f00", 1)
    testing.expect_value(t, app.color_format(rgba, st, context.temp_allocator), "#ff0000")

    // A drag leaves a float trimmed rather than padded — `0.5`, never `0.500`.
    _, _, _, fl, _ := at("{0, 0, 0}", 1)
    testing.expect_value(t, app.color_format({0.5, 1, 0, 1}, fl, context.temp_allocator), "{0.5, 1, 0}")
}

// What is NOT a colour. The tuple pattern is the loose one, so this is where it earns its keep:
// numbers outside every colour scale, fields that are not numbers, and the wrong count.
@(test)
test_color_at_refuses_what_is_not_a_colour :: proc(t: ^testing.T) {
    no := []string {
        "size = (1920, 1080, 60)", // a resolution, not a colour
        "p := (x, y, z)", // identifiers
        "v := (1, 2)", // two fields
        "m := (1, 2, 3, 4, 5)", // five
        "hash = ff0000", // hex with no '#'
        "id := #ff000", // five digits: no hex colour is that long
        "f(1, 2, 3", // unterminated
    }
    for s in no {
        runes := utf8.string_to_runes(s, context.temp_allocator)
        found := false
        for c in 0 ..< len(runes) {
            if _, _, _, _, ok := app.color_at(runes, c); ok {
                found = true
                break
            }
        }
        testing.expectf(t, !found, "%q must not read as a colour", s)
    }
}

// The bracket walk resolves the INNER pair, so an Odin array literal's `[3]` and the call
// around a tuple are not what the caret lands in.
@(test)
test_color_tuple_takes_the_inner_brackets :: proc(t: ^testing.T) {
    _, lo, hi, _, ok := at("draw(rect, [3]f32{0.1, 0.2, 0.3}, 4)", 20)
    testing.expect(t, ok, "the caret is inside the array literal")
    testing.expect_value(t, lo, 17)
    testing.expect_value(t, hi, 32)

    // A caret ON either bracket is inside it, and one just past the closer still is.
    for col in ([]int{17, 31, 32}) {
        _, l, h, _, k := at("draw(rect, [3]f32{0.1, 0.2, 0.3}, 4)", col)
        testing.expectf(t, k && l == 17 && h == 32, "column %d missed the literal", col)
    }
}

// HSV is the editing model, so the trip through it must not move the colour. Grey is the case
// that breaks a careless conversion: it has no hue, and every hue maps back to the same grey.
@(test)
test_color_hsv_round_trips :: proc(t: ^testing.T) {
    for c in ([][4]f32{{1, 0, 0, 1}, {0.2, 0.4, 0.6, 0.5}, {0.5, 0.5, 0.5, 1}, {0, 0, 0, 1}, {1, 1, 1, 1}}) {
        back := app.color_hsva_to_rgba(app.color_rgba_to_hsva(c))
        for k in 0 ..< 4 {
            testing.expectf(t, abs(back[k] - c[k]) < 0.001, "%v -> %v", c, back)
        }
    }
}

// --- editing a buffer through the picker ---

@(private = "file")
picker_app :: proc(text: string, col: int) -> app.App {
    a: app.App
    a.main = .Text
    a.scale = 1
    a.color.buf_idx = -1
    b: edit.Buffer
    edit.buffer_set_text(&b, text)
    b.cursors[b.primary].head.col = col
    b.cursors[b.primary].anchor = b.cursors[b.primary].head
    append(&a.editor.buffers, b)
    return a
}

@(private = "file")
picker_free :: proc(a: ^app.App) {
    app.color_close(a, true) // owns the original token; commit so it does not write into the freed doc
    for &b in a.editor.buffers {
        edit.buffer_destroy(&b)
    }
    delete(a.editor.buffers)
}

@(private = "file")
line0 :: proc(a: ^app.App) -> string {
    return string(txt.doc_line(&a.editor.buffers[0].doc, 0, context.temp_allocator))
}

// The whole gesture: Alt+Enter lands on the literal, a slider rewrites it in place, and the
// commit leaves ONE undo step behind. The preview writes are not journalled, so undo must
// return the line to what it was before the picker opened — not to the last colour dragged past.
@(test)
test_color_edits_the_buffer_in_place :: proc(t: ^testing.T) {
    a := picker_app("fg := [3]f32{1, 0, 0}", 14)
    defer picker_free(&a)

    testing.expect(t, app.color_open_at_caret(&a), "the caret is on a colour tuple")
    testing.expect(t, a.color.live, "a colour in a buffer is edited in place")
    testing.expect_value(t, a.color.style.kind, app.Color_Kind.Tuple)

    app.color_set_hsva(&a, {120, 1, 1, 1}) // green
    testing.expect_value(t, line0(&a), "fg := [3]f32{0, 1, 0}")

    app.color_set_hsva(&a, {240, 1, 1, 1}) // and blue, still one gesture
    testing.expect_value(t, line0(&a), "fg := [3]f32{0, 0, 1}")

    app.color_close(&a, true)
    testing.expect_value(t, line0(&a), "fg := [3]f32{0, 0, 1}")
    testing.expect(t, a.editor.buffers[0].dirty, "a committed colour is an unsaved edit")

    testing.expect(t, txt.doc_undo(&a.editor.buffers[0].doc), "the commit must be undoable")
    testing.expect_value(t, line0(&a), "fg := [3]f32{1, 0, 0}")
    testing.expect(t, !txt.doc_undo(&a.editor.buffers[0].doc), "and must be ONE step, not one per frame")
}

// Escape puts the token back exactly as it was, including the buffer's dirty flag — a picker
// opened on a saved file and cancelled must not leave it starred.
@(test)
test_color_cancel_restores_the_token :: proc(t: ^testing.T) {
    a := picker_app("  accent #9253be", 11)
    defer picker_free(&a)

    testing.expect(t, app.color_open_at_caret(&a), "the caret is on a hex literal")
    app.color_set_hsva(&a, {0, 1, 1, 1})
    testing.expect_value(t, line0(&a), "  accent #ff0000")

    app.color_close(&a, false)
    testing.expect_value(t, line0(&a), "  accent #9253be")
    testing.expect(t, !a.editor.buffers[0].dirty, "a cancelled picker leaves the file as it found it")
    testing.expect(t, !a.color.active, "and the pane closes")
}
