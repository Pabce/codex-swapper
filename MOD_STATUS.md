# MOD_STATUS — codex-swapper mod pinned state

Last updated: 2026-08-22 (re-pin to 0.149.0-alpha.4; M5 is now the main dev machine)

## Pinned release
- App build: 26.818.31338
- Bundled CLI (app Resources/codex): 0.149.0-alpha.4
- Upstream tag: rust-v0.149.0-alpha.4
- Fork branch: mod-0.149.0-alpha.4
- Mod commits replayed: 9 of 10 (the "refresh Cargo.lock" commit dropped as
  empty — lock is regenerated from the alpha.4 base at build time);
  base = rust-v0.149.0-alpha.4

### alpha.21 -> alpha.4 (0.149) re-pin notes (2026-08-22)
- Machine move: the fork checkout on this M5 was gutted (no .git, no sources);
  restored by cloning over Tailscale SSH from the M1 hub
  (`git clone m1hub:/Users/pbarham/opt/codex-swapper/codex-rs codex-rs`),
  then `origin` re-pointed to https://github.com/openai/codex.git. The M1 copy
  was a SHALLOW clone (depth 1); unshallowed from GitHub on the M5
  (`git fetch origin main --unshallow`). Keep it full here.
- Cargo.lock conflicts in every re-pin: resolve with `git checkout --ours`
  (keep the NEW upstream lock; cargo regenerates mod deltas during build).
- core/src/client.rs conflict (failover arm): upstream refactored the plain
  401 arm to `provider.is_recoverable_auth_error(&t)` and added a new
  `&mut provider_auth_recovery_attempted` argument to `handle_unauthorized`.
  Resolution: keep the swapper usage-exhaustion arm (401/402/403/429 ->
  flip_opencode_go_key -> retry once) FIRST, adapted to pass the new arg,
  followed by upstream's `is_recoverable_auth_error` arm unchanged.
- target/ lives at ~/.cache/codex-swapper/target (build-mod.sh fallback);
  symlinked codex-rs/codex-rs/target -> there so smoke/launch scripts and
  update-mod.sh find release/codex at the conventional path.
- Upstream grew ModelInfo between alphas; 12 core/tests/suite literals lacked
  the mod's request_non_streaming field -> added `request_non_streaming: false`
  next to supports_namespace_tools in 8 suite files (mod commit ac92ad4e84).
- Verified on the rebuilt alpha.4 binary: tier2_stdio_smoke.py RESULT: OK;
  bare Luna -> openai, merged model/list intact;
  cargo test -p codex-core --lib -- client::tests: 19 passed, 0 failed.

### Previous pin (0.148.0-alpha.21, re-pinned 2026-08-21)

- fd0812088 ("tolerate missing supports_parallel_tool_calls") is OBSOLETE:
  upstream deleted the ModelInfo field entirely between alphas (moved to
  tool-handler level in spec_plan). Resolved by taking upstream side; commit
  skipped as empty. No local cache rewrite needed anymore.
- a0909a00c conflicts resolved: `request_non_streaming` anchored after
  truncation_policy in protocol/src/openai_models.rs and in the models-manager
  fallback initializer (the obsolete parallel field line removed).
- Verified on the rebuilt alpha.21 binary: gpt-5.6-sol default turn,
  ox-alpha-free via --profile opengo (non-streaming path), deepseek-v4-flash
  regression, tier2_stdio_smoke RESULT: OK.

## Previous pin (0.148.0-alpha.15)
- App build: 26.814.41407
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
- app-server/src/models.rs — preserve active-provider ownership for bare
  colliding slugs (`c097e783f`); bare Luna routes to OpenAI and namespaced Luna
  routes to OpenCode Go
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
- REMOVED from the catalogs on 2026-08-20: the opencode-go gateway no longer
  serves `muse-spark-1.2` (live probe -> "Model muse-spark-1.2 is not
  supported", direct and via the US exit; absent from the gateway `/models`
  list of 27). Only `muse-spark-1.2-contributor` remains. The historical notes
  below apply to the period when the model was still served (verified
  2026-08-19); re-add the entry if the gateway restores it.
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

### ox-alpha-free note (END-TO-END VERIFIED 2026-08-21)
- Stealth free preview; docs still list it as chat-completions-only, but the
  Responses endpoint works in practice (same docs-lag as DeepSeek).
- Gateway ID mapping matters: opencode-go gateway serves it as `ox-alpha-free`;
  the main Zen API serves the same model as `x-preview-f-free`. Using the wrong
  ID on either base returns 401 `ModelError: "Model ... is not supported"`.
- Raw probes (`probe_oxalpha_responses.py`): basic turn, function-call
  emission with valid JSON args, and the function_call -> function_call_output
  round trip all PASS non-streaming; plain-string `input` is rejected with
  "Input cannot be empty" (use the structured array form).
- Its STREAMING is degenerate on both gateways: bare `response.output_text.delta`
  with no output_item lifecycle and a `response.completed` whose output array is
  null (text turns drop the message); with tools attached only an
  `output_item.added` announcement arrives and arguments never stream.
  Two mods fix this: (1) core synthesizes item lifecycle around orphan text
  deltas as a safety net; (2) new per-model catalog flag `request_non_streaming`
  POSTs once and materializes the JSON response instead of consuming SSE.
- CLI usage: `codex-mod exec --profile opengo -m ox-alpha-free "..."`. The
  profile ships `model_catalog_json`, which is how per-model metadata reaches
  exec (exec has no app-server-style convention-catalog injection). Desktop
  threads get it automatically via the existing config_manager injection.
- Verified: text turn exit 0 with visible reply; real shell tool-call turn
  (file created + correct summary); deepseek-v4-flash regression clean on the
  same binary.
- Catalog flags: levels low/medium/high (default medium), supports_search_tool
  false, context_window 256000 (unverified), request_non_streaming true.

### models_cache.json drift incident (2026-08-21)
- OpenAI changed their `/models` payload mid-day; fresh cache entries omitted
  `supports_parallel_tool_calls`, whose deserializer field had no
  `#[serde(default)]` -> "failed to load models cache" at startup and fallback
  metadata everywhere. Fixed properly by adding the serde default; existing
  caches were also rewritten locally to unblock immediately.

### Not promotable (Responses API path on this gateway)
- minimax-m3 / minimax-m2.5 / kimi-k3 / qwen3.8-max / qwen3.7-max / qwen3.7-plus /
  qwen3.6-plus / qwen3.5-plus — "Model ... is not supported for format openai"
  (chat-completions/anthropic-only; no Responses API support).
- minimax-m2.7 — accepts the Responses input shape but 500s when any tool is attached.
- mimo-v2-pro / mimo-v2-omni — deprecated upstream (migrate to mimo-v2.5*).
- hy3-preview — "Model is unavailable".
- muse-spark-1.2-contributor — geo-blocked ("not available in your country").

## Reasoning-effort arrays (LIVE-VERIFIED 2026-08-20 against the gateway)
Probed every model x {minimal, low, medium, high, xhigh, max} with the exact
Responses shape (contributor via the US proxy). Catalog arrays now match what
the gateway accepts without error; defaults unchanged.
- deepseek-v4-flash / deepseek-v4-pro — minimal..max (all six accepted;
  previously under-listed low/high/max); default high.
- gpt-5.6-luna — low..max (minimal rejected); default medium.
- grok-4.5, hy3, kimi-k2.7-code, kimi-k2.6, kimi-k2.5, glm-5.3, glm-5.2,
  glm-5.1, glm-5, mimo-v2.5-pro, mimo-v2.5 — minimal..max (minimal added;
  accepted by gateway and upstream); default medium.
- muse-spark-1.2-contributor — minimal..xhigh (max rejected: upstream accepts
  none/minimal/low/medium/high/xhigh; none rejected by this endpoint);
  default medium.
- `none` is accepted by the gateway for deepseek/luna/hy3/kimi/glm/mimo but
  REJECTED for grok-4.5 ("effort must be one of: minimal low medium high") and
  muse-spark-1.2-contributor; it is intentionally NOT surfaced in the picker
  arrays (kept to the standard codex minimal..max set).
- muse-spark-1.2 — removed with the model (see note above).

## Verification
- tier2_stdio_smoke.py: PASSED (re-verified 2026-08-20) — merged `model/list`
  returns 8 OpenAI + 14 opencode-go + 1 contributor entries; muse-spark-1.2
  absent (gateway drop); effort arrays asserted (deepseek minimal..max,
  contributor minimal..xhigh, luna low..max); luna namespace + deepseek
  resolution intact.
- Luna collision regression (2026-08-20): reproduced on the old release as
  bare `gpt-5.6-luna -> opencode-go`; rebuilt release PASS with bare Luna
  resolving to `openai` and `opencode-go/gpt-5.6-luna` resolving to
  `opencode-go` in the same app-server process.
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

### Incident 2026-08-20: proxy crashed on large request bodies ("stream disconnected")
The desktop thread (muse-spark-1.2-contributor via the US proxy) failed with
`stream disconnected before completion: error sending request for url
(http://127.0.0.1:18887/v1/responses)`. Root cause (proxy log): the proxy
passed the whole JSON body to curl as a `-d <body>` command-line argument,
and macOS ARG_MAX (1 MiB) was exceeded once the thread's conversation context
grew — `OSError: [Errno 7] Argument list too long: 'curl'`, handler died, no
response sent (60 occurrences in /tmp/us-proxy.log). Fixed in
`us-forward-proxy.py`:
- body now sent via stdin (`--data-binary @-` + subprocess `input=body`), no
  argv size limit;
- curl max-time raised 90s -> 600s (the proxy buffers the whole upstream
  response; 90s killed long muse turns);
- `launch-us-proxy.sh` now detaches via `os.setsid()` (macOS has no setsid(1))
  because nohup+disown did not survive tool-session process-group cleanup.
Verified 2026-08-20: 1.5 MB body -> HTTP 200 with a response id via both the
US exit (contributor) and the direct path (deepseek); real
`codex exec --profile opencode-go-us` contributor turn exit 0; proxy survives
session boundaries.
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
