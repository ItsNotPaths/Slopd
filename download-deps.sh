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
echo "==> tree-sitter (runtime parser lib for syntax highlighting; static lib)"
# The tree-sitter C runtime (parser engine), pinned to a release tag for
# reproducibility. Per-language GRAMMARS are NOT vendored here — they install at
# runtime via `slopd --grammar` (git clone + cc the parser to grammars/<lang>.so).
# This vendors only the engine the editor links against (Odin foreign import). Its
# whole runtime is the lib/src/lib.c amalgamation, so — like libvterm — we compile
# that one file straight to libtree-sitter.a with cc + ar, no Makefile needed.
TS_VERSION="v0.26.9"
TS_SRC="$VENDOR/tree-sitter"
TS_A="$TS_SRC/.libs/libtree-sitter.a"
if [ -f "$TS_A" ]; then
    echo "  already present: libtree-sitter.a"
else
    if [ ! -d "$TS_SRC" ] || [ -z "$(ls -A "$TS_SRC" 2>/dev/null)" ]; then
        echo "  cloning tree-sitter $TS_VERSION..."
        git clone --depth=1 --branch "$TS_VERSION" "https://github.com/tree-sitter/tree-sitter.git" "$TS_SRC"
    fi
    echo "  building static libtree-sitter.a..."
    (
        cd "$TS_SRC"
        mkdir -p .libs
        cc -c -O2 -fPIC -Ilib/include -Ilib/src lib/src/lib.c -o lib.o
        ar rcs .libs/libtree-sitter.a lib.o
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
echo "==> Hack font (bundled default, from Source Foundry)"
# The editor embeds Hack-Regular.ttf at build time (#load). Fetched from the
# canonical Source Foundry release, not the local system, for reproducibility.
fetch "Hack" \
    "https://github.com/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.tar.gz" \
    "$VENDOR/fonts" 1 "ttf/Hack-Regular.ttf"

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
