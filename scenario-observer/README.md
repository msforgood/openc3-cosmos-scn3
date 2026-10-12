# Scenario 3 process observer

The MM pointer demo ends by terminating `core-cpu1`. Flight telemetry cannot
report its own SIGSEGV. This service exposes one read-only status endpoint for
each fixed target, so Scenario Runner can match the terminated process to its
pre-command process instance. A telemetry timeout is never sufficient proof.

## Target supervision

Both targets must run `core-cpu1` as the systemd service's main process with
`Restart=no` during the demonstration. QEMU's `cfs.service` already has this
restart setting. Its source wrapper at
`qemu-cfs/iot/rootfs/usr/local/sbin/cfs-run` now ends with `exec ./core-cpu1`;
install that wrapper in the guest when deploying the new QEMU bundle. The BBB
unit is `bbb-cfs.service` in this directory. From WSL, install it with
`python3 scenario-observer/install_bbb_service.py --apply` **before** running
`deploy_all_three_arm.py --target bbb --apply`. The installer verifies the
pinned SSH host key, preserves any old unit, and does not interrupt a manually
running cFS process. Stop that process, then start `cfs.service` and confirm
its main process is `/home/debian/cfs-bbb/core-cpu1`. The BBB bundle deployer
requires this active direct-exec service before staging or activating files.

The observer accepts `ExecMainCode=2` (killed) or `3` (core dumped) with
`ExecMainStatus=11`. A shell wrapper's ordinary exit status `139` is not
accepted as SIGSEGV evidence.

## Credentials and Compose

Create credential files outside Git. Set these Compose variables in the shell
or local `.env` before starting the observer:

| Variable | Value |
| --- | --- |
| `SCENARIO_QEMU_KEY_PATH` | Path to the QEMU SSH private key; the existing WSL key is `~/.ssh/cfs-qemu-iot_ed25519` |
| `SCENARIO_BBB_PASSWORD_PATH` | Path to a file containing the BBB SSH password |
| `SCENARIO_QEMU_HOST_KEY_SHA256` | Pinned SHA256 fingerprint of the QEMU SSH host key |
| `SCENARIO_BBB_HOST_KEY_SHA256` | Pinned SHA256 fingerprint of the BBB SSH host key |
| `SCENARIO_OBSERVER_TOKEN` | Optional shared bearer token for the script runner |

The key fingerprints must be checked against the trusted `known_hosts` used
for deployment. Missing credentials or fingerprints make that target return
HTTP 503; they never disable host-key validation. No observer port is published
on the host. The script runner reaches `http://scenario-observer:2911` on the
private Compose network. The observer executes one fixed command that reads
`/proc/sys/kernel/random/boot_id` and `systemctl show cfs.service` over SSH. It accepts
neither arbitrary target names nor remote commands.

The status JSON contains `running`, `pid`, an opaque `instance_id`, and a
`last_exit` record. Runner captures `instance_id` before sending any MM command
and succeeds only when the later signal-11 record has that same ID. After the
result is recorded, restart `cfs.service` explicitly to restore other demos.
