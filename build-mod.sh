#!/usr/bin/env bash
# Fast release build for the codex-swapper mod.
#
# The stock workspace release profile (lto="thin", codegen-units=4, no
# incremental) makes codex-core codegen the long pole of every mod rebuild.
# This wrapper overrides the profile for the mod loop and MUST be used for
# every rebuild: flipping these flags later forces a full recompile, so keep
# them stable once the first build completes.
#
#   CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16  (4 -> 16; better LLVM parallelism on 10 cores)
#   CARGO_PROFILE_RELEASE_LTO=off           (skip the thin-LTO pass; binary slightly larger)
#
# CARGO_INCREMENTAL is intentionally NOT set here: codegen is the long pole and
# incremental costs disk (this machine is at ~96% full).
#
# Usage:
#   build-mod.sh            # release build of codex-cli + code-mode host refresh
#   build-mod.sh check      # fast compile-correctness preflight (no codegen)
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
WS="$PROJECT/codex-rs/codex-rs"
APP_HOST="/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host"

# If we are on a machine without the fork checkout (e.g. CI or colleague's
# --from-source), clone upstream at the pinned tag and apply mod.patch.
PINNED_TAG="rust-v0.148.0-alpha.15"
if [ ! -d "$WS" ]; then
  echo "codex-rs checkout not found — cloning openai/codex at $PINNED_TAG..."
  mkdir -p "$(dirname "$WS")"
  if [ ! -d "$PROJECT/codex-rs/.git" ]; then
    git clone https://github.com/openai/codex.git "$PROJECT/codex-rs" --branch "$PINNED_TAG" --depth 1
    # The clone above checks out the tag directly; move it to codex-rs/codex-rs layout expected by the workspace:
    # openai/codex already has the workspace at its root; our WS is codex-rs/codex-rs, so the extra level is the repo root.
    # Actually openai/codex repo root IS the workspace root (codex-rs/ is inside). The extra codex-rs/codex-rs nesting in
    # this repo is historical (we cloned into codex-rs/ and the workspace is codex-rs/codex-rs). For a fresh clone we
    # keep the same nesting: clone into codex-rs and the workspace is codex-rs/codex-rs.
    :
  fi
  if [ -f "$PROJECT/mod.patch" ]; then
    echo "applying mod.patch..."
    git -C "$PROJECT/codex-rs" checkout -B "mod-$PINNED_TAG" "$PINNED_TAG" 2>/dev/null || git -C "$PROJECT/codex-rs" checkout -b "mod-$PINNED_TAG" "$PINNED_TAG"
    git -C "$PROJECT/codex-rs" apply --3way "$PROJECT/mod.patch" || {
      echo "patch apply failed — trying git am" >&2
      git -C "$PROJECT/codex-rs" am --3way "$PROJECT/mod.patch" || exit 1
    }
  else
    echo "warning: mod.patch not found — building stock codex (no mod)" >&2
  fi
fi

export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_PROFILE_RELEASE_LTO=off

cd "$WS"

if [ "${1:-}" = "check" ]; then
  echo "=== preflight: cargo check --release -p codex-core ==="
  cargo check --release -p codex-core
  exit 0
fi

echo "=== building release (codegen-units=16, lto=off) ==="
cargo build --release -p codex-cli
cp "$APP_HOST" "$WS/target/release/codex-code-mode-host"
echo "code-mode host refreshed"
echo "=== DONE ==="
