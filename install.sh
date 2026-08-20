#!/usr/bin/env bash
# codex-swapper install — one-command setup for macOS arm64 + latest ChatGPT.app
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Pabce/codex-swapper/main/install.sh | bash
#   ./install.sh                          # binary install (download Release asset)
#   ./install.sh --from-source            # build locally (needs cargo + ~12 GiB free)
#   ./install.sh --with-us-proxy          # also template ~/.config/codex-swapper/us-proxy.env
#   ./install.sh --check                  # doctor only, no changes
#   ./install.sh --uninstall              # remove mod wiring (keeps ~/.codex history)
#
# Idempotent: re-running patches config.toml / catalogs / bins without clobbering
# your projects / history / existing sessions.

set -euo pipefail

REPO="Pabce/codex-swapper"
PINNED_CLI="0.148.0-alpha.15"
PINNED_APP="26.814.41407"  # informational; mismatch is a warning not a hard error

MODE="binary"
WITH_US_PROXY=0
DOCTOR_ONLY=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --from-source) MODE="source" ;;
    --with-us-proxy) WITH_US_PROXY=1 ;;
    --check|--doctor) DOCTOR_ONLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# Resolve repo root when running from a checkout; otherwise use tmp for curl|bash.
if [ -f "$0" ] && [ -d "$(dirname "$0")/model-catalogs" ]; then
  SRCROOT="$(cd "$(dirname "$0")" && pwd)"
else
  SRCROOT=""
fi

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
BIN_DIR="$CODEX_HOME/bin"
CATALOG_DIR="$CODEX_HOME/model-catalogs"
CONFIG="$CODEX_HOME/config.toml"
PROXY_ENV_DIR="$HOME/.config/codex-swapper"
PROXY_ENV="$PROXY_ENV_DIR/us-proxy.env"
LOCAL_BIN="$HOME/.local/bin"

say() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33mwarning: %s\033[0m\n" "$*" >&2; }
die() { printf "\033[31merror: %s\033[0m\n" "$*" >&2; exit 1; }

doctor() {
  local ok=1
  echo "== codex-swapper doctor =="
  echo "arch: $(uname -m)  os: $(sw_vers -productVersion 2>/dev/null || echo '?')"
  if [ "$(uname -m)" != "arm64" ]; then warn "only arm64 is supported/tested"; ok=0; fi
  if [ -f /Applications/ChatGPT.app/Contents/Info.plist ]; then
    local bv
    bv="$(defaults read /Applications/ChatGPT.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"
    echo "ChatGPT.app: $bv (pinned $PINNED_APP)"
    # not fatal - app updates frequently
    if [ "$bv" != "$PINNED_APP" ]; then warn "ChatGPT.app $bv != pinned $PINNED_APP - mod tracks the bundled CLI; run update-mod.sh on the dev machine or wait for a new Release"; fi
    if [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then
      echo "bundled codex: $(/Applications/ChatGPT.app/Contents/Resources/codex --version 2>/dev/null || echo '?') (pinned $PINNED_CLI)"
    fi
  else
    warn "ChatGPT.app not found at /Applications/ChatGPT.app"
  fi
  for p in "$BIN_DIR/oc-go-key" "$BIN_DIR/oc-usage" "$CATALOG_DIR/opencode-go.json" "$CONFIG"; do
    if [ -f "$p" ]; then echo "ok  $p"; else echo "miss $p"; fi
  done
  if [ -x "$LOCAL_BIN/codex-mod" ]; then echo "ok  $LOCAL_BIN/codex-mod -> $(readlink "$LOCAL_BIN/codex-mod" 2>/dev/null || cat "$LOCAL_BIN/codex-mod" | head -1)"; else echo "miss $LOCAL_BIN/codex-mod"; fi
  if [ -x "$LOCAL_BIN/codex" ] || [ -x "$CODEX_HOME/../.local/bin/codex" ]; then :; fi
  # installed binary version (prefer modded, fall back to any)
  local modbin=""
  if [ -n "${SRCROOT:-}" ] && [ -x "$SRCROOT/codex-rs/codex-rs/target/release/codex" ]; then
    modbin="$SRCROOT/codex-rs/codex-rs/target/release/codex"
  elif [ -x "$LOCAL_BIN/codex" ]; then
    # legacy: some users had $LOCAL_BIN/codex as the mod
    modbin="$LOCAL_BIN/codex"
  fi
  # also check the binary that launch-tier2.sh will actually use: CODEX_CLI_PATH from config or script
  # prefer the canonical mod binary location if install.sh placed it elsewhere
  local release_bin="$PROXY_ENV_DIR/../.."
  # just report what we find
  if [ -n "$modbin" ] && [ -x "$modbin" ]; then
    echo "modded codex: $($modbin --version 2>/dev/null || echo '?')  ($modbin)"
  else
    echo "modded codex: not found (expected $SRCROOT/codex-rs/codex-rs/target/release/codex or Release asset)"
  fi
  # Keychain presence (no secret printed)
  if /usr/bin/security find-generic-password -a "$USER" -s opencode-go -w >/dev/null 2>&1; then
    echo "ok  Keychain opencode-go ($USER)"
  else
    echo "miss Keychain opencode-go ($USER) — needed for OpenCode Go models"
  fi
  if /usr/bin/security find-generic-password -a "$USER" -s opencode-go-alt -w >/dev/null 2>&1; then
    echo "ok  Keychain opencode-go-alt ($USER)"
  else
    echo "info Keychain opencode-go-alt ($USER) — optional second key for failover"
  fi
  if [ -f "$PROXY_ENV" ]; then echo "ok  $PROXY_ENV"; else echo "info $PROXY_ENV — only for muse-spark-1.2-contributor US egress"; fi
  # quick merged-list smoke if binary exists
  if [ -n "$modbin" ] && [ -x "$modbin" ]; then
    echo "smoke: merged model/list via stdio harness..."
    if [ -f "${SRCROOT:-/tmp}/tier2_stdio_smoke.py" ]; then
      python3 "${SRCROOT:-.}/tier2_stdio_smoke.py" 2>&1 | tail -n 20 || warn "smoke failed"
    fi
  fi
  echo "== doctor done =="
  # don't exit non-zero on warnings; only on truly missing core bits when not doctor-only?
  return 0
}

uninstall_mod() {
  say "uninstalling codex-swapper wiring (keeping history/sessions)..."
  # Remove provider sections from config.toml (keep projects / notify / mcp etc.)
  if [ -f "$CONFIG" ]; then
    python3 - "$CONFIG" << 'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
# Remove opencode-go provider blocks (both direct and US)
# Match from [model_providers.opencode-go...] until next [ or EOF
t2 = re.sub(r'\n\[model_providers\.opencode-go[^\]]*\][^\[]*?(?=\n\[|\Z)', '', t, flags=re.S)
if t2 != t:
    p.write_text(t2)
    print("removed [model_providers.opencode-go*] from config.toml")
else:
    print("no [model_providers.opencode-go*] found")
PY
  fi
  rm -f "$CATALOG_DIR/opencode-go.json" "$CATALOG_DIR/opencode-go-us.json" "$CATALOG_DIR/opencode-go-us-contributor.json" "$CATALOG_DIR/opencode-go-us-cli.json"
  rm -f "$BIN_DIR/oc-go-key" "$BIN_DIR/oc-usage"
  rm -f "$LOCAL_BIN/codex-mod" "$LOCAL_BIN/codex-mod-us"
  echo "kept: $CODEX_HOME history/sessions; $PROXY_ENV (if you want it: rm $PROXY_ENV)"
  say "uninstall done — quit ChatGPT and reopen it normally to use stock codex."
  exit 0
}

if [ "$UNINSTALL" = 1 ]; then uninstall_mod; fi
if [ "$DOCTOR_ONLY" = 1 ]; then doctor; exit 0; fi

# --- preflight ---
if [ "$(uname)" != "Darwin" ]; then die "only macOS is supported"; fi
if [ "$(uname -m)" != "arm64" ]; then warn "only arm64 is tested — continuing anyway"; fi

if [ ! -d "$CODEX_HOME" ]; then
  say "creating $CODEX_HOME"
  mkdir -p "$CODEX_HOME"
fi
mkdir -p "$BIN_DIR" "$CATALOG_DIR" "$LOCAL_BIN" "$PROXY_ENV_DIR"

# --- binary ---
install_binary() {
  if [ "$MODE" = "source" ]; then
    if [ -z "$SRCROOT" ]; then die "--from-source needs a git checkout (not curl|bash); clone the repo first"; fi
    say "building from source (this takes ~20-30 min, needs ~12 GiB free)..."
    df -h /System/Volumes/Data | tail -1
    bash "$SRCROOT/build-mod.sh"
    # build-mod.sh leaves binary at codex-rs/codex-rs/target/release/codex
    local built="$SRCROOT/codex-rs/codex-rs/target/release/codex"
    ln -sf "$built" "$LOCAL_BIN/codex-mod"
    echo "linked $LOCAL_BIN/codex-mod -> $built"
  else
    # Binary mode: prefer a local Release asset next to this script (offline / dev),
    # else download from GitHub Releases.
    local asset="codex-macos-arm64-$PINNED_CLI.tar.gz"
    local url="https://github.com/$REPO/releases/download/$PINNED_CLI/$asset"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    if [ -n "$SRCROOT" ] && [ -f "$SRCROOT/dist/$asset" ]; then
      say "installing binary from local dist/$asset"
      tar -xzf "$SRCROOT/dist/$asset" -C "$tmpdir"
    else
      say "downloading $asset from $url"
      if ! curl -fsSL -o "$tmpdir/$asset" "$url"; then
        warn "download failed — falling back to building from source if you have a checkout"
        if [ -n "$SRCROOT" ] && [ -f "$SRCROOT/build-mod.sh" ]; then
          echo "hint: ./install.sh --from-source"
        fi
        die "could not fetch $url (is the Release published? pinned CLI is $PINNED_CLI)"
      fi
      tar -xzf "$tmpdir/$asset" -C "$tmpdir"
    fi
    # Archive is expected to contain: codex, codex-code-mode-host, model-catalogs/*, bin/*
    if [ -f "$tmpdir/codex" ]; then
      local dest="$LOCAL_BIN/codex-mod"
      # Keep the mod binary distinct from any stock $LOCAL_BIN/codex
      install -m 755 "$tmpdir/codex" "$dest"
      say "installed $dest ($($dest --version 2>/dev/null || echo '?'))"
    fi
    if [ -f "$tmpdir/codex-code-mode-host" ]; then
      install -m 755 "$tmpdir/codex-code-mode-host" "$tmpdir/codex-code-mode-host.installed" 2>/dev/null || true
      # Place host next to the mod binary so the harness finds it
      cp -p "$tmpdir/codex-code-mode-host" "$(dirname "$LOCAL_BIN/codex-mod")/codex-code-mode-host" 2>/dev/null || true
      # also keep a copy next to the checkout's binary for launch-tier2.sh compat
      if [ -n "$SRCROOT" ]; then
        mkdir -p "$SRCROOT/codex-rs/codex-rs/target/release"
        cp -p "$tmpdir/codex-code-mode-host" "$SRCROOT/codex-rs/codex-rs/target/release/codex-code-mode-host" 2>/dev/null || true
      fi
    fi
    # If the asset bundled catalogs/bins, install them from the tmpdir too (install.sh will also sync from SRCROOT below)
    if [ -d "$tmpdir/model-catalogs" ]; then
      mkdir -p "$CATALOG_DIR"
      cp -p "$tmpdir/model-catalogs/"*.json "$CATALOG_DIR/" 2>/dev/null || true
    fi
    if [ -d "$tmpdir/bin" ]; then
      mkdir -p "$BIN_DIR"
      cp -p "$tmpdir/bin/"* "$BIN_DIR/" 2>/dev/null || true
      chmod +x "$BIN_DIR/"* 2>/dev/null || true
    fi
    trap - EXIT
    rm -rf "$tmpdir"
  fi
}

# Only install/replace binary if not already present at the pinned version
need_binary=1
if [ -x "$LOCAL_BIN/codex-mod" ]; then
  cur="$("$LOCAL_BIN/codex-mod" --version 2>/dev/null | awk '{print $2}')"
  if [ "$cur" = "$PINNED_CLI" ]; then
    echo "modded binary already at $cur — skipping download"
    need_binary=0
  else
    echo "modded binary is $cur, pinned is $PINNED_CLI — updating"
  fi
fi
# Also handle legacy checkout binary
if [ -n "${SRCROOT:-}" ] && [ -x "$SRCROOT/codex-rs/codex-rs/target/release/codex" ]; then
  cur2="$("$SRCROOT/codex-rs/codex-rs/target/release/codex" --version 2>/dev/null | awk '{print $2}' || echo '?')"
  if [ "$cur2" = "$PINNED_CLI" ] && [ "$need_binary" = 1 ] && [ "$MODE" = "binary" ]; then
    echo "checkout binary already at $cur2 — skipping download, linking wrapper"
    ln -sf "$SRCROOT/codex-rs/codex-rs/target/release/codex" "$LOCAL_BIN/codex-mod"
    need_binary=0
  fi
fi

if [ "$need_binary" = 1 ]; then
  install_binary
else
  # Ensure wrapper link exists even when skipping
  if [ -n "${SRCROOT:-}" ] && [ -x "$SRCROOT/codex-rs/codex-rs/target/release/codex" ] && [ ! -x "$LOCAL_BIN/codex-mod" ]; then
    ln -sf "$SRCROOT/codex-rs/codex-rs/target/release/codex" "$LOCAL_BIN/codex-mod"
  fi
fi

# Ensure codex-code-mode-host is next to the modded binary (stock host copy)
if [ -x "$LOCAL_BIN/codex-mod" ]; then
  hostdir="$(dirname "$LOCAL_BIN/codex-mod")"
  if [ ! -x "$hostdir/codex-code-mode-host" ] && [ -x /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host ]; then
    cp -p /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host "$hostdir/codex-code-mode-host"
    echo "copied stock codex-code-mode-host next to modded binary"
  fi
fi
if [ -n "${SRCROOT:-}" ] && [ -x "$SRCROOT/codex-rs/codex-rs/target/release/codex" ]; then
  if [ ! -x "$SRCROOT/codex-rs/codex-rs/target/release/codex-code-mode-host" ] && [ -x /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host ]; then
    cp -p /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host "$SRCROOT/codex-rs/codex-rs/target/release/codex-code-mode-host"
  fi
fi

# --- catalogs ---
say "syncing model catalogs → $CATALOG_DIR"
if [ -n "$SRCROOT" ] && [ -d "$SRCROOT/model-catalogs" ]; then
  cp -p "$SRCROOT/model-catalogs/opencode-go.json" "$CATALOG_DIR/opencode-go.json"
  cp -p "$SRCROOT/model-catalogs/opencode-go-us-contributor.json" "$CATALOG_DIR/opencode-go-us-contributor.json" 2>/dev/null || true
  # Generate the two derived catalogs
  if [ -f "$SRCROOT/sync-us-catalog.py" ]; then
    python3 "$SRCROOT/sync-us-catalog.py"
  else
    cp -p "$SRCROOT/model-catalogs/opencode-go-us.json" "$CATALOG_DIR/opencode-go-us.json" 2>/dev/null || true
    cp -p "$SRCROOT/model-catalogs/opencode-go-us-cli.json" "$CATALOG_DIR/opencode-go-us-cli.json" 2>/dev/null || true
  fi
else
  # curl|bash path: fetch catalogs directly from raw.githubusercontent
  for f in opencode-go.json opencode-go-us-contributor.json; do
    curl -fsSL -o "$CATALOG_DIR/$f" "https://raw.githubusercontent.com/$REPO/main/model-catalogs/$f" || warn "could not fetch $f"
  done
  # Generate derived catalogs via embedded python if sync script not present
  python3 - << 'PY'
import json, pathlib, os
home = pathlib.Path(os.path.expanduser("~/.codex/model-catalogs"))
full = json.loads((home / "opencode-go.json").read_text())
contrib = json.loads((home / "opencode-go-us-contributor.json").read_text())
(home / "opencode-go-us.json").write_text(json.dumps(contrib, indent=1) + "\n")
seen=set(); merged=[]
for e in full["models"] + contrib["models"]:
    s=e.get("slug") or e.get("model")
    if not s or s in seen: continue
    seen.add(s); merged.append(e)
(home / "opencode-go-us-cli.json").write_text(json.dumps({"models": merged}, indent=1) + "\n")
print(f"generated opencode-go-us.json ({len(contrib['models'])}) and opencode-go-us-cli.json ({len(merged)})")
PY
fi

# --- bin helpers ---
say "installing auth helpers → $BIN_DIR"
if [ -n "$SRCROOT" ] && [ -d "$SRCROOT/bin" ]; then
  install -m 755 "$SRCROOT/bin/oc-go-key" "$BIN_DIR/oc-go-key"
  install -m 755 "$SRCROOT/bin/oc-usage" "$BIN_DIR/oc-usage"
else
  for f in oc-go-key oc-usage; do
    curl -fsSL -o "$BIN_DIR/$f" "https://raw.githubusercontent.com/$REPO/main/bin/$f" || warn "could not fetch bin/$f"
    chmod +x "$BIN_DIR/$f" 2>/dev/null || true
  done
fi

# --- config.toml ---
say "patching $CONFIG"
mkdir -p "$(dirname "$CONFIG")"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" << 'TOML'
# Codex config — created by codex-swapper install.sh
TOML
fi
python3 - << 'PY'
import pathlib, re, os
p = pathlib.Path(os.path.expanduser("~/.codex/config.toml"))
t = p.read_text()
changed = False

# Ensure [model_providers.opencode-go] + auth
if '[model_providers.opencode-go]' not in t:
    t += """
[model_providers.opencode-go]
name = "OpenCode Go"
base_url = "https://opencode.ai/zen/go/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.opencode-go.auth]
command = "/Users/REPLACE/.codex/bin/oc-go-key"
timeout_ms = 5000
refresh_interval_ms = 300000
""".replace("/Users/REPLACE", os.path.expanduser("~"))
    changed = True

if '[model_providers.opencode-go-us]' not in t:
    t += """
[model_providers.opencode-go-us]
name = "OpenCode Go US"
base_url = "http://127.0.0.1:18887/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.opencode-go-us.auth]
command = "/Users/REPLACE/.codex/bin/oc-go-key"
timeout_ms = 5000
refresh_interval_ms = 300000
""".replace("/Users/REPLACE", os.path.expanduser("~"))
    changed = True

# Fix older installs that hardcoded /Users/pbarham
if "/Users/pbarham/.codex/bin/oc-go-key" in t:
    t = t.replace("/Users/pbarham/.codex/bin/oc-go-key", os.path.expanduser("~/.codex/bin/oc-go-key"))
    changed = True

# Ensure CLI US profile file exists for `codex exec --profile opencode-go-us`
profile = pathlib.Path(os.path.expanduser("~/.codex/opencode-go-us.config.toml"))
if not profile.exists():
    profile.write_text(f"""# OpenCode Go US — opt-in CLI profile (muse-spark-1.2-contributor via US proxy)
# The proxy (us-forward-proxy.py) routes only muse-spark* through the US exit; everything else is direct.
model = "muse-spark-1.2-contributor"
model_provider = "opencode-go-us-cli"
model_catalog_json = "{os.path.expanduser("~/.codex/model-catalogs/opencode-go-us-cli.json")}"
model_reasoning_effort = "high"
web_search = "live"

[model_providers.opencode-go-us-cli]
name = "OpenCode Go"
base_url = "http://127.0.0.1:18887/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.opencode-go-us-cli.auth]
command = "{os.path.expanduser("~/.codex/bin/oc-go-key")}"
timeout_ms = 5000
refresh_interval_ms = 300000
""")
    print(f"wrote {profile}")

if changed:
    p.write_text(t)
    print(f"patched {p}")
else:
    print(f"{p} already has opencode-go providers")
PY

# --- wrappers ---
say "installing wrappers → $LOCAL_BIN"
# codex-mod is the Mach-O binary itself (installed above). Nothing to do here
# except ensure it is executable; codex-mod-us is a tiny shell wrapper.
# codex-mod-us: opt-in US proxy + modded CLI
cat > "$LOCAL_BIN/codex-mod-us" << 'USWRAP'
#!/usr/bin/env bash
# Opt-in wrapper: ensures US proxy is up, then runs modded CLI with opencode-go-us profile
set -euo pipefail
# Find launch-us-proxy.sh: prefer sibling, checkout, shared install
LAUNCH=""
for q in "$HOME/.local/share/codex-swapper/launch-us-proxy.sh" "$HOME/opt/codex-swapper/launch-us-proxy.sh" "/Users/pbarham/opt/codex-swapper/launch-us-proxy.sh"; do
  if [ -f "$q" ]; then LAUNCH="$q"; break; fi
done
if [ -n "$LAUNCH" ]; then
  "$LAUNCH" 18887 >/dev/null 2>&1 || true
fi
for c in "$HOME/.local/bin/codex-mod" "$HOME/opt/codex-swapper/codex-rs/codex-rs/target/release/codex" "/Users/pbarham/opt/codex-swapper/codex-rs/codex-rs/target/release/codex"; do
  if [ -x "$c" ]; then exec "$c" exec --profile opencode-go-us "$@"; fi
done
echo "error: modded codex binary not found (run install.sh)" >&2
exit 1
USWRAP
chmod +x "$LOCAL_BIN/codex-mod-us"

# Install/update launch-tier2.sh and launch-us-proxy.sh in the checkout for dev ergonomics
if [ -n "${SRCROOT:-}" ]; then
  # launch-tier2.sh is already in the repo; ensure it is executable
  chmod +x "$SRCROOT/launch-tier2.sh" "$SRCROOT/launch-us-proxy.sh" 2>/dev/null || true
fi
# Also install them to ~/.local/bin-adjacent for curl|bash users who want the app launcher
if [ -n "${SRCROOT:-}" ] && [ -f "$SRCROOT/launch-tier2.sh" ]; then
  mkdir -p "$HOME/.local/share/codex-swapper"
  cp -p "$SRCROOT/launch-tier2.sh" "$HOME/.local/share/codex-swapper/launch-tier2.sh"
  cp -p "$SRCROOT/launch-us-proxy.sh" "$HOME/.local/share/codex-swapper/launch-us-proxy.sh" 2>/dev/null || true
  cp -p "$SRCROOT/us-forward-proxy.py" "$HOME/.local/share/codex-swapper/us-forward-proxy.py" 2>/dev/null || true
else
  mkdir -p "$HOME/.local/share/codex-swapper"
  curl -fsSL -o "$HOME/.local/share/codex-swapper/launch-tier2.sh" "https://raw.githubusercontent.com/$REPO/main/launch-tier2.sh" 2>/dev/null || true
  curl -fsSL -o "$HOME/.local/share/codex-swapper/launch-us-proxy.sh" "https://raw.githubusercontent.com/$REPO/main/launch-us-proxy.sh" 2>/dev/null || true
  curl -fsSL -o "$HOME/.local/share/codex-swapper/us-forward-proxy.py" "https://raw.githubusercontent.com/$REPO/main/us-forward-proxy.py" 2>/dev/null || true
  chmod +x "$HOME/.local/share/codex-swapper/launch-tier2.sh" "$HOME/.local/share/codex-swapper/launch-us-proxy.sh" 2>/dev/null || true
fi

# --- US proxy env template ---
if [ "$WITH_US_PROXY" = 1 ]; then
  if [ ! -f "$PROXY_ENV" ]; then
    mkdir -p "$PROXY_ENV_DIR"
    cat > "$PROXY_ENV" << 'ENVEOF'
# Fill in your NordVPN SOCKS5 SERVICE credentials, then: chmod 600 this file.
# Dashboard -> Manual setup -> SOCKS5 (this is NOT your Nord app login).
NORD_SOCKS_USER=
NORD_SOCKS_PASS=
ENVEOF
    chmod 600 "$PROXY_ENV"
    say "created $PROXY_ENV — fill in NORD_SOCKS_USER/PASS to enable muse-spark-1.2-contributor"
  else
    echo "exists $PROXY_ENV (not overwriting)"
  fi
fi

# --- final checks ---
say "install done — running doctor..."
doctor || true

cat << MSG

Next steps:
  1. Add your OpenCode Go API key(s) to the Keychain (once per machine):
       security add-generic-password -a $USER -s opencode-go -w 'sk-...'
       # optional second key for failover:
       # security add-generic-password -a $USER -s opencode-go-alt -w 'sk-...'

  2. Launch the modded desktop app:
       # quit ChatGPT first, then:
       ./launch-tier2.sh            # from a checkout
       # or
       ~/.local/share/codex-swapper/launch-tier2.sh  # curl|bash install
       # plain CLI (no app):
       codex-mod --help
       codex-mod-us -m muse-spark-1.2-contributor "hello"  # via US proxy (needs $PROXY_ENV)

  3. Verify:
       ./install.sh --check

  To update after a ChatGPT.app update:  ./update-mod.sh  (on dev Mac) -> new Release -> ./install.sh on other Macs
  To remove the mod:  ./install.sh --uninstall  (keeps history)
MSG
