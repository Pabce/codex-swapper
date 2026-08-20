#!/usr/bin/env python3
"""Regenerate the opencode-go US catalogs.

Two surfaces consume `<codex_home>/model-catalogs/` files:

1. Desktop app (`~/.codex/config.toml`, provider id `opencode-go-us`): the
   modded app-server merges the convention-based static catalog
   `<provider-id>.json` into `model/list`. `opencode-go-us.json` stays
   CONTRIBUTOR-ONLY so the desktop picker has one clean contributor row next
   to the direct `opencode-go` provider's full list (DESIGN B4).

2. CLI US profile (`~/.codex/opencode-go-us.config.toml`, provider id
   `opencode-go-us-cli`): the profile's `model_catalog_json` and the mod's
   per-thread catalog injection both resolve through
   `model-catalogs/opencode-go-us-cli.json`, which is the FULL opencode-go
   model list plus the contributor entry. That lets the CLI picker (`/model`
   in the interactive CLI, `-m` in `codex exec`) select every model while
   us-forward-proxy.py routes only muse-spark* requests through the US exit
   and everything else direct.

Sources (in this repo under model-catalogs/ or in $CODEX_HOME/model-catalogs/):
  - `opencode-go.json`                : full opencode-go catalog (15 models)
  - `opencode-go-us-contributor.json` : the muse-spark-1.2-contributor entry

Run after either source changes:
    python3 sync-us-catalog.py
    # or after install:
    python3 /Users/pbarham/opt/codex-swapper/sync-us-catalog.py
"""
import json
import os
import sys
from pathlib import Path

def find_catalogs():
    # Prefer $CODEX_HOME, fall back to repo's model-catalogs/
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "model-catalogs"
    repo = Path(__file__).parent / "model-catalogs"
    # If home has the files, use them; else use repo
    if (home / "opencode-go.json").exists():
        return home / "opencode-go.json", home / "opencode-go-us-contributor.json", home / "opencode-go-us.json", home / "opencode-go-us-cli.json"
    return repo / "opencode-go.json", repo / "opencode-go-us-contributor.json", repo / "opencode-go-us.json", repo / "opencode-go-us-cli.json"

def main() -> int:
    FULL, CONTRIB, DESKTOP_OUT, CLI_OUT = find_catalogs()
    # Also ensure repo sources exist — if we were given CODEX_HOME paths but they don't exist, try repo
    if not FULL.exists():
        FULL = Path(__file__).parent / "model-catalogs" / "opencode-go.json"
        CONTRIB = Path(__file__).parent / "model-catalogs" / "opencode-go-us-contributor.json"
        DESKTOP_OUT = Path.home() / ".codex" / "model-catalogs" / "opencode-go-us.json"
        CLI_OUT = Path.home() / ".codex" / "model-catalogs" / "opencode-go-us-cli.json"
    full = json.loads(FULL.read_text())
    contrib = json.loads(CONTRIB.read_text())

    DESKTOP_OUT.parent.mkdir(parents=True, exist_ok=True)
    DESKTOP_OUT.write_text(json.dumps(contrib, indent=1) + "\n")

    seen = set()
    merged = []
    for entry in full["models"] + contrib["models"]:
        slug = entry.get("slug") or entry.get("model")
        if not slug or slug in seen:
            continue
        seen.add(slug)
        merged.append(entry)

    CLI_OUT.write_text(json.dumps({"models": merged}, indent=1) + "\n")
    # Also keep repo copies in sync if we wrote to HOME
    repo_desktop = Path(__file__).parent / "model-catalogs" / "opencode-go-us.json"
    repo_cli = Path(__file__).parent / "model-catalogs" / "opencode-go-us-cli.json"
    try:
        if DESKTOP_OUT != repo_desktop:
            repo_desktop.write_text(json.dumps(contrib, indent=1) + "\n")
        if CLI_OUT != repo_cli:
            repo_cli.write_text(json.dumps({"models": merged}, indent=1) + "\n")
    except OSError:
        pass
    print(
        f"wrote {DESKTOP_OUT} with {len(contrib['models'])} model (contributor-only)\n"
        f"wrote {CLI_OUT} with {len(merged)} models "
        f"({len(full['models'])} full + {len(contrib['models'])} contributor)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
