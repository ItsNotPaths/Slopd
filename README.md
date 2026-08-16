# Slopd

A GPU text editor in [Odin](https://odin-lang.org): two panes, a command line, no modes.
iTree-sitter highlighting, real PTY terminals, an image viewer, one static ~1.9MB binary.
Linux, OpenGL 3.3.

![Slopd](imgs/hero.png)

## Build

```sh
./download-deps.sh                 # vendors glfw, libvterm, tree-sitter, the font + icons
odin build src -out:slopd -define:GLFW_SHARED=false
./release.sh --local               # or: stripped -o:speed build into build/
```

| | |
|---|---|
| **main surfaces** | `Text` (the buffer ring) · `Image` (the media viewer) |
| **aux modes** | `FileTree` (as an `ls` listing or a file browser) · `Terminal` · `Config` · `Grep` |
| **views** | `Split` both panes · `Zen` full-width editor, aux slides in while focused · `Full` one surface fills the window |

Views are toggled from the command line: `:zen`/`:zm`, `:full`/`:fm`, `:normal`/`:nm`. `Esc` with
nothing to cancel turns Zen on and flips which side is shown.

## Keys

Non-modal / Alt-rooted: bare keys type, arrows navigate, chords live under Alt.

| | |
|---|---|
| `Alt+Left/Right`, `Alt+E` | focus editor / aux |
| `Alt+F` `Alt+T` `Alt+R` | aux mode: filetree, terminal, grep results |
| `Alt+C` `Alt+;` | command line: a shell line · the same line with the builtin `:` typed |
| `Alt+W` | open it pre-filled with `:j `, ready for a line number |
| `Alt+Enter` | editor: follow the token under the caret (def / URL / `[[file]]` / colour) · filetree: `:cd` to the folder |
| `Shift+Enter` | filetree: open in the desktop app, or stage a runnable's command |
| `Alt+1..9`, `Alt+Up/Down` | terminal session N / prev / next (switcher shows while Alt is held) |
| `Alt+N` `Alt+Q` `Alt+L` | terminal: new · close · lock its cwd |
| `Ctrl+Alt+Up/Down`, `PageUp/Down` | terminal copy cursor (`Shift+Alt+Up/Down` extends, `Ctrl+Shift+C` copies) |
| `Alt+G` | hand the project root to the configured git tool |
| `Alt+A` + arrow | drop a multi-cursor trail (`Alt+M` = next motion moves all, `Esc` collapses) |
| `Ctrl+Up/Down` | jump `jump_lines` lines · `Ctrl+Enter` fold/unfold the block |
| `Alt+[` `Alt+]` | nudge the split · `Ctrl+=` `Ctrl+-` `Ctrl+0` font zoom |
| `Ctrl+S/Z/Y/C/X/V` | save, undo, redo, clipboard |

Filetree file ops are `Ctrl` chords (`^y` mark, `^u` unmark all, `^c` copy, `^x` cut, `^v`
paste, `^d` delete, `^w` path, `^h` set the workspace to the browsed folder — `:cd` plus `:tu` in
one keystroke); hold `Ctrl` for the cheat-sheet bar, or **right-click** for the same list as
buttons. Copy and cut act on the marked set, or on the row under the cursor when nothing is
marked, and paste applies it to the folder you are browsing.

The mouse is purely additive: everything it reaches has a key binding, so `mouse: off` costs no
capability. Typing stands the pointer down.

## File browser

`file_pane: browser` gives the filetree pane a second face — a top bar of square buttons
`[◀] [▶] [⟳]`, a path bar whose segments are buttons, a places sidebar, and contents as a list
or a grid of tiles. **The listing underneath is the same one**: the same entries, marks,
clipboard and `Ctrl` chords, so this is a choice of presentation and never of capability.

| | |
|---|---|
| `^←` `^→` `^r` | history back / forward · reload — the three square buttons |
| `^g` | list ⇄ grid (the toggle button; `file_view` persists it) |
| `^1`..`^9` | open the sidebar's Nth place |
| `Backspace` | up a directory — and the only way out of a grid, where `←`/`→` step a tile |
| click the path's empty space | the path bar becomes a text line — type or paste a folder |
| right-click | the file-ops menu, at the pointer; on empty space it acts on the folder (paste, set workspace here) |

## Command line

`Alt+C` opens it, and what you type is a **shell** command, run in a terminal session. A Slopd
**builtin** is asked for by name with a leading `:` — `grep foo` is the program, `:grep foo` is
the project search in the Grep pane. `Alt+;` opens the line with the `:` already typed.

A submitted line is an `&&` chain of both kinds, mixed: shell steps run in a terminal session and
the chain waits on each exit code, builtins run inside Slopd. `rm -rf old && :ls` is the shell's
delete followed by our listing refresh — the line `^d` stages for you. Text staged by a UI
gesture renders in the alert colour until you touch it.

| | |
|---|---|
| `:tN` | send this line's shell parts to session N (`:t2 make`) · alone, a goto |
| `:j` / `:jump` | `:j 40`, `:j +5`, `:j file`, `:j file 40` |
| `:grep <re>` | project-wide search into the Grep pane |
| `:cd [dir]` | set the project root · `:tu` syncs unlocked terminals |
| `:ls` `:cf` `:gs` | filetree (also: refresh) · config pane · git tool |
| `:put [text]` | type text + the editor selection into the target terminal, no newline |
| `:reload y\|n` | answer a disk-conflict prompt |
| `:readme` `:license` | open the embedded docs |
| `:zen` `:full` `:normal` | view arrangement |
| `:w :wa :q :q! :wq :wqa` | write / quit, the only way out; guarded by the unsaved ring |

**The two `cd`s.** `:cd src` moves Slopd's project root — what `:grep` searches, what the file
panes list, where a new terminal starts. A bare `cd src` is the shell's own, moving that one
session. Neither follows the other; `:tu` pushes the root into every unlocked session when you
want them back in step (`^h` in the file panes is those two builtins in one keystroke).

<table>
<tr>
<td width="50%"><b>Terminals</b>, libvterm + a real PTY per session, up to 99. Alt shows the switcher.<br><img src="imgs/terminal.png"></td>
<td width="50%"><b>Grep pane</b>, <code>:grep &lt;re&gt;</code>, results with context; Enter jumps.<br><img src="imgs/grep.png"></td>
</tr>
<tr>
<td><b>Config pane</b> (<code>:cf</code>), every setting is a dropdown; the syntax list installs, updates and uninstalls grammars in place.<br><img src="imgs/config.png"></td>
<td><b>Folding</b> (<code>Ctrl+Enter</code>), collapse the block opening on the line; whitespace dots and the active-scope indent rail are the reading aids beside it.<br><img src="imgs/fold.png"></td>
</tr>
<tr>
<td colspan="2"><b>Image viewer</b>, opening an image flips the main pane to the media surface. Wheel zooms about the pointer, drag pans, double-click refits.<br><img src="imgs/media.png"></td>
</tr>
</table>

## Install

Slopd runs two ways, and where the binary sits decides which. **Unzip it anywhere** and it is
portable: `slopd.config`, `themes/`, `grammars/` and `perf.log` all sit beside the binary, and
moving the folder moves its whole world. **Install it** and the files take their native places.

```sh
slopd --install      # copy this binary to ~/.local/bin/slopd, and move its files in
slopd --uninstall    # remove that copy; settings, themes and grammars are kept
slopd --where        # which mode, and every path in use
```

| | |
|---|---|
| `~/.local/bin/slopd` | the binary |
| `~/.config/slopd/slopd.config` | settings (`$XDG_CONFIG_HOME` if you set it) |
| `~/.local/share/slopd/` | `themes/`, `grammars/`, `perf.log` (`$XDG_DATA_HOME` if you set it) |

The first `--install` moves a portable folder's files in, and never overwrites one already
there, so a reinstall from a fresh build keeps your settings. Install and uninstall are also
the Config pane's first row (`:cf`), which is where the mode in force is shown — they run in
terminal 1 and print every path they touch, because installing moves the binary Slopd is
running from.

There is still **no search path**: one mode picks one directory per kind of file and Slopd
reads and writes only there. Copy the binary into `/usr/bin` by hand and it says so and
writes nothing, because a setting it could not save is worse than one it refuses.

## Config

`slopd.config`, simple `key: value` with `#` comments. Editing a setting in the Config pane
rewrites its line in place and leaves the comment alone. No setting can point outside Slopd's
own directories.

| key | values | |
|---|---|---|
| `theme` | `default` \| `<name>` | a name, never a path: `themes/<name>.theme`. A value with a `/` is refused |
| `indent` | `tab` \| `spaces2` \| `spaces4` … | what Tab inserts |
| `line_numbers` | `global` \| `relative` | gutter |
| `scroll_mode` | `follow` \| `middle` | every line view: move only when the target would leave, or pin it to the middle row |
| `font_size` | int | logical points; `Ctrl +/-` writes it back (debounced) |
| `jump_lines` | int | `Ctrl+Up/Down` step |
| `whitespace`, `indent_guides`, `folding` | `on` \| `off` | editor reading aids |
| `folder_cd` | `stage` \| `run` | filetree `Alt+Enter`: review the `:cd` in the CL, or run it |
| `git_tool` | e.g. `lazygit` | what `Alt+G` / `:gs` hands the project root to |
| `git_term` | int \| empty | terminal session to run it in; empty = spawn detached (for a GUI tool) |
| `grep_pane` | `on` \| `off` | `:grep`: always open the results pane vs jump straight on a lone hit |
| `disk_conflict` | `prompt` \| `keep` | file changed on disk under unsaved edits |
| `mouse`, `hover` | `on` \| `off` | pointer input; hover tints the row under it |
| `file_pane` | `ls` \| `browser` | the filetree pane's face: the dired listing, or the file browser |
| `file_view` | `list` \| `grid` | the browser's contents; its toggle button writes this back |
| `file_icons` | `on` \| `off` | per-type icons in the browser (needs the vendored icon face) |

## Theme

`key: #rrggbb`, `#` comments, unknown keys ignored, so theme files are
interchangeable. Missing keys fall back to the baked-in Gruvbox Material default. Drop
files into the `themes/` folder (`slopd --where` names it).

```
bg fg accent muted urgent
border_light border_dark separator
selection line_highlight
code_keyword code_string code_comment code_number
code_operator code_type code_return_type
cl_inject                                 # staged (auto-filled) command-line text
code_function code_variable code_constant code_punctuation   # Slopd: tree-sitter
whitespace indent_guide indent_guide_active                  # Slopd: editor guides
```

## Syntax

Tree-sitter. `languages` is a generated registry of ~300 languages (ext → grammar repo);
nothing is installed by default. A grammar is cloned and compiled to `grammars/<lang>.so`
on demand, from the Config pane's syntax list, or:

```sh
slopd --grammar install|update|uninstall <lang>
slopd --health [lang]        # ✓/✗ table
```

## CLI & env

| | |
|---|---|
| `--version` / `-v` | build version |
| `--<path>` | launch there: a directory becomes the workspace (`slopd --~/code/thing`), a file opens with its folder as the workspace (`slopd --/etc/fstab`) |
| `--install` / `--uninstall` | copy this binary to `~/.local/bin/slopd` and move its files to the XDG folders / remove that copy, keeping the files |
| `--where` | the mode in force, and every path in use |
| `--util` | launch into Full on the aux pane (filetree fills the window) |
| `--perflog` | append per-second frame timings to `perf.log` (in the data folder) |
| `--sysbus` | *(parked/WIP)* print one D-Bus snapshot of the watched system services, then exit |
| `$SLOPD_FONT` | `.ttf` to use instead of the bundled Iosevka subset |

## License

GPL-3.0. `:license` in the command line opens the embedded copy.

Embedded fonts keep their own: **Iosevka Fixed** (SIL OFL 1.1) for text, and the file-browser
icons from **Nerd Fonts**' Seti-UI and Devicons sets (both MIT) — the CC-BY and Apache icon sets
are deliberately left out so the embed carries one licence note.
