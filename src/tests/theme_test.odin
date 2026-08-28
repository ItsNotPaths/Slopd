package tests

import "core:testing"
import "../gfx"

@(test)
test_parse_hex_color :: proc(t: ^testing.T) {
    c, ok := gfx.parse_hex_color("#ff8000")
    testing.expect(t, ok)
    testing.expect(t, c == [3]f32{1.0, f32(0x80) / 255, 0.0})

    c2, ok2 := gfx.parse_hex_color("d4be98") // no leading '#'
    testing.expect(t, ok2)
    testing.expect(t, c2 == [3]f32{f32(0xd4) / 255, f32(0xbe) / 255, f32(0x98) / 255})

    _, bad := gfx.parse_hex_color("nope")
    testing.expect(t, !bad)
}

@(test)
test_parse_theme :: proc(t: ^testing.T) {
    th: gfx.Theme
    gfx.parse_theme("# a comment\nbg: #292828\nfg:#d4be98\nbogus: #112233\naccent:  #9253be\n", &th)
    testing.expect(t, th.bg == [3]f32{f32(0x29) / 255, f32(0x28) / 255, f32(0x28) / 255})
    testing.expect(t, th.fg == [3]f32{f32(0xd4) / 255, f32(0xbe) / 255, f32(0x98) / 255})
    testing.expect(t, th.accent == [3]f32{f32(0x92) / 255, f32(0x53) / 255, f32(0xbe) / 255})
    // unknown key "bogus" is ignored (no crash, nothing set)
}

@(test)
test_default_theme :: proc(t: ^testing.T) {
    // The baked-in default is parsed from the embedded default.theme.
    dt := gfx.default_theme()
    testing.expect(t, dt.bg == [3]f32{f32(0x29) / 255, f32(0x28) / 255, f32(0x28) / 255})
    testing.expect(t, dt.code_keyword == [3]f32{f32(0xd3) / 255, f32(0x86) / 255, f32(0x9b) / 255})
}
