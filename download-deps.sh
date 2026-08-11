#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

echo "==> libvterm (leonerd's, the editor-standard parser; static lib)"
# leonerd's libvterm (neovim mirror): a pure VT state machine — no PTY, no curses,
# no I/O. We feed it bytes and read out a cell grid, owning the PTY + rendering
# ourselves (fits Slopd's GPU glyph grid). It's a handful of dependency-free .c
# files, so we compile them straight to libvterm.a with cc + ar rather than its
# libtool-based Makefile — no extra build tooling, same single-binary story as glfw.
VTERM_SRC="$VENDOR/libvterm"
VTERM_A="$VTERM_SRC/.libs/libvterm.a"
if [ -f "$VTERM_A" ]; then
    echo "  already present: libvterm.a"
else
    if [ ! -d "$VTERM_SRC" ] || [ -z "$(ls -A "$VTERM_SRC" 2>/dev/null)" ]; then
        echo "  cloning libvterm..."
        git clone --depth=1 "https://github.com/neovim/libvterm.git" "$VTERM_SRC"
    fi
    # Apply Slopd's local patches (vendor/ is gitignored, so the fix lives in patches/
    # and is re-applied on every fresh fetch). --forward skips already-applied hunks so
    # re-running this script is idempotent. See each patch's header for the why.
    for p in "$VENDOR"/../patches/libvterm-*.patch; do
        [ -e "$p" ] || continue
        echo "  applying $(basename "$p")..."
        patch -p1 --forward -r - -d "$VTERM_SRC" < "$p" || true
    done
    echo "  building static libvterm.a..."
    (
        cd "$VTERM_SRC"
        mkdir -p .libs
        cc -c -O2 -fPIC -Iinclude -Isrc src/*.c
        ar rcs .libs/libvterm.a ./*.o
        rm -f ./*.o
    )
    echo "  done."
fi

echo ""
echo "==> tree-sitter (Odin bindings + runtime parser lib for syntax highlighting)"
# Syntax highlighting links the tree-sitter C runtime through laytan/odin-tree-sitter
# (MIT) — complete, maintained Odin foreign bindings — pinned to a commit. Its foreign
# import expects tree-sitter/libtree-sitter.a beside the bindings, so we clone the
# tree-sitter C source (pinned tag) into that subdir and compile its lib.c amalgamation
# to the .a there (cc + ar, no Makefile — like libvterm). We use ONLY the engine
# bindings: Slopd owns grammar install (`slopd --grammar`) + runtime dlopen, so the
# bindings' own grammar-build machinery (build/, per-grammar binding generation) goes
# unused. Per-language GRAMMARS are NOT vendored — they install at runtime.
TS_VERSION="v0.26.9"
TS_BINDINGS_REV="8a33ed2be99736437c00df98cb26e01c2a772b61"
OTS_SRC="$VENDOR/odin-tree-sitter"
TS_SRC="$OTS_SRC/tree-sitter"          # where the bindings' foreign import looks
TS_A="$TS_SRC/libtree-sitter.a"
if [ -f "$TS_A" ] && [ -f "$OTS_SRC/bindings.odin" ]; then
    echo "  already present: odin-tree-sitter + libtree-sitter.a"
else
    if [ ! -f "$OTS_SRC/bindings.odin" ]; then
        echo "  cloning odin-tree-sitter bindings (pinned $TS_BINDINGS_REV)..."
        rm -rf "$OTS_SRC"
        git clone --depth=1 "https://github.com/laytan/odin-tree-sitter.git" "$OTS_SRC"
        git -C "$OTS_SRC" fetch -q --depth 1 origin "$TS_BINDINGS_REV"
        git -C "$OTS_SRC" checkout -q "$TS_BINDINGS_REV"
    fi
    if [ ! -d "$TS_SRC/lib" ]; then
        echo "  cloning tree-sitter $TS_VERSION..."
        rm -rf "$TS_SRC"
        git clone --depth=1 --branch "$TS_VERSION" "https://github.com/tree-sitter/tree-sitter.git" "$TS_SRC"
    fi
    echo "  building static libtree-sitter.a (beside the bindings)..."
    (
        cd "$TS_SRC"
        cc -c -O2 -fPIC -Ilib/include -Ilib/src lib/src/lib.c -o lib.o
        ar rcs libtree-sitter.a lib.o
        rm -f lib.o
    )
    echo "  done."
fi

echo ""
echo "==> clay (immediate-mode layout + hit-test engine; static lib)"
# Clay is a single header (clay.h) that becomes a library only when one translation
# unit defines CLAY_IMPLEMENTATION — so we clone the repo (pinned commit) and emit a
# three-line clay.c that does exactly that, then compile it to libclay.a with cc + ar,
# no Makefile/CMake. Same story as libvterm and the tree-sitter runtime: a static
# archive under gitignored vendor/, reached by relative path from bindings/clay, so
# `odin build src` links it transitively.
#   -ffreestanding matches upstream's own build-clay-lib.sh: Clay allocates nothing and
#   calls no libc beyond memcpy, so it must not pick up hosted-environment assumptions.
# The ODIN BINDING is NOT downloaded — bindings/clay/clay.odin is a tracked verbatim
# copy of upstream's, and the two are one ABI pair: bump CLAY_REV and re-copy the
# binding together, never one alone (see that file's header).
CLAY_REV="e6cc36941ab2af5d81107617039d6f527a1c660b"  # main @ 2026-05-20; v0.14 is a year behind it
CLAY_SRC="$VENDOR/clay"
CLAY_A="$CLAY_SRC/libclay.a"
if [ -f "$CLAY_A" ]; then
    echo "  already present: libclay.a"
else
    if [ ! -f "$CLAY_SRC/clay.h" ]; then
        echo "  cloning clay (pinned $CLAY_REV)..."
        rm -rf "$CLAY_SRC"
        git clone -q "https://github.com/nicbarker/clay.git" "$CLAY_SRC"
        git -C "$CLAY_SRC" checkout -q "$CLAY_REV"
    fi
    echo "  building static libclay.a..."
    (
        cd "$CLAY_SRC"
        printf '#define CLAY_IMPLEMENTATION\n#include "clay.h"\n' > clay.c
        cc -c -O2 -fPIC -ffreestanding clay.c -o clay.o
        ar rcs libclay.a clay.o
        rm -f clay.o clay.c
    )
    echo "  done."
fi

echo ""
echo "==> glfw (static lib for release builds)"
# Release builds link glfw statically (-define:GLFW_SHARED=false) so users don't
# need libglfw installed. Void only ships the .so, so we build libglfw3.a from
# source. OpenGL is NOT built/linked here: it's loaded at runtime from the
# system GPU driver via gl.load_up_to(), so there is nothing to vendor for GL.
GLFW_VERSION="3.4"
GLFW_SRC="$VENDOR/glfw-src"
GLFW_A="$VENDOR/glfw/libglfw3.a"          # project-local copy (cache / record)
ODIN_ROOT="$(odin root)"                    # e.g. /root/.local/odin/
ODIN_GLFW_A="${ODIN_ROOT%/}/vendor/glfw/lib/libglfw3.a"  # where Odin's bindings look

if [ -f "$GLFW_A" ] && [ -f "$ODIN_GLFW_A" ]; then
    echo "  already present: libglfw3.a"
else
    if [ ! -f "$GLFW_A" ]; then
        if [ ! -d "$GLFW_SRC" ] || [ -z "$(ls -A "$GLFW_SRC" 2>/dev/null)" ]; then
            echo "  downloading glfw $GLFW_VERSION source..."
            mkdir -p "$GLFW_SRC"
            curl -fsSL "https://github.com/glfw/glfw/archive/refs/tags/${GLFW_VERSION}.tar.gz" \
                | tar xz --strip-components=1 -C "$GLFW_SRC"
        fi
        echo "  building static libglfw3.a..."
        cmake -S "$GLFW_SRC" -B "$GLFW_SRC/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DGLFW_BUILD_EXAMPLES=OFF \
            -DGLFW_BUILD_TESTS=OFF \
            -DGLFW_BUILD_DOCS=OFF >/dev/null
        cmake --build "$GLFW_SRC/build" --parallel >/dev/null
        mkdir -p "$(dirname "$GLFW_A")"
        cp "$GLFW_SRC/build/src/libglfw3.a" "$GLFW_A"
    fi
    # Stock Odin bindings hard-code the path ../lib/libglfw3.a relative to the
    # bindings package, so the archive must live inside the Odin install tree.
    echo "  installing into Odin tree: $ODIN_GLFW_A"
    mkdir -p "$(dirname "$ODIN_GLFW_A")"
    cp "$GLFW_A" "$ODIN_GLFW_A"
    echo "  done."
fi

echo ""
echo "==> stb (truetype static lib for the glyph renderer)"
# Odin ships the stb bindings but only prebuilt wasm/darwin objects; the Linux
# static lib is built from the C source that ships with Odin. Self-contained,
# no external deps — same single-binary story as the static glfw build.
STB_TT_A="${ODIN_ROOT%/}/vendor/stb/lib/stb_truetype.a"
if [ -f "$STB_TT_A" ]; then
    echo "  already present: stb_truetype.a"
else
    echo "  building stb static libs..."
    # Odin replaced src/Makefile with build_stb.sh; older installs still ship the
    # Makefile, so take whichever this tree has. Both write ../lib/stb_truetype.a.
    STB_SRC="${ODIN_ROOT%/}/vendor/stb/src"
    if [ -f "$STB_SRC/build_stb.sh" ]; then
        sh "$STB_SRC/build_stb.sh" unix >/dev/null
    else
        make -C "$STB_SRC" >/dev/null
    fi
    echo "  done."
fi

echo ""
echo "==> Iosevka Fixed font (bundled default, SIL OFL 1.1)"
# The editor embeds IosevkaFixed-Latin.ttf at build time (#load). Iosevka Fixed has no
# ligatures and a strictly uniform advance, so every glyph lands on Slopd's fixed cell
# grid. Fetched from the canonical upstream release for reproducibility. Two wrinkles:
#   - The PkgTTF asset is a .zip (not .tar.gz, so the tar-based fetch() can't take it)
#     and bundles every weight; we pull out just the Regular face with python3's
#     zipfile (already required for the language registry; avoids depending on unzip).
#   - The upstream TTF carries ~38k glyphs (~8.9MB), most of them CJK and unreachable
#     stylistic variants we never show. We subset to the symbol set a terminal actually
#     needs — Latin, punctuation, arrows, math, box-drawing, block elements, geometric
#     shapes, Braille, technical and Powerline glyphs — so any TUI (Claude Code, Helix,
#     …) draws its borders, cursors and spinners. That is ~220KB, and since font.odin
#     `#load`s this file the difference is the binary's: 10.5MB full vs 1.9MB subset.
#     Ranges are generous; fontTools keeps only codepoints the font actually has.
# fontTools stays optional — without it we embed the full face and the build still works
# — but the fallback must not be STICKY, which is the bug this shape fixes: the presence
# check now tests for the SUBSET (by size), not merely for a file, and the full face is
# cached beside it, so installing fontTools and re-running subsets in place instead of
# silently keeping a 10.5MB binary forever. src/tests/font_test.odin asserts the ceiling.
IOSEVKA_VERSION="34.6.1"
IOSEVKA_TTF="$VENDOR/fonts/IosevkaFixed-Latin.ttf"
IOSEVKA_FULL="$VENDOR/fonts/IosevkaFixed-Regular-full.ttf" # kept only while still un-subset
IOSEVKA_SUBSET_MAX=1048576                                 # subset ~220KB, full ~8.9MB
if [ -f "$IOSEVKA_TTF" ] && [ "$(wc -c <"$IOSEVKA_TTF")" -lt "$IOSEVKA_SUBSET_MAX" ]; then
    echo "  already present: IosevkaFixed-Latin.ttf (subset)"
else
    mkdir -p "$VENDOR/fonts"
    # Get the full face: reuse the cache, or promote an earlier un-subset embed, before
    # paying for the 130MB download again.
    if [ ! -f "$IOSEVKA_FULL" ]; then
        if [ -f "$IOSEVKA_TTF" ]; then
            echo "  found a full (un-subset) font from an earlier run — re-subsetting it"
            mv "$IOSEVKA_TTF" "$IOSEVKA_FULL"
        else
            echo "  downloading Iosevka Fixed (large: the PkgTTF zip is ~130MB)..."
            iosevka_zip="$(mktemp --suffix=.zip)"
            curl -fsSL \
                "https://github.com/be5invis/Iosevka/releases/download/v${IOSEVKA_VERSION}/PkgTTF-IosevkaFixed-${IOSEVKA_VERSION}.zip" \
                -o "$iosevka_zip"
            python3 - "$iosevka_zip" "$IOSEVKA_FULL" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
matches = [n for n in z.namelist() if n.endswith("IosevkaFixed-Regular.ttf")]
if len(matches) != 1:
    sys.exit(f"expected exactly one IosevkaFixed-Regular.ttf in the zip, found {matches}")
with open(dst, "wb") as f:
    f.write(z.read(matches[0]))
PY
            rm -f "$iosevka_zip"
        fi
    fi
    if python3 -c "import fontTools.subset" 2>/dev/null; then
        echo "  subsetting to the terminal symbol set (fontTools)..."
        # Latin + punctuation + Greek; superscripts/currency/letterlike/number-forms;
        # arrows, math, technical, control pictures; box-drawing, blocks, geometric
        # shapes; misc symbols, dingbats, math-A, supplemental arrows; Braille; misc
        # symbols-and-arrows; Powerline (PUA). Generous — subset keeps only what exists.
        python3 -m fontTools.subset "$IOSEVKA_FULL" \
            --unicodes=U+0020-007E,U+00A0-024F,U+0370-03FF,U+2000-206F,U+2070-209F,U+20A0-20BF,U+2100-218F,U+2190-21FF,U+2200-22FF,U+2300-23FF,U+2400-243F,U+2500-257F,U+2580-259F,U+25A0-25FF,U+2600-26FF,U+2700-27BF,U+27C0-27EF,U+27F0-27FF,U+2800-28FF,U+2900-297F,U+2B00-2BFF,U+E0A0-E0D4 \
            --layout-features='' \
            --no-hinting \
            --name-IDs='*' \
            --recommended-glyphs \
            --output-file="$IOSEVKA_TTF"
        echo "  subset: $(wc -c <"$IOSEVKA_FULL") -> $(wc -c <"$IOSEVKA_TTF") bytes"
        rm -f "$IOSEVKA_FULL" # subset succeeded: nothing left to re-subset from
    else
        cp "$IOSEVKA_FULL" "$IOSEVKA_TTF" # keep the cache: re-running is then free
        echo "  WARNING: fontTools not found — embedding the FULL ~8.9MB font, which makes" >&2
        echo "  the binary ~10.5MB instead of ~1.9MB. Install it and re-run this script to" >&2
        echo "  subset in place (no re-download):" >&2
        echo "    python3 -m pip install fonttools   # or your distro's python3-fonttools" >&2
    fi
    echo "  done."
fi

echo ""
echo "==> file-type icons (Symbols Nerd Font Mono, subset — Seti-UI + Devicons)"
# The file browser (`file_pane: browser`) draws a per-type icon per row and per tile. Those
# icons are GLYPHS, baked into the same atlas as the text from a second embedded face, so
# there is no icon cache, no image decode and no second texture — see font.odin.
#
# We take two whole PUA blocks rather than a curated list: Seti-UI (U+E5FA-E6B7, the file-type
# set from the Seti editor theme, plus Nerd Fonts' own `custom-` folder/default glyphs) and
# Devicons (U+E700-E7C5, the language and tool logos). BOTH ARE MIT — deliberately, so the
# embed carries one licence note; Font Awesome, Material and Codicons are CC-BY/Apache and are
# left out, as are Octicons, which would push this past the size line below for glyphs the
# other two already cover. Taking whole blocks is what lets src/icons.odin's ext -> icon table
# grow later without re-running this script.
#
# ~174KB for 391 glyphs, against 2.5MB for the full face. Unlike Iosevka, this font is
# OPTIONAL: without fontTools we embed nothing at all and the browser falls back to its plain
# coloured tiles, because a 2.5MB icon font in a 2.2MB binary is not a fallback anyone wants.
NERD_VERSION="3.4.0"
ICONS_TTF="$VENDOR/fonts/SymbolsNerdFont-Icons.ttf"
ICONS_FULL="$VENDOR/fonts/SymbolsNerdFontMono-Regular-full.ttf"
ICONS_SUBSET_MAX=262144 # 256KB: the subset is ~173KB, the full face 2.5MB
# Seti-UI, then Devicons' first block, then three named Devicons glyphs from ABOVE it. The
# rest of Devicons (U+E7C6-E8EF) is another ~300 brand logos — aws, bower, chrome — that no
# file type maps to, and taking it would cost 344KB instead of 174KB. Adding a fourth
# exception later is a one-line edit here plus a re-run.
ICONS_RANGES="U+E5FA-E6B7,U+E700-E7C5,U+E80B,U+E843,U+E8EB" # +json, +nixos, +yaml
if [ -f "$ICONS_TTF" ] && [ -s "$ICONS_TTF" ] && [ "$(wc -c <"$ICONS_TTF")" -lt "$ICONS_SUBSET_MAX" ]; then
    echo "  already present: SymbolsNerdFont-Icons.ttf (subset)"
else
    mkdir -p "$VENDOR/fonts"
    if [ ! -f "$ICONS_FULL" ]; then
        echo "  downloading Symbols Nerd Font ($NERD_VERSION)..."
        icons_zip="$(mktemp --suffix=.zip)"
        curl -fsSL \
            "https://github.com/ryanoasis/nerd-fonts/releases/download/v${NERD_VERSION}/NerdFontsSymbolsOnly.zip" \
            -o "$icons_zip"
        python3 - "$icons_zip" "$ICONS_FULL" <<'ICONPY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
matches = [n for n in z.namelist() if n.endswith("SymbolsNerdFontMono-Regular.ttf")]
if len(matches) != 1:
    sys.exit(f"expected exactly one SymbolsNerdFontMono-Regular.ttf in the zip, found {matches}")
with open(dst, "wb") as f:
    f.write(z.read(matches[0]))
ICONPY
        rm -f "$icons_zip"
    fi
    if python3 -c "import fontTools.subset" 2>/dev/null; then
        echo "  subsetting to Seti-UI + Devicons (fontTools)..."
        python3 -m fontTools.subset "$ICONS_FULL" \
            --unicodes="$ICONS_RANGES" \
            --layout-features='' \
            --no-hinting \
            --name-IDs='*' \
            --recommended-glyphs \
            --output-file="$ICONS_TTF"
        echo "  subset: $(wc -c <"$ICONS_FULL") -> $(wc -c <"$ICONS_TTF") bytes"
        rm -f "$ICONS_FULL"
    else
        # An EMPTY file, not the full face: font.odin #loads this unconditionally, and an empty
        # slice is exactly how it is told "there are no icons" (icons_ok stays false and the
        # browser draws its plain tiles). src/tests/font_test.odin asserts the ceiling.
        : >"$ICONS_TTF"
        echo "  WARNING: fontTools not found — file-type icons are DISABLED (the browser falls" >&2
        echo "  back to plain coloured tiles). Install it and re-run to enable them:" >&2
        echo "    python3 -m pip install fonttools   # or your distro's python3-fonttools" >&2
    fi
    echo "  done."
fi

echo ""
echo "==> language registry (parsed down from Helix's languages.toml)"
# Slopd's tree-sitter language set follows Helix: tools/gen-languages.py fetches
# Helix's languages.toml (pinned) and relabels it into our tiny `languages` file
# (name + grammar repo/rev/subpath + file extensions). Generated, but COMMITTED —
# src/grammar.odin #loads it into the binary, and #load resolves at compile time,
# so a fresh clone has to build without ever running this script. This step is a
# refresh, not a bootstrap. Grammars themselves are NOT fetched here — they install
# at runtime via `slopd --grammar`. Bump HELIX_REF and re-run to update the set.
ROOT="$(dirname "$VENDOR")"
if python3 "$ROOT/tools/gen-languages.py" "$ROOT/languages"; then
    :
else
    echo "  WARNING: language registry refresh failed (need python3 + network);" >&2
    echo "  the committed languages file is kept, so the build still works." >&2
fi

echo ""
echo "All deps ready."
