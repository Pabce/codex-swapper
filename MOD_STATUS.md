# MOD_STATUS — codex-swapper mod pinned state

Last updated: 2026-08-20T12:00:00Z (CLI US profile now exposes all models)

## Pinned release
- App build: 26.814.41407
- Bundled CLI (app Resources/codex): 0.148.0-alpha.15
- Upstream tag: rust-v0.148.0-alpha.15
- Fork branch: mod-0.148.0-alpha.15
- Fork commit: 308ff33a0 (82f043fe3 -> ae7326407 -> 647bbf0a2 -> 1efb81f15 -> 489022aa9 -> 6e11e883a; base ffe1de5ce)

## Binary
- Path: /Users/pbarham/opt/codex-swapper/codex-rs/codex-rs/target/release/codex
- Profile: release (NEVER debug — debug panics in error_or_panic)
- code-mode host: copied from app bundle (version-matched)
- Build profile: `./build-mod.sh` — CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16, LTO=off
  (fast mod loop; keep these flags stable across rebuilds or you force a full
  recompile). Built 2026-08-19 15:44 (incremental, 19m31s after the fast-profile
  cache warmed).

## Changes (committed on the mod branch)
- app-server/Cargo.toml — `codex-model-provider-info` promoted to a normal dep
- app-server/src/models.rs — merged `model/list` catalogs + `resolve_model_provider`
- app-server/src/request_processors.rs — import for merged models
- app-server/src/request_processors/catalog_processor.rs — `model/list` merge
- app-server/src/request_processors/thread_processor.rs — provider resolved from model id
- app-server/src/config_manager.rs — per-thread static-catalog injection
- core/src/thread_manager.rs — per-thread models manager when provider differs
- app-server/src/models.rs — provider-namespaced slugs for colliding model ids (`ae7326407`)
- models-manager/src/manager.rs — strip the provider namespace from the wire model slug
- models-manager/src/manager_tests.rs — updated namespaced-slug tests
- core/src/client.rs — OpenCode Go key failover arm + state rotation (`647bbf0a2`)
- core/src/client_tests.rs — rotation/provider-match helper tests
- core/src/client.rs — omit `client_metadata` for non-OpenAI providers (`1efb81f15`):
  grok-4.5 on the opencode-go gateway rejected the unknown field
  ("json: unknown field client_metadata"). client_metadata is OpenAI-internal
  telemetry, so custom gateways get none.
- core/src/tools/spec_plan.rs — gate the hosted `web_search` tool on
  `model_info.supports_search_tool` (`1efb81f15`): kimi/glm/mimo/hy3 upstreams
  reject the web_search tool shape ("tools[i].function.name invalid", "[1210]").
- core/src/client_tests.rs — `custom_provider_responses_request_omits_client_metadata` (`1efb81f15`)
- protocol/src/openai_models.rs + core/src/tools/spec_plan.rs —
  `ModelInfo.supports_namespace_tools` (default true) gates namespace-tool
  emission (`489022aa9`): grok-4.5's upstream only accepts `function` tools and
  rejects `namespace` discriminators.

## Model compatibility pass (2026-08-19, against https://opencode.ai/zen/go/v1)
Method: exact-codex-request-shape probes (client_metadata, prompt_cache_key,
instructions, tools incl. function/custom/namespace/web_search/tool_search,
reasoning, text.verbosity, parallel_tool_calls) + real `codex-mod exec` turns.

### Working end-to-end (real codex-mod exec turns, all exit 0)
- deepseek-v4-flash / deepseek-v4-pro — existing; web_search OK
- gpt-5.6-luna — existing; web_search OK (catalog flag flipped true after live verify)
- muse-spark-1.2 — NEW; real file-edit turn completed (wrote + verified
  /tmp/muse_spark_probe.txt). Special-case config: `apply_patch_tool_type: null`
  (see below).
- grok-4.5 — NEW; fixed by the 3 mods. Config: apply_patch null +
  supports_search_tool false + supports_namespace_tools false (function tools only).
- hy3, glm-5.3, kimi-k2.7-code, mimo-v2.5-pro — NEW; web_search OFF.
- Wire-verified, same-family as the above (not individually real-turned):
  glm-5, glm-5.1, glm-5.2, kimi-k2.5, kimi-k2.6, mimo-v2.5.

### muse-spark-1.2 note
- Passes plain and function-call Responses API turns, but the opencode-go
  gateway's muse-spark upstream rejects the freeform `custom` apply_patch tool
  ("`custom` tools are not supported on this endpoint"). The model natively
  supports custom tools on Meta's own API (https://api.meta.ai/v1 — drop-in
  OpenAI compatible, key from https://dev.meta.ai), so this is a gateway
  translation gap, not a model limitation.
- Working config: `apply_patch_tool_type: null` -> codex omits the custom tool;
  muse-spark edits via shell_command. Tradeoff: no structured apply_patch.
- Reasoning efforts verified: minimal/low/medium/high/xhigh (max rejected).
  Catalog lists minimal..xhigh, default medium.

### grok-4.5 note
- Accepted the base codex request (function tools only). Three gateway gaps
  fixed: client_metadata (mod), custom apply_patch + tool_search (catalog:
  apply_patch null + supports_search_tool false), namespace tools (mod +
  supports_namespace_tools false). Tradeoff: no apply_patch / MCP namespaces /
  multi-agent; function-tool agent only.

### Not promotable (Responses API path on this gateway)
- minimax-m3 / minimax-m2.5 / kimi-k3 / qwen3.8-max / qwen3.7-max / qwen3.7-plus /
  qwen3.6-plus / qwen3.5-plus — "Model ... is not supported for format openai"
  (chat-completions/anthropic-only; no Responses API support).
- minimax-m2.7 — accepts the Responses input shape but 500s when any tool is attached.
- mimo-v2-pro / mimo-v2-omni — deprecated upstream (migrate to mimo-v2.5*).
- hy3-preview — "Model is unavailable".
- muse-spark-1.2-contributor — geo-blocked ("not available in your country").

## Reasoning-effort arrays (catalog data only)
- muse-spark-1.2 — minimal/low/medium/high/xhigh (max rejected); default medium.
- grok-4.5, hy3, glm-5*, kimi-k2*, mimo-v2.5* — low/medium/high/xhigh/max; default medium.
- deepseek / luna — unchanged from prior verification.

## Verification
- tier2_stdio_smoke.py: PASSED — merged `model/list` returns 8 OpenAI + 15 opencode-go
  entries; muse/grok/hy3/glm/kimi/mimo present; luna namespace + deepseek resolution intact.
- Unit tests: client_tests (incl. new custom-provider client_metadata test) PASS.
- Real turns (2026-08-19): deepseek-flash, luna, hy3, glm-5.3, kimi-k2.7-code,
  mimo-v2.5-pro, grok-4.5, muse-spark-1.2 (incl. file-edit turn) COMPLETED.

## US routing for muse-spark-1.2-contributor (option B, 2026-08-19) — OPT-IN ONLY
Default launch mode is proxy-free and direct to https://opencode.ai/zen/go/v1.
The US exit is engaged only through the explicit `opencode-go-us` path:

- `us-forward-proxy.py` — scoped forward proxy on 127.0.0.1:18887;
  per-model routing: only models matching US_SOCKS5_MODELS (default
  "muse-spark") egress through the US SOCKS5 exit (NordVPN
  us.socks.nordhold.net + service creds); all other models are forwarded
  direct (no VPN). NOT started by default.
- `launch-us-proxy.sh 18887` — ensure/foreground runner (creds from
  ~/.config/codex-swapper/us-proxy.env, NORD_SOCKS_USER/PASS, chmod 600).
- `~/.codex/opencode-go-us.config.toml` — the opt-in CLI profile:
  base_url -> http://127.0.0.1:18887/v1, provider id `opencode-go-us-cli`,
  `model_catalog_json` -> `model-catalogs/opencode-go-us-cli.json` (FULL
  opencode-go list + muse-spark-1.2-contributor, 16 models). The CLI picker
  can therefore select every model; the proxy routes only muse-spark* through
  the US exit and everything else direct (2026-08-20: deepseek-v4-flash ->
  direct and muse-spark-1.2-contributor -> US exit re-verified end-to-end,
  both exit 0, no fallback-model-metadata warnings).
- `codex-mod-us` (~/.local/bin) — auto-starts the proxy, then runs the modded
  CLI with `--profile opencode-go-us`. Desktop app is NOT wired to the proxy by
  default; add `[model_providers.opencode-go-us]` to config.toml to expose it
  in the picker later if wanted.
- `sync-us-catalog.py` regenerates BOTH catalog files from
  `opencode-go.json` + `opencode-go-us-contributor.json`:
  `opencode-go-us.json` (contributor-only, desktop) and
  `opencode-go-us-cli.json` (full, CLI profile). The CLI uses a distinct
  provider id so the mod's per-thread injection cannot swap in the
  contributor-only catalog, and the desktop picker gets no
  `opencode-go-us/*` duplicate rows.
- Mod commit `6e11e883a`: provider_is_opencode_go also matches the loopback
  proxy base_url (name "OpenCode Go"), so key failover stays armed on the US path.
- Verified 2026-08-19: pass-through streaming end-to-end (real deepseek turn via
  proxy, exit 0); default direct path re-verified after revert (exit 0); smoke
  test PASS. Contributor turn VERIFIED 2026-08-19 (NordVPN us.socks.nordhold.net exit):
`./probe_contributor.sh` -> no RegionError; `codex-mod-us -m muse-spark-1.2-contributor`
real turn completed (exit 0), and a real file-edit turn wrote + verified
/tmp/contrib_probe.txt. muse-spark-1.2-contributor is now usable via the opt-in
US path (codex-mod-us / `codex exec --profile opencode-go-us`).
## Desktop app integration for muse-spark-1.2-contributor (2026-08-19)
- `~/.codex/config.toml` registers `[model_providers.opencode-go-us]`
  (name "OpenCode Go US", base_url http://127.0.0.1:18887/v1, auth oc-go-key),
  so the merged picker shows "Muse Spark 1.2 Contributor · OpenCode Go US".
- `~/.codex/model-catalogs/opencode-go-us.json` is contributor-only (one clean
  picker row; no duplicate rows with the direct opencode-go provider).
  Re-verified 2026-08-20 after the CLI profile gained its own
  `opencode-go-us-cli` provider: merged model/list still shows the 15 direct
  opencode-go rows + one bare contributor row, no `opencode-go-us/*` entries.
- `launch-tier2.sh` starts the US proxy by default (START_US_PROXY=0 to skip).
- Mod commit `308ff33a0`: failover matcher matches the "OpenCode Go" name
  family, so key rotation stays armed on the "OpenCode Go US" provider.
- Verified: smoke test asserts `muse-spark-1.2-contributor` in the merged
  model/list (PASS); thread/start with no modelProvider resolves
  provider opencode-go-us; real CLI turn through the US path completes.
  NOTE: the standalone stdio app-server turn harness hangs in shell-snapshot
  env setup in this sandbox for EVERY provider (the OpenAI turn smoke hangs
  identically), so the final in-app click-through must be checked in a real
  launch-tier2.sh session.

## Update procedure
Run: /Users/pbarham/opt/codex-swapper/update-mod.sh [VERSION]
Fast mod rebuild: /Users/pbarham/opt/codex-swapper/build-mod.sh [check]
