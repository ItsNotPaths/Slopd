package tests

import app "../slopd"
import "core:testing"
import "core:unicode/utf8"

// Alt+Enter classifies the token under the caret, most specific first: a `[[wikilink]]`, then a
// URL, then a path, then a colour, then a bare identifier. The three classifiers here are pure
// -- a line of runes and a caret -- and the thing they all have to agree on is where a token
// STARTS and ENDS, at every caret a person can leave inside it.

@(private = "file")
runes :: proc(s: string) -> []rune {
    return utf8.string_to_runes(s, context.temp_allocator)
}

// The caret rests anywhere in `[[name]]`, including on the brackets themselves. Resting on the
// opening bracket used to find nothing: the scan reads pairs BEHIND the caret, and at column 0
// there is no pair behind it.
@(test)
test_wikilink_at_every_caret :: proc(t: ^testing.T) {
    line := runes("see [[notes]] later")
    for col in 4 ..= 12 { // '[' at 4 through the last ']' at 12
        name, ok := app.link_wikilink_at(line, col)
        testing.expectf(t, ok, "no link at col %d", col)
        testing.expectf(t, name == "notes", "col %d gave %q", col, name)
    }

    // Outside it there is nothing to follow.
    _, before := app.link_wikilink_at(line, 0)
    testing.expect(t, !before)
    _, after := app.link_wikilink_at(line, 15)
    testing.expect(t, !after)
}

// Two links on one line: the caret picks the one it is in, never the neighbour.
@(test)
test_wikilink_picks_its_own :: proc(t: ^testing.T) {
    line := runes("[[one]] [[two]]")
    first, ok1 := app.link_wikilink_at(line, 3)
    testing.expect(t, ok1)
    testing.expect_value(t, first, "one")

    second, ok2 := app.link_wikilink_at(line, 11)
    testing.expect(t, ok2)
    testing.expect_value(t, second, "two")

    // The gap between them belongs to neither.
    _, between := app.link_wikilink_at(line, 7)
    testing.expect(t, !between)
}

@(test)
test_wikilink_needs_both_halves :: proc(t: ^testing.T) {
    _, unclosed := app.link_wikilink_at(runes("[[never closed"), 4)
    testing.expect(t, !unclosed)
    _, single := app.link_wikilink_at(runes("[not a link]"), 4)
    testing.expect(t, !single)
}

// A URL is taken only with a scheme it knows, and prose punctuation at the end is the
// sentence's, not the link's.
@(test)
test_url_at_caret :: proc(t: ^testing.T) {
    line := runes("see https://example.com/a_b?q=1, then stop.")
    url, ok := app.link_url_at(line, 10)
    testing.expect(t, ok)
    testing.expect_value(t, url, "https://example.com/a_b?q=1")

    // The caret resting just past the token still finds it.
    tail := runes("https://example.com")
    past, ok2 := app.link_url_at(tail, len(tail))
    testing.expect(t, ok2)
    testing.expect_value(t, past, "https://example.com")

    _, bare := app.link_url_at(runes("example.com"), 3) // no scheme: not ours to open
    testing.expect(t, !bare)
}

// An identifier is what the definition jump greps for, so it must not start at a digit and must
// stop at the punctuation around it.
@(test)
test_ident_at_caret :: proc(t: ^testing.T) {
    line := runes("foo.bar_baz(42)")
    id, ok := app.link_ident_at(line, 5)
    testing.expect(t, ok)
    testing.expect_value(t, id, "bar_baz")

    _, num := app.link_ident_at(line, 12) // "42" is no symbol to jump to
    testing.expect(t, !num)

    _, punct := app.link_ident_at(runes("a + b"), 2) // on the '+', with a token either side
    testing.expect(t, !punct)
}
