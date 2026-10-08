# Scenario Runner 1.0.13: three cFS demonstrations

This checkout contains one Scenario Runner catalog for both `CFS-1_QEMU` and
`CFS-1_BBB`: CS CRC/X-band (18 steps), TC log/photo traversal (7 steps),
and MM indirect write (11 steps). The two housekeeping procedures are also
retained. The Scenario API serves eight definitions total.

The CRC procedure uses 16 one-byte CS OneShot commands. It then receives a
fresh frame from the separate `CFS-1_*_XBAND` telemetry target and verifies
its AES-GCM tag with the reconstructed key. The key is kept only in procedure
memory; run events and result text contain the authenticated frame summary,
not key bytes.

## Source and deployment

Use this integration checkout and its `compose.yaml` as the source for the
`openc3-cosmos-scn3` Compose project. Its init and API images, procedure/UI
gems, and installed-release check are pinned to **1.0.13**. The older
`open_c3/openc3-cosmos-scn3` checkout still has 1.0.8 source; starting that
checkout without the project forwarding configuration would attempt an older
init image.

Set `CFS_BBB_BIND_IP=192.168.7.1` in the shell that runs Compose when the
BBB USB link is used. This publishes BBB housekeeping TM on UDP 1235 and the
separate X-band stream on UDP 4322 at the BBB-facing host address. With no
override these two ports bind to loopback for QEMU-only use. QEMU X-band uses
UDP 4323 inside the Docker network. The unified cFS target plugin must have
both `CFS-1_BBB_XBAND` and `CFS-1_QEMU_XBAND` installed, and each flight
target must run the integrated CS/XKEY/TC_CAMERA/MM/payload app set.

For an existing 1.0.12 installation, perform a guarded upgrade:

1. Confirm that Scenario Runner and OpenC3 Script Runner have no active runs.
   Preserve a consistent backup of the `scenario-data` volume and the
   installed 1.0.12 init/API images and Scenario gems.
2. From this checkout, build both matching images with the same project name:
   `docker compose -p openc3-cosmos-scn3 build openc3-cosmos-init scenario-api`.
3. Stop the old API:
   `docker compose -p openc3-cosmos-scn3 stop scenario-api`.
4. Run the one-time installer:
   `docker compose -p openc3-cosmos-scn3 run --rm --no-deps -e SCENARIO_UPGRADE_FROM=1.0.12 openc3-cosmos-init`.
   Proceed only after it exits 0. The installer verifies the old two-gem
   release, database schema and idle state, Script Runner idle state, new
   package manifest, catalog, policy, procedure, and UI hashes.
5. Start the matching API:
   `docker compose -p openc3-cosmos-scn3 up -d --no-deps scenario-api`,
   then `docker compose -p openc3-cosmos-scn3 up -d`.

Do not keep `SCENARIO_UPGRADE_FROM` in `.env`. A failed multi-gem upgrade
leaves `/data/.scenario-install-incomplete`; inspect actual installed
plugins and restore from backup before clearing that marker. Do not remove
the `scenario-data` volume.

Verify `openc3-cosmos-init` exited 0, `scenario-api` is healthy,
`/scenario-api/scenarios` returns eight definitions, and the Scenario
Runner selector lists the corresponding QEMU/BBB procedures. Run the
appropriate target only after its TC/TM and X-band interfaces are receiving.

## This workspace's Compose entry point

`open_c3/openc3-cosmos-scn3/compose.override.yaml` forwards the original
checkout's init/API builds and plugin mounts to this integration checkout.
Run `docker compose up -d` from that original directory, as usual. The
expected init status after startup is `Exited (0)`; the API should be
`healthy`. Keep the override in place while using the all-scenario catalog.

If BBB commands reach the board but its telemetry screen stops updating,
check `CFS-1_BBB_INTF` receive count before changing the flight software.
On 2026-10-08, BBB was sending UDP packets to `192.168.7.1:1235` and the
operator interface remained connected with receive count zero. Recreating
only the operator with
`docker compose up -d --force-recreate --no-deps openc3-operator` restored
its receive count and live BBB telemetry; QEMU telemetry also remained live.
This observation localizes the interruption to the host/operator UDP ingress
path, but does not identify a single internal Docker cause.
