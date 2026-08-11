package tests

import app ".."
import "core:c"
import "core:fmt"
import "core:testing"
import stbtt "vendor:stb/truetype"

// The embedded default font, measured rather than assumed.
//
// font.odin `#load`s vendor/fonts/IosevkaFixed-Latin.ttf straight into the binary, so
// whatever download-deps.sh leaves in vendor/ IS the shipped payload. That script subsets
// the ~8.9MB upstream face down to the terminal symbol set, but the subset needs fontTools;
// without it the script falls back to the FULL font, and because it skips the download when
// the file already exists, the fallback is sticky — nothing later notices. That is how the
// binary silently sat at 10.5MB with 8.9MB of unreachable CJK in it.
//
// Two assertions, because the fix has two ways to regress: a SIZE ceiling (catches the full
// font sneaking back in) and a COVERAGE floor (catches a subset trimmed too aggressively,
// which would cost the box-drawing and Powerline glyphs a TUI needs). Both are bounds with
// margin, not exact figures — the measured size is printed so drift stays visible.

// Comfortably above the ~217KB subset, far below the ~8.9MB full face.
@(private = "file")
FONT_SIZE_CEILING :: 1 << 20

@(test)
test_embedded_font_is_subset :: proc(t: ^testing.T) {
	n := len(app.IOSEVKA_TTF)
	fmt.printfln("embedded font: %d bytes (ceiling %d)", n, FONT_SIZE_CEILING)
	testing.expectf(
		t,
		n < FONT_SIZE_CEILING,
		"embedded font is %d bytes: download-deps.sh shipped the un-subset face (needs fontTools)",
		n,
	)
}

// One codepoint per block font.odin's subset ranges promise, named so a failure says which
// block went missing rather than just a number.
@(private = "file")
COVERAGE := [?]struct {
	r:     rune,
	block: string,
}{
	{'A', "ASCII"},
	{'é', "Latin-1 Supplement"},
	{'λ', "Greek"},
	{'…', "General Punctuation"},
	{'€', "Currency Symbols"},
	{'→', "Arrows"},
	{'∑', "Mathematical Operators"},
	{'⌘', "Miscellaneous Technical"},
	{'␉', "Control Pictures"},
	{'─', "Box Drawing"},
	{'█', "Block Elements"},
	{'●', "Geometric Shapes"},
	{'★', "Miscellaneous Symbols"},
	{'✔', "Dingbats"},
	{'⣿', "Braille"},
	{'⬤', "Misc Symbols and Arrows"},
	{'', "Powerline (PUA)"},
}

@(test)
test_embedded_font_covers_terminal_symbols :: proc(t: ^testing.T) {
	info: stbtt.fontinfo
	if !testing.expect(t, bool(stbtt.InitFont(&info, raw_data(app.IOSEVKA_TTF), 0)), "font failed to parse") {
		return
	}
	for c in COVERAGE {
		testing.expectf(
			t,
			stbtt.FindGlyphIndex(&info, c.r) != 0,
			"embedded font lacks U+%04X (%s) — subset ranges dropped a block a TUI draws with",
			int(c.r),
			c.block,
		)
	}
}

// Iosevka Fixed is strictly monospace and font.odin leans on that: it measures 'M' once and
// steps every cell by that width, so a face whose advances disagree would drift ±1px a cell.
@(test)
test_embedded_font_is_monospace :: proc(t: ^testing.T) {
	info: stbtt.fontinfo
	if !testing.expect(t, bool(stbtt.InitFont(&info, raw_data(app.IOSEVKA_TTF), 0)), "font failed to parse") {
		return
	}
	want, lsb: c.int
	stbtt.GetCodepointHMetrics(&info, 'M', &want, &lsb)
	testing.expect(t, want > 0, "'M' has no advance")
	for r in rune('!') ..= rune('~') {
		advance: c.int
		stbtt.GetCodepointHMetrics(&info, r, &advance, &lsb)
		testing.expectf(t, advance == want, "advance for %q is %d, want %d (not monospace)", r, advance, want)
	}
}
