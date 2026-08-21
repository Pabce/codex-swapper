#!/usr/bin/env bash
# Build and install the lightweight Codex Swapper launcher app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../launch-tier2.sh" ]; then
  SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/launch-tier2.sh" ]; then
  SOURCE_ROOT="$SCRIPT_DIR"
else
  echo "error: could not locate launch-tier2.sh relative to $SCRIPT_DIR" >&2
  exit 1
fi

if [ "$(uname)" != "Darwin" ]; then
  echo "error: the launcher app is macOS-only" >&2
  exit 1
fi

if [ -n "${CODEX_SWAPPER_APP_PATH:-}" ]; then
  TARGET="$CODEX_SWAPPER_APP_PATH"
elif [ -w /Applications ]; then
  TARGET="/Applications/Codex Swapper.app"
else
  mkdir -p "$HOME/Applications"
  TARGET="$HOME/Applications/Codex Swapper.app"
fi

case "$TARGET" in
  */Codex\ Swapper.app) ;;
  *) echo "error: launcher target must end in 'Codex Swapper.app': $TARGET" >&2; exit 1 ;;
esac

for required in \
  "$SOURCE_ROOT/launcher/CodexSwapperLauncher.swift" \
  "$SOURCE_ROOT/launcher/Info.plist" \
  "$SOURCE_ROOT/launch-tier2.sh" \
  "$SOURCE_ROOT/launch-us-proxy.sh" \
  "$SOURCE_ROOT/us-forward-proxy.py"; do
  if [ ! -f "$required" ]; then
    echo "error: missing launcher source: $required" >&2
    exit 1
  fi
done

SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -z "$SWIFTC" ] || [ ! -x "$SWIFTC" ]; then
  echo "error: swiftc is required to build the local launcher app" >&2
  echo "hint: install the Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
  echo "error: the macOS SDK could not be resolved with xcrun" >&2
  exit 1
fi

ICON_SOURCE="/Applications/ChatGPT.app/Contents/Resources/app.icns"
if [ ! -f "$ICON_SOURCE" ]; then
  ICON_SOURCE="/Applications/ChatGPT.app/Contents/Resources/electron.icns"
fi
if [ ! -f "$ICON_SOURCE" ]; then
  echo "error: ChatGPT launcher icon not found; is /Applications/ChatGPT.app installed?" >&2
  exit 1
fi

STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGING_APP="$STAGING_ROOT/Codex Swapper.app"
MACOS_DIR="$STAGING_APP/Contents/MacOS"
RESOURCES_DIR="$STAGING_APP/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp -p "$SOURCE_ROOT/launcher/Info.plist" "$STAGING_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGING_APP/Contents/PkgInfo"
cp -p "$ICON_SOURCE" "$RESOURCES_DIR/CodexSwapper.icns"
install -m 755 "$SOURCE_ROOT/launch-tier2.sh" "$RESOURCES_DIR/launch-tier2.sh"
install -m 755 "$SOURCE_ROOT/launch-us-proxy.sh" "$RESOURCES_DIR/launch-us-proxy.sh"
install -m 755 "$SOURCE_ROOT/us-forward-proxy.py" "$RESOURCES_DIR/us-forward-proxy.py"

"$SWIFTC" \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  "$SOURCE_ROOT/launcher/CodexSwapperLauncher.swift" \
  -o "$MACOS_DIR/CodexSwapperLauncher"

/usr/bin/codesign --force --sign - --timestamp=none "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

if [ -e "$TARGET" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != "dev.pbarham.codex-swapper.launcher" ]; then
    echo "error: refusing to replace unexpected app at $TARGET (bundle id: ${existing_id:-unknown})" >&2
    exit 1
  fi
  rm -rf "$TARGET"
fi
mkdir -p "$(dirname "$TARGET")"
mv "$STAGING_APP" "$TARGET"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ "${CODEX_SWAPPER_SKIP_REGISTER:-0}" != "1" ] && [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
fi
touch "$TARGET"

echo "installed $TARGET"
echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")"
echo "signature: $(/usr/bin/codesign -dv "$TARGET" 2>&1 | sed -n 's/^Identifier=//p')"
