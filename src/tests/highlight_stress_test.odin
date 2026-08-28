package tests

import app "../slopd"
import "core:strings"
import "core:testing"
import "../txt"
import "../edit"

// Incremental reparse over the grammars that can break it in ways odin cannot.
//
// Tree-sitter does not fail loudly on a bad incremental step: given Input_Edit offsets that do
// not match the document changes, or an external scanner whose state does not restore, it
// quietly produces a WRONG TREE. So every check here is the same shape — edit a parsed buffer,
// reparse incrementally, and compare the colours against a separate buffer holding the same
// final text that has only ever been parsed whole.
//
//   python   its external scanner carries an INDENT STACK. Editing leading whitespace is the
//            case where that state has to serialise and restore correctly across the edit, and
//            no amount of odin exercises it.
//   cpp      the heaviest grammar in the registry: the most parse table to get through and the
//            most subtrees to reuse or discard.

@(private = "file")
PY_SRC :: `import sys
from dataclasses import dataclass


@dataclass
class Point:
    x: int = 0
    y: int = 0

    def shifted(self, dx, dy):
        if dx > 0:
            return Point(self.x + dx, self.y + dy)
        return self


def main(argv):
    total = 0
    for i in range(10):
        if i % 2 == 0:
            total += i
        else:
            total -= i
    print(f"total={total}", file=sys.stderr)
    return 0
`

@(private = "file")
CPP_SRC :: `#include <string>
#include <vector>

namespace demo {

template <typename T>
struct Box {
    T value;
    explicit Box(T v) : value(v) {}
    const T& get() const { return value; }
};

class Widget {
public:
    Widget(std::string name, int count) : name_(std::move(name)), count_(count) {}

    int total() const {
        int sum = 0;
        for (const auto& n : parts_) {
            sum += n;
        }
        return sum * count_;
    }

private:
    std::string name_;
    int count_ = 0;
    std::vector<int> parts_;
};

}  // namespace demo
`

// One buffer, parsed and then edited; a second holding the same final text, parsed whole. The
// two must agree cell for cell.
@(private = "file")
Editor_Fn :: proc(d: ^txt.Doc)

@(private = "file")
expect_incremental_matches_full :: proc(t: ^testing.T, lang, ext, src: string, edits: []Editor_Fn, what: string) {
    a: app.App
    if !hl_app(t, &a, lang, ext) {
        return
    }
    defer hl_app_destroy(&a)

    live: edit.Buffer
    defer edit.buffer_destroy(&live)
    edit.buffer_set_text(&live, src)
    live.path = strings.clone(strings.concatenate({"stress.", ext}, context.temp_allocator))

    // Parse it whole, then apply each edit with a repaint after it — so every step but the
    // first is incremental, off the tree the step before it left.
    _ = hl_rows(&a, &live)
    for edit, i in edits {
        edit(&live.doc)
        _ = hl_rows(&a, &live)
    }
    got := clone_rows(hl_rows(&a, &live))

    ref: edit.Buffer
    defer edit.buffer_destroy(&ref)
    edit.buffer_set_text(&ref, txt.doc_string(&live.doc, context.temp_allocator))
    ref.path = strings.clone(live.path)
    want := hl_rows(&a, &ref)
    expect_rows_equal(t, got, want, what)
}

// --- the edits, as plain procs (Odin closures cannot capture) ---

// Indent the body of `shifted` one level deeper, then take it back out. This is the python
// scanner's whole job: the INDENT/DEDENT tokens it emits come from state it has to carry across
// the edit, and getting that wrong changes the block structure of everything below.
@(private = "file")
py_indent :: proc(d: ^txt.Doc) {
    for line in 10 ..= 12 {
        txt.doc_reset_cursor(d, txt.Pos{line, 0})
        txt.doc_insert_text(d, "    ")
    }
}

@(private = "file")
py_dedent :: proc(d: ^txt.Doc) {
    for line in 10 ..= 12 {
        txt.doc_reset_cursor(d, txt.Pos{line, 0})
        for _ in 0 ..< 4 {
            txt.doc_delete(d)
        }
    }
}

// Open a new suite: a nested `if` under the loop, which the scanner has to push a level for.
@(private = "file")
py_nest :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, txt.Pos{18, txt.doc_line_len(d, 18)})
    txt.doc_insert_text(d, "\n            if i > 4:\n                total *= 2")
}

// Type a run mid-identifier, then split a line — the ordinary edits, in a heavy grammar.
@(private = "file")
type_run :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, txt.Pos{8, 4})
    for r in "extra_" {
        txt.doc_insert_rune(d, r)
    }
}

@(private = "file")
split_line :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, txt.Pos{5, 0})
    txt.doc_insert_text(d, "// inserted\n")
}

@(private = "file")
delete_first_line :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, txt.Pos{0, 0})
    txt.doc_move(d, .Down, true)
    txt.doc_delete(d)
}

// Open a brace block that closes further down — the edit that makes tree-sitter rebuild a large
// subtree rather than a token, and the one where a wrong reuse shows up as colour drift.
@(private = "file")
cpp_open_block :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, txt.Pos{12, txt.doc_line_len(d, 12)})
    txt.doc_insert_text(d, "\n    void reset() { value = T{}; }")
}

@(test)
test_incremental_python_indentation :: proc(t: ^testing.T) {
    expect_incremental_matches_full(
        t,
        "python",
        "py",
        PY_SRC,
        {py_indent, py_dedent, py_nest},
        "python indent/dedent/nest",
    )
}

@(test)
test_incremental_python_ordinary_edits :: proc(t: ^testing.T) {
    expect_incremental_matches_full(t, "python", "py", PY_SRC, {type_run, delete_first_line}, "python edits")
}

@(test)
test_incremental_cpp :: proc(t: ^testing.T) {
    expect_incremental_matches_full(
        t,
        "cpp",
        "cpp",
        CPP_SRC,
        {type_run, split_line, cpp_open_block, delete_first_line},
        "cpp edits",
    )
}

// Typing one character at a time, reparsing after each, in the heaviest grammar — where a small
// error in the recorded offsets accumulates over the run instead of showing up at once.
@(test)
test_incremental_cpp_typing :: proc(t: ^testing.T) {
    a: app.App
    if !hl_app(t, &a, "cpp", "cpp") {
        return
    }
    defer hl_app_destroy(&a)

    live: edit.Buffer
    defer edit.buffer_destroy(&live)
    edit.buffer_set_text(&live, CPP_SRC)
    live.path = strings.clone("stress.cpp")

    txt.doc_reset_cursor(&live.doc, txt.Pos{18, txt.doc_line_len(&live.doc, 18)})
    for r in " int extra = sum + 1;" {
        txt.doc_insert_rune(&live.doc, r)
        _ = hl_rows(&a, &live)
    }
    got := clone_rows(hl_rows(&a, &live))

    ref: edit.Buffer
    defer edit.buffer_destroy(&ref)
    edit.buffer_set_text(&ref, txt.doc_string(&live.doc, context.temp_allocator))
    ref.path = strings.clone("stress.cpp")
    want := hl_rows(&a, &ref)
    expect_rows_equal(t, got, want, "cpp typed run")
}
