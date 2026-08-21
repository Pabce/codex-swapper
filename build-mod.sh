#!/usr/bin/env bash
# Fast release build for the codex-swapper mod.
#
# The stock workspace release profile (lto="thin", codegen-units=4, no
# incremental) makes codex-core codegen the long pole of every mod rebuild.
# This wrapper overrides the profile for the mod loop and MUST be used for
# every rebuild: flipping these flags later forces a full recompile, so keep
# them stable once the first build completes.
#
# Tuned for Si-only/latest (2026-08-20):
#   CARGO_PROFILE_RELEASE_CODEGEN_UNITS=32  (4 -> 32; better LLVM parallelism on 10c)
#   CARGO_PROFILE_RELEASE_LTO=off           (skip thin-LTO; binary slightly larger)
#   CARGO_INCREMENTAL=1                     (reuses prior codegen; costs ~20G but sccache helps)
#   RUSTC_WRAPPER=sccache  (if available)  (caches crate compiles across update-mod cherry-picks)
#   zld  (if available)    (fast ld64 drop-in; ~25% link time)
#   CARGO_TARGET_DIR fallback: tries external SSD, then ~/.cache, else default
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
PINNED_TAG="rust-v0.148.0-alpha.21"
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

# --- perf: sccache + incremental + zld + target-dir fallback ---
# sccache and incremental are mutually exclusive (sccache forbids -C incremental).
# We pick one: sccache (better for update-mod cherry-picks) OR incremental+custom target.
# zld is independent.

# 1) sccache (if installed): caches crate compiles across builds; disables incremental
if command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER=sccache
  export SCCACHE_DIR="${SCCACHE_DIR:-$HOME/.cache/sccache}"
  mkdir -p "$SCCACHE_DIR" 2>/dev/null || true
  sccache --start-server >/dev/null 2>&1 || true
  unset CARGO_INCREMENTAL
  echo "sccache: enabled (cache at $SCCACHE_DIR, incremental OFF)"; sccache --show-stats 2>&1 | grep -E "Cache size|Hit rate" | head -n 2 || true
  echo "target: default ./target (sccache active; custom CARGO_TARGET_DIR disabled for compatibility)"
else
  echo "sccache: not found (brew install sccache for ~30% faster rebuilds)"
  export CARGO_INCREMENTAL=1
  echo "incremental: enabled (no sccache)"
  # 2) CARGO_TARGET_DIR: only when sccache is OFF, keep 20G target off the nearly-full Data volume
  _try_target_dir() {
    local cand
    for cand in "/Volumes/Extreme SSD/codex-target" "$HOME/.cache/codex-swapper/target" ""; do
      if [ -z "$cand" ]; then
        echo "using default CARGO_TARGET_DIR (./target)"
        return 0
      fi
      if mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ]; then
        export CARGO_TARGET_DIR="$cand"
        echo "using CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
        return 0
      fi
    done
  }
  _try_target_dir
fi

# 3) zld (if installed): fast ld64 drop-in
if command -v zld >/dev/null 2>&1; then
  export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-fuse-ld=$(command -v zld)"
  echo "zld: enabled ($(command -v zld))"
else
  echo "zld: not found (brew install michaeleisel/zld/zld for ~25% faster links)"
fi

export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=32
export CARGO_PROFILE_RELEASE_LTO=off

cd "$WS"

if [ "${1:-}" = "check" ]; then
  echo "=== preflight: cargo check --release -p codex-core ==="
  cargo check --release -p codex-core
  exit 0
fi

echo "=== building release (codegen-units=32, lto=off, incremental=1, sccache=${RUSTC_WRAPPER:-none}, zld=$(command -v zld >/dev/null 2>&1 && echo yes || echo no), target=${CARGO_TARGET_DIR:-$WS/target}) ==="
cargo build --release -p codex-cli
# copy host next to the produced binary (honours CARGO_TARGET_DIR)
_target="${CARGO_TARGET_DIR:-$WS/target}"
cp "$APP_HOST" "$_target/release/codex-code-mode-host"
echo "code-mode host refreshed"
echo "=== DONE ==="
