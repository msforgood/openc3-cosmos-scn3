#!/usr/bin/env python3
"""Install (but do not start) the direct-exec cFS unit on the BBB.

Run from WSL with an already pinned SSH host key. Existing units are backed up
once. Starting the unit is deliberately separate so a running manual cFS
session can be stopped and its logs captured first.
"""

from __future__ import annotations

import argparse
import getpass
from pathlib import Path

import paramiko


UNIT = Path(__file__).with_name("bbb-cfs.service")
REMOTE_STAGE = "/tmp/cfs-psp-demo.service.stage"
REMOTE_UNIT = "/etc/systemd/system/cfs.service"
REMOTE_BACKUP = "/etc/systemd/system/cfs.service.pre-psp-segv"


def run(client: paramiko.SSHClient, command: str, password: str | None = None) -> str:
    stdin, stdout, stderr = client.exec_command(command, timeout=20)
    if password is not None:
        stdin.write(password + "\n")
        stdin.flush()
    stdin.channel.shutdown_write()
    result = stdout.read().decode(errors="replace").strip()
    error = stderr.read().decode(errors="replace").strip()
    if stdout.channel.recv_exit_status():
        raise RuntimeError(error or result or "remote command failed")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="install the unit on the BBB")
    parser.add_argument("--host", default="192.168.7.2")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--known-hosts", type=Path, default=Path.home() / ".ssh/known_hosts")
    args = parser.parse_args()
    if not UNIT.is_file():
        raise SystemExit(f"missing unit: {UNIT}")
    if not args.apply:
        print(f"Ready to install {UNIT} as {REMOTE_UNIT}; add --apply to connect.")
        return
    if not args.known_hosts.is_file():
        raise SystemExit("known_hosts is missing; verify and pin the BBB host key first")

    password = getpass.getpass("BBB SSH/sudo password: ")
    client = paramiko.SSHClient()
    client.load_host_keys(str(args.known_hosts))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    try:
        client.connect(args.host, port=args.port, username="debian", password=password,
                       timeout=8, auth_timeout=8, banner_timeout=8,
                       allow_agent=False, look_for_keys=False)
        run(client, "test -x /home/debian/cfs-bbb/core-cpu1")
        with client.open_sftp() as sftp:
            sftp.put(str(UNIT), REMOTE_STAGE)
        script = (
            "sudo -S -p '' sh -c '"
            f"if test -f {REMOTE_UNIT} && ! test -e {REMOTE_BACKUP}; then "
            f"cp {REMOTE_UNIT} {REMOTE_BACKUP}; fi; "
            f"install -m 0644 -o root -g root {REMOTE_STAGE} {REMOTE_UNIT}; "
            "systemctl daemon-reload'"
        )
        run(client, script, password)
        run(client, f"rm -f {REMOTE_STAGE}")
        print("BBB cfs.service installed. Stop any manual core-cpu1 session before starting it.")
    finally:
        client.close()


if __name__ == "__main__":
    main()
