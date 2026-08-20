#!/usr/bin/env bash
# update-mod.sh [VERSION] — re-pin the codex-swapper mod to a new app/CLI release.
#
# The desktop app bundles its own `codex` CLI (the blue update button updates
# both). The mod MUST track the exact bundled release, never upstream HEAD.
#
# Usage:
#   update-mod.sh            # auto-detect version from the app bundle
#   update-mod.sh 0.149.0-alpha.1
#
# Steps: locate upstream tag -> new branch -> cherry-pick all mod commits ->
# release build -> refresh code-mode host -> smoke test -> update MOD_STATUS.md.
set -euo pipefail

PROJECT="/Users/pbarham/opt/codex-swapper"
FORK="$PROJECT/codex-rs"
WS="$FORK/codex-rs"
APP_CODEX="/Applications/ChatGPT.app/Contents/Resources/codex"
APP_HOST="/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host"
SMOKE="$PROJECT/tier2_stdio_smoke.py"
STATUS="$PROJECT/MOD_STATUS.md"
REMOTE="origin"

echo "=== codex-swapper update ==="

# 1. Determine the target version.
NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
  NEW_VERSION="$("$APP_CODEX" --version 2>/dev/null | awk '{print $2}')"
  if [ -z "$NEW_VERSION" ]; then
    echo "error: could not detect bundled CLI version; pass it as an argument" >&2
    exit 1
  fi
  echo "detected bundled CLI version: $NEW_VERSION"
else
  echo "target version: $NEW_VERSION"
fi

# 2. Locate the upstream tag (format: rust-v<VERSION>; drop peeled ^{} entries).
cd "$FORK"
TAG_LINE="$(git ls-remote --tags "$REMOTE" 2>/dev/null |
  grep -Fv '^{}' |
  grep -F "refs/tags/rust-v$NEW_VERSION" |
  head -1)"
if [ -z "$TAG_LINE" ]; then
  echo "error: no upstream tag rust-v${NEW_VERSION} found." >&2
  echo "  list candidates: git ls-remote --tags $REMOTE | grep ${NEW_VERSION}" >&2
  exit 1
fi
TAG="$(printf '%s' "$TAG_LINE" | awk '{print $2}' | sed 's#^refs/tags/##')"
if [ "$TAG" != "rust-v$NEW_VERSION" ]; then
  echo "error: expected tag rust-v${NEW_VERSION} but found '${TAG}'" >&2
  exit 1
fi
echo "upstream tag: $TAG"

# 3. Snapshot EVERY mod commit on the current branch (there is more than one).
# The mod branch is named mod-<old-version> and was branched off
# rust-v<old-version>, so that tag is the base the mod commits sit on top of.
CURRENT_BRANCH="$(git branch --show-current)"
if [ -z "$(git status --porcelain)" ]; then :; else
  echo "error: working tree is dirty; commit the mod changes before updating." >&2
  git status --short >&2
  exit 1
fi
case "$CURRENT_BRANCH" in
  mod-*) OLD_TAG="rust-v${CURRENT_BRANCH#mod-}" ;;
  *) echo "error: expected to be on a mod-<version> branch, got '$CURRENT_BRANCH'" >&2; exit 1 ;;
esac
if ! git rev-parse --verify --quiet "$OLD_TAG^{commit}" >/dev/null; then
  echo "error: base tag $OLD_TAG not found locally (git fetch $REMOTE tag $OLD_TAG)" >&2
  exit 1
fi
MOD_COMMITS="$(git rev-list --reverse "$OLD_TAG..HEAD")"
if [ -z "$MOD_COMMITS" ]; then
  echo "error: no mod commits found in $OLD_TAG..HEAD" >&2
  exit 1
fi
echo "current branch: $CURRENT_BRANCH (base $OLD_TAG)"
echo "mod commits to replay:"
git --no-pager log --oneline --reverse "$OLD_TAG..HEAD" | sed 's/^/  /'

# 4. Fetch the tag, branch off it, replay every mod commit.
git fetch "$REMOTE" tag "$TAG"
NEW_BRANCH="mod-$NEW_VERSION"
if git show-ref --verify --quiet "refs/heads/$NEW_BRANCH"; then
  echo "error: branch $NEW_BRANCH already exists; delete it first (git branch -D $NEW_BRANCH)" >&2
  exit 1
fi
git checkout -b "$NEW_BRANCH" "$TAG"
if ! git cherry-pick $MOD_COMMITS; then
  echo "error: cherry-pick conflicted. Resolve conflicts, 'git cherry-pick --continue'," >&2
  echo "then rerun the build manually (or re-run this script after committing)." >&2
  exit 1
fi
echo "applied mod changes on branch: $NEW_BRANCH"

# 5. Disk check (release build needs ~12 GiB in target/release).
AVAIL_KB="$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')"
if [ "${AVAIL_KB:-0}" -lt 15000000 ]; then
  echo "warning: only $((AVAIL_KB / 1024 / 1024)) GiB free; release build needs ~12 GiB." >&2
  echo "  consider: cd $WS && cargo clean   (frees the old build artifacts)" >&2
fi

# 6. Release build + refresh code-mode host.
cd "$WS"
echo "=== building release (this takes ~30 min; watch cargo output) ==="
cargo build --release -p codex-cli
cp "$APP_HOST" "$WS/target/release/codex-code-mode-host"
echo "code-mode host refreshed"

# 7. Smoke test (merged model/list + thread/start provider resolution).
echo "=== running smoke test ==="
python3 "$SMOKE"

# 8. Record state.
cat > "$STATUS" <<EOF
# MOD_STATUS — codex-swapper mod pinned state

Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Pinned release
- App build: $("$APP_CODEX" --version 2>/dev/null | tr '\n' ' '; echo "(app: $(defaults read /Applications/ChatGPT.app/Contents/Info CFBundleShortVersionString 2>/dev/null))")
- Bundled CLI (app Resources/codex): $NEW_VERSION
- Upstream tag: $TAG
- Fork branch: $NEW_BRANCH
- Fork commit: $(git rev-parse --short HEAD)

## Binary
- Path: $WS/target/release/codex
- Profile: release (NEVER debug — debug panics in error_or_panic)
- code-mode host: copied from app bundle (version-matched)

## Verification
- tier2_stdio_smoke.py: PASSED on $(date -u +%Y-%m-%d)

## Update procedure
Run: $PROJECT/update-mod.sh [VERSION]
EOF

echo
echo "=== DONE ==="
echo "Quit ChatGPT, then relaunch with: $PROJECT/launch-tier2.sh"
