#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$PROJECT_DIR/build"
# The binary is `slopd`, not the folder's name: lower case, because it is what you type. It is
# also the app-id the window reports (APP_ID in src/main.odin), the name `--install` writes to
# ~/.local/bin, and the name slopd.desktop calls in Exec. One spelling, everywhere.
BIN_NAME="slopd"

usage() {
    cat <<EOF
usage: $(basename "$0") [--local] [--public --version vX.Y.Z [--notes "text"]]

  --local               build locally into build/ inside the project (gitignored)
  --public              trigger release.yml workflow via gh CLI
  --version <tag>       required when --public is used
  --notes <text>        optional release notes
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --notes)   NOTES="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage
    exit 1
fi

if [ $DO_LOCAL -eq 1 ]; then
    echo "==> Local build: $BIN_NAME -> $RELEASE_DIR"
    # Empty the folder rather than replacing it. A rebuilt directory is a NEW directory:
    # a shell sitting in it lands on a deleted inode, and anything pointing at it (a file
    # manager tab, a symlink, a bookmark) has to be re-opened. -mindepth 1 spares the
    # folder itself; -delete is depth-first and takes dotfiles, which a `rm -rf dir/*`
    # glob would silently leave behind.
    mkdir -p "$RELEASE_DIR"
    find "$RELEASE_DIR" -mindepth 1 -delete
    # -define:GLFW_SHARED=false  -> link vendor/glfw/lib/libglfw3.a statically so
    # the shipped binary does not depend on a system libglfw. (OpenGL is always
    # loaded at runtime from the GPU driver; there is nothing to link for it.)
    # Requires ./download-deps.sh to have built the static archive first.
    # SLOPD_VERSION stamps `slopd --version`; a local build is not a tagged one, so it
    # says so rather than claiming a release number.
    odin build "$PROJECT_DIR/src" -out:"$RELEASE_DIR/$BIN_NAME" \
        -o:speed -define:GLFW_SHARED=false -define:SLOPD_VERSION="dev-local"
    # ~150KB of a ~1.9MB binary is .symtab/.strtab. A -o:speed build carries no .debug_*
    # sections to begin with, so --strip-all costs no debuggability that this build had.
    # release.yml already strips; do it here too so a local build matches the download.
    strip --strip-all "$RELEASE_DIR/$BIN_NAME"
    # The release is the BINARY plus its config, and nothing else. The language registry,
    # the default theme, the README and the LICENSE are all #load-ed into the executable
    # (`readme` / `license` in the command line open the last two). themes/ and grammars/
    # are user-added, created on first use — a language is installed from the Config pane
    # (cf) or `slopd --grammar install`, which keeps the dist tiny. This folder is a
    # PORTABLE install: it runs from here, files beside the binary, until `slopd --install`
    # copies it to ~/.local/bin and moves those files to the XDG folders (see install.odin).
    [ -f "$PROJECT_DIR/slopd.config" ]  && cp "$PROJECT_DIR/slopd.config"  "$RELEASE_DIR/" || true
    echo "==> Local done: $RELEASE_DIR"
fi

if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2
        exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2
        exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for i in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"
            break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2
        exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
