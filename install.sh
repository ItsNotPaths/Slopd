#!/usr/bin/env sh
#
# Slopd installer.
#
#   curl -fsSL https://github.com/ItsNotPaths/Slopd/releases/latest/download/install.sh | sh
#
# What it does, and NOTHING else:
#
#   1. downloads the release binary into ~/.local/bin/slopd
#   2. asks whether to add Slopd to your application list
#   3. on Omarchy, asks whether to add a Hyprland window rule
#
# It does NOT write a config file. Slopd runs on the defaults baked into the binary until
# you install it from inside the app — the Config pane's first row (`cf`, Enter), or
# `slopd --install` — which is what writes ~/.config/slopd/slopd.config and creates
# ~/.local/share/slopd/{themes,grammars}. That split is deliberate: this script puts a
# program on your PATH, and the program decides when to start owning files in your home.
#
# POSIX sh, not bash: this is run by whatever `sh` is, on a machine that has just met us.
#
# Flags (for a non-interactive run — CI, a dotfiles bootstrap):
#   --yes            take the default answer to every question, ask nothing
#   --no-desktop     skip the application list
#   --no-omarchy     skip the Omarchy window rule
#   --version <tag>  install that release instead of the latest

set -eu

REPO="ItsNotPaths/Slopd"
BIN_NAME="slopd"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/${BIN_NAME}"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

ASSUME_YES=0
WANT_DESKTOP=1
WANT_OMARCHY=1
REL_TAG="latest"

usage() {
    cat <<'EOF'
usage: install.sh [--yes] [--no-desktop] [--no-omarchy] [--version <tag>]

Downloads Slopd into ~/.local/bin, then asks about desktop integration.
It writes no config file — install from inside the app to get one.

  --yes, -y        take the default answer to every question, ask nothing
  --no-desktop     skip the application list
  --no-omarchy     skip the Omarchy window rule
  --version <tag>  install that release instead of the latest
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)     ASSUME_YES=1; shift ;;
        --no-desktop) WANT_DESKTOP=0; shift ;;
        --no-omarchy) WANT_OMARCHY=0; shift ;;
        --version)    REL_TAG="${2:-latest}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Ask a yes/no question, default yes. Reads from /dev/tty, NOT stdin: piped into `sh`, stdin
# IS this script, and a read from it would swallow the rest of the file. No tty (a CI run, a
# pipe with no terminal) takes the default, which is the only answer nobody is there to give.
ask() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -r /dev/tty ] || return 0
    printf '%s [Y/n] ' "$1" > /dev/tty
    read -r reply < /dev/tty || return 0
    case "$reply" in
        [nN]*) return 1 ;;
        *)     return 0 ;;
    esac
}

# --- what machine is this ---

# /etc/os-release's ID, and the family behind it. The family is used for ONE thing: naming
# the command that installs a missing curl, because "install curl" is a different sentence on
# every distribution. Nothing here installs a package on your behalf.
#
# The file is PARSED, not sourced. Sourcing it is the usual trick and it is wrong here: the
# file sets VERSION, NAME and a dozen other common names, and it would quietly overwrite
# whatever this script happens to call the same thing.
os_release_field() {
    [ -r /etc/os-release ] || return 0
    sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d '"'"'"
}

OS_ID="$(os_release_field ID)"
OS_LIKE="$(os_release_field ID_LIKE)"
[ -n "$OS_ID" ] || OS_ID="unknown"

os_family() {
    case " ${OS_ID} ${OS_LIKE} " in
        *" arch "*|*" archlinux "*|*" omarchy "*) echo arch ;;
        *" debian "*|*" ubuntu "*)                echo debian ;;
        *" fedora "*|*" rhel "*|*" centos "*)     echo fedora ;;
        *" suse "*|*" opensuse "*)                echo suse ;;
        *" alpine "*)                             echo alpine ;;
        *)                                        echo unknown ;;
    esac
}

pkg_hint() {
    case "$(os_family)" in
        arch)   echo "sudo pacman -S $1" ;;
        debian) echo "sudo apt install $1" ;;
        fedora) echo "sudo dnf install $1" ;;
        suse)   echo "sudo zypper install $1" ;;
        alpine) echo "sudo apk add $1" ;;
        *)      echo "install $1 with your package manager" ;;
    esac
}

ARCH="$(uname -m)"
[ "$(uname -s)" = "Linux" ] || die "Slopd is Linux only (this is $(uname -s))."
# One binary is published, and it is x86_64. Saying so beats downloading it and watching the
# kernel refuse to run it.
[ "$ARCH" = "x86_64" ] || die "no ${ARCH} build is published — build from source: https://github.com/${REPO}"

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "neither curl nor wget is installed. $(pkg_hint curl)"
fi

# --- 1. the binary ---

if [ "$REL_TAG" = "latest" ]; then
    URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"
else
    URL="https://github.com/${REPO}/releases/download/${REL_TAG}/${BIN_NAME}"
fi

say "Slopd  ·  ${OS_ID} ($(os_family)), ${ARCH}"
step "Downloading ${BIN_NAME} (${REL_TAG})"

mkdir -p "$BIN_DIR"
# Download to a staging file beside the target and rename over it. A rename is atomic, and it
# is the one way to replace a binary that may be RUNNING right now: writing in place fails
# with ETXTBSY, while the running process simply keeps the old inode until it exits.
STAGE="${BIN_PATH}.download.$$"
trap 'rm -f "$STAGE"' EXIT INT TERM
fetch "$URL" "$STAGE" || die "download failed: $URL"
[ -s "$STAGE" ] || die "downloaded an empty file from $URL"
chmod 755 "$STAGE"
mv -f "$STAGE" "$BIN_PATH"
trap - EXIT INT TERM

say "    ${BIN_PATH}   ($("$BIN_PATH" --version 2>/dev/null || echo 'installed'))"

# --- 2. the application list ---

if [ "$WANT_DESKTOP" -eq 1 ] && ask "Add Slopd to your application list?"; then
    step "Adding the launcher entry"
    "$BIN_PATH" --desktop add | sed 's/^/    /'
fi

# --- 3. Omarchy ---

# Omarchy's Hyprland config is Lua, and its user files are loaded after Omarchy's own defaults
# so a package update can improve those defaults without rewriting anything here. Slopd's rule
# gets its OWN file, required by one line in hyprland.lua: a whole file is removable, and a
# block appended into the middle of a config you edit by hand is not.
if [ "$OS_ID" = "omarchy" ] && [ "$WANT_OMARCHY" -eq 1 ] && [ -f "${HYPR_DIR}/hyprland.lua" ]; then
    say ""
    say "Omarchy detected. A window rule renders Slopd fully opaque — Omarchy fades every"
    say "window to 0.985/0.96 by default, which puts your wallpaper behind the syntax colours."
    if ask "Add it to ~/.config/hypr/?"; then
        step "Writing ${HYPR_DIR}/slopd.lua"
        cat > "${HYPR_DIR}/slopd.lua" <<'LUA'
-- Slopd. Written by install.sh; delete this file and the require() line in hyprland.lua to
-- undo it. See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
--
-- Fully opaque: Omarchy tags every window for its default 0.985/0.96 fade, and a text editor
-- is the wrong place for it — the wallpaper reads through the background the syntax colours
-- were chosen against. The tag has to come OFF as well as the opacity going on, because the
-- default rule is applied last, after this file has run.
o.window({ class = "^slopd$" }, { tag = "-default-opacity", opacity = "1 1" })

-- Deliberately NOT tagged "+terminal", even though Slopd hosts real terminals. That tag makes
-- Omarchy's universal SUPER+C send Ctrl+Insert, which is a terminal's copy chord and not
-- Slopd's. Untagged, SUPER+C arrives as a plain Ctrl+C — which is copy in the editor, and
-- copy in a terminal pane too once `term_ctrl_c: copy` is set. `slopd --install` writes that
-- line into your config for you on Omarchy.
LUA
        if ! grep -q 'require("hypr.slopd")' "${HYPR_DIR}/hyprland.lua"; then
            cp "${HYPR_DIR}/hyprland.lua" "${HYPR_DIR}/hyprland.lua.bak.$(date +%s)"
            printf '\n-- Slopd window rule (added by its installer).\nrequire("hypr.slopd")\n' \
                >> "${HYPR_DIR}/hyprland.lua"
            say "    required from hyprland.lua (backed up alongside it)"
        fi
        command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
    fi
fi

# --- what is left to do ---

say ""
step "Done"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) say "    Run it:  ${BIN_NAME}" ;;
    *)
        say "    ${BIN_DIR} is not on your PATH. Add it:"
        say "        export PATH=\"${BIN_DIR}:\$PATH\""
        say "    Until then, run it as:  ${BIN_PATH}"
        ;;
esac

say ""
say "    Slopd is running on the defaults inside the binary. To get a config file you can"
say "    edit, install it from the app: open the Config pane (\`cf\`), Enter on the first"
say "    row, and choose install. That writes:"
say "        ~/.config/slopd/slopd.config"
say "        ~/.local/share/slopd/{themes,grammars}"
