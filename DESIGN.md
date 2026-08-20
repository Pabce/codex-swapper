# Codex provider switching — mod design (Phase 2)

Date: 2026-08-18

## Goal

Switch the desktop app + CLI between the OpenAI provider and a custom
provider (`opencode-go`) from inside the app, without breaking daily use.

## Verified seams (current app build 26.814.41407)

- The desktop app resolves the harness binary via `CODEX_CLI_PATH` first, then
  packaged `Resources/codex`. Verified in `app.asar`.
- The app whitelists `model/list`, `config/read`, `config/batchWrite`
  (`reloadUserConfig:true`), and `modelProvider/capabilities/read`.
- The stock app can therefore be pointed at a modded binary with a separate
  `CODEX_HOME` (Tier 2), with no `.app` copy or re-signing.

## Findings that shape the implementation

### 1. Per-thread `model_provider` is already honored end-to-end

The wire protocol and daemon already support per-thread provider override:

- `ThreadStartParams` carries `model_provider: Option<String>`
  (`app-server-protocol/src/protocol/v2/thread.rs`).
- `thread/start` -> `thread_start_inner` ->
  `build_thread_config_overrides(model, model_provider, ...)` ->
  `ConfigOverrides.model_provider`.
- `Config::load_config_with_layer_stack` resolves:
  `model_provider_id = model_provider.or(cfg.model_provider).unwrap_or("openai")`
  then looks the id up in the merged `model_providers` map.

Conclusion: no daemon-level provider routing work is needed. The mod is
primarily about (a) surfacing all providers in `model/list` and (b) resolving
the provider from the selected model id when the client does not send
`model_provider`.

### 2. `model/list` only lists the active provider

- `catalog_processor::model_list` calls `supported_models()` which calls
  `ThreadManager::list_models()` -> `ModelsManager::list_models()`.
- `build_models_manager()` constructs one models manager from the active
  provider only (`create_model_provider(config.model_provider, ...)`).
- `opencode-go` uses `model_catalog_json`, so it maps to
  `StaticModelsManager`.

To merge catalogs, `catalog_processor::model_list` must enumerate all
registered providers and merge their model lists, rather than listing one
provider.

### 3. The protocol `Model` has no provider tag

`app-server-protocol/src/protocol/v2/model.rs`'s `Model` struct has `id`,
`model`, `display_name`, etc., but no `model_provider` field. A provider tag
added here would be dropped by the closed desktop app (its bundled TS types
do not know about the field), so tagging must be id/name based for the
harness-only path.

### 4. The desktop app sends `modelProvider: null` for normal picks

`app.asar` inspection shows normal `thread/start` / `thread/resume` /
`thread/fork` requests send `modelProvider: null` with the selected
`model`. The only in-app path that sets `modelProvider` is the built-in
Copilot provider flow (`codex_vscode_copilot`), which is hardcoded and reads
a keychain secret.

Consequence: when a custom-provider model is chosen from a merged picker, the
daemon must infer `model_provider` from the selected `model` id because the
app will not send it.

### 5. Per-provider catalogs are not in the config schema

`model_catalog_json` is a single top-level key, not a field of
`ModelProviderInfo`. When the base provider is `openai`, the opencode-go
catalog is not loaded into `Config.model_catalog`. To merge catalogs we need
either:

1. per-provider catalog path support (`ModelProviderInfo.model_catalog_json`),
   or
2. a convention (e.g. `~/.codex/model-catalogs/<provider-id>.json`), or
3. remote catalog fetch from each custom provider.

## Recommended implementation (harness-only)

Status: A, B, and the catalog injection are implemented in the local fork and
build cleanly with passing unit tests.

### A. Merge catalogs in `model/list` (DONE)

In `catalog_processor::list_models` / `models.rs`, replace single-provider
`supported_models()` with a merged listing that iterates registered
providers, loads each provider's catalog, and returns one `Vec<Model>`.
Keep fallback semantics per provider.

Implementation: `app-server/src/models.rs::merged_supported_models` plus a
convention-based static-catalog loader
`<codex_home>/model-catalogs/<provider-id>.json`.

### B. Resolve provider from model id on thread start (DONE)

In `thread_start_inner` (and the resume/fork equivalents), before
`build_thread_config_overrides`, compute:

```text
model_provider = model_provider
    .or_else(|| resolve_provider_for_model(&config, model.as_deref()))
```

where `resolve_provider_for_model` looks up the requested model id across the
same merged provider catalogs used by `model/list`.

Implementation: `ThreadRequestProcessor::build_thread_config_overrides` calls
`models::resolve_model_provider` when the client omits `model_provider`.

### B2. Inject the static catalog for the resolved provider (DONE)

`ConfigManager::load_with_cli_overrides` injects `model_catalog_json` into the
per-thread request overrides when the resolved provider is custom and
`<codex_home>/model-catalogs/<provider-id>.json` exists. Without this the
provider is treated as remote-catalog and the daemon tries to fetch `/models`,
which fails against backends that do not speak the Codex catalog schema.

Verified empirically: the OpenCode Go `/models` endpoint returns an
OpenAI-style `{"object":"list","data":[...]}` body, not Codex's
`{"models":[...]}`, so the static catalog is required.

### B3. Give cross-provider threads their own models manager (DONE)

`ThreadManagerState::spawn_thread` reused the shared models manager built from
the startup config. For a thread that resolves to a different provider that
means model metadata was still looked up against the wrong provider, producing
`Unknown model ... will use fallback model metadata`. The fix stores the
startup `model_provider_id` and, when a thread resolves to a different
provider, builds a per-thread models manager from the thread config via
`build_models_manager`.

Verified via the stdio smoke test: `model/list` returns the merged catalog and
`thread/start` with `modelProvider: null` resolves `modelProvider: opencode-go`
with no fallback-metadata warning.

### B4. Disambiguate colliding model ids in the picker (DONE, 2026-08-19)

The desktop picker keys selection on the `model` slug (`e.model === selectedModel`
in the app bundle). When the active provider and a custom provider both expose
the same slug (OpenAI's `gpt-5.6-luna` and opencode-go's `gpt-5.6-luna`), every
colliding row renders as selected at the same time.

Fix (commits `82f043fe3` + `ae7326407` on `mod-0.148.0-alpha.15`):

1. `app-server/src/models.rs::merged_supported_models` tracks claimed slugs in a
   deterministic order (active provider first, then registered custom providers
   sorted by id). A custom-provider catalog model whose slug is already claimed
   is emitted under the provider-namespaced form `<provider-id>/<slug>` for both
   `id` and `model`, and its `display_name` is suffixed with ` · <provider name>`
   (e.g. `GPT 5.6 Luna · OpenCode Go`). Non-colliding custom models keep their
   bare slug.
2. `resolve_model_provider_in_catalogs` first checks the explicit
   `<provider-id>/<slug>` form (validating the namespace is a registered custom
   provider whose catalog contains the suffix), then falls back to the existing
   catalog search for bare slugs. This is what lets `thread/start` /
   `thread/resume` / `thread/fork` resolve `opencode-go/gpt-5.6-luna` to
   provider `opencode-go` while storing the namespaced model verbatim (so the
   picker highlight matches the thread).
3. `models-manager/src/manager.rs::construct_model_info_from_candidates` already
   matched namespaced slugs against catalog metadata (`find_model_by_namespaced_suffix`).
   When that lookup is the one that matched, `model_info.slug` is now rewritten
   to the bare suffix so the wire request to the provider carries `gpt-5.6-luna`,
   not `opencode-go/gpt-5.6-luna`. The namespace is a picker-level
   disambiguation, never part of the backend model id.

Known caveat: threads created *before* this fix that store the bare `gpt-5.6-luna`
slug under `model_provider = opencode-go` (3 rows in the live DB) will show the
OpenAI row highlighted in the picker until the user re-selects the namespaced
`opencode-go/gpt-5.6-luna` entry. The thread still runs correctly; the stored
`model_provider` is independent of the slug.

### B5. OpenCode Go key failover on usage exhaustion (DONE, 2026-08-19)

Two OpenCode Go subscriptions are held in the login Keychain (`opencode-go` and
`opencode-go-alt`, account `pbarham`). When the active one hits its quota the
turn should roll onto the other key instead of failing.

**What the gateway actually does when exhausted** (probed live, and confirmed
against the `opencode` client's own error parsing in `~/.opencode/bin/opencode`):

- Quota exhaustion is **HTTP 429** (captured live on 2026-08-19 against a
  weekly-exhausted key):

  ```json
  {"type":"error","error":{"type":"GoUsageLimitError",
    "message":"Weekly usage limit reached. Resets in 4 days. …"},
   "metadata":{"workspace":"wrk_…","limitName":"weekly"}}
  ```

  The free tier emits `FreeUsageLimitError` in the same shape. The opencode
  client maps them to `reason: "account_rate_limit"` / `"free_tier_limit"` and
  shows a "Go limit reached" / "Free limit reached" upsell.
- A missing or empty bearer token is a plain `401`:
  `{"type":"error","error":{"type":"AuthError","message":"Missing API key."}}`.
- So the mod arms on `401 | 402 | 403 | 429` rather than on body sniffing —
  every exhaustion/auth shape the gateway can emit lands in that set.

**Reading remaining quota without the website**: `GET https://opencode.ai/zen/go/v1/usage`
is key-gated and returns exactly the workspace-dashboard data:

```json
{"usage":{"rolling":{"status":"ok","percent":58,"resetsAt":"..."},
          "weekly":{"status":"ok","percent":81,"resetsAt":"..."},
          "monthly":{"status":"ok","percent":40,"resetsAt":"..."}}}
```

`status` goes to `rate-limited` at 100%. Sibling guesses (`/limits`, `/account`,
`/me`, `/subscription`, `/billing`) are all 404; `/models` is public (200 with a
bogus key) so it cannot be used to validate a key. Cloudflare rejects urllib's
TLS fingerprint (error 1010) — the tool uses `curl`.
`~/.codex/bin/oc-usage` prints both keys' windows, marks which key the
dispatcher will hand out next, and is on `PATH` via `~/.local/bin/oc-usage`.

**Consulting usage from inside Codex** (app and CLI): skill
`$CODEX_HOME/skills/opencode-go-usage` tells the agent to run `oc-usage`; both
surfaces read the same skills directory. One wrinkle drove the design — Codex
runs agent shell commands inside a sandbox that **blocks Keychain access**, so
the live fetch fails under `read-only` and `workspace-write` alike (verified;
only `danger-full-access` succeeds). So `oc-usage` caches each successful fetch
to `$CODEX_HOME/oc-usage.json` — percentages, status and reset times only, never
key material — and falls back to it with an age label when the Keychain is
unreachable. The cache is kept warm by `oc-go-key`, which the harness runs
*outside* the sandbox on every auth fetch (every `refresh_interval_ms`, 5 min):
it fires a detached, TTL-gated (~10 min) `oc-usage --refresh-cache` that cannot
affect its own output or exit status — the dispatcher still returns in ~90 ms
against a 5 s timeout.

**Implementation** (commit `647bbf0a2`, `core/src/client.rs`):

1. `provider_is_opencode_go` matches the provider by base URL
   (`https://opencode.ai/zen/go/v1`), so no other provider path is touched.
2. A new arm in `ModelClientSession`'s stream loop, placed *before* the existing
   401 arm, fires on that status set when the provider matches and
   `key_rotated == false`. It rotates the state file, then hands the error to
   the stock `handle_unauthorized` recovery so the external auth command is
   re-run and the request retried. `key_rotated` makes it fire at most once per
   turn; the stock recovery tail already returns `Err` when exhausted, so there
   is no loop.
3. `rotate_opencode_go_key_state(home)` flips `<CODEX_HOME>/oc-go.key` between
   `1` and `2` (absent == `1`) and is a no-op when `<CODEX_HOME>/oc-go.override`
   exists (user pin). Path-taking so it is testable without env mutation;
   `flip_opencode_go_key()` is the `find_codex_home()` wrapper.
4. `~/.codex/bin/oc-go-key` is the auth `command` in `config.toml`. It reads the
   pin, then the state file, and prints the matching Keychain secret — falling
   back to the other key when the selected item is missing or empty, so the
   gateway is never handed an empty token.

Unit tests: `client::tests::{rotate_opencode_go_key_state_defaults_to_key_two_then_back,
rotate_opencode_go_key_state_respects_override, provider_is_opencode_go_matches_only_gateway_url}`.

End-to-end (2026-08-19): with the auth command pointed at a test dispatcher that
returns an invalid key for state 1 and the real key for state 2, a
`codex exec -m deepseek-v4-flash -c model_provider="opencode-go"` turn completed
(`EXIT=0`) and `oc-go.key` was left at `2` — the turn could only succeed via the
rotation + retry.

**CLI path (verified 2026-08-19)**: the arm lives in `codex-core`, so it is
shared by the desktop app-server, `codex exec`, and the TUI. Two things gate it
from the command line:

1. **Binary.** `codex` on `PATH` resolves to the stock app-bundled CLI
   (`/Applications/ChatGPT.app/Contents/Resources/codex`, then the standalone
   `~/.codex/packages/standalone/current/bin/codex`) — neither has the mod. Use
   `codex-mod` (symlink in `~/.local/bin` -> the release build).
2. **Profile.** `~/.codex/opencode-go.config.toml` layers its *own*
   `[model_providers.opencode-go.auth]` block over the base config, so it had to
   be pointed at the dispatcher too — otherwise the profile silently reinstated
   the direct `/usr/bin/security` lookup and pinned key 1.

Real (not fault-injected) end-to-end with key 1 weekly-exhausted:
`codex-mod exec --profile opencode-go "Reply with exactly: OK"` -> the gateway
returned 429 on key 1, the mod rotated `~/.codex/oc-go.key` to `2`, retried, and
the turn completed (`EXIT=0`). A second turn started on key 2 and completed
without rotating, confirming the state is sticky and the arm does not flap.

Note: the provider-from-model resolution is an app-server-path mod, so a CLI run
without `--profile opencode-go` still needs `-c model_provider="opencode-go"` to
reach the gateway at all.

### C. TUI `/provider` (Tier 1 sandbox first)

- `tui/src/chatwidget/model_popups.rs` is the `/model` picker.
- A `/provider` command would list registered providers and switch the active
  provider for the session, then refresh the model list.
- This is the safest place to prototype before attempting the desktop path.

## Open items

- Confirm the desktop app passes a custom model id verbatim in
  `ThreadStartParams.model` when selected from a merged picker (runtime check
  needed via a real desktop launch).
- Confirm whether the OpenCode Go backend executes the `web_search` tool.
- Decide catalog-source strategy long term (per-provider config field vs. the
  current `<codex_home>/model-catalogs/<id>.json` convention vs. remote fetch).

## Critical operational requirement: RELEASE builds only (2026-08-19)

The modded harness must be built with `cargo build --release`, never debug.

Root cause of a real incident: `codex-core::util::error_or_panic` is called
when a thread's history contains a `custom_tool_call` without a matching
`custom_tool_call_output` (e.g., a truncated/interrupted rollout).

- Debug build: `cfg!(debug_assertions)` is true -> `panic!` -> the tokio worker
  dies -> every turn on that thread hangs forever (and fork/compact too).
- Release build (and the stock app's bundled binary): logs the error, inserts a
  synthetic `"aborted"` output, and continues.

This exactly matched the stuck-thread symptoms: fresh threads worked, but any
thread with the orphaned call hung, and the stock (release) app did not.

Build the mod with:

```bash
cargo build --release -p codex-cli
cp /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host \
   target/release/codex-code-mode-host
```

Note: turns on a huge thread (85+ turns) can occasionally exceed 90s (slow
model calls, especially near rate-limit exhaustion); this is model/API latency,
not a harness bug, and reproduces identically on the stock binary.

## B6. Model-compat pass + gateway-gap mods (2026-08-19)

Probed every model on `https://opencode.ai/zen/go/v1` with the exact codex
request shape and real `codex-mod exec` turns. Key finding: several models
"support the Responses API" at the basic level but break on specific codex
request features. The failures fall into three gateway-translation gaps, all
now handled:

1. **`client_metadata`** (grok-4.5: `json: unknown field client_metadata`).
   `client_metadata` is OpenAI-internal turn telemetry, so `build_responses_request`
   now attaches it only for the OpenAI provider (commit `1efb81f15`).
2. **Hosted `web_search` tool** (kimi/glm/mimo/hy3 upstreams reject the
   `web_search` tool shape). `spec_plan.rs` now gates emission on
   `model_info.supports_search_tool` in addition to the provider capability
   (commit `1efb81f15`). The flag was previously only used for the file-search
   tool, so web search was being attached to models that reject it.
3. **`namespace` tools** (grok-4.5 rejects the `namespace` discriminator).
   New `ModelInfo.supports_namespace_tools` (default true) gates
   `namespace_tools_enabled` (commit `489022aa9`). MCP/plugin namespaces and
   multi-agent are dropped per-model when the upstream is function-only.

Two models need catalog-only restrictions because their upstreams reject the
freeform `custom` apply_patch tool: `muse-spark-1.2` and `grok-4.5` both set
`apply_patch_tool_type: null`, so codex omits the custom tool and the model
edits via `shell_command`. muse-spark accepts namespace tools and works with
only that restriction; grok additionally needs `supports_search_tool: false`
and `supports_namespace_tools: false` (function tools only).

Open questions this pass left behind:
- muse-spark's `custom`-tool support exists on Meta's own API
  (`https://api.meta.ai/v1`, drop-in OpenAI compatible). A direct `meta`
  provider (key from https://dev.meta.ai) would restore apply_patch; the
  codex-swapper gateway cannot pass `custom` tools to muse-spark today.
- A future mod could map `custom` -> `function` at the wire layer + teach the
  apply_patch handler to accept a `Function` payload, restoring apply_patch for
  custom-tool-averse upstreams without a direct provider. Not done: it is
  invasive and shell-based editing already works.

## B7. muse-spark-1.2-contributor via US egress (2026-08-19, VERIFIED)

The contributor tier is in the OpenCode Go plan (added ~Aug 18-19, generous
quota) and ~16x cheaper than the standard rate, but Meta's contributor preview
is US-focused ("available in select countries" per Meta; community reports say
still US-only) and the opencode gateway enforces it per-source-IP with
`403 RegionError`. The user enabled the dashboard "Allow models that train on
request data" toggle and opted into US routing.

Wiring (opt-in only; default launch mode stays proxy-free and direct):
- `us-forward-proxy.py` on 127.0.0.1:18887 forwards only opencode-go traffic
  through a US SOCKS5 exit (NordVPN us.socks.nordhold.net:1080 + service creds
  from ~/.config/codex-swapper/us-proxy.env) when configured, else pass-through.
  The proxy is NOT started by the default launch path.
- `~/.codex/opencode-go-us.config.toml` — the opt-in CLI profile
  (base_url -> http://127.0.0.1:18887/v1). It uses provider id
  `opencode-go-us-cli` with the FULL catalog
  (`model-catalogs/opencode-go-us-cli.json`: every opencode-go model plus
  muse-spark-1.2-contributor, same capability flags as muse-spark-1.2), so
  the CLI picker (`/model` in the interactive CLI, `-m` in `codex exec`) can
  select every model while the proxy routes only muse-spark* requests through
  the US exit and everything else direct — identical routing semantics to the
  desktop app. The distinct provider id is required because the mod's
  per-thread catalog injection resolves `model-catalogs/<provider-id>.json`;
  sharing the desktop's `opencode-go-us` id would inject the contributor-only
  catalog into every CLI thread (and sharing the full catalog would flood the
  desktop picker with `opencode-go-us/*` duplicate rows).
- `model-catalogs/opencode-go-us.json` — contributor-only catalog for the
  DESKTOP app's `opencode-go-us` provider (one clean picker row; DESIGN B4).
  `sync-us-catalog.py` regenerates both catalog files from
  `model-catalogs/opencode-go.json` (full list) +
  `model-catalogs/opencode-go-us-contributor.json` (contributor entry).
- `codex-mod-us` wrapper ensures the proxy then runs
  `codex exec --profile opencode-go-us`.
- Mod commit `6e11e883a`: provider_is_opencode_go also matches the loopback
  proxy base_url so key failover stays armed on the US path.

Verified 2026-08-19 via NordVPN US SOCKS5 exit: direct probe returns 200 (no
RegionError); a real `codex-mod-us -m muse-spark-1.2-contributor` turn and a
real file-edit turn (wrote + verified /tmp/contrib_probe.txt) both completed
(exit 0).

Verified per-model routing 2026-08-19: muse-spark-1.2-contributor -> US exit,
deepseek-v4-flash -> direct (proxy log lines), both turns exit 0. Only muse
requests egress through the VPN; everything else in the US profile is direct.

Desktop app: opencode-go-us is registered in ~/.codex/config.toml (name
"OpenCode Go US") with a contributor-only catalog, and launch-tier2.sh starts
the proxy. Standalone-stdio app-server turns hang in shell-snapshot setup in
the Codex sandbox for every provider (incl. the OpenAI turn smoke), so the
in-app click-through must be validated in a real launch-tier2.sh session.

Operational notes:
- Contributor tier is token-rate-limited in a rolling ~5h window (Meta docs),
  and it is the data-for-training tier ("used to improve our products").
- The US exit is a NordVPN shared datacenter IP; if opencode/Meta or Cloudflare
  starts flagging it, the fallback is a clean US VPS SOCKS5 exit.
- Desktop app is not wired to the proxy by default; add
  `[model_providers.opencode-go-us]` to config.toml to expose it in the picker
  later if wanted.
