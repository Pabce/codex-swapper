# codex-swapper

Modded [openai/codex](https://github.com/openai/codex) harness that merges an extra **OpenCode Go** provider into the ChatGPT desktop app's model picker. The installer adds a separate **Codex Swapper.app** launcher without copying or re-signing OpenAI's ChatGPT.app.

Pinned to **ChatGPT.app `26.814.41407`** / **CLI `0.148.0-alpha.15`** (`rust-v0.148.0-alpha.15`, branch `mod-0.148.0-alpha.15`). See `MOD_STATUS.md` and `DESIGN.md`.

Target: **macOS arm64 + recent ChatGPT.app only**. No Linux/Intel compat layers.

---

## One-command install

```bash
# From a checkout (dev machine):
./install.sh

# Or from anywhere (second Mac, colleague's Mac):
curl -fsSL https://raw.githubusercontent.com/Pabce/codex-swapper/main/install.sh | bash
```

This:
- Installs the prebuilt `codex-mod` binary to `~/.local/bin/codex-mod` (Mach-O arm64)
- Copies the stock `codex-code-mode-host` next to it so `codex app` command runner still works
- Syncs model catalogs to `~/.codex/model-catalogs/` (`opencode-go.json` + US variants)
- Patches `~/.codex/config.toml` idempotently (adds `[model_providers.opencode-go]` + `opencode-go-us`, never clobbers your `projects.*` / history)
- Installs auth helpers `~/.codex/bin/oc-go-key` + `oc-usage`
- Installs `/Applications/Codex Swapper.app`, a small locally signed launcher with its own icon and bundle identity
- Leaves `~/.codex` sessions/history untouched. Re-running is safe.

```bash
./install.sh --check          # doctor: versions, Keychain, smoke
./install.sh --with-us-proxy  # also template ~/.config/codex-swapper/us-proxy.env (Nord SOCKS5 service creds)
./install.sh --from-source    # build locally (needs cargo + ~12 GiB free, ~20 min)
./install.sh --uninstall      # remove mod wiring, keep history
```

### Add your OpenCode Go API key(s) — once per machine

Keys are read from the macOS Keychain by `~/.codex/bin/oc-go-key`, never from disk.

```bash
security add-generic-password -a $USER -s opencode-go -w 'sk-...'
# optional second key for automatic failover on 429 / usage exhaustion:
security add-generic-password -a $USER -s opencode-go-alt -w 'sk-...'

# Check usage (cached for sandboxed Codex turns):
~/.codex/bin/oc-usage
~/.codex/bin/oc-usage --short
```

### Launch

```bash
# Click "Codex Swapper" in Applications, Spotlight, or the Dock.
# The launcher offers to quit ChatGPT first when the stock app is running.
open -a "Codex Swapper"

# Command-line equivalents:
./launch-tier2.sh                              # from a checkout
~/.local/share/codex-swapper/launch-tier2.sh  # curl|bash install

# CLI without the app (gateway models need the profile for provider + catalog):
codex-mod --help
codex-mod exec --profile opengo -m deepseek-v4-flash "hello"
codex-mod exec --profile opengo -m ox-alpha-free "hello"

# Opt-in US exit for muse-spark-1.2-contributor (needs ~/.config/codex-swapper/us-proxy.env):
codex-mod-us -m muse-spark-1.2-contributor "hello"
```

`Codex Swapper.app` has bundle id `dev.pbarham.codex-swapper.launcher` and uses the blue-purple Codex terminal icon shipped inside ChatGPT.app, so it is visually distinct from the stock ChatGPT icon. It remains a lightweight launcher: after checking the single-instance boundary, it runs `launch-tier2.sh` and exits.

`launch-tier2.sh` forwards `CODEX_CLI_PATH` (modded binary) + `CODEX_HOME=~/.codex` through process-scoped `open --env` arguments, so the app shows your real projects/sessions/config without changing the GUI session's global environment.

Set `START_US_PROXY=0` to launch without the US proxy (then the contributor row errors but all direct models still work).

---

## Updating

The mod tracks the **bundled CLI version** inside ChatGPT.app (blue update button updates both). After ChatGPT.app updates:

1. On the **dev Mac**: `./update-mod.sh [NEW_VERSION]` — finds upstream tag, cherry-picks mod commits, rebuilds, smoke-tests, updates `MOD_STATUS.md`.
2. Tag + push: `git tag 0.149.0-alpha.1 && git push origin 0.149.0-alpha.1` → GitHub Actions builds `codex-macos-arm64-0.149.0-alpha.1.tar.gz` + Release.
3. On **other Macs**: `./install.sh` (or `curl … | bash`) — downloads the new asset, patches in place.

---

## Model notes

Probed against `https://opencode.ai/zen/go/v1` with the exact Codex request shape (see `model_compat_probe.py`):

Working (real `codex-mod exec` turns, exit 0): `deepseek-v4-flash`, `deepseek-v4-pro`, `gpt-5.6-luna`, `muse-spark-1.2`, `grok-4.5`, `hy3`, `glm-5*`, `kimi-k2*`, `mimo-v2.5*`. See `MOD_STATUS.md` for per-model `apply_patch` / `web_search` / `namespace` flags.

Working end-to-end (text + shell tool turns, 2026-08-21): `ox-alpha-free` — stealth free preview whose docs entry says chat-completions-only but whose Responses endpoint works. Its SSE stream is degenerate, so the catalog flags it `request_non_streaming`; run it with `codex-mod exec --profile opengo -m ox-alpha-free "..."`. Gateway ID is `ox-alpha-free`; the main Zen API serves the same model as `x-preview-f-free`.

Not promotable on this gateway's Responses API: `minimax-m3/m2.5`, `kimi-k3`, `qwen3.*`, `minimax-m2.7` (500 with tools), `hy3-preview`, `muse-spark-1.2-contributor` (geo-blocked; use the US proxy path).

---

## Building locally

```bash
./build-mod.sh          # release (codegen-units=16, lto=off) ~20 min
./build-mod.sh check    # fast cargo check
./tier2_stdio_smoke.py  # merged model/list + provider resolution smoke
```

---

## Repo layout

```
install.sh              # one-command installer (binary or --from-source)
launch-tier2.sh         # app launcher (CODEX_CLI_PATH via launchctl)
launch-us-proxy.sh      # US SOCKS5 proxy ensure/foreground runner
us-forward-proxy.py     # scoped per-model proxy (only muse-spark* via US exit)
sync-us-catalog.py      # regenerates opencode-go-us.json + opencode-go-us-cli.json
bin/oc-go-key           # Keychain dispatcher (failover + detached oc-usage cache refresh)
bin/oc-usage            # usage reporter with sandboxed cache fallback
model-catalogs/*.json   # source catalogs (installed to ~/.codex/model-catalogs/)
codex-rs/               # fork of openai/codex (branch mod-0.148.0-alpha.15)
```

Secrets (`~/.config/codex-swapper/us-proxy.env`, Keychain items, `~/.codex/auth.json`) are never committed — see `.gitignore`.

---

## Troubleshooting

```bash
./install.sh --check            # versions, Keychain, catalogs, smoke
~/.codex/bin/oc-usage --json    # which key is active, usage percents
curl -s http://127.0.0.1:18887/healthcheck  # US proxy liveness
```

If `install.sh` says `download failed`: the pinned Release asset isn't published yet — use `./install.sh --from-source` on the dev Mac and push a tag.

If a model 500s with `client_metadata` / `custom` tools / `namespace` errors: that's the per-model compatibility layer — see `MOD_STATUS.md` and `model-catalogs/*.json`.
