#!/usr/bin/env python3
"""Generate Slopd's language registry by parsing down Helix's languages.toml.

Slopd follows Helix for its tree-sitter language set: rather than hand-curate
grammar repos + file-extension maps, we pull Helix's languages.toml (pinned to a
release for reproducibility) and relabel it into our own tiny line format. This
script is the ONLY thing that touches Helix data — its output (the `languages`
file) is generated, never committed, and ships beside the binary like themes/ and
grammars/. download-deps.sh runs it for dev; release.sh runs it for the release.

We keep Helix's pinned grammar revs (reproducible installs at no extra cost) and
its subpaths (correct for multi-grammar repos like tree-sitter-typescript). We do
NOT take its queries — highlights.scm comes from each grammar's own repo at install
time. Helix is MPL-2.0 (GPL-compatible); this is a reformatted name->repo->exts
mapping, attributed in the generated file's header.

Output line format (tab-separated, '-' for an empty field):
    name <TAB> repo <TAB> rev <TAB> subpath <TAB> ext,ext,...
"""

import sys
import tomllib
import urllib.request

# Pinned Helix release — bump to refresh the registry (re-run via download-deps.sh).
HELIX_REF = "25.07.1"
LANGUAGES_TOML_URL = (
    f"https://raw.githubusercontent.com/helix-editor/helix/{HELIX_REF}/languages.toml"
)


def fetch_languages_toml() -> dict:
    # Timeout so a stalled network can't hang a build indefinitely.
    with urllib.request.urlopen(LANGUAGES_TOML_URL, timeout=30) as resp:
        return tomllib.loads(resp.read().decode("utf-8"))


def build_registry(doc: dict) -> list[dict]:
    # grammar name -> its git source (only git-sourced grammars are installable).
    sources: dict[str, dict] = {}
    for g in doc.get("grammar", []):
        src = g.get("source", {})
        if "git" in src:
            sources[g["name"]] = src

    # grammar name -> set of file extensions, unioned across every language that
    # uses it (a language's `grammar` defaults to its own name).
    exts: dict[str, list[str]] = {name: [] for name in sources}
    for lang in doc.get("language", []):
        grammar = lang.get("grammar", lang["name"])
        if grammar not in sources:
            continue
        for ft in lang.get("file-types", []):
            # file-types may hold {glob = ...} tables; we only map plain extensions.
            if isinstance(ft, str) and ft not in exts[grammar]:
                exts[grammar].append(ft)

    out = []
    for name in sorted(sources):
        src = sources[name]
        out.append(
            {
                "name": name,
                "repo": src["git"],
                "rev": src.get("rev", ""),
                "subpath": src.get("subpath", ""),
                "exts": exts[name],
            }
        )
    return out


def write_registry(path: str, registry: list[dict]) -> None:
    lines = [
        "# Slopd language registry — GENERATED, do not edit.",
        f"# Parsed down from helix-editor/helix languages.toml @ {HELIX_REF} (MPL-2.0).",
        "# Refresh by re-running tools/gen-languages.py (via download-deps.sh).",
        "# fields: name<TAB>repo<TAB>rev<TAB>subpath<TAB>ext,ext,...   ('-' = empty)",
    ]
    for g in registry:
        lines.append(
            "\t".join(
                [
                    g["name"],
                    g["repo"],
                    g["rev"] or "-",
                    g["subpath"] or "-",
                    ",".join(g["exts"]) or "-",
                ]
            )
        )
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "languages"
    registry = build_registry(fetch_languages_toml())
    write_registry(out_path, registry)
    print(f"  wrote {len(registry)} grammars -> {out_path} (helix {HELIX_REF})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
