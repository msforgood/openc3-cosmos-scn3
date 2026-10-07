# Scenario management API

This Rails API manages the two fixed QEMU housekeeping scenarios through the existing OpenC3 Script Runner 6.10.1. It does not execute Ruby/Python locally, accept arbitrary scripts or command parameters, modify the CFS plugin, or install a plugin. The shared protocol is in [CONTRACT.md](CONTRACT.md). Deployment is integrated in the repository root Compose and the image-contained cosmos-init bootstrap; see [Scenario Runner](../SCENARIO_RUNNER.md).

## Build and test

From the repository root (the additional build context supplies the canonical procedure files):

```sh
docker compose build scenario-api
docker run --rm --network none --entrypoint bundle local/openc3-scenario-api:6.10.1-1.0.4 exec rake test
```

The test container is isolated from all OpenC3 deployments and sends no commands. The image bundles pinned OpenC3 6.10.1, Rails 7.2 and Puma 7 (required by this OpenC3 gem), plus SQLite. `Gemfile.lock` fixes transitive dependencies. Build argument `OPENC3_BASE_IMAGE` may select a local mirror of the 6.10.1 Script Runner API image. The image runs as UID/GID 1001 and initializes `/data` with matching ownership.

`config/scenarios.json` and `config/safety_policy.json` are byte copies of the canonical procedure plugin files in `../openc3-cosmos-init/plugins/packages/openc3-cosmos-cfs-scenario-runner/targets/SCENARIO_RUNNER/lib`. The Docker build replaces these test-fixture copies from the canonical additional context and includes run_scenario.py. Rebuild both images together; editing a test-fixture copy is not a catalog update. No API endpoint writes definitions. Hashes use recursively sorted compact UTF-8 JSON, excluding presentation fields. The procedure pins its own installed catalog to the persisted API snapshot before any command.

## Configuration

| Variable | Default / purpose |
|---|---|
| `PORT` | `2910` |
| `SCENARIO_DB` | `/data/scenario.sqlite3`; durable dedicated local volume |
| `SCENARIO_CATALOG` | `/scenario-api/config/scenarios.json`; immutable image catalog |
| `SCENARIO_SCRIPT_API_URL` | `http://openc3-cosmos-script-runner-api:2902` |
| `SCENARIO_PUBLIC_API_URL` | `http://scenario-api:2910/scenario-api`; procedure callback URL |
| `SCENARIO_ALLOWED_HOSTS` | `scenario-api,localhost,127.0.0.1`; add the actual reverse-proxy host when necessary |
| OpenC3 environment | Existing Redis, config bucket and authentication settings, including the existing service-password/Enterprise setup |

The safety policy must sit beside the catalog as `safety_policy.json`. The shipped procedure accepts the default internal callback URL only. API gems are installed in the image's system gem directory, not the shared writable `/gems` plugin volume. Preserve system gem lookup when carrying deployment `GEM_HOME` settings. The read-only `/gems` mount is required for the installed-release check and existing Enterprise authorization when present. Startup verifies the installed release record, canonical procedure payload and definitions before starting the execution manager.

Run exactly one API process with the same persistent database. Puma uses one process and 2–8 threads; the application holds a lifetime exclusive file lock next to SQLite. Multiple hosts with distinct databases, distributed filesystems, and multiple replicas are unsupported. Do not delete the database, lock rows, or volume to recover an ambiguous run: that would discard the evidence preventing another launch.

`GET /scenario-api/health` checks application/reconciliation-thread readiness without requiring credentials; it is not a declaration that Redis, Script Runner, QEMU, or telemetry is healthy. Authentication and preflight failures fail closed. Requests use the current OpenC3 `Authorization` header unchanged. Core has a shared-token security model and no per-user target restrictions; Enterprise supplies its existing granular authorization. This service always enables token verification, requires scope, checks target rights on every run operation, and checks command/telemetry permissions before launch. The authenticated procedures and operators are trusted callback writers under that existing security model.

## Durable lifecycle

The API commits an immutable definition snapshot, run, idempotency fingerprint and scope/target lock in a `BEGIN IMMEDIATE` SQLite transaction before attempting one HTTP launch. Concurrent equal request keys return one run; changed content conflicts. Different keys compete for the same database-unique `(scope,target)` lock. Global active capacity is four. Network I/O never holds a database transaction.

For a lost browser start response, `POST /scenario-api/runs/reconcile` accepts the identical start payload and atomically returns the exact existing request or persists a terminal `failed` / `request_not_accepted` record without a target lock. The latter permanently fences that request key: even an original create already in preflight must replay the failure before insertion and cannot launch. The fence stores bounded identifiers with no executable definition, works across catalog changes, and counts toward the 10,000 retained records. Reconciliation never changes an existing execution or its lock, never calls the backend, and requires target `script_run` authorization. Target lists show their active lock owner before terminal history. See the contract for response semantics and failure handling.

The launch body contains only scope and four non-secret correlation environment variables. Script Runner's real endpoint returns its integer ID as plain text. Any exception, timeout, invalid response or non-200 response after attempting launch is conservative `unknown`; neither API retries nor process restarts launch again. The API reconciles both running and completed ScriptStatusModel records, validating filename, run ID and definition hash. Ambiguous multiple IDs set a persistent conflict flag. A callback can associate the ID before the launch HTTP response arrives.

Stop commits intent before publishing the existing `script-api:cmd-running-script-channel:<id>` JSON `"stop"` message. Publishing is not termination; neither 404/missing status nor lost connectivity releases the lock. Stop publication is attempted at most three times per run, at least five seconds apart, and every publication revalidates correlation. No PID killing or Script Runner delete endpoint is used.

Only source-defined terminal states (`completed`, `completed_errors`, `stopped`, `crashed`, `killed`) with a valid `end_time` confirm termination. Success additionally needs a successful procedure callback and no pending stop. A successful callback alone leaves the target locked; `completed` without that callback is failed, not inferred success. Conflicting IDs remain unresolved even if one later disappears. Native `error` is paused execution, so it requests stop rather than releasing the lock. Managed prompt expiry and the run deadline also request stop.

If a stop races a successfully completed procedure, the conservative final state is `failed` with `stop_unconfirmed_completed`: termination is confirmed, but cancellation was not. The original advisory result remains visible. This state does not claim that an already accepted command failed or that the run was stopped.

After restart, reconciliation resumes from durable records and never dispatches persisted launches. An unresolved run may block its target indefinitely. Operators must inspect the actual Script Runner process and its persisted status, restore service connectivity/status visibility, and retain the database while investigating. There is deliberately no unsafe force-unlock endpoint. If authoritative status was permanently lost, manual recovery requires an independently documented proof of process termination and an audited offline database migration; this component does not automate that decision. Locks cover this API's runs, not separately launched traditional Script Runner sessions.

## Bounds and data handling

| Resource | Limit |
|---|---|
| Request body / query | 16 KiB / 2 KiB, checked before Rails parsing |
| Active runs / retained runs | 4 / 10,000; admission fails at capacity |
| SQLite | WAL + `synchronous=FULL`, 5-second busy timeout, approximately 512 MiB max database pages; 16 MiB retained WAL target |
| Callback events per run | 1,000, plus 16 reserved lifecycle events; saturation requests stop |
| Event / text | 4 KiB / 2 KiB; flat scalar fields only |
| Catalog / definitions / steps | 64 KiB / 32 / 16; strict schema plus per-command fresh-wait pairing and total time budget |
| API run deadline / prompt | At most 120 seconds / 120 seconds and within run deadline; shipped runs are 30 seconds |
| Polling / reconciliation | Two-second interval, serialized; maximum 1,000 running + 1,000 completed statuses scanned per unassociated run |
| HTTP launch | 3-second connect/write, 5-second read, 10-second wall bound, zero retries, 128-byte response |
| Redis/auth/preflight waits | 5–8 seconds, no unbounded retry loop |
| API events/list page | At most 100 rows |

The database has no credential fields. Request tokens are passed in memory only, Rails parameter logging is filtered, generic upstream errors are sanitized, and callback text redacts the current credential and recognizable secret assignments. Do not send credentials or arbitrary dumps in callbacks. Catalog/runtime environment values are non-secret. The API stores bounded structured progress, not unrestricted Script Runner console logs. Deployment should cap Docker logs (the supplied overlay does) and monitor disk/admission capacity. Retention is intentionally not automatic because deleting idempotency evidence can permit a repeated command; archival or compaction requires a planned maintenance policy.

## Source-grounded validation

Tests exercise service transactions against real SQLite, concurrent threads and separate SQLite connections, restart reopening, ambiguous launch, duplicate/conflicting callbacks, corrupt correlation, terminal proof, deadlines, target/scope authorization, credential redaction, body/event bounds, and real Rails routes. Adapter tests execute the installed 6.10.1 `ScriptStatusModel.get`, `is_complete?`, and Core `Authorization` methods with the Redis transport stubbed; they assert actual HTTP launch and stop-channel shapes. No test requires live credentials or a flight/BBB target.
