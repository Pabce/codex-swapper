#!/usr/bin/env bash
# Tier 2 launcher: stock ChatGPT.app + modded codex harness, using the real
# ~/.codex home so your existing projects, sessions, and config all show up.
#
# We launch via `open` (so the GUI app is properly detached from this shell),
# and forward the env through `launchctl setenv` because `open` does not pass
# arbitrary env vars to the app. The vars are unset again afterward so they do
# not leak into every later GUI app.
#
# Important: the desktop app is single-instance. If it is already running,
# `open` will just activate the existing process without these env vars. Quit
# the app first, then run this script.
set -euo pipefail

# Resolve modded binary: prefer checkout, then ~/.local/bin/codex-mod (Release install)
PROJECT="$(cd "$(dirname "$0")" && pwd)"
CANDIDATES=(
  "$PROJECT/codex-rs/codex-rs/target/release/codex"
  "$HOME/.local/bin/codex-mod"
  "/Users/pbarham/opt/codex-swapper/codex-rs/codex-rs/target/release/codex"
)
MODDED_CODEX=""
for c in "${CANDIDATES[@]}"; do
  if [ -x "$c" ]; then MODDED_CODEX="$c"; break; fi
done
if [ -z "$MODDED_CODEX" ]; then
  echo "error: modded codex binary not found. Tried:" >&2
  printf '  %s
' "${CANDIDATES[@]}" >&2
  echo "hint: ./install.sh  (or ./install.sh --from-source)" >&2
  exit 1
fi
MODDED_CODE_MODE_HOST="$(dirname "$MODDED_CODEX")/codex-code-mode-host"
# Legacy checkout host location
if [ ! -x "$MODDED_CODE_MODE_HOST" ] && [ -x "$PROJECT/codex-rs/codex-rs/target/release/codex-code-mode-host" ]; then
  MODDED_CODE_MODE_HOST="$PROJECT/codex-rs/codex-rs/target/release/codex-code-mode-host"
fi
STOCK_CODE_MODE_HOST="/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host"
MOD_HOME="$HOME/.codex"
APP_NAME="ChatGPT"

# Proxy launcher: prefer sibling, then checkout, then shared install
find_proxy_launcher() {
  for q in "$(dirname "$MODDED_CODEX")/launch-us-proxy.sh" "$PROJECT/launch-us-proxy.sh" "$HOME/.local/share/codex-swapper/launch-us-proxy.sh" "/Users/pbarham/opt/codex-swapper/launch-us-proxy.sh"; do
    if [ -f "$q" ]; then echo "$q"; return 0; fi
  done
  return 1
}

# The opencode-go-us provider (muse-spark-1.2-contributor) routes through the
# scoped US-forwarding proxy on 127.0.0.1:18887. Start it so the picker row
# works; set START_US_PROXY=0 to launch without the proxy (then the
# contributor row will error but all direct models still work).
if [ "${START_US_PROXY:-1}" = "1" ]; then
  LAUNCH="$(find_proxy_launcher || true)"; [ -n "$LAUNCH" ] && "$LAUNCH" 18887
fi

# The harness resolves codex-code-mode-host next to its own executable. The
# modded debug binary has no sibling host, and building one from source is
# blocked on a V8 prebuilt-archive download. Reuse the stock app host so the
# command runner remains available.
if [ ! -x "$MODDED_CODE_MODE_HOST" ] && [ -x "$STOCK_CODE_MODE_HOST" ]; then
  cp -p "$STOCK_CODE_MODE_HOST" "$MODDED_CODE_MODE_HOST"
  echo "copied stock codex-code-mode-host next to modded binary"
fi

echo "launching $APP_NAME via open with:"
echo "  CODEX_CLI_PATH=$MODDED_CODEX"
echo "  CODEX_HOME=$MOD_HOME"

launchctl setenv CODEX_CLI_PATH "$MODDED_CODEX"
launchctl setenv CODEX_HOME "$MOD_HOME"
open -a "$APP_NAME"
# Give LaunchServices time to spawn the app before clearing the env.
sleep 3
launchctl unsetenv CODEX_CLI_PATH
launchctl unsetenv CODEX_HOME

echo
echo "launched. If the app was already running, this only activated it without"
echo "the modded env; quit it first and rerun."
echo "To return to normal daily use, quit the app and open ChatGPT normally."
