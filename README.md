# Slopd

A GPU text editor in [Odin](https://odin-lang.org): two panes, a command line, no modes.
iTree-sitter highlighting, real PTY terminals, an image viewer, one static ~1.9MB binary.
Linux, OpenGL 3.3.

![Slopd](imgs/hero.png)

## Build

```sh
./download-deps.sh                 # vendors glfw, libvterm, tree-sitter, the font
odin build src -out:slopd -define:GLFW_SHARED=false
./release.sh --local               # or: stripped -o:speed build into ../Slopd-release/
```

| | |
|---|---|
| **main surfaces** | `Text` (the buffer ring) · `Image` (the media viewer) |
| **aux modes** | `FileTree` · `Terminal` · `Config` · `Grep` |
| **views** | `Split` both panes · `Zen` full-width editor, aux slides in while focused · `Full` one surface fills the window |

Views are toggled from the command line: `zen`/`zm`, `full`/`fm`, `normal`/`nm`. `Esc` with
nothing to cancel turns Zen on and flips which side is shown.

## Keys

Non-modal / Alt-rooted: bare keys type, arrows navigate, chords live under Alt.

| | |
|---|---|
| `Alt+Left/Right`, `Alt+E` | focus editor / aux |
| `Alt+F` `Alt+T` `Alt+R` | aux mode: filetree, terminal, grep results |
| `Alt+C` | open the command line |
| `Alt+W` | open it pre-filled with `j ` (the jump builtin), ready for a line number |
| `Alt+Enter` | editor: follow the token under the caret (def / URL / `[[file]]` / colour) · filetree: `cd` to the folder |
| `Shift+Enter` | filetree: open in the desktop app, or stage a runnable's command |
| `Alt+1..9`, `Alt+Up/Down` | terminal session N / prev / next (switcher shows while Alt is held) |
| `Alt+N` `Alt+Q` `Alt+L` | terminal: new · close · lock its cwd |
| `Ctrl+Alt+Up/Down`, `PageUp/Down` | terminal copy cursor (`Shift+Alt+Up/Down` extends, `Ctrl+Shift+C` copies) |
| `Alt+G` | hand the project root to the configured git tool |
| `Alt+A` + arrow | drop a multi-cursor trail (`Alt+M` = next motion moves all, `Esc` collapses) |
| `Ctrl+Up/Down` | jump `jump_lines` lines · `Ctrl+Enter` fold/unfold the block |
| `Alt+[` `Alt+]` | nudge the split · `Ctrl+=` `Ctrl+-` `Ctrl+0` font zoom |
| `Ctrl+S/Z/Y/C/X/V` | save, undo, redo, clipboard |

Filetree file ops are dired-style `Ctrl` chords (`^y` yank, `^u` reset, `^c` copy, `^x` cut,
`^p` paste, `^d` delete, `^w` path), hold `Ctrl` for the cheat-sheet bar.

The mouse is purely additive (`mouse: off` costs no capability). Wheel scrolls whatever is
under the pointer and detaches the view; a click focuses the pane and does its own job;
typing stands the pointer down.

## Command line

`Alt+C`. A submitted line is an `&&` chain of Slopd **builtins** and **shell** commands;
shell steps run in a terminal session and the chain waits on each exit code. A leading `tN`
targets session N. Text staged by a UI gesture renders in the alert colour until you touch it.

| | |
|---|---|
| `j` / `jump` | `j 40`, `j +5`, `j file`, `j file 40` |
| `grep <re>` | project-wide search into the Grep pane |
| `cd [dir]` | set the project root (Slopd's, not a shell's) · `tu` syncs unlocked terminals |
| `ls` `cf` `gs` | filetree (also: refresh) · config pane · git tool |
| `put [text]` | type text + the editor selection into the target terminal, no newline |
| `reload y\|n` | answer a disk-conflict prompt |
| `readme` `license` | open the embedded docs |
| `zen` `full` `normal` | view arrangement |
| `w wa q q! wq wqa` | write / quit, the only way out; guarded by the unsaved ring |

Anything else is shell.

<table>
<tr>
<td width="50%"><b>Terminals</b>, libvterm + a real PTY per session, up to 99. Alt shows the switcher.<br><img src="imgs/terminal.png"></td>
<td width="50%"><b>Grep pane</b>, <code>grep &lt;re&gt;</code>, results with context; Enter jumps.<br><img src="imgs/grep.png"></td>
</tr>
<tr>
<td><b>Config pane</b> (<code>cf</code>), every setting is a dropdown; the syntax list installs, updates and uninstalls grammars in place.<br><img src="imgs/config.png"></td>
<td><b>Folding</b> (<code>Ctrl+Enter</code>), collapse the block opening on the line; whitespace dots and the active-scope indent rail are the reading aids beside it.<br><img src="imgs/fold.png"></td>
</tr>
<tr>
<td colspan="2"><b>Image viewer</b>, opening an image flips the main pane to the media surface. Wheel zooms about the pointer, drag pans, double-click refits.<br><img src="imgs/media.png"></td>
</tr>
</table>

## Config

`slopd.config`, simple `key: value` with `#` comments. It sits **beside the binary**, and so
does everything else Slopd owns: `themes/`, `grammars/`, `perf.log`. No search path, no
`~/.config/slopd`, and no setting can point outside that directory. Move the binary and its
whole world moves with it. Editing a setting in the Config pane rewrites its line in place
and leaves the comment alone.

| key | values | |
|---|---|---|
| `theme` | `default` \| `<name>` | a name, never a path: `themes/<name>.theme` beside the binary. A value with a `/` is refused |
| `indent` | `tab` \| `spaces2` \| `spaces4` … | what Tab inserts |
| `line_numbers` | `global` \| `relative` | gutter |
| `scroll_mode` | `follow` \| `middle` | every line view: move only when the target would leave, or pin it to the middle row |
| `font_size` | int | logical points; `Ctrl +/-` writes it back (debounced) |
| `jump_lines` | int | `Ctrl+Up/Down` step |
| `whitespace`, `indent_guides`, `folding` | `on` \| `off` | editor reading aids |
| `folder_cd` | `stage` \| `run` | filetree `Alt+Enter`: review the `cd` in the CL, or run it |
| `git_tool` | e.g. `lazygit` | what `Alt+G` / `gs` hands the project root to |
| `git_term` | int \| empty | terminal session to run it in; empty = spawn detached (for a GUI tool) |
| `grep_pane` | `on` \| `off` | always open the results pane vs jump straight on a lone hit |
| `disk_conflict` | `prompt` \| `keep` | file changed on disk under unsaved edits |
| `mouse`, `hover` | `on` \| `off` | pointer input; hover tints the row under it |

## Theme

`key: #rrggbb`, `#` comments, unknown keys ignored, so theme files are
interchangeable. Missing keys fall back to the baked-in Gruvbox Material default. Drop
files into `themes/` beside the binary.

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
| `--util` | launch into Full on the aux pane (filetree fills the window) |
| `--perflog` | append per-second frame timings to `perf.log` (beside the binary) |
| `$SLOPD_FONT` | `.ttf` to use instead of the bundled Iosevka subset |

## License

GPL-3.0. `license` in the command line opens the embedded copy.
