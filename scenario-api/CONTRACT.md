# Scenario Runner contract — version 1

All routes use `/scenario-api` and JSON. `scope` is a required query or JSON field (normally `DEFAULT`), and `Authorization` uses the existing OpenC3 header verbatim (Core sends its token directly; do not add a Bearer prefix). All reads require `script_view` on the selected target; mutations/context/callback require `script_run` on that target. Launch also requires `script_run` on `SCENARIO_RUNNER`, `cmd` for each fixed command and `tlm` for each telemetry reference. Core has shared authentication; Enterprise supplies granular permissions through the existing OpenC3 authorization module.

## Catalog

The procedure plugin owns `targets/SCENARIO_RUNNER/lib/scenarios.json`: an array of definitions. API loads a read-only copy through `SCENARIO_CATALOG`. Definitions have `schemaVersion:1`, `id`, `version`, `name`, `description`, `supportedTargets`, `timeoutSec`, `steps`, `telemetryItems`, `successCriteria`. Only `CFS-1_QEMU` is supported initially. No caller-supplied commands, scripts, environments or parameter overrides exist.

Step forms:

```json
[
  {"id":"request-hk","type":"command","packet":"CFE_ES_SEND_HK_CMD","parameters":{},"timeoutSec":3},
  {"id":"confirm-hk","type":"waitTelemetry","packet":"CFE_ES_HK","item":"COMMAND_COUNTER","operator":"gte","value":0,"timeoutSec":10,"pollIntervalSec":0.5},
  {"id":"settle","type":"delay","seconds":0.5}
]
```

`telemetryItems` contains `{packet,item}` entries. `successCriteria` is `{type:"allStepsSucceeded",requireFreshTelemetry:true}`. `definition_hash` is SHA-256 hex over recursively key-sorted compact UTF-8 JSON of the definition, with no added API metadata or trailing newline. Definitions use integer/fixed decimal values and ASCII identifiers; API and procedure compare canonical hash before commands. The procedure also compares its immutable local catalog with the persisted snapshot.

## Browser API

| Method | Route | Request / response |
|---|---|---|
| GET | `/scenarios?scope=DEFAULT` | `{items:[definition + {definition_hash}]}` filtered to permitted targets |
| GET | `/scenarios/:id?scope=DEFAULT&target=CFS-1_QEMU` | definition + `definition_hash` |
| POST | `/runs` | `{scope,scenario_id,definition_version,definition_hash,target,request_id}`; optional `Idempotency-Key` instead of request_id; if both, values must match |
| POST | `/runs/reconcile` | Identical start body/key; HTTP 200 with the exact existing run or a durable failed request that cannot launch |
| GET | `/runs?scope=DEFAULT&target=CFS-1_QEMU` | `{items:[run]}` active lock owner first, then newest history, bounded `limit` (1–100, default 25) |
| GET | `/runs/:id?scope=DEFAULT` | run |
| GET | `/runs/:id/events?scope=DEFAULT&after=0` | `{items:[event],next_cursor}`; bounded limit 1–100, ascending durable integer cursor |
| POST | `/runs/:id/stop` | `{scope}`; idempotent request, returns run with `stopping` or existing terminal state |
| POST | `/runs/:id/prompt` | `{scope,prompt_id,answer}`; answer must be an offered choice or `cancel`; returns run |

Create returns 201 on first accepted attempt and 200 on same-key replay. A launch transport ambiguity returns 202 and `unknown`, with no automatic relaunch. Changed content under the same key returns 409 `idempotency_conflict`; stale version/hash returns 409 `definition_mismatch`; target contention returns 409 `target_locked`; global capacity is 429. A durable run is committed before the single upstream launch request. The upstream request sends the installed procedure path only.

Run fields: `id`, `scope`, `target`, `scenario_id`, `definition_version`, `definition_hash`, `request_id`, `state`, `script_id` (nullable), `created_at`, `updated_at`, `deadline`, `stop_requested`, `termination_confirmed`, `prompt` (nullable), `result` (nullable), `error` (nullable). UTC times are ISO-8601. States: `launching`, `running`, `waiting`, `stopping`, `unknown`, `succeeded`, `failed`, `stopped`. Unknown/stopping always retain the lock. For actual executions, `termination_confirmed` means an authoritative terminal ScriptStatusModel record with `end_time` was observed; for `request_not_accepted` it means admission was atomically fenced before any execution. A pre-launch validation error creates no run. A callback result alone never releases a lock or confirms success.

### Recovering an unconfirmed start

`POST /runs/reconcile` requires scope and target `script_run` authorization and the **identical** start fields and request key. In one `BEGIN IMMEDIATE` SQLite transaction it looks up `(scope, request_id)` and compares the canonical request fingerprint (all start fields except `request_id`). An exact match returns that record unchanged, including completed, stopped, failed, launching, running, or unknown records; it never substitutes the target's latest run. Changed content is 409 `idempotency_conflict`, and conflicting body/header keys are 400 `idempotency_key_mismatch`.

If absent, the same transaction records `state:"failed"`, `error:"request_not_accepted"`, `termination_confirmed:true`, `script_id:null`, `prompt:null`, and `result:null`. It uses the existing runs/events tables without acquiring or deleting a target lock. This is a failed **request**, not a failed execution. Its stored definition is null and it cannot launch. Both create's initial replay check and its insertion transaction replay this failure with HTTP 200, even if the original create was already in preflight; recovery never calls launch, status, or stop. If create committed first, recovery preserves its run and lock regardless of HTTP connectivity.

An absent request is validated by bounded field formats, independently of the current catalog: scenario ID `[a-z][a-z0-9-]{0,63}`, numeric `major.minor.patch` version of at most 32 bytes, lowercase 64-character SHA-256 hash, existing scope/target name syntax, and existing 8–128-character request-key syntax. This allows recovery after a definition changes or disappears. No commands, parameters, arbitrary definitions, or credentials are accepted. The 10,000-record capacity and body/event bounds also apply to failed requests; a capacity/database/auth failure does **not** establish a fence, so clients must retain the pending identity until a successful response.

Clients may repeat reconciliation with the same request, including after reload or from multiple tabs, but must never automatically repeat start. After a failed request is confirmed, they should discover any other active target run before enabling a fresh user-initiated start with a new key. Active lock owners precede terminal history in target lists so failed requests cannot hide a real execution behind pagination. Unknown/running/stopping executions retain their existing termination rules and cannot be unlocked by this endpoint.

Event: `{id,run_id,type,data,created_at}`. Step `data` includes `step_id`, `status`, and optional `commandAccepted`, `telemetryConfirmed`, `packet`, `item`, `value`, `received_at`, `message`. Receipt time describes observed telemetry only when the procedure supplies `received_at`; HTTP request acceptance is not telemetry confirmation. Error shape is `{error:{code,message}}` with 400/401/403/404/409/413/429/503. Error text is sanitized and never includes upstream response bodies or credentials.

## Procedure bootstrap and callbacks

Fixed procedure: `SCENARIO_RUNNER/procedures/run_scenario.py`. The launch `environment` array carries only `SCENARIO_RUN_ID`, `SCENARIO_API_URL`, `SCENARIO_DEFINITION_HASH`, `SCENARIO_CONTRACT_VERSION=1`. The URL is the configured API origin including `/scenario-api`, without credentials. Authentication uses existing per-process OpenC3 authentication in memory; credentials are never added to this environment array or persisted by this API.

`GET /runs/:id/context?scope=DEFAULT` returns `{run_id,scope,target,definition,definition_hash,stop_requested,deadline,prompt}`. Prompt is `{prompt_id,message,choices,deadline,status,answer}` or null. Context is bounded and can be polled to observe managed cancellation/prompt answers.

`POST /runs/:id/callback` accepts `{scope,script_id,event_id,type,data}`. `script_id` is a decimal **string**, for example `"123"`. Types: `started`, `step`, `log`, `prompt`, `result`. `event_id` is a unique caller-generated string, stable across retries; exact replays succeed without duplicate events, changed replays fail 409. `script_id` must match ScriptStatusModel filename and its `SCENARIO_RUN_ID`/`SCENARIO_DEFINITION_HASH` environment. Successful callbacks return the context. Do not include raw exception text, passwords, tokens or arbitrary telemetry dumps.

Prompt data: `{prompt_id,message,choices:["continue","cancel"],deadline:<UTC ISO8601>}`. Deadline must be in the future and within both run deadline and 120 seconds. These are managed prompts, not arbitrary native Script Runner prompt forwarding. Answer is one offered choice or `cancel`; cancellation and deadline expiry request stop. The shipped fixed procedures avoid native interactive prompts. Unsupported native `paused`/`error`/`breakpoint` states lead to stop request so unattended runs cannot hang indefinitely.

`result` data is `{status:"succeeded"|"failed",message?:<sanitized text>}`. A successful run needs both successful procedure result and ScriptStatusModel `completed` plus `end_time`, with no stop requested. Missing callback or unrecognized status becomes failed/unknown, never inferred success. A stop that races successful completion yields `failed` with `error:"stop_unconfirmed_completed"`, `termination_confirmed:true`, and the original advisory result; it means cancellation was not confirmed, not that the command failed. Script Runner `stop` merely publishes a request; terminal statuses are `completed`, `completed_errors`, `stopped`, `crashed`, `killed` with `end_time`. Reconciliation uses durable IDs/correlation, never reruns a request. Missing/unreachable/contradictory state retains locks.

## Deployment and bounds

Rails API, OpenC3 6.10.1 base, port 2910, one Puma process; SQLite database `/data/scenario.sqlite3` on a dedicated local persistent volume. A process file lock enforces one service instance per database. No live deployment is changed by this component. `SCENARIO_SCRIPT_API_URL`, `SCENARIO_PUBLIC_API_URL`, `SCENARIO_CATALOG`, `SCENARIO_DB`, OpenC3 Redis/config-bucket/auth settings are configured by deployment. The catalog and `safety_policy.json` are immutable image files packaged identically with the procedure; installed copies must match before launch. The worker periodically reconciles active runs and expires deadlines using read-only status access and the existing stop channel. Limits are fixed/enforced for body size, active/total runs, events, log data, pagination, callback count, network waits, prompt duration and definition size; exact values and operational limitations are in README.md. Scenario presentation adds `permittedTargets` to the unmodified definition so clients can filter target choices without changing the canonical definition hash.
