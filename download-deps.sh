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

echo "==> libvterm"
if [ -d "$VENDOR/libvterm" ] && [ -n "$(ls -A "$VENDOR/libvterm" 2>/dev/null)" ]; then
    echo "  already present: libvterm"
else
    echo "  cloning libvterm..."
    git clone --depth=1 "https://github.com/TragicWarrior/libvterm.git" "$VENDOR/libvterm"
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
echo "All deps ready."
