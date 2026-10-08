# Scenario Runner 1.0.14: three cFS demonstrations

This checkout contains one Scenario Runner catalog for both `CFS-1_QEMU` and
`CFS-1_BBB`: CS CRC/X-band (18 steps), TC log/photo traversal (7 steps),
and MM indirect write (11 steps). The two housekeeping procedures are also
retained. The Scenario API serves eight definitions total.

The CRC procedure uses 16 one-byte CS OneShot commands. It then receives a
fresh frame from the separate `CFS-1_*_XBAND` telemetry target and verifies
its AES-GCM tag with the reconstructed key. The 1.0.14 run result stores the
recovered lab key as hex; the Scenario Runner UI displays that key and the
authenticated frame's decrypted lab flag. Treat run records as sensitive lab
evidence and clear them before reusing this setup with real keys.

## Source and deployment

Use this integration branch and its `compose.yaml` as the source for the
`openc3-cosmos-scn3` Compose project. The init/API images, both Scenario gems,
and runtime release check are pinned to **1.0.14**. Compose sets that version
explicitly, so a stale `SCENARIO_VERSION` in the shell or `.env` cannot
select a mismatched image. The older `open_c3/openc3-cosmos-scn3` checkout
has 1.0.8 source; its local, untracked `compose.override.yaml` is only a
bridge for this machine and is not part of this branch. Run from a clean
checkout of this branch when deploying elsewhere.

Set `CFS_BBB_BIND_IP=192.168.7.1` in the shell that runs Compose when the
BBB USB link is used. This publishes BBB housekeeping TM on UDP 1235 and the
separate X-band stream on UDP 4322 at the BBB-facing host address. With no
override these two ports bind to loopback for QEMU-only use. QEMU X-band uses
UDP 4323 inside the Docker network. The unified cFS target plugin must have
both `CFS-1_BBB_XBAND` and `CFS-1_QEMU_XBAND` installed, and each flight
target must run the integrated CS/XKEY/TC_CAMERA/MM/payload app set.

For a new installation or one already on 1.0.14, build the matching images
and start the Compose project:

```sh
docker compose -p openc3-cosmos-scn3 build openc3-cosmos-init scenario-api
docker compose -p openc3-cosmos-scn3 up -d
```

For a complete earlier Scenario Runner installation (1.0.8 through 1.0.13),
the installer detects the installed gem pair and upgrades it to 1.0.14.
Prepare the existing deployment before starting the new init:

1. Confirm that Scenario Runner and OpenC3 Script Runner have no active runs.
   Preserve a consistent backup of the `scenario-data` volume and the
   installed init/API images and Scenario gems.
2. From this checkout, build both matching images with the same project name:
   `docker compose -p openc3-cosmos-scn3 build openc3-cosmos-init scenario-api`.
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
`/scenario-api/scenarios` returns eight definitions, and the Scenario
Runner selector lists the corresponding QEMU/BBB procedures. Run the
appropriate target only after its TC/TM and X-band interfaces are receiving.

## This workspace's earlier Compose entry point

`open_c3/openc3-cosmos-scn3/compose.override.yaml` forwards the original
checkout's init/API builds and plugin mounts to this integration checkout on
this machine. The expected init status after startup is `Exited (0)`; the
API should be `healthy`. In a clone of the integration branch, use its own
`compose.yaml` and do not copy that machine-specific override.

If BBB commands reach the board but its telemetry screen stops updating,
check `CFS-1_BBB_INTF` receive count before changing the flight software.
On 2026-10-08, BBB was sending UDP packets to `192.168.7.1:1235` and the
operator interface remained connected with receive count zero. Recreating
only the operator with
`docker compose up -d --force-recreate --no-deps openc3-operator` restored
its receive count and live BBB telemetry; QEMU telemetry also remained live.
This observation localizes the interruption to the host/operator UDP ingress
path, but does not identify a single internal Docker cause.
