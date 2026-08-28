package tests

import app ".."
import "core:strings"
import "core:testing"
import "../txt"

// The comment toggle: which token a file gets, and the one rule the toggle turns on — a block
// goes fully commented unless every line holding text is commented already, and only then bare.

@(private = "file")
mk :: proc(path, src: string) -> app.Buffer {
    b: app.Buffer
    txt.doc_init(&b.doc)
    app.buffer_set_text(&b, src)
    b.path = strings.clone(path)
    return b
}

@(private = "file")
text :: proc(b: ^app.Buffer) -> string {
    return txt.doc_string(&b.doc, context.temp_allocator)
}

@(private = "file")
whole :: proc(b: ^app.Buffer) {
    txt.doc_select_all(&b.doc)
}

@(test)
test_comment_token_by_extension :: proc(t: ^testing.T) {
    tok, ok := app.comment_token("/w/src/main.odin")
    testing.expect(t, ok)
    testing.expect_value(t, tok, "//")

    tok, ok = app.comment_token("/w/deploy.PY") // the extension is not case-sensitive
    testing.expect(t, ok)
    testing.expect_value(t, tok, "#")

    tok, ok = app.comment_token("/w/Makefile") // named, not suffixed
    testing.expect(t, ok)
    testing.expect_value(t, tok, "#")

    tok, ok = app.comment_token("/w/q.lua")
    testing.expect(t, ok)
    testing.expect_value(t, tok, "--")

    _, ok = app.comment_token("/w/notes.zzz")
    testing.expect(t, !ok, "an unknown extension must not be guessed at")
    _, ok = app.comment_token("")
    testing.expect(t, !ok)
}

// The token goes at the SHALLOWEST indentation of the block, so the shape of the code survives
// the round trip. A blank line takes no token, and comes back untouched.
@(test)
test_comment_toggle_round_trip :: proc(t: ^testing.T) {
    src := "fn:\n    a\n\n        b" // as stored: doc_normalize drops one trailing newline
    b := mk("/w/x.odin", src)
    defer app.buffer_destroy(&b)

    whole(&b)
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), "// fn:\n//     a\n\n//         b")
    testing.expect(t, b.dirty)

    whole(&b)
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), src)
}

// The rule that makes one key do both: a block where some line still has bare text is COMMENTED,
// which is what stops a half-commented selection from toggling itself apart.
@(test)
test_comment_toggle_takes_a_mixed_block_forward :: proc(t: ^testing.T) {
    b := mk("/w/x.odin", "// done\nnot yet")
    defer app.buffer_destroy(&b)

    whole(&b)
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), "// // done\n// not yet")

    whole(&b)
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), "// done\nnot yet")
}

// Uncommenting takes the token and the single space a comment pass wrote after it — no more, so
// a line indented past the token keeps its own indentation.
@(test)
test_uncomment_takes_only_its_own_space :: proc(t: ^testing.T) {
    b := mk("/w/x.odin", "//no space\n//  two spaces")
    defer app.buffer_destroy(&b)

    whole(&b)
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), "no space\n two spaces")
}

// With no selection it is the caret's line, and the caret rides the shift rather than being left
// where the text used to be.
@(test)
test_comment_one_line_carries_the_caret :: proc(t: ^testing.T) {
    b := mk("/w/x.py", "x = 1\ny = 2")
    defer app.buffer_destroy(&b)

    txt.doc_reset_cursor(&b.doc, txt.Pos{1, 4})
    testing.expect(t, app.buffer_comment_toggle(&b))
    testing.expect_value(t, text(&b), "x = 1\n# y = 2")
    testing.expect_value(t, b.doc.cursors[0].head, txt.Pos{1, 6})
}

// Nothing to do is not an edit: an unknown language, and a selection of blank lines.
@(test)
test_comment_toggle_declines :: proc(t: ^testing.T) {
    b := mk("/w/notes.zzz", "a\nb")
    defer app.buffer_destroy(&b)
    whole(&b)
    testing.expect(t, !app.buffer_comment_toggle(&b))
    testing.expect(t, !b.dirty)

    blank := mk("/w/x.odin", "\n\n")
    defer app.buffer_destroy(&blank)
    before := strings.clone(text(&blank), context.temp_allocator)
    whole(&blank)
    testing.expect(t, !app.buffer_comment_toggle(&blank))
    testing.expect_value(t, text(&blank), before)
}
