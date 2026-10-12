"""Read-only cFS process status for the MM pointer demo.

Only two fixed targets and two fixed SSH commands are exposed.  The browser and
scenario procedure never provide a host, service, or shell command.
"""

from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading

import paramiko


STATUS_COMMAND = (
    "printf 'BOOT_ID='; cat /proc/sys/kernel/random/boot_id; "
    "systemctl show cfs.service --no-pager "
    "-p ActiveState -p MainPID -p ExecMainPID -p ExecMainCode "
    "-p ExecMainStatus -p Result -p InvocationID"
)
TARGETS = {
    "CFS-1_QEMU": "QEMU",
    "CFS-1_BBB": "BBB",
}


def read_secret(path: str) -> str | None:
    if not path:
        return None
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def fingerprint(key: paramiko.PKey) -> str:
    return base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")


class PinnedHostKey(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected: str):
        self.expected = expected.removeprefix("SHA256:")

    def missing_host_key(self, client, hostname, key):
        if not self.expected or fingerprint(key) != self.expected:
            raise paramiko.SSHException(f"untrusted SSH host key for {hostname}")


def parse_show(output: str) -> dict[str, str]:
    values = {}
    for line in output.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    required = {"ActiveState", "MainPID", "ExecMainPID", "ExecMainCode", "ExecMainStatus", "Result"}
    if not required.issubset(values):
        raise ValueError("incomplete systemd status")
    return values


def integer(value: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


class SSHBackend:
    def __init__(self, prefix: str):
        self.host = os.environ.get(f"SCENARIO_{prefix}_SSH_HOST", "")
        self.port = integer(os.environ.get(f"SCENARIO_{prefix}_SSH_PORT", "22"))
        self.user = os.environ.get(f"SCENARIO_{prefix}_SSH_USER", "")
        self.expected_key = os.environ.get(f"SCENARIO_{prefix}_HOST_KEY_SHA256", "")
        self.key_file = os.environ.get(f"SCENARIO_{prefix}_SSH_KEY_FILE", "")
        self.password_file = os.environ.get(f"SCENARIO_{prefix}_SSH_PASSWORD_FILE", "")

    def _run(self, client: paramiko.SSHClient, command: str) -> str:
        _, stdout, stderr = client.exec_command(command, timeout=15)
        result = stdout.read().decode("utf-8", errors="replace").strip()
        error = stderr.read().decode("utf-8", errors="replace").strip()
        if stdout.channel.recv_exit_status() != 0:
            raise RuntimeError(error or "SSH status command failed")
        return result

    def status(self) -> tuple[str, dict[str, str]]:
        if not (self.host and self.user and self.expected_key and self.port):
            raise RuntimeError("observer SSH target is not configured")
        password = read_secret(self.password_file) if self.password_file else None
        key_file = self.key_file if self.key_file and Path(self.key_file).stat().st_size else None
        if not (password or key_file):
            raise RuntimeError("observer SSH credential is not configured")
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(PinnedHostKey(self.expected_key))
        try:
            client.connect(
                self.host,
                port=self.port,
                username=self.user,
                password=password,
                key_filename=key_file,
                timeout=10,
                auth_timeout=10,
                banner_timeout=10,
                allow_agent=False,
                look_for_keys=False,
            )
            values = parse_show(self._run(client, STATUS_COMMAND))
            boot_id = values.pop("BOOT_ID", "")
            if not boot_id:
                raise ValueError("missing boot ID")
            return boot_id, values
        finally:
            client.close()


class Observer:
    def __init__(self, backends: dict[str, SSHBackend]):
        self.backends = backends
        self.last_running: dict[str, tuple[str, int]] = {}
        self.last_exit: dict[str, dict] = {}
        self.lock = threading.Lock()

    def status(self, target: str) -> dict:
        boot_id, values = self.backends[target].status()
        running = values["ActiveState"] == "active" and integer(values["MainPID"]) > 0
        pid = integer(values["MainPID"] if running else values["ExecMainPID"])
        invocation = values.get("InvocationID", "")
        instance_id = f"{boot_id}:{invocation}" if invocation else ""
        with self.lock:
            if running:
                if not instance_id:
                    raise ValueError("running service has no invocation ID")
                self.last_running[target] = (instance_id, pid)
            elif not instance_id and self.last_running.get(target, (None, None))[1] == pid:
                instance_id = self.last_running[target][0]
            code = integer(values["ExecMainCode"])
            signal_number = integer(values["ExecMainStatus"])
            if not running and instance_id and code in (2, 3) and signal_number == 11:
                self.last_exit[target] = {
                    "instance_id": instance_id,
                    "signal": 11,
                    "signal_name": "SIGSEGV",
                    "observed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                }
            last_exit = self.last_exit.get(target)
        return {
            "target": target,
            "running": running,
            "instance_id": instance_id or None,
            "pid": pid or None,
            "last_exit": last_exit,
        }


OBSERVER = Observer({target: SSHBackend(prefix) for target, prefix in TARGETS.items()})
TOKEN = os.environ.get("SCENARIO_OBSERVER_TOKEN", "")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, data: dict):
        body = json.dumps(data, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"error": "unauthorized"})
            return
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
            return
        prefix = "/v1/targets/"
        if not (self.path.startswith(prefix) and self.path.endswith("/status")):
            self._send(404, {"error": "not_found"})
            return
        target = self.path[len(prefix):-len("/status")]
        if target not in TARGETS:
            self._send(404, {"error": "unknown_target"})
            return
        try:
            self._send(200, OBSERVER.status(target))
        except (OSError, ValueError, RuntimeError, paramiko.SSHException) as error:
            self.log_error("observer target %s unavailable: %s", target, type(error).__name__)
            self._send(503, {"error": "observer_unavailable", "target": target})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 2911), Handler).serve_forever()
