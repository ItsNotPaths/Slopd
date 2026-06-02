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
    make -C "${ODIN_ROOT%/}/vendor/stb/src" >/dev/null
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
#   - The upstream TTF carries thousands of CJK/symbol glyphs (~9MB), but Slopd only
#     bakes printable ASCII, so we subset it to U+0020-007E with fontTools (~12KB)
#     before embedding. fontTools is optional: without it we fall back to the full
#     font (the build still works, just a far larger binary) and print how to get it.
IOSEVKA_VERSION="34.6.1"
IOSEVKA_TTF="$VENDOR/fonts/IosevkaFixed-Latin.ttf"
if [ -f "$IOSEVKA_TTF" ]; then
    echo "  already present: IosevkaFixed-Latin.ttf"
else
    echo "  downloading Iosevka Fixed (large: the PkgTTF zip is ~130MB)..."
    mkdir -p "$VENDOR/fonts"
    iosevka_zip="$(mktemp --suffix=.zip)"
    iosevka_full="$(mktemp --suffix=.ttf)"
    curl -fsSL \
        "https://github.com/be5invis/Iosevka/releases/download/v${IOSEVKA_VERSION}/PkgTTF-IosevkaFixed-${IOSEVKA_VERSION}.zip" \
        -o "$iosevka_zip"
    python3 - "$iosevka_zip" "$iosevka_full" <<'PY'
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
    # Subset to printable ASCII if fontTools is available; else ship the full font.
    if python3 -c "import fontTools.subset" 2>/dev/null; then
        echo "  subsetting to printable ASCII (fontTools)..."
        python3 -m fontTools.subset "$iosevka_full" \
            --unicodes=U+0020-007E \
            --layout-features='' \
            --no-hinting \
            --name-IDs='*' \
            --recommended-glyphs \
            --output-file="$IOSEVKA_TTF"
        rm -f "$iosevka_full"
    else
        echo "  WARNING: fontTools not found — embedding the FULL ~9MB font (the binary" >&2
        echo "  will be much larger). Install it and re-run to get the ~12KB subset:" >&2
        echo "    python3 -m pip install fonttools   # or your distro's python3-fonttools" >&2
        mv "$iosevka_full" "$IOSEVKA_TTF"
    fi
    echo "  done."
fi

echo ""
echo "==> language registry (parsed down from Helix's languages.toml)"
# Slopd's tree-sitter language set follows Helix: tools/gen-languages.py fetches
# Helix's languages.toml (pinned) and relabels it into our tiny `languages` file
# (name + grammar repo/rev/subpath + file extensions). GENERATED, never committed;
# it resolves beside the binary at runtime like themes/ and grammars/. For dev
# (`odin run`) that's the project root; release.sh regenerates it into the release
# folder. Grammars themselves are NOT fetched here — they install at runtime via
# `slopd --grammar`. Refresh by bumping HELIX_REF in the script and re-running.
ROOT="$(dirname "$VENDOR")"
if python3 "$ROOT/tools/gen-languages.py" "$ROOT/languages"; then
    :
else
    echo "  WARNING: language registry generation failed (need python3 + network);" >&2
    echo "  syntax highlighting will have no languages until it succeeds." >&2
fi

echo ""
echo "All deps ready."
