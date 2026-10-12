# Live validation: OpenC3 and all three cFS scenarios (2026-10-08)

The original `open_c3/openc3-cosmos-scn3` Compose directory now includes
`compose.override.yaml`, which points init/API builds and plugin mounts to
the `integration/all-three-scenarios` worktree. `docker compose up -d` from
that directory exits successfully. `openc3-cosmos-init` exits 0,
`scenario-api` reports healthy, and Scenario Runner 1.0.13 serves eight
definitions. The installed cFS target plugin is 7.0.5. Both target
housekeeping screens render and show live telemetry.

The initial HTTP 502 came from a version mismatch: installed Runner 1.0.11
data was paired with the original checkout's 1.0.8 init image. The guarded
upgrade and Compose forwarding configuration now keep the installed release
and source version aligned. Backups of the previous database, gems, and
target plugin are under `open_c3/openc3-cosmos-scn3/backups/`.

| Target | Scenario | Successful steps | Run ID |
| --- | --- | ---: | --- |
| QEMU | CS CRC key recovery and authenticated X-band frame | 18/18 | `ce05b5e3-bd59-4b0d-bac8-d7d36fda6d83` |
| QEMU | TC log overwritten by camera path traversal | 7/7 | `0ffc7e27-1744-4358-a36f-8cd25778c061` |
| QEMU | MM pointer edit causes controller APP_ERROR exit | 11/11 | `7bbfde3c-2613-44f9-b67c-0000a80c30dc` |
| BBB | CS CRC key recovery and authenticated X-band frame | 18/18 | `3df59e11-ecec-4e22-bf4d-a7e398213409` |
| BBB | TC log overwritten by camera path traversal | 7/7 | `e8fa8eb8-c573-474f-b109-f99df0cc37a0` |
| BBB | MM pointer edit causes controller APP_ERROR exit | 11/11 | `91f43c14-e6c9-4a46-b716-e03b14cda83c` |

These results come from the installed Scenario API run and step-event
records, using the real QEMU and BBB TC/TM interfaces. The CRC procedure
does not print the reconstructed key; it proves use of that key by verifying
and decrypting an authenticated X-band frame. Scenario 3 intentionally
terminates `PAYLOAD_CTRL_APP`, so restart cFS before repeating it. Keep
existing `/cf/log/tc*.log` files during restart; the logger resumes at the
next available number.

After target plugin installation, BBB was still transmitting UDP telemetry
on its USB link, but the OpenC3 operator receive counter stayed at zero.
`docker compose up -d --force-recreate --no-deps openc3-operator` restored
BBB receive traffic; the Scenario Runner BBB housekeeping screen then showed
live packets. This is a recovery observation, not a definitive diagnosis of
the Docker Desktop UDP forwarding internals.

## Subsequent Runner 1.0.14 and XKEY flag validation

OpenC3 was upgraded to Scenario Runner 1.0.14. Its init exited 0, the
Scenario API was healthy, the Runner URL returned HTTP 200, and the API
listed eight definitions. Both flight targets' TM and X-band interface
receive counters increased. The focused CRC tests passed 8/8 and the Runner
UI component tests passed 19/19.

The initial BBB 1.0.14 CRC run recovered all 16 key bytes but failed its
final `xband_payload_invalid` check. The new Runner expected a decrypted
`flag{crc_oracle}` payload while both deployed XKEY modules still encrypted
the older synthetic housekeeping payload. The updated ARM XKEY module was
built for each target, deployed with the previous module backed up, and
verified by SHA-256 and the new flag payload in the binary. No existing TC
log or photo was removed.

| Target | Scenario | Successful steps | 1.0.14 run ID |
| --- | --- | ---: | --- |
| QEMU | CS CRC key recovery and X-band flag | 18/18 | `6a171a36-862f-41f4-8974-818a5214ffa6` |
| QEMU | TC log overwritten by camera path traversal | 7/7 | `d9b2825b-e5b1-45ab-969d-5b0c81508fa6` |
| QEMU | MM pointer edit causes controller APP_ERROR exit | 11/11 | `8055c3a1-4ba6-4b72-a81b-d64d9013027d` |
| BBB | CS CRC key recovery and X-band flag | 18/18 | `7f075db4-402c-4e48-985b-bdf213bd0380` |
| BBB | TC log overwritten by camera path traversal | 7/7 | `c58f1807-e98a-4088-800c-29db74f60f24` |
| BBB | MM pointer edit causes controller APP_ERROR exit | 11/11 | `9c565783-2ade-40b1-8a70-bae77a4b0fcc` |

The successful X-band steps authenticated a fresh AES-GCM frame and
decrypted `flag{crc_oracle}` on both targets. The recovered per-start keys
are in the restricted lab run results and are intentionally omitted from
this document; Runner 1.0.14 displays them in the result UI.
The 1.0.14 UI component tests cover key and flag rendering; a separate
browser automation check was blocked by the browser tool's URL policy, so
the post-upgrade page was verified by HTTP/API response rather than a visual
browser inspection.

After the scenario 3 runs, both cFS targets were restarted to restore
`PAYLOAD_CTRL_APP` for another demonstration. Existing TC logs and photos
were preserved, the new XKEY module remained deployed, and TO_LAB was
re-enabled. Both targets' ordinary TM and X-band receive counters increased;
the controller and pulse apps reported their normal ready states.

## Runner 1.0.15 manual step and TC audit validation

The 1.0.15 init exited 0, the matching Scenario API was healthy, and its
catalog returned eight definitions. Existing 1.0.14 Scenario data and gems
were copied to separate Docker backup volumes before the upgrade. The
`/tools/scenariorunner` page returned HTTP 200. The browser automation tool
could not start because its Windows sandbox helper failed, so a visual
browser check was not completed; all 124 UI tests and the production UI build
passed.

The live validation helper started each run in manual mode and answered each
next-step prompt with the same `continue` API request used by the new
`Run step` button. It checked that command events include the actual OpenC3
packet name and JSON parameter object. Runtime values below are represented
only by command counts; the recovered keys are omitted.

| Target | Scenario | Successful steps | TC events | Run ID |
| --- | --- | ---: | ---: | --- |
| QEMU | CS CRC key recovery and X-band flag | 18/18 | 16 | `0e086741-1b95-4949-82ae-93628b9f802e` |
| QEMU | TC log/photo traversal | 7/7 | 8 | `137137ce-3f6c-4f90-8a4e-ed21baf3fdbb` |
| QEMU | MM indirect write and APP_ERROR | 11/11 | 10 | `4a97dbef-1968-4945-9def-940ba378d207` |
| BBB | CS CRC key recovery and X-band flag | 18/18 | 16 | `83fd4f52-a553-40ee-a1de-29bf5679b319` |
| BBB | TC log/photo traversal | 7/7 | 8 | `753ec838-b5d2-4a8a-a50a-0966a6dd2185` |
| BBB | MM indirect write and APP_ERROR | 11/11 | 10 | `e7f44707-72cd-4e25-b46d-dcb0e683c1a6` |

The automatic QEMU ES housekeeping run also succeeded (2/2 steps, one TC
event, run `3b893de3-42b3-47f8-a751-75bec77b2191`), covering the retained
`Start script` path. The recorded command events for the three key actions
were `CS_CMD_ONE_SHOT` with a runtime address and `SIZE=1`,
`TC_CAMERA_CAPTURE_CMD` with the selected `../log/tcNNNN.log` filename, and
`MM_CMD_DEBUG_WRITE` with a one-byte width and runtime pointer-slot address.

After each PSP run, cFS was restarted on that target. New payload status
telemetry then showed `PAYLOAD_CTRL_STATE.FAULT=0`, `HALT_ACKED=0`, and
`PAYLOAD_PULSE_STATE.STATE=ACTIVE`, `BOUND=1`, `FAULT_LATCH=0` on both QEMU and
BBB. Ordinary TO/CI housekeeping also resumed.

## Runner 1.0.16 step command visibility (2026-10-10)

The Scenario Runner now shows each step's planned TC packet and parameter
assignment before execution. Values computed at send time, such as
`REQUEST_ID`, the XKEY address, the TC log index, and the MM pointer slot,
are labelled as runtime expressions. After a command is accepted, the same
step shows the exact packet name and `parameters_json` recorded by OpenC3;
the Run log includes them too. Steps that only inspect telemetry say `No TC`.
Old runs without command events cannot supply exact historical values.

The complete UI suite passed 129 tests and the Playwright browser fixture
passed with zero page errors. The 1.0.16 init image and Scenario API image
built successfully; the installer exited 0 and the API became healthy. Before
upgrade, the data and gem volumes were copied to
`openc3-scn3-scenario-data-pre116-20261010` and
`openc3-scn3-gems-pre116-20261010`. The two installed Scenario gems report
1.0.16, the catalog still has eight definitions, and 86 run records with 82
command events survived; no active lock remains. The Runner page and its new
bundle return HTTP 200, and the bundle contains the `Planned TC` and
`Accepted TC` rendering. For example, a retained `recover-byte-02` event
records `CS_CMD_ONE_SHOT` with `SIZE=1`, `MAX_BYTES_PER_CYCLE=1`, and the
runtime `ADDRESS` used in that run. Direct visual inspection of the live
browser was unavailable because the browser control tool failed, so the
live check used HTTP assets and the separate Playwright fixture.

## Runner 1.0.17 execution result cards (2026-10-10)

The step card keeps `Planned TC` and now shows an `Execution result` block
when that step finishes. It uses the procedure's exact step message, including
`0x<address>: CRC 0x<value>, byte N/16 recovered` for each CRC byte. The old
per-step `Accepted TC` parameter block was removed; accepted packet and JSON
parameter details remain in the Run log. A generic telemetry wait displays
`PACKET.ITEM = value` when its step has no message. The existing X-band,
TC-log, and PSP evidence panels remain available.
The retained live event for `recover-byte-00` contains exactly
`0xb69f20b8: CRC 0xa3c1, byte 1/16 recovered`.

The full UI suite passed 130 tests, the Playwright browser fixture passed
with zero page errors, and its desktop screenshot was inspected. The
installer and runtime release tests passed 6/6 and 12/12 respectively. The
user authorized stopping a waiting BBB manual CRC run; the Scenario API
reported `stopped` with confirmed termination and released its lock before
upgrade. The 1.0.16 data and gems were backed up to
`openc3-scn3-scenario-data-pre117-20261010` and
`openc3-scn3-gems-pre117-20261010`.

The 1.0.17 init exited 0 and the matching API is healthy. Both installed
Scenario gems report 1.0.17; the catalog still has eight definitions and
the retained database has 87 runs, 83 command events, and no active lock.
The Runner page and its new UI bundle return HTTP 200. The served bundle
contains `Planned TC` and `Execution result` but no old `Accepted TC` card.
Authenticated live-browser visual inspection was not completed; the live
check used the installed HTTP bundle and the separate browser fixture.

## Runner 1.0.18 Korean explanatory text (2026-10-10)

The Runner's guidance, scenario summaries, step descriptions, telemetry
overview, and scenario evidence panels now display Korean explanatory text.
The catalog definitions and their hashes are unchanged: UI display copy is
selected by scenario ID. TC packet and parameter names, raw execution results,
`Planned TC` and `Execution result` headings, and button labels remain in
English. Planned TC values computed at send time use Korean explanatory text
while preserving their technical identifiers.

The full UI suite passed 131 tests. The Playwright browser fixture passed with
no page errors. Installer tests passed 6/6 and installed-release tests passed
12/12. The Scenario API and init images built successfully. Before replacing
1.0.17, there were no active run locks; 87 runs and 2,159 events were present.
The data and gem volumes were backed up to
`openc3-scn3-scenario-data-pre118-20261010` and
`openc3-scn3-gems-pre118-20261010`; the original and backup SQLite files had
matching SHA-256 hashes.

The 1.0.18 installer exited 0 and the matching API is healthy. The installed
record and both Scenario gems report 1.0.18, and the catalog still contains
eight definitions. The database retains 87 runs and 2,159 events with no
active lock. The Runner page and its current JavaScript chunk return HTTP 200;
the served chunk contains the Korean guidance, `Planned TC`,
`Execution result`, `Run step`, and `Start script`, but not the former English
guidance sentence. Direct visual inspection in the in-app browser was
unavailable because its control tool failed; the installed asset and browser
fixture were checked separately.

## Runner 1.0.19 fresh step results and simplified display (2026-10-10)

`Execution result` now appears only after a step in the current run has
finished. Opening or refreshing the Runner after a previous terminal run
starts with an empty step list; a run that was active before refresh is still
recovered, including one that finished while the page was reloading. Starting
a new run clears the previous step results immediately. The UI removes run
and request UUIDs, internal step IDs in step cards and log messages, repeated
title and metadata, and event count decorations. Run log command entries use
the visible step number and retain exact packet names and parameter JSON.

The full UI suite passed 136 tests, including the fresh-view regression test.
The Playwright browser fixture passed with no page errors, and its desktop
screenshot was inspected. Installer tests passed 6/6 (37 assertions),
installed-release tests passed 12/12 (25 assertions), and Compose validation
passed. Both 1.0.19 images built successfully.

No run was active before upgrade. The 1.0.18 data and gem volumes were backed
up to `openc3-scn3-scenario-data-pre119-20261010` and
`openc3-scn3-gems-pre119-20261010`; the SQLite backup and source SHA-256 hashes
matched. The 1.0.19 installer exited 0 and the matching API is healthy. Both
Scenario gems report 1.0.19, the catalog still has eight definitions, and
the database retains 88 runs and 2,180 events with no active lock. The Runner
page and its current JavaScript chunk return HTTP 200. The served chunk
contains the updated Korean result guidance, `Planned TC`, `Execution result`,
`Run step`, and `Start script`, without the removed request ID label. Direct
visual inspection in the in-app browser was unavailable because its control
tool failed; the installed asset and separate browser fixture were checked.
