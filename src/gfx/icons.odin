package gfx

import "core:path/filepath"
import "core:strings"

// The file browser's type icons: a name or an extension mapped to ONE RUNE. They are glyphs
// from a second embedded face (font.odin), so an icon costs a codepoint here and nothing else —
// no image decode, no cache, no second texture — and every pane draws one with plain text.
//
// **The icon says TYPE and the colour says STATE.** A directory, an executable, a file with
// unsaved edits in the ring: those are the entry's colour (filebrowser_entry_color), never a
// different icon, so a Rust file looks like a Rust file whether or not you have edited it.
//
// The tables are linear scans, deliberately. They are read for the rows ON SCREEN (a few dozen)
// against short keys, which is far cheaper than the map a hundred-entry table suggests — and it
// keeps them `@(rodata)` literals that a test can walk. Extensions are matched lower-cased.
//
// Codepoints come from Symbols Nerd Font's Seti-UI and Devicons blocks (both MIT), vendored and
// subset by download-deps.sh. **A codepoint outside the vendored ranges silently draws nothing**,
// so tests/icons_test.odin asserts every rune here is one the embedded face actually carries.

ICON_FOLDER     :: rune(0xE5FF) // custom-folder
ICON_FILE       :: rune(0xE612) // custom-default
ICON_TEXT       :: rune(0xE64E) // seti-text
ICON_MARKDOWN   :: rune(0xE609) // seti-markdown
ICON_CONFIG     :: rune(0xE615) // seti-config
ICON_JSON       :: rune(0xE80B) // dev-json
ICON_YAML       :: rune(0xE8EB) // dev-yaml
ICON_TOML       :: rune(0xE6B2) // custom-toml
ICON_XML        :: rune(0xE619) // seti-xml
ICON_LICENSE    :: rune(0xE60A) // seti-license
ICON_TODO       :: rune(0xE69C) // seti-todo
ICON_IMAGE      :: rune(0xE60D) // seti-image
ICON_SVG        :: rune(0xE698) // seti-svg
ICON_VIDEO      :: rune(0xE69F) // seti-video
ICON_AUDIO      :: rune(0xE638) // seti-audio
ICON_PDF        :: rune(0xE67D) // seti-pdf
ICON_WORD       :: rune(0xE6A5) // seti-word
ICON_XLS        :: rune(0xE6A6) // seti-xls
ICON_CSV        :: rune(0xE64A) // seti-csv
ICON_NOTEBOOK   :: rune(0xE678) // seti-notebook
ICON_FONT       :: rune(0xE659) // seti-font
ICON_ARCHIVE    :: rune(0xE6AA) // seti-zip
ICON_DB         :: rune(0xE64D) // seti-db
ICON_SQL        :: rune(0xE7C4) // dev-sqlite
ICON_LOCK       :: rune(0xE672) // seti-lock
ICON_MAKEFILE   :: rune(0xE673) // seti-makefile
ICON_CMAKE      :: rune(0xE794) // dev-cmake
ICON_GRADLE     :: rune(0xE660) // seti-gradle
ICON_NPM        :: rune(0xE71E) // dev-npm
ICON_DOCKER     :: rune(0xE650) // seti-docker
ICON_GIT        :: rune(0xE702) // dev-git
ICON_GITIGNORE  :: rune(0xE65D) // seti-git_ignore
ICON_VIM        :: rune(0xE62B) // custom-vim
ICON_NIX        :: rune(0xE843) // dev-nixos
ICON_TEX        :: rune(0xE69B) // seti-tex
ICON_HTML       :: rune(0xE60E) // seti-html
ICON_CSS        :: rune(0xE614) // seti-css
ICON_SASS       :: rune(0xE603) // seti-sass
ICON_GRAPHQL    :: rune(0xE662) // seti-graphql
ICON_SHELL      :: rune(0xE691) // seti-shell
ICON_POWERSHELL :: rune(0xE683) // seti-powershell
ICON_C          :: rune(0xE649) // seti-c
ICON_CPP        :: rune(0xE646) // seti-cpp
ICON_CSHARP     :: rune(0xE648) // seti-c_sharp
ICON_RUST       :: rune(0xE68B) // seti-rust
ICON_GO         :: rune(0xE627) // seti-go
ICON_PYTHON     :: rune(0xE606) // seti-python
ICON_JAVASCRIPT :: rune(0xE60C) // seti-javascript
ICON_TYPESCRIPT :: rune(0xE628) // seti-typescript
ICON_REACT      :: rune(0xE625) // seti-react
ICON_JAVA       :: rune(0xE66D) // seti-java
ICON_KOTLIN     :: rune(0xE634) // seti-kotlin
ICON_SWIFT      :: rune(0xE699) // seti-swift
ICON_RUBY       :: rune(0xE605) // seti-ruby
ICON_PHP        :: rune(0xE608) // seti-php
ICON_LUA        :: rune(0xE620) // seti-lua
ICON_HASKELL    :: rune(0xE61F) // seti-haskell
ICON_OCAML      :: rune(0xE67A) // seti-ocaml
ICON_ELIXIR     :: rune(0xE62D) // seti-elixir
ICON_ERLANG     :: rune(0xE7B1) // dev-erlang
ICON_CLOJURE    :: rune(0xE642) // seti-clojure
ICON_SCALA      :: rune(0xE68E) // seti-scala
ICON_DART       :: rune(0xE64C) // seti-dart
ICON_PERL       :: rune(0xE67E) // seti-perl
ICON_NIM        :: rune(0xE677) // seti-nim
ICON_ZIG        :: rune(0xE6A9) // seti-zig
ICON_CRYSTAL    :: rune(0xE62F) // seti-crystal
ICON_JULIA      :: rune(0xE624) // seti-julia
ICON_R          :: rune(0xE68A) // seti-r

// One rule: an exact file name, or an extension, and the icon it names.
Icon_Rule :: struct {
    key:  string,
    icon: rune,
}

// Matched FIRST, against the whole lower-cased name: these are the files whose meaning is their
// name rather than their extension, and half of them have no extension at all.
@(rodata)
ICON_BY_NAME := []Icon_Rule{
    {"makefile", ICON_MAKEFILE},
    {"gnumakefile", ICON_MAKEFILE},
    {"dockerfile", ICON_DOCKER},
    {"docker-compose.yml", ICON_DOCKER},
    {"compose.yml", ICON_DOCKER},
    {".gitignore", ICON_GITIGNORE},
    {".gitattributes", ICON_GITIGNORE},
    {".gitmodules", ICON_GIT},
    {".gitconfig", ICON_GIT},
    {"license", ICON_LICENSE},
    {"licence", ICON_LICENSE},
    {"copying", ICON_LICENSE},
    {"readme", ICON_MARKDOWN},
    {"readme.md", ICON_MARKDOWN},
    {"todo", ICON_TODO},
    {"todo.md", ICON_TODO},
    {"cmakelists.txt", ICON_CMAKE},
    {"package.json", ICON_NPM},
    {"package-lock.json", ICON_NPM},
    {"cargo.toml", ICON_RUST},
    {"cargo.lock", ICON_RUST},
    {"go.mod", ICON_GO},
    {"go.sum", ICON_GO},
    {"build.gradle", ICON_GRADLE},
    {".vimrc", ICON_VIM},
    {"flake.nix", ICON_NIX},
    {"shell.nix", ICON_NIX},
    {".editorconfig", ICON_CONFIG},
    {".env", ICON_CONFIG},
    {"slopd.config", ICON_CONFIG},
}

// Matched on the extension, lower-cased and without its dot.
@(rodata)
ICON_BY_EXT := []Icon_Rule{
    {"txt", ICON_TEXT},
    {"log", ICON_TEXT},
    {"rst", ICON_TEXT},
    {"nfo", ICON_TEXT},
    {"md", ICON_MARKDOWN},
    {"markdown", ICON_MARKDOWN},
    {"pdf", ICON_PDF},
    {"doc", ICON_WORD},
    {"docx", ICON_WORD},
    {"odt", ICON_WORD},
    {"rtf", ICON_WORD},
    {"xls", ICON_XLS},
    {"xlsx", ICON_XLS},
    {"ods", ICON_XLS},
    {"csv", ICON_CSV},
    {"tsv", ICON_CSV},
    {"ipynb", ICON_NOTEBOOK},
    {"epub", ICON_WORD},
    {"tex", ICON_TEX},
    {"bib", ICON_TEX},
    {"json", ICON_JSON},
    {"jsonc", ICON_JSON},
    {"yaml", ICON_YAML},
    {"yml", ICON_YAML},
    {"toml", ICON_TOML},
    {"xml", ICON_XML},
    {"plist", ICON_XML},
    {"ini", ICON_CONFIG},
    {"cfg", ICON_CONFIG},
    {"conf", ICON_CONFIG},
    {"config", ICON_CONFIG},
    {"properties", ICON_CONFIG},
    {"desktop", ICON_CONFIG},
    {"service", ICON_CONFIG},
    {"html", ICON_HTML},
    {"htm", ICON_HTML},
    {"xhtml", ICON_HTML},
    {"css", ICON_CSS},
    {"scss", ICON_SASS},
    {"sass", ICON_SASS},
    {"less", ICON_SASS},
    {"graphql", ICON_GRAPHQL},
    {"gql", ICON_GRAPHQL},
    {"nix", ICON_NIX},
    {"png", ICON_IMAGE},
    {"jpg", ICON_IMAGE},
    {"jpeg", ICON_IMAGE},
    {"gif", ICON_IMAGE},
    {"bmp", ICON_IMAGE},
    {"webp", ICON_IMAGE},
    {"ico", ICON_IMAGE},
    {"tif", ICON_IMAGE},
    {"tiff", ICON_IMAGE},
    {"ppm", ICON_IMAGE},
    {"xcf", ICON_IMAGE},
    {"psd", ICON_IMAGE},
    {"svg", ICON_SVG},
    {"mp3", ICON_AUDIO},
    {"flac", ICON_AUDIO},
    {"wav", ICON_AUDIO},
    {"ogg", ICON_AUDIO},
    {"opus", ICON_AUDIO},
    {"m4a", ICON_AUDIO},
    {"aac", ICON_AUDIO},
    {"wma", ICON_AUDIO},
    {"mid", ICON_AUDIO},
    {"mp4", ICON_VIDEO},
    {"mkv", ICON_VIDEO},
    {"webm", ICON_VIDEO},
    {"avi", ICON_VIDEO},
    {"mov", ICON_VIDEO},
    {"wmv", ICON_VIDEO},
    {"flv", ICON_VIDEO},
    {"m4v", ICON_VIDEO},
    {"ttf", ICON_FONT},
    {"otf", ICON_FONT},
    {"woff", ICON_FONT},
    {"woff2", ICON_FONT},
    {"zip", ICON_ARCHIVE},
    {"tar", ICON_ARCHIVE},
    {"gz", ICON_ARCHIVE},
    {"tgz", ICON_ARCHIVE},
    {"xz", ICON_ARCHIVE},
    {"bz2", ICON_ARCHIVE},
    {"zst", ICON_ARCHIVE},
    {"7z", ICON_ARCHIVE},
    {"rar", ICON_ARCHIVE},
    {"iso", ICON_ARCHIVE},
    {"deb", ICON_ARCHIVE},
    {"rpm", ICON_ARCHIVE},
    {"jar", ICON_JAVA},
    {"db", ICON_DB},
    {"sqlite", ICON_DB},
    {"sqlite3", ICON_DB},
    {"sql", ICON_SQL},
    {"pem", ICON_LOCK},
    {"key", ICON_LOCK},
    {"crt", ICON_LOCK},
    {"cer", ICON_LOCK},
    {"gpg", ICON_LOCK},
    {"asc", ICON_LOCK},
    {"c", ICON_C},
    {"h", ICON_C},
    {"cpp", ICON_CPP},
    {"cc", ICON_CPP},
    {"cxx", ICON_CPP},
    {"hpp", ICON_CPP},
    {"hh", ICON_CPP},
    {"hxx", ICON_CPP},
    {"cs", ICON_CSHARP},
    {"rs", ICON_RUST},
    {"go", ICON_GO},
    {"py", ICON_PYTHON},
    {"pyi", ICON_PYTHON},
    {"pyw", ICON_PYTHON},
    {"js", ICON_JAVASCRIPT},
    {"mjs", ICON_JAVASCRIPT},
    {"cjs", ICON_JAVASCRIPT},
    {"ts", ICON_TYPESCRIPT},
    {"jsx", ICON_REACT},
    {"tsx", ICON_REACT},
    {"vue", ICON_REACT},
    {"svelte", ICON_REACT},
    {"java", ICON_JAVA},
    {"kt", ICON_KOTLIN},
    {"kts", ICON_KOTLIN},
    {"swift", ICON_SWIFT},
    {"rb", ICON_RUBY},
    {"gemspec", ICON_RUBY},
    {"php", ICON_PHP},
    {"lua", ICON_LUA},
    {"hs", ICON_HASKELL},
    {"lhs", ICON_HASKELL},
    {"ml", ICON_OCAML},
    {"mli", ICON_OCAML},
    {"ex", ICON_ELIXIR},
    {"exs", ICON_ELIXIR},
    {"erl", ICON_ERLANG},
    {"hrl", ICON_ERLANG},
    {"clj", ICON_CLOJURE},
    {"cljs", ICON_CLOJURE},
    {"scala", ICON_SCALA},
    {"sbt", ICON_SCALA},
    {"dart", ICON_DART},
    {"pl", ICON_PERL},
    {"pm", ICON_PERL},
    {"nim", ICON_NIM},
    {"zig", ICON_ZIG},
    {"cr", ICON_CRYSTAL},
    {"jl", ICON_JULIA},
    {"r", ICON_R},
    {"sh", ICON_SHELL},
    {"bash", ICON_SHELL},
    {"zsh", ICON_SHELL},
    {"fish", ICON_SHELL},
    {"ps1", ICON_POWERSHELL},
    {"vim", ICON_VIM},
    {"cmake", ICON_CMAKE},
    {"gradle", ICON_GRADLE},
}

// The icon for an entry. Directories are one icon whatever they are called — a folder is a
// folder — then the name table, then the extension, then the generic file. `.odin` deliberately
// resolves to that last one: Nerd Fonts has no Odin glyph, and a wrong logo is worse than none.
file_icon :: proc(name: string, is_dir: bool) -> rune {
    if is_dir {
        return ICON_FOLDER
    }
    lower := strings.to_lower(name, context.temp_allocator)
    for r in ICON_BY_NAME {
        if r.key == lower {
            return r.icon
        }
    }
    // filepath.ext keeps the dot and returns "" for a dotfile like `.bashrc`, which is what we
    // want: a dotfile with no second dot is named, not typed.
    ext := strings.trim_prefix(filepath.ext(lower), ".")
    if ext != "" {
        for r in ICON_BY_EXT {
            if r.key == ext {
                return r.icon
            }
        }
    }
    return ICON_FILE
}
