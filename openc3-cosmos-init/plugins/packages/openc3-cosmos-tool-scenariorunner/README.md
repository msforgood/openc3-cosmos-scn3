# Scenario Runner Tool for OpenC3 6.10.1

An independent COSMOS tool for fixed, installed scenarios. The desktop layout
uses 45% for scenario selection, immutable step preview, progress, timing, stop,
managed prompts and the latest 1,000 run events; 55% for the selected target's
existing telemetry screens and read-only Limits changes. Below 1,000px it stacks.

| Identity | Value |
| --- | --- |
| Tool / path | `scenariorunner` / `/tools/scenariorunner` |
| npm package | `@openc3/cosmos-tool-scenariorunner`, version `1.0.4` |
| Plugin gem | `openc3-cosmos-tool-scenariorunner-1.0.4.gem` |
| Common libraries | `@openc3/js-common` and `@openc3/vue-common`, exactly `6.10.1` |
| Development port | `2931` (strict; no fallback port) |
| API base | `/scenario-api` |
| Storage namespace | `openc3.scenariorunner.v1.<scope>` |

The OpenC3 base application supplies AppNav and its import map. `plugin.txt`
registers the independent tool, and the tool uses the normal `TopBar` and
single-spa bootstrap/mount/unmount lifecycle. There are no changes to Command
Sender, Limits Monitor, AppNav, base configuration, or base application code. The Tool now participates in the shared pnpm workspace and cosmos-init image build.

## Build and package

From the repository root, build both images with the normal Compose build:

```sh
docker compose build openc3-cosmos-init scenario-api
```

The init Dockerfile builds this Tool and the separate procedure gem, verifies the
release manifest, and embeds the guarded installer. Startup installs them through
`openc3cli load`; see the repository root `SCENARIO_RUNNER.md` for migration and
recovery. No host gem directory or separate installer container is needed.

For local frontend development, run from `openc3-cosmos-init/plugins` with the
project's pnpm 10 toolchain:

```sh
pnpm install --frozen-lockfile --ignore-scripts
pnpm build:common
pnpm --filter @openc3/cosmos-tool-scenariorunner test
pnpm --filter @openc3/cosmos-tool-scenariorunner build
pnpm --filter @openc3/cosmos-tool-scenariorunner test:browser
```

The common libraries resolve to sibling workspace sources at 6.10.1. The workspace
`pnpm-lock.yaml` is the dependency authority; this package has no npm lockfile.
The browser fixture intercepts backend traffic and uses installed Chrome (or
`SCENARIO_BROWSER_CHANNEL=msedge`). It writes ignored local evidence. Production
assets remain `tools/scenariorunner/main.js` plus chunks. The image packages them
with release 1.0.4; a source edit requires rebuild and a new release for deployment.
`pnpm --filter @openc3/cosmos-tool-scenariorunner serve` uses port2931.

## Backend contract and operation

The authoritative contract is `scenario-api/CONTRACT.md` at the repository root. This client
uses the authenticated OpenC3 `Api` service, preserving its raw Authorization
header, token refresh, manual flag and scope behavior. It never stores tokens
in its own keys. Required API operations are catalog/read/list/start/reconcile/stop,
event cursor reads (100 per page), and offered managed prompt choices.

The Target dropdown contains every distinct installed name returned by the
authenticated OpenC3 `get_target_names()` call for the current scope, sorted by
name. Catalog-only targets are never added. A saved installed target remains
selected even when it has no scenarios; otherwise the default prefers the
first installed target with a permitted scenario, then the first installed name.
Scenario choices still require both `supportedTargets` and `permittedTargets`
when supplied. Unsupported targets show **No scenarios available for this
target**, disable Start, and retain their read-only telemetry panel. Empty or
failed catalog responses do not remove installed targets or their telemetry;
catalog and target discovery failures have separate messages and retry controls.
Only fixed scenario metadata and the selected target are submitted. Start
contains `scenario_id`, `definition_version`, `definition_hash`, `target` and
a unique `request_id`; there is no command editor or parameter override.

Start and target/scenario selection lock synchronously before network I/O.
Existing active runs are discovered on target selection. An ambiguous start
persists its request identity and automatically posts that identical payload to
`/runs/reconcile`; legacy saved `pendingRequest` entries follow the same path on
reload. A start response wait ends after 30 seconds and begins recovery. This
does not cancel a real execution: the server returns its exact existing run or
atomically records a failed request that prevents any late admission of that
request ID. Start is never automatically resent, and late original responses
cannot replace recovered or newer state.

The UI displays **Start request FAILED** separately from an actual run. It
checks for other active target runs before unlocking a fresh user-initiated
start with a new request ID. A confirmed failed request remains visible during
API disconnection; existing running, stopping, and unknown executions retain
their state and locks. Recovery failures retain the request and retry serially
after 1, 2, 5, 10, and 30 seconds (five retries, at most one recovery in flight).
After exhaustion, an online event, **Recover run**, or reload starts another
bounded recovery cycle. The common authenticated API transport retains its
60-second HTTP timeout; recovery never overlaps another recovery still waiting
on it. Unmount clears retry/start-wait timers, removes the online listener, and
invalidates late results. Backend target locks remain authoritative across tabs.

| API state | UI state |
| --- | --- |
| launching, running | running |
| waiting | waiting_input |
| stopping | stopping |
| unknown, unrecognized | needs_attention |
| succeeded / failed / stopped | corresponding terminal state |
| no run | ready |

Stop acceptance is displayed as `stopping`, not as a confirmed stop. An API
communication failure retains the last run status and lock. The API connection
indicator also expires after 10 seconds without a successful active-run read.
Polls are serialized: one batch, then a 1-second delay, with no overlapping
run batches. A terminal full event page is drained before polling ends. Event
history is capped at 1,000 records; older step results remain in the bounded
fixed-step progress map. Managed prompt choices have the server deadline,
duplicate-submit protection and cancellation; expiry is enforced by the API.

## Telemetry and read-only screens

The tool loads definitions from `/openc3-api/screens` and
`/openc3-api/screen/<target>/<screen>` and renders the actual 6.10.1
`Openc3Screen`. Scenario `telemetryItems` selects the related ES/EVS HK screen
by packet-name prefix before falling back to another installed HK screen.

Before mounting a screen, `passiveScreen.js` validates its rendered definition.
Only inspected passive CFS layout/value/label widgets and simple style settings
are accepted. Buttons, custom/dynamic widgets, raw/global settings, other-target
telemetry references and polling periods under one second are rejected. A
rejected selection shows an error and never mounts `Openc3Screen`; no portion
of that definition executes. This intentionally excludes more complex normal
screens until their widget implementations are reviewed. ES and EVS CFS HK
definitions use the accepted subset. Value context menus are intercepted before
the widget listener, including keyboard context gestures, because the upstream
Details dialog contains mutable Limits controls. Read-only screen tabs remain
usable; global Limits settings are not included.

The compact **Telemetry overview** sits above the expanded packet screen.
It uses unique item references returned by the passive validator, validates
item names/array indexes/value types, and prioritizes scenario `telemetryItems`
only when those items appear in the installed screen. OpenC3 reserved packet,
receipt and buffer fields are omitted from the overview. It shows at most 24
rows in a 265px scroll area, with an explicit displayed/eligible item count.
Counts describe only these displayed rows, never overall target health.

Each row shows the packet receipt time, formatted value and separate units,
and a state chip with text/icon as well as color. Counts distinguish alarm,
caution, within limits, unconfigured, stale, disconnected, disabled and unknown.
The current Limits set is read-only text. `get_tlm` supplies item metadata
(`limits.enabled`, named threshold objects, state colors and units);
`get_limits_set` supplies the current set. Metadata is refreshed every 30 seconds
within the existing serial monitor, grouped by displayed packet. Failed
metadata becomes unknown and retries; successful value reads can continue.

The OpenC3 6.10.1 `get_tlm_values(items, 10, 0)` result is an array of
**`[value, limitsState]` pairs**, not timestamp-bearing triples. One request
combines receipt items with `CONVERTED` and `FORMATTED` values. Only finite
converted numbers drive visual scales; display strings and units are never
parsed into numeric values. Numeric gauges use actual RL/YL/YH/RH and optional
GL/GH thresholds, a fixed linear domain with labeled overflow tails, and
explicit clamped-pointer labels. Invalid/reversed/degenerate ranges have no
numeric gauge. A missing set uses actual DEFAULT thresholds, labeled as such.

Items with no numeric limits show neutral recent-sample traces, or an explicit
no-numeric-limits label. Observed minima/maxima are **not normal ranges**.
CFS HK definitions currently have no configured numeric limits; no definitions
are changed. Each trend keeps at most 30 fresh samples, appending only when its
packet receipt advances; cached, stale, future or backward receipts cannot
create fresh samples. Selection changes clear trends and metadata. Generation
guards reject late screen, value and metadata responses on target/screen/scope
or scenario-item changes and unmount. Stale/disconnected/null/disabled/unknown
overview states cannot inherit a green healthy chip; inactive gauges are gray.
The overview has no settings, context menu, command or mutation controls.

Freshness reads `RECEIVED_TIMESECONDS` for **all packets referenced by the
validated selected screen**. The displayed time is the newest actual packet
receipt, never the time of a successful HTTP poll. Any missing packet gives
`no data`; any packet older than 10 seconds gives `delayed`; a failed or stalled
telemetry API read gives `disconnected`. Screen colors are grayed whenever
the data are not live. Future timestamps beyond 5 seconds are not considered
fresh. Run status and telemetry communication status are separate.

Limits uses the actual `LimitsEventsChannel` and its `history_count` option.
Only exact selected-target `LIMITS_CHANGE` events are displayed. Global events
are excluded; there are no enable/disable/reset/settings mutations. No events
does not mean healthy telemetry. The Limits connection has its own indicator.
Events are flushed at most every 250ms and capped at 1,000.

Target switches and unmount invalidate pending screen/packet results, clear
timers, remove the unload listener, unsubscribe and disconnect Cable. Each
target owns a separate Cable; a subscription resolving after cleanup is
immediately unsubscribed and its late-created socket disconnected. Leaving
the tool does not automatically stop an active server run.

## Verification and limitations

`pnpm test` covers real lifecycle/race behavior through unit and mocked Vue
component tests. Browser smoke covers both development modules and production
SystemJS, the actual common widgets, complete installed target discovery,
unsupported-target telemetry browsing, active-screen
rejection, layout, locks, prompt, stop, stale data, and cleanup. See
`evidence/*-result.json`, screenshots, and the coordinator's
`.scenario-orchestration/ui-report.md` for measured results.

Mocked browser success establishes frontend/6.10.1 compatibility, not live
spacecraft behavior, deployed authorization, or backend reconciliation.
Production API routing, plugin installation, and an approved isolated end-to-end
run must be validated separately. The tool inherits the base application's
authentication and trusted installed library/widget boundary. Upstream build
warnings about ButtonWidget `eval` and bundle size remain; the passive screen
gate prevents command-bearing screen definitions from mounting in this tool.

The local smoke fixture also exercises the read-only overview with real API
metadata shapes: unconfigured CFS counters, asymmetric numeric limits, an enum
alarm, disabled and missing values, overflow, and stale telemetry. Set
`SCENARIO_EVIDENCE_DIR` to route its screenshots/results to a separate directory.
Worker evidence for this addition is in
`tests/browser/evidence/telemetry-overview/`; production build, packaging and
installed verification remain coordinator-owned.

`tests/browser/installed.mjs` is a separate, explicitly gated integration
harness for the coordinator's isolated localhost:32900 environment. It uses
real responses, private credentials read only in memory, and one fixed QEMU
HK scenario; `--resume=<run-id>` instead validates a previously completed run
using reads only. It checks numeric HK values against the API after remounts
because the standard screen initially shows null until its first value poll.
The installed evidence records login-phase diagnostics separately from the
authenticated tool phase. This harness is not part of the default test command.

See `LICENSE.txt` and `NOTICE.md` for OpenC3/Ball attribution and AGPL terms.
