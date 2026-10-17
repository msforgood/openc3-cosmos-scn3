# Scenario Runner 1.0.29: three cFS demonstrations and one ground-station demonstration

This checkout contains one Scenario Runner catalog for both `CFS-1_QEMU` and
`CFS-1_BBB`. Each target lists the same three demonstrations in order:
`01. CS 1바이트 CRC 키 복원` (18 steps), `02. TC 로그 사진 경로 변경` (7 steps),
and `03. MM 포인터 변경` (9 steps). The fourth definition,
`04. 지상국 운영 TC 시퀀스 예약` (4 steps), targets the OpenC3 `INST` simulator.
The Scenario API serves four definitions. The two example housekeeping procedures are removed.

The CRC procedure uses 16 one-byte CS OneShot commands. It then receives a
fresh frame from the separate `CFS-1_*_XBAND` telemetry target and verifies
its AES-GCM tag with the reconstructed key. The run result stores the
recovered lab key as hex; the Scenario Runner UI displays that key and the
authenticated frame's decrypted lab flag. Treat run records as sensitive lab
evidence and clear them before reusing this setup with real keys.

## Running the demonstration

`Start script` runs every step automatically. `Run step` on the first row
starts a manual run and executes that first step. After each success, only the
next row's button becomes available. The same Script Runner process stays
alive, preserving the recovered key, selected log index, or PSP pointer state
between steps. Buttons cannot skip or repeat completed steps. A manual run
has a 30-minute overall deadline; the automatic run keeps the scenario's
normal timeout.

Every step lists its planned TC packet(s) and parameter assignments before
execution. Runtime values, such as CRC addresses, log indices, request IDs,
and MM pointer slots, are labeled with their source or calculation. After a
step finishes, its `Execution result` block shows the returned outcome; a CRC
byte step includes the memory address, CRC, and recovered-byte count. The
Run log retains accepted command events with exact packet and parameter JSON.
Read-only steps explicitly say that no TC is planned. Older runs created
before command auditing have no exact command values in the Run log. The
OpenC3 target definition supplies packet header defaults in addition to the
listed parameters.

For scenario 01, the live telemetry selector lists only the installed
`CS_HK_TLM_SCREEN` and `XKEY_HK_SCREEN` on the selected target. Changing to
another scenario restores that target's full installed screen list and
selects the screen matching the new scenario's telemetry items.

## Source and deployment

Use this integration branch and its `compose.yaml` as the source for the
`openc3-cosmos-scn3` Compose project. The init/API images, both Scenario gems,
and runtime release check are pinned to **1.0.29**. Compose sets that version
explicitly, so a stale `SCENARIO_VERSION` in the shell or `.env` cannot
select a mismatched image. Use this checkout's `compose.yaml` when building
the matched image pair.

Set `CFS_BBB_BIND_IP=192.168.7.1` in the shell that runs Compose when the
BBB USB link is used. This publishes BBB housekeeping TM on UDP 1235 and the
separate X-band stream on UDP 4322 at the BBB-facing host address. With no
override these two ports bind to loopback for QEMU-only use. QEMU X-band uses
UDP 4323 inside the Docker network. The unified cFS target plugin must have
both `CFS-1_BBB_XBAND` and `CFS-1_QEMU_XBAND` installed, and each flight
target must run the integrated CS/XKEY/TC_CAMERA/MM/PAYLOAD_DATA_APP app set.

This OpenC3 repository contains the cFS target plugin source in
`cfs-cosmos-plugin/` and the verified `7.0.5.pre.all.3` gem in
`openc3-cosmos-init/cfs-artifacts/`. The init image packages that gem and
installs it before the Scenario Runner gems. A fresh clone therefore installs
the `CFS-1_QEMU`, `CFS-1_BBB`, and X-band targets without fetching another
repository or uploading a gem by hand. The installer reuses existing cFS
plugin variables when upgrading an older installation; new installations use
the defaults in `cfs-cosmos-plugin/plugin.txt`. The target definitions include
the `PAYLOAD_DATA_*` TC/TM packets needed by the PSP procedure. When changing
the cFS plugin source, build a new gem and update its filename and checksum
in the root `.gitignore`, the init `.dockerignore` and `Dockerfile`, and
`openc3-cosmos-init/scenario/install-cfs-plugin.rb`. Then rebuild the init
image.

From a fresh clone, run `docker compose up --build -d` in this repository and
check that `openc3-cosmos-init` exits with code 0. Building the image is
necessary when an older image with the same tag is already cached locally.

The PSP procedure requires the private `scenario-observer` service and a
supervised `core-cpu1` on each target. QEMU's `cfs-run` wrapper must end with
`exec ./core-cpu1`; BBB uses the direct `ExecStart` unit in
[`scenario-observer/README.md`](../scenario-observer/README.md). Both units
use `Restart=no` during this demonstration. Configure pinned SSH host keys
and target credentials as described there; the observer has no published host
port. Its process-instance and signal-11 report is the final proof of a
SIGSEGV. Missing telemetry alone never counts as success. The procedure
intentionally terminates cFS, so restart that target's service after recording
the result before running another scenario. After every QEMU or BBB cFS
service restart, send that target's `TO_LAB_CMD_ENABLE_OUTPUT` and verify fresh
TM again; the previous output state does not survive the flight restart.

For a new installation or one already on 1.0.29, build the matching images
and start the Compose project:

```sh
docker compose -p openc3-cosmos-scn3 build openc3-cosmos-init scenario-api scenario-observer
docker compose -p openc3-cosmos-scn3 up -d
```

For a complete earlier Scenario Runner installation (1.0.8 through 1.0.28),
the installer detects the installed gem pair and upgrades it to 1.0.29.
Prepare the existing deployment before starting the new init:

1. Confirm that Scenario Runner and OpenC3 Script Runner have no active runs.
   Preserve a consistent backup of the `scenario-data` volume and the
   installed init/API images and Scenario gems.
2. From this checkout, build the matching images with the same project name:
   `docker compose -p openc3-cosmos-scn3 build openc3-cosmos-init scenario-api scenario-observer`.
3. Stop the old API:
   `docker compose -p openc3-cosmos-scn3 stop scenario-api`.
4. Run the installer with `docker compose -p openc3-cosmos-scn3 up -d --force-recreate openc3-cosmos-init`,
   then check `docker compose -p openc3-cosmos-scn3 ps -a openc3-cosmos-init`
   and its logs. Proceed only after it exits 0. The installer verifies the old two-gem
   release, database schema and idle state, Script Runner idle state, new
   package manifest, catalog, policy, procedure, and UI hashes. To require a
   specific old version, set `SCENARIO_UPGRADE_FROM` to that version for this
   command; a mismatch is rejected.
5. Start the matching API:
   `docker compose -p openc3-cosmos-scn3 up -d --no-deps scenario-api`,
   then `docker compose -p openc3-cosmos-scn3 up -d`.

Do not keep `SCENARIO_UPGRADE_FROM` in `.env`. An unknown/newer release,
duplicate or partial plugin installation, active run, or unsupported database
schema is rejected. A failed multi-gem upgrade leaves
`/data/.scenario-install-incomplete`; inspect actual installed plugins and
restore from backup before clearing that marker. Do not remove the
`scenario-data` volume. OpenC3 Core is fixed at 6.10.1; the automatic
version handling concerns the Scenario Runner installation, not arbitrary
OpenC3 Core releases.

Verify `openc3-cosmos-init` exited 0, `scenario-api` is healthy,
`/scenario-api/scenarios` returns four definitions. The Scenario Runner selector
lists the first three procedures for each QEMU/BBB target and the fourth for
`INST`. Run a cFS target only after its TC/TM and X-band interfaces are receiving.

The shared scenario IDs are `cs-crc-key-oracle`, `tc-log-photo-traversal`,
and `psp-mm-indirect-write`. A run request carries one ID plus the selected
`target`; TC, TM, X-band and process observation use that target. Existing
completed records retain their previous target-specific IDs and definition
snapshots in the Scenario database.

## 2026-10-12 release 1.0.26 QEMU and BBB live validation

The updated 03 procedure completed automatically on **both** targets, 9/9
steps each. `MM_CMD_DEBUG_MAP` located an existing read-only code address in
the loaded `.so`. The four-byte pointer write and readback succeeded, and the
observer confirmed that each **original cFS process** terminated with
`SIGSEGV(11)` after resume.

| Target | Duration | Original PID | Pointer slot | Normal buffer → code address | Signal 11 observed (UTC) |
| --- | --- | --- | --- | --- | --- |
| QEMU | 20 seconds | `25225` | `0xb64c2080` | `0xb6f26000` → `0xb64b0000` | `2026-10-12T11:24:03.552263Z` |
| BBB | 50 seconds | `11493` | `0xb6972080` | `0xb6eef000` → `0xb6960000` | `2026-10-12T11:18:43Z` |

Step 2 `MM_CMD_DEBUG_MAP` and step 3 denied `MM_CMD_DEBUG_WRITE` each retried
once after losing an `MM_DEBUG` TM. The accepted TCs show a distinct
`REQUEST_ID` for each retry, and the run continued from the matching response.
This completed run demonstrates that the 1.0.26 Runner tolerates those
transient BBB TM losses. After both runs, the two `cfs.service` instances
were restarted and confirmed active: QEMU PID `25509` and BBB PID `11717`.
`TO_LAB_CMD_ENABLE_OUTPUT` was sent again to each target, with QEMU
`DEST_IP=172.21.0.2` and BBB `DEST_IP=192.168.7.1`.

## 2026-10-12 release 1.0.25 validation

The ARM QEMU/BBB builds completed, and their `mm.so` and `pay_data_app.so`
modules were deployed with the previous modules retained for rollback. The
unified cFS plugin `7.0.5.pre.all.3` and both Scenario Runner 1.0.25 gems were
installed. The init container exited 0 and the matching API health endpoint
returned `ok`. Before the upgrade, the scenario-data and installed-gem volumes
were backed up to `openc3-scn3-scenario-data-pre125-20261012` and
`openc3-scn3-gems-pre125-20261012`.

In the live Scenario Runner, the updated 03 procedure succeeded on QEMU in
9/9 steps, taking about 19 seconds. `MM_CMD_DEBUG_MAP` located the pointer
slot at `0xb6522080` and an existing read-only code address at `0xb6510000`.
The direct buffer write was denied, a four-byte pointer write and readback
changed the target from `0xb6f8a000` to `0xb6510000`, and the observer
confirmed that the original cFS PID `25047` terminated with signal 11 after
resume. This release uses no separate `mprotect(PROT_NONE)` guard page. A BBB
scenario 01 regression run also succeeded in 18/18 steps and authenticated
its X-band frame.

Two BBB 03 Runner attempts stopped at step 5 and step 7 because the expected
`MM_DEBUG` TM timed out, although the corresponding MM commands completed on
board. Neither attempt is recorded as a 9/9 Runner success. In a subsequent
manual check, redirecting the pointer to code address `0xb64b0000` and
sending `PAYLOAD_DATA_RESUME_CMD` terminated the original cFS PID `11048`
with `ExecMainCode=2`, `ExecMainStatus=11`. The BBB service was restarted as
PID `11493`, and `TO_LAB_CMD_ENABLE_OUTPUT` was sent again. Neither 1.0.25
Runner attempt completed all nine steps.

Automated checks passed: 63 Python Runner tests, 90 Scenario API tests with
783 assertions, 6 init upgrade tests with 49 assertions, and 5 cFS plugin
packet-contract tests with 42 assertions. The frontend image built and the
new 03 evidence was inspected in the live browser. The historical 1.0.22
results below used the earlier guard-page implementation; they are retained
as records of that release.

## 2026-10-12 scenario 01 telemetry selector verification

Scenario Runner 1.0.24 installed with init exit 0 and a healthy matching API.
In the live browser, scenario 01 listed exactly `CS_HK_TLM_SCREEN` and
`XKEY_HK_SCREEN` on both QEMU and BBB. Selecting the CS screen on BBB loaded
its packet display. Changing QEMU to scenario 02 restored the full installed
screen list and selected `CI_LOG_STATUS_SCREEN`. All 142 UI tests passed.
Before installation, the 1.0.23 scenario-data and gem volumes were backed up
to `openc3-scn3-scenario-data-pre124-20261012` and
`openc3-scn3-gems-pre124-20261012`.

## 2026-10-12 shared catalog live validation

The 1.0.22 init exited 0 and the Scenario API became healthy. Its catalog
returned exactly three definitions, each permitted on QEMU and BBB; the live
Scenario Runner selector showed the same three numbered procedures for both
targets. Before the upgrade, the scenario-data and installed-gem volumes were
copied to `openc3-scn3-scenario-data-pre122-20261012` and
`openc3-scn3-gems-pre122-20261012`.

All six live target/procedure combinations succeeded:

| Target | 01 CRC/X-band | 02 TC log/photo | 03 MM/SIGSEGV |
| --- | --- | --- | --- |
| QEMU | 18/18 steps; 16 CS TC; X-band authentication | 7/7 steps in manual mode; log overwritten with PNG bytes | 9/9 steps; observer confirmed signal 11 |
| BBB | 18/18 steps; 16 CS TC; X-band authentication | 7/7 steps in manual mode; log overwritten with PNG bytes | 9/9 steps; observer confirmed signal 11 |

After the 03 runs, both `cfs.service` instances were restarted and
`TO_LAB_CMD_ENABLE_OUTPUT` was sent to each. Fresh `TO_LAB_HK` and `CI_LAB_HK`
were received from both targets. Automated checks passed: 61 Python runner
tests, 141 UI tests, 90 API tests, and 6 installer tests.

## 2026-10-12 selector update verification

The 1.0.20 QEMU example run was stopped after user approval and its target
lock cleared. The Scenario data and installed gem volumes were backed up in
`backups/scenario-runner-1.0.20-20261012/` before upgrading. The 1.0.21 init
exited 0, the matching API became healthy, and both Scenario gems reported
1.0.21. The running API image contains exactly six definitions. In the live
Scenario Runner page, the target selector showed only `CFS-1_QEMU` and
`CFS-1_BBB`; both scenario selectors showed 01 CS, 02 TC log, and 03 MM in
that order, with the ES/EVS examples absent. The API image test suite passed
90 tests and 795 assertions; the UI suite passed 138 tests.

## Earlier Compose observations

The expected init status after startup is `Exited (0)`; the API should be
`healthy`. Use this checkout's Compose files and check the effective
configuration with `docker compose config` before deployment.

If BBB commands reach the board but its telemetry screen stops updating,
check `CFS-1_BBB_INTF` receive count before changing the flight software.
On 2026-10-08, BBB was sending UDP packets to `192.168.7.1:1235` and the
operator interface remained connected with receive count zero. Recreating
only the operator with
`docker compose up -d --force-recreate --no-deps openc3-operator` restored
its receive count and live BBB telemetry; QEMU telemetry also remained live.
This observation localizes the interruption to the host/operator UDP ingress
path, but does not identify a single internal Docker cause.
