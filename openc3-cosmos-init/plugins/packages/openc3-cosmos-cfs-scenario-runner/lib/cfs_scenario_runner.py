"""Fixed, bounded housekeeping procedures; no user code and no transport sender.

Only the adapter touches OpenC3. The engine and validation are dependency-free
so the same safety behavior can be tested without any flight connection.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import threading
import time
from urllib.parse import urlsplit


CATALOG_PATH = Path(__file__).resolve().parents[1] / "targets/SCENARIO_RUNNER/lib/scenarios.json"
# This file is packaged with the immutable catalog and shared with the API.
POLICY = json.loads(CATALOG_PATH.with_name("safety_policy.json").read_bytes())
ALLOWED_TARGETS = frozenset(POLICY["allowedTargets"])
COMMANDS = {name: (data["telemetryPacket"], data["streamId"]) for name, data in POLICY["commands"].items()}
ITEMS = frozenset(POLICY["telemetryItems"])
TELEMETRY_TYPES = POLICY.get("telemetryTypes", {})
ORACLE = POLICY["crcKeyOracle"]
TCLOG = POLICY["tcLogTraversal"]
RECEIPT_ITEMS = ("RECEIVED_COUNT", "RECEIVED_TIMESECONDS")
RESERVED_ITEMS = frozenset({"PACKET_TIMESECONDS", "PACKET_TIMEFORMATTED", "RECEIVED_TIMESECONDS", "RECEIVED_TIMEFORMATTED", "RECEIVED_COUNT"})
HEADER_DEFAULTS = POLICY["headerDefaults"]
IDENTIFIER = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
MAX_EVENTS = 64
MAX_CALLS = 1024
MAX_CATALOG_BYTES = 65536


class ScenarioError(RuntimeError):
    """Only static error codes are exposed; upstream exceptions can contain tokens."""


def require(condition, code="invalid_definition"):
    if not condition:
        raise ScenarioError(code)


def bounded_call(function, seconds, label):
    """Bound even a stalled authentication/HTTP call; never retry a command.

    A timed-out in-flight request is ambiguous and cannot be unsent. The engine
    exits immediately and submits no subsequent commands. The daemon is not
    joined by Script Runner shutdown; management retains the target lock until
    authoritative process termination is observed.
    """
    require(isinstance(seconds, (int, float)) and seconds > 0, "deadline_exceeded")
    result = queue.Queue(maxsize=1)

    def work():
        try:
            result.put((True, function()))
        except BaseException:
            result.put((False, None))

    threading.Thread(target=work, daemon=True, name="scenario-api-call").start()
    try:
        ok, value = result.get(timeout=seconds)
    except queue.Empty:
        raise ScenarioError(label + "_timeout") from None
    if not ok:
        raise ScenarioError(label + "_error") from None
    return value


def canonical_hash(definition):
    try:
        data = json.dumps(definition, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        require(len(data.encode("utf-8")) <= MAX_CATALOG_BYTES)
        return hashlib.sha256(data.encode("utf-8")).hexdigest()
    except (TypeError, ValueError, RecursionError):
        raise ScenarioError("invalid_definition") from None


def _keys(value, names):
    require(type(value) is dict and set(value) == set(names.split()))


def _number(value, low, high):
    require(type(value) in (int, float) and math.isfinite(value) and low <= value <= high)


def _reference(value):
    _keys(value, "packet item")
    require(value["packet"] in {v[0] for v in COMMANDS.values()} and value["item"] in ITEMS)
    return value["packet"], value["item"]


def validate_definition(definition):
    """Strict schema plus semantic constraints; every send must have a fresh wait."""
    _keys(definition, "schemaVersion id version name description supportedTargets timeoutSec steps telemetryItems successCriteria")
    require(type(definition["schemaVersion"]) is int and definition["schemaVersion"] == 1)
    require(type(definition["id"]) is str and IDENTIFIER.fullmatch(definition["id"]))
    require(type(definition["version"]) is str and len(definition["version"]) <= 32 and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", definition["version"]))
    for field, maximum in (("name", 120), ("description", 1000)):
        require(type(definition[field]) is str and 1 <= len(definition[field]) <= maximum)
    require(type(definition["supportedTargets"]) is list and len(definition["supportedTargets"]) == 1 and definition["supportedTargets"][0] in ALLOWED_TARGETS)
    if definition["supportedTargets"][0] == "CFS-1_BBB":
        require(definition["id"] == TCLOG["scenarioIds"]["CFS-1_BBB"] and
                any(type(step) is dict and step.get("type") == "tcLogPhase" for step in definition["steps"]))
    _number(definition["timeoutSec"], 1, 120)
    _keys(definition["successCriteria"], "type requireFreshTelemetry")
    require(definition["successCriteria"]["type"] == "allStepsSucceeded" and definition["successCriteria"]["requireFreshTelemetry"] is True)
    refs = definition["telemetryItems"]
    require(type(refs) is list and 1 <= len(refs) <= 16)
    refs = [_reference(value) for value in refs]
    require(len(set(refs)) == len(refs))
    steps = definition["steps"]
    require(type(steps) is list and 2 <= len(steps) <= 17)
    if any(type(step) is dict and step.get("type") in ("resolveAddress", "crcByte") for step in steps):
        require(definition["id"] == "qemu-cs-crc-key-oracle" and definition["timeoutSec"] == 120)
        require(len(steps) == ORACLE["keyBytes"] + 1)
        expected_refs = {
            (ORACLE["keyPacket"], ORACLE[name]) for name in ("keyAddressItem", "keyLengthItem", "channelReadyItem")
        } | {
            (ORACLE["checksumPacket"], ORACLE[name]) for name in ("checksumAddressItem", "checksumValueItem")
        }
        require(set(refs) == expected_refs)
        require(steps[0] == {"id": "locate-key", "type": "resolveAddress", "timeoutSec": 10, "pollIntervalSec": 0.5})
        for offset, step in enumerate(steps[1:]):
            require(step == {"id": f"recover-byte-{offset:02d}", "type": "crcByte", "offset": offset,
                             "timeoutSec": 6, "pollIntervalSec": 0.25})
        canonical_hash(definition)
        return definition
    if any(type(step) is dict and step.get("type") == "tcLogPhase" for step in steps):
        target = definition["supportedTargets"][0]
        require(definition["id"] == TCLOG["scenarioIds"].get(target) and definition["timeoutSec"] == 120)
        require(set(refs) == {("CI_LOG_STATUS", "RESULT"), ("CI_LOG_CHUNK", "RESULT"),
                              ("TC_CAMERA_RESULT", "STATUS")})
        require(len(steps) == len(TCLOG["phases"]))
        for step, phase in zip(steps, TCLOG["phases"]):
            require(step == {"id": phase, "type": "tcLogPhase", "phase": phase})
        canonical_hash(definition)
        return definition
    seen, waited, pending = set(), set(), set()
    total, commands = 0.0, 0
    for step in steps:
        require(type(step) is dict and type(step.get("id")) is str and IDENTIFIER.fullmatch(step["id"]))
        require(step["id"] not in seen)
        seen.add(step["id"])
        kind = step.get("type")
        if kind == "command":
            _keys(step, "id type packet parameters timeoutSec")
            require(step["packet"] in COMMANDS and type(step["parameters"]) is dict and not step["parameters"])
            _number(step["timeoutSec"], 0.1, 5)
            packet = COMMANDS[step["packet"]][0]
            require(packet not in pending)
            pending.add(packet)
            commands += 1
            total += step["timeoutSec"] + 1  # Conservative command spacing budget.
        elif kind == "delay":
            _keys(step, "id type seconds")
            _number(step["seconds"], 0, 5)
            total += step["seconds"]
        elif kind == "waitTelemetry":
            _keys(step, "id type packet item operator value timeoutSec pollIntervalSec")
            ref = _reference({"packet": step["packet"], "item": step["item"]})
            require(ref in refs and step["packet"] in pending)
            require(step["operator"] in ("eq", "gte", "lte"))
            require(type(step["value"]) is int and 0 <= step["value"] <= 255)
            _number(step["timeoutSec"], 0.1, 30)
            _number(step["pollIntervalSec"], 0.25, 2)
            pending.remove(step["packet"])
            waited.add(ref)
            total += step["timeoutSec"]
        else:
            raise ScenarioError("invalid_definition")
    require(1 <= commands <= 4 and not pending and waited == set(refs))
    require(total <= definition["timeoutSec"])
    canonical_hash(definition)
    return definition


def load_catalog(path=CATALOG_PATH):
    data = Path(path).read_bytes()
    require(len(data) <= MAX_CATALOG_BYTES, "invalid_catalog")
    try:
        catalog = json.loads(data)
    except (ValueError, UnicodeError):
        raise ScenarioError("invalid_catalog") from None
    require(type(catalog) is list and 1 <= len(catalog) <= 32, "invalid_catalog")
    result = {}
    for definition in catalog:
        validate_definition(definition)
        require(definition["id"] not in result, "invalid_catalog")
        result[definition["id"]] = definition
    return result


def pin_definition(context, catalog, expected_hash):
    require(type(context) is dict and type(context.get("definition")) is dict, "invalid_context")
    snapshot = context["definition"]
    validate_definition(snapshot)
    local = catalog.get(snapshot["id"])
    require(local is not None, "definition_mismatch")
    validate_definition(local)
    require(local["version"] == snapshot["version"], "definition_mismatch")
    require(type(expected_hash) is str and re.fullmatch(r"[0-9a-f]{64}", expected_hash), "definition_mismatch")
    require(canonical_hash(snapshot) == canonical_hash(local) == context.get("definition_hash") == expected_hash, "definition_mismatch")
    require(context.get("target") in ALLOWED_TARGETS.intersection(local["supportedTargets"]), "invalid_target")
    require(context.get("stop_requested") is False, "stop_requested")
    return local


@dataclass(frozen=True)
class Sample:
    value: object
    count: int
    received: float
    stale: bool = False


@dataclass(frozen=True)
class PacketSample:
    values: dict
    count: int
    received: float
    stale: bool = False


def cfe_crc16(data):
    """cFE ES CRC-16 table is the reflected 0xA001 polynomial, seed zero."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc & 0xffff


CRC_BYTE_LOOKUP = {cfe_crc16(bytes((byte,))): byte for byte in range(256)}
require(len(CRC_BYTE_LOOKUP) == 256, "crc_oracle_not_injective")


class OpenC3Adapter:
    def __init__(self, api, scope, disconnected=False):
        require(not disconnected, "disconnected_mode")
        self.api, self.scope = api, scope
        # Existing OpenC3 JSON-RPC transport; normal command checks remain enabled.
        self.api.json_drb.timeout = 2.0

    def targets(self):
        return self.api.get_target_names(scope=self.scope)

    def command_definition(self, target, packet):
        return self.api.get_cmd(target, packet, scope=self.scope)

    def telemetry_definition(self, target, packet):
        return self.api.get_tlm(target, packet, scope=self.scope)

    def command(self, target, packet, parameters, timeout):
        # Do not use script.cmd: it intercepts hazardous/critical errors to prompt.
        # API_SERVER.cmd performs the same checked server call and returns/errors.
        return self.api.cmd(target, packet, parameters, timeout=timeout, scope=self.scope)

    def sample(self, target, packet, item):
        names = (item,) + RECEIPT_ITEMS
        values = self.api.get_tlm_values(
            [f"{target}__{packet}__{name}__RAW" for name in names],
            stale_time=5, cache_timeout=0, scope=self.scope,
        )
        require(type(values) is list and len(values) == 3 and all(type(v) is list and len(v) >= 2 for v in values), "invalid_telemetry")
        value, count, received = [row[0] for row in values]
        count = 0 if count is None else count
        received = 0 if received is None else received
        require(type(count) is int and count >= 0, "invalid_telemetry")
        require(type(received) in (int, float) and math.isfinite(received) and received >= 0, "invalid_telemetry")
        return Sample(value, count, received, any(row[1] == "STALE" for row in values))

    def sample_fields(self, target, packet, fields):
        names = tuple(fields) + RECEIPT_ITEMS
        rows = self.api.get_tlm_values(
            [f"{target}__{packet}__{name}__RAW" for name in names],
            stale_time=5, cache_timeout=0, scope=self.scope,
        )
        require(type(rows) is list and len(rows) == len(names) and
                all(type(row) is list and len(row) >= 2 for row in rows), "invalid_telemetry")
        count = rows[-2][0]
        received = rows[-1][0]
        count = 0 if count is None else count
        received = 0 if received is None else received
        require(type(count) is int and count >= 0, "invalid_telemetry")
        require(type(received) in (int, float) and math.isfinite(received) and received >= 0, "invalid_telemetry")
        return PacketSample(dict(zip(fields, (row[0] for row in rows))), count, received,
                            any(row[1] == "STALE" for row in rows))


class ManagementClient:
    """Authenticated context/callback HTTP with no transport logging or retries."""
    def __init__(self, base_url, run_id, scope, script_id, authentication, session=None):
        # Only the dedicated internal management service can receive credentials.
        parsed = urlsplit(base_url)
        require(parsed.scheme == "http" and parsed.hostname == "scenario-api" and parsed.port == 2910 and parsed.path == "/scenario-api" and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment, "invalid_management_url")
        require(type(run_id) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", run_id), "invalid_run_id")
        require(type(scope) is str and re.fullmatch(r"[A-Z0-9_-]{1,64}", scope), "invalid_scope")
        require(re.fullmatch(r"[1-9][0-9]{0,19}", str(script_id)), "invalid_script_id")
        if session is None:
            import requests
            session = requests.Session()
            session.trust_env = False
        self.session, self.authentication = session, authentication
        self.url, self.scope = base_url + "/runs/" + run_id, scope
        self.script_id, self.run_id = str(script_id), run_id
        self.sequence = 0

    def _request(self, method, suffix, body=None):
        require(self.authentication is not None, "authentication_unavailable")
        token = self.authentication.token()
        require(type(token) is str and 0 < len(token) <= 16384, "authentication_unavailable")
        response = self.session.request(
            method, self.url + suffix, params={"scope": self.scope}, json=body,
            headers={"Authorization": token, "Content-Type": "application/json"},
            timeout=(1, 2), allow_redirects=False, stream=True,
        )
        try:
            require(response.status_code == 200, "management_rejected")
            data = bytearray()
            for chunk in response.iter_content(4096):
                data.extend(chunk)
                require(len(data) <= MAX_CATALOG_BYTES, "management_response_too_large")
            result = json.loads(data)
            require(type(result) is dict, "invalid_context")
            return result
        finally:
            response.close()

    def context(self):
        return self._request("GET", "/context")

    def emit(self, kind, data):
        self.sequence += 1
        require(self.sequence <= MAX_EVENTS, "event_limit")
        return self._request("POST", "/callback", {
            "scope": self.scope, "script_id": self.script_id,
            "event_id": f"{self.run_id}:{self.script_id}:{self.sequence}",
            "type": kind, "data": data,
        })


class ScenarioRunner:
    def __init__(self, adapter, management, catalog, expected_hash, *, monotonic=time.monotonic, wall_time=time.time, sleep=time.sleep, call=bounded_call):
        self.adapter, self.management = adapter, management
        self.catalog, self.expected_hash = catalog, expected_hash
        self.monotonic, self.wall_time, self.sleep, self.call = monotonic, wall_time, sleep, call
        self.deadline = monotonic() + 5  # Bootstrap also has an absolute deadline.
        self.calls, self.events = 0, 0
        self.last_send = None
        self.baselines = {}
        self.step_id = None

    def _remaining(self, limit=2):
        remaining = min(limit, self.deadline - self.monotonic())
        require(remaining > 0, "deadline_exceeded")
        return remaining

    def _call(self, function, label, limit=2):
        self.calls += 1
        require(self.calls <= MAX_CALLS, "call_limit")
        value = self.call(function, self._remaining(limit), label)
        self._remaining()
        return value

    def _context(self, value):
        require(type(value) is dict, "invalid_context")
        require(value.get("run_id") == self.management.run_id and value.get("scope") == self.management.scope, "context_mismatch")
        require(value.get("target") == self.target and value.get("definition_hash") == self.expected_hash, "definition_mismatch")
        require(value.get("stop_requested") is False, "stop_requested")
        require(value.get("prompt") is None, "unsupported_prompt")
        return value

    def _emit(self, kind, data):
        self.events += 1
        require(self.events <= MAX_EVENTS, "event_limit")
        return self._context(self._call(lambda: self.management.emit(kind, data), "callback"))

    def _check_stop(self):
        return self._context(self._call(self.management.context, "context"))

    def _preflight(self, definition):
        names = self._call(self.adapter.targets, "targets")
        require(type(names) is list and self.target in set(names).intersection(definition["supportedTargets"]).intersection(ALLOWED_TARGETS), "target_not_installed")
        if any(step["type"] == "tcLogPhase" for step in definition["steps"]):
            self._preflight_tc_log()
            return
        for packet in dict.fromkeys(s["packet"] for s in definition["steps"] if s["type"] == "command"):
            data = self._call(lambda: self.adapter.command_definition(self.target, packet), "command_definition")
            require(type(data) is dict and data.get("target_name") == self.target and data.get("packet_name") == packet, "invalid_command")
            require(not any(data.get(flag) for flag in ("hazardous", "disabled", "hidden")), "invalid_command")
            items = {v["name"]: v for v in data.get("items", [])}
            expected = dict(HEADER_DEFAULTS, CCSDS_STREAMID=COMMANDS[packet][1])
            require(set(items) == set(expected) | RESERVED_ITEMS, "command_definition_mismatch")
            require(all(items[k].get("default") == v for k, v in expected.items()), "command_definition_mismatch")
            require(items["CCSDS_STREAMID"].get("id_value") == expected["CCSDS_STREAMID"], "command_definition_mismatch")
        for packet in dict.fromkeys(ref["packet"] for ref in definition["telemetryItems"]):
            data = self._call(lambda: self.adapter.telemetry_definition(self.target, packet), "telemetry_definition")
            require(type(data) is dict and data.get("target_name") == self.target and data.get("packet_name") == packet, "invalid_telemetry_item")
            items = {v["name"]: v for v in data.get("items", [])}
            required = {r["item"] for r in definition["telemetryItems"] if r["packet"] == packet}
            require(required.union(RECEIPT_ITEMS) <= set(items), "invalid_telemetry_item")
            require(all(items[k].get("data_type") == "UINT" and
                        items[k].get("bit_size") == TELEMETRY_TYPES.get(f"{packet}.{k}", 8)
                        for k in required), "telemetry_definition_mismatch")
            require(all(items[k].get("data_type") == "DERIVED" for k in RECEIPT_ITEMS), "telemetry_definition_mismatch")
        if any(step["type"] == "crcByte" for step in definition["steps"]):
            self._preflight_oracle()

    def _preflight_tc_log(self):
        fields = {
            "CI_LOG_STATUS_CMD": (2, {"REQUEST_ID": ("UINT", 16), "RESERVED": ("UINT", 16)}),
            "CI_LOG_SEAL_CMD": (3, {"REQUEST_ID": ("UINT", 16), "RESERVED": ("UINT", 16)}),
            "CI_LOG_READ_CMD": (4, {"REQUEST_ID": ("UINT", 16), "FILE_INDEX": ("UINT", 16), "OFFSET": ("UINT", 32)}),
            "TC_CAMERA_CAPTURE_CMD": (2, {"REQUEST_ID": ("UINT", 16), "FILENAME": ("STRING", 256)}),
            "CFE_ES_SEND_HK_CMD": (0, {}),
        }
        for packet, (function_code, expected_fields) in fields.items():
            data = self._call(lambda p=packet: self.adapter.command_definition(self.target, p), "command_definition")
            require(type(data) is dict and data.get("target_name") == self.target and
                    data.get("packet_name") == packet and
                    not any(data.get(flag) for flag in ("hazardous", "disabled", "hidden")), "invalid_command")
            items = {item["name"]: item for item in data.get("items", [])}
            header = dict(HEADER_DEFAULTS, CCSDS_STREAMID=COMMANDS[packet][1], CCSDS_FC=function_code)
            require(set(items) == set(header) | set(expected_fields) | RESERVED_ITEMS, "command_definition_mismatch")
            require(all(items[name].get("default") == value for name, value in header.items()) and
                    items["CCSDS_STREAMID"].get("id_value") == header["CCSDS_STREAMID"], "command_definition_mismatch")
            require(all((items[name].get("data_type"), items[name].get("bit_size")) == kind_size
                        for name, kind_size in expected_fields.items()), "command_definition_mismatch")
        telemetry = {
            "CI_LOG_STATUS": {"REQUEST_ID": 16, "RESULT": 16, "ACTIVE_INDEX": 16,
                              "LAST_CLOSED_INDEX": 16, "ACTIVE_RECORDS": 32, "TOTAL_LOGGED": 32,
                              "WRITE_ERRORS": 32, "READ_ERRORS": 32},
            "CI_LOG_CHUNK": {"REQUEST_ID": 16, "RESULT": 16, "FILE_INDEX": 16,
                             "DATA_LENGTH": 16, "OFFSET": 32, "FILE_SIZE": 32, "DATA": 8},
            "TC_CAMERA_RESULT": {"REQUEST_ID": 16, "STATUS": 16, "BYTES_WRITTEN": 32,
                                 "FILENAME": 256},
        }
        for packet, required in telemetry.items():
            data = self._call(lambda p=packet: self.adapter.telemetry_definition(self.target, p), "telemetry_definition")
            require(type(data) is dict and data.get("target_name") == self.target and
                    data.get("packet_name") == packet, "invalid_telemetry_item")
            items = {item["name"]: item for item in data.get("items", [])}
            require(set(required) | set(RECEIPT_ITEMS) <= set(items), "invalid_telemetry_item")
            require(all(items[name].get("data_type") == ("STRING" if name == "FILENAME" else "UINT") and
                        items[name].get("bit_size") == size for name, size in required.items()),
                    "telemetry_definition_mismatch")
            require(all(items[name].get("data_type") == "DERIVED" for name in RECEIPT_ITEMS),
                    "telemetry_definition_mismatch")

    def _preflight_oracle(self):
        packet = ORACLE["command"]
        data = self._call(lambda: self.adapter.command_definition(self.target, packet), "command_definition")
        require(type(data) is dict and data.get("target_name") == self.target and
                data.get("packet_name") == packet and
                not any(data.get(flag) for flag in ("hazardous", "disabled", "hidden")), "invalid_command")
        items = {item["name"]: item for item in data.get("items", [])}
        expected = dict(HEADER_DEFAULTS, CCSDS_STREAMID=ORACLE["streamId"])
        fields = {"ADDRESS", "SIZE", "MAX_BYTES_PER_CYCLE"}
        require(set(items) == set(expected) | fields | RESERVED_ITEMS, "command_definition_mismatch")
        require(all(items[name].get("default") == value for name, value in expected.items()) and
                items["CCSDS_STREAMID"].get("id_value") == ORACLE["streamId"], "command_definition_mismatch")
        require(all(items[name].get("data_type") == "UINT" and items[name].get("bit_size") == 32
                    for name in fields), "command_definition_mismatch")
        packet = ORACLE["checksumPacket"]
        data = self._call(lambda: self.adapter.telemetry_definition(self.target, packet), "telemetry_definition")
        require(type(data) is dict and data.get("target_name") == self.target and data.get("packet_name") == packet,
                "invalid_telemetry_item")
        items = {item["name"]: item for item in data.get("items", [])}
        for name in ("checksumSizeItem", "checksumBusyItem"):
            item = ORACLE[name]
            require(item in items and items[item].get("data_type") == "UINT" and
                    items[item].get("bit_size") == TELEMETRY_TYPES[f"{packet}.{item}"], "telemetry_definition_mismatch")

    def _delay(self, seconds):
        end = self.monotonic() + seconds
        while self.monotonic() < end:
            self._check_stop()
            remaining = end - self.monotonic()
            if remaining > 0:
                self.sleep(min(0.5, remaining, self._remaining()))

    def _command(self, step):
        if self.last_send is not None:
            self._delay(max(0, 1 - (self.monotonic() - self.last_send)))
        self._check_stop()
        packet = COMMANDS[step["packet"]][0]
        baseline = self._call(lambda: self.adapter.sample(self.target, packet, "COMMAND_COUNTER"), "baseline")
        sent_at = self.wall_time()
        self.baselines[packet] = (baseline, sent_at)
        self.last_send = self.monotonic()
        timeout = self._remaining(step["timeoutSec"])
        accepted = self._call(lambda: self.adapter.command(self.target, step["packet"], dict(step["parameters"]), timeout), "command", timeout)
        require(type(accepted) is dict and accepted.get("target_name") == self.target and accepted.get("cmd_name") == step["packet"], "command_not_accepted")
        return {"packet": step["packet"], "commandAccepted": True, "telemetryConfirmed": False}

    def _wait_telemetry(self, step):
        baseline, sent_at = self.baselines[step["packet"]]
        end = min(self.deadline, self.monotonic() + step["timeoutSec"])
        maximum_polls = math.ceil(step["timeoutSec"] / step["pollIntervalSec"]) + 1
        for _ in range(maximum_polls):
            if self.monotonic() >= end:
                break
            self._check_stop()
            sample = self._call(lambda: self.adapter.sample(self.target, step["packet"], step["item"]), "telemetry", min(2, max(0.001, end - self.monotonic())))
            now = self.wall_time()
            fresh = (not sample.stale and sample.count > baseline.count and sample.received > baseline.received and sample.received >= sent_at and -1 <= now - sample.received <= 5)
            valid = type(sample.value) is int and 0 <= sample.value <= 255
            matches = valid and {"eq": sample.value == step["value"], "gte": sample.value >= step["value"], "lte": sample.value <= step["value"]}[step["operator"]]
            if self.monotonic() < end and fresh and matches:
                return {"packet": step["packet"], "item": step["item"], "value": sample.value, "received_at": datetime.fromtimestamp(sample.received, timezone.utc).isoformat(), "commandAccepted": False, "telemetryConfirmed": True}
            remaining = end - self.monotonic()
            if remaining > 0:
                self.sleep(min(step["pollIntervalSec"], remaining, self._remaining()))
        raise ScenarioError("telemetry_timeout")

    def _resolve_address(self, step):
        end = min(self.deadline, self.monotonic() + step["timeoutSec"])
        fields = (ORACLE["keyAddressItem"], ORACLE["keyLengthItem"], ORACLE["channelReadyItem"])
        for _ in range(math.ceil(step["timeoutSec"] / step["pollIntervalSec"]) + 1):
            self._check_stop()
            sample = self._call(lambda: self.adapter.sample_fields(self.target, ORACLE["keyPacket"], fields), "telemetry")
            address, length, ready = (sample.values[field] for field in fields)
            if (not sample.stale and sample.count > 0 and type(address) is int and
                    0x10000 <= address <= 0xffffffff - ORACLE["keyBytes"] and
                    length == ORACLE["keyBytes"] and ready == 1):
                self.key_address = address
                self.recovered = bytearray()
                return {"packet": ORACLE["keyPacket"], "item": ORACLE["keyAddressItem"],
                        "value": address, "received_at": datetime.fromtimestamp(sample.received, timezone.utc).isoformat(),
                        "telemetryConfirmed": True, "message": f"RAM key address 0x{address:08x}"}
            if self.monotonic() >= end:
                break
            self.sleep(min(step["pollIntervalSec"], end - self.monotonic(), self._remaining()))
        raise ScenarioError("key_address_unavailable")

    def _crc_byte(self, step):
        require(hasattr(self, "key_address") and len(self.recovered) == step["offset"], "invalid_oracle_state")
        address = self.key_address + step["offset"]
        packet = ORACLE["checksumPacket"]
        fields = (ORACLE["checksumAddressItem"], ORACLE["checksumSizeItem"],
                  ORACLE["checksumValueItem"], ORACLE["checksumBusyItem"])
        baseline = self._call(lambda: self.adapter.sample_fields(self.target, packet, fields), "baseline")
        if self.last_send is not None:
            self._delay(max(0, 1 - (self.monotonic() - self.last_send)))
        self._check_stop()
        self.last_send = self.monotonic()
        timeout = self._remaining(2)
        accepted = self._call(lambda: self.adapter.command(self.target, ORACLE["command"],
                                 {"ADDRESS": address, "SIZE": 1, "MAX_BYTES_PER_CYCLE": 1}, timeout),
                              "command", timeout)
        require(type(accepted) is dict and accepted.get("target_name") == self.target and
                accepted.get("cmd_name") == ORACLE["command"], "command_not_accepted")
        end = min(self.deadline, self.monotonic() + step["timeoutSec"])
        for _ in range(math.ceil(step["timeoutSec"] / step["pollIntervalSec"]) + 1):
            if self.monotonic() >= end:
                break
            self._check_stop()
            sample = self._call(lambda: self.adapter.sample_fields(self.target, packet, fields),
                                "telemetry", min(2, max(0.001, end - self.monotonic())))
            reported_address, size, checksum, busy = (sample.values[field] for field in fields)
            if (not sample.stale and sample.count > baseline.count and sample.received > baseline.received and
                    reported_address == address and size == 1 and busy == 0 and type(checksum) is int):
                crc = checksum & 0xffff  # cFE can sign-extend its int16 CRC to a uint32 TM field.
                require(crc in CRC_BYTE_LOOKUP, "crc_not_invertible")
                value = CRC_BYTE_LOOKUP[crc]
                self.recovered.append(value)
                return {"packet": packet, "item": ORACLE["checksumValueItem"], "value": crc,
                        "received_at": datetime.fromtimestamp(sample.received, timezone.utc).isoformat(),
                        "commandAccepted": True, "telemetryConfirmed": True,
                        "message": f"0x{address:08x}: CRC 0x{crc:04x} -> byte 0x{value:02x}"}
            self.sleep(min(step["pollIntervalSec"], end - self.monotonic(), self._remaining()))
        raise ScenarioError("crc_telemetry_timeout")

    def _tc_next_request_id(self):
        if not hasattr(self, "tc_request_id"):
            self.tc_request_id = int(self.wall_time() * 1000) & 0xffff
        self.tc_request_id = (self.tc_request_id + 1) & 0xffff
        return self.tc_request_id

    def _tc_request(self, command, parameters, response_packet, fields, result_field):
        request_id = self._tc_next_request_id()
        parameters = dict(parameters, REQUEST_ID=request_id)
        baseline = self._call(lambda: self.adapter.sample_fields(self.target, response_packet, fields), "baseline")
        if self.last_send is not None:
            self._delay(max(0, 1 - (self.monotonic() - self.last_send)))
        self._check_stop()
        sent_at = self.wall_time()
        self.last_send = self.monotonic()
        timeout = self._remaining(2)
        accepted = self._call(lambda: self.adapter.command(self.target, command, parameters, timeout),
                              "command", timeout)
        require(type(accepted) is dict and accepted.get("target_name") == self.target and
                accepted.get("cmd_name") == command, "command_not_accepted")
        end = min(self.deadline, self.monotonic() + 10)
        for _ in range(41):
            if self.monotonic() >= end:
                break
            self._check_stop()
            sample = self._call(lambda: self.adapter.sample_fields(self.target, response_packet, fields),
                                "telemetry", min(2, max(0.001, end - self.monotonic())))
            now = self.wall_time()
            fresh = (not sample.stale and sample.count > baseline.count and
                     sample.received > baseline.received and sample.received >= int(sent_at) - 1 and
                     -1 <= now - sample.received <= 5)
            if fresh and sample.values.get("REQUEST_ID") == request_id:
                result = sample.values.get(result_field)
                require(type(result) is int and 0 <= result <= 6, "invalid_telemetry")
                require(result == 0, f"tc_result_{result}")
                return sample
            self.sleep(min(0.25, max(0, end - self.monotonic()), self._remaining()))
        raise ScenarioError("tc_telemetry_timeout")

    def _tc_status(self, seal=False):
        fields = ("REQUEST_ID", "RESULT", "ACTIVE_INDEX", "LAST_CLOSED_INDEX",
                  "ACTIVE_RECORDS", "TOTAL_LOGGED", "WRITE_ERRORS", "READ_ERRORS")
        command = "CI_LOG_SEAL_CMD" if seal else "CI_LOG_STATUS_CMD"
        return self._tc_request(command, {"RESERVED": 0}, "CI_LOG_STATUS", fields, "RESULT")

    def _tc_read(self, index):
        fields = ("REQUEST_ID", "RESULT", "FILE_INDEX", "DATA_LENGTH", "OFFSET", "FILE_SIZE", "DATA")
        sample = self._tc_request("CI_LOG_READ_CMD", {"FILE_INDEX": index, "OFFSET": 0},
                                  "CI_LOG_CHUNK", fields, "RESULT")
        values = sample.values
        length, size, raw = values["DATA_LENGTH"], values["FILE_SIZE"], values["DATA"]
        require(values["FILE_INDEX"] == index and values["OFFSET"] == 0 and
                type(length) is int and 0 < length <= TCLOG["maxChunkBytes"] and
                type(size) is int and length <= size, "invalid_log_chunk")
        if type(raw) in (bytes, bytearray):
            data = bytes(raw)
        elif (type(raw) in (list, tuple) and len(raw) == TCLOG["maxChunkBytes"] and
              all(type(value) is int and 0 <= value <= 255 for value in raw)):
            data = bytes(raw)
        else:
            raise ScenarioError("invalid_log_chunk")
        require(len(data) == TCLOG["maxChunkBytes"] and all(value == 0 for value in data[length:]),
                "invalid_log_chunk")
        return data[:length], size, sample.received

    def _tc_camera(self, filename):
        fields = ("REQUEST_ID", "STATUS", "BYTES_WRITTEN", "FILENAME")
        sample = self._tc_request("TC_CAMERA_CAPTURE_CMD", {"FILENAME": filename},
                                  "TC_CAMERA_RESULT", fields, "STATUS")
        count = sample.values["BYTES_WRITTEN"]
        require(type(count) is int and 8 <= count <= 1048576, "invalid_photo_size")
        return count, sample.received

    def _tc_hk(self):
        if self.last_send is not None:
            self._delay(max(0, 1 - (self.monotonic() - self.last_send)))
        self._check_stop()
        self.last_send = self.monotonic()
        timeout = self._remaining(2)
        accepted = self._call(lambda: self.adapter.command(self.target, "CFE_ES_SEND_HK_CMD", {}, timeout),
                              "command", timeout)
        require(type(accepted) is dict and accepted.get("target_name") == self.target and
                accepted.get("cmd_name") == "CFE_ES_SEND_HK_CMD", "command_not_accepted")

    def _tc_log_phase(self, step):
        phase = step["phase"]
        if phase == "seal-baseline":
            values = self._tc_status(seal=True).values
            require(values["WRITE_ERRORS"] == 0 and values["LAST_CLOSED_INDEX"] >= 1 and
                    values["ACTIVE_INDEX"] > values["LAST_CLOSED_INDEX"], "log_not_ready")
            self.tc_baseline_index = values["LAST_CLOSED_INDEX"]
            return {"file_index": self.tc_baseline_index, "message": "Closed the previous onboard TC log",
                    "commandAccepted": True, "telemetryConfirmed": True}
        if phase == "record-normal":
            require(hasattr(self, "tc_baseline_index"), "invalid_log_state")
            self._tc_hk()
            count, received = self._tc_camera(TCLOG["normalFilename"])
            return {"filename": TCLOG["normalFilename"], "photo_bytes": count,
                    "received_at": datetime.fromtimestamp(received, timezone.utc).isoformat(),
                    "message": "Normal camera TC and housekeeping TC accepted",
                    "commandAccepted": True, "telemetryConfirmed": True}
        if phase == "seal-target":
            values = self._tc_status(seal=True).values
            index = values["LAST_CLOSED_INDEX"]
            require(type(index) is int and self.tc_baseline_index < index <= 9999 and
                    values["ACTIVE_INDEX"] > index and values["WRITE_ERRORS"] == 0,
                    "target_log_unavailable")
            self.tc_target_index = index
            self.tc_total_before = values["TOTAL_LOGGED"]
            return {"file_index": index, "total_logged": self.tc_total_before,
                    "message": f"Sealed onboard /cf/log/tc{index:04d}.log",
                    "commandAccepted": True, "telemetryConfirmed": True}
        require(hasattr(self, "tc_target_index"), "invalid_log_state")
        if phase == "read-before":
            data, size, received = self._tc_read(self.tc_target_index)
            require(data.startswith(b"TCLOG v1\n") and b"mid=0x18E2" in data,
                    "expected_tc_log_missing")
            self.tc_before = data
            return {"file_index": self.tc_target_index, "file_size": size,
                    "before_text": data.decode("ascii", errors="replace"), "before_hex": data.hex(),
                    "received_at": datetime.fromtimestamp(received, timezone.utc).isoformat(),
                    "message": "Read original onboard TC log bytes", "telemetryConfirmed": True}
        if phase == "overwrite-log":
            require(hasattr(self, "tc_before"), "invalid_log_state")
            filename = f"../log/tc{self.tc_target_index:04d}.log"
            count, received = self._tc_camera(filename)
            self.tc_photo_bytes = count
            return {"file_index": self.tc_target_index, "filename": filename, "photo_bytes": count,
                    "received_at": datetime.fromtimestamp(received, timezone.utc).isoformat(),
                    "message": "Camera reported writing the chosen filename",
                    "commandAccepted": True, "telemetryConfirmed": True}
        if phase == "read-after":
            require(hasattr(self, "tc_photo_bytes"), "invalid_log_state")
            data, size, received = self._tc_read(self.tc_target_index)
            require(data.startswith(bytes.fromhex(TCLOG["imageSignatureHex"])) and
                    size == self.tc_photo_bytes and data != self.tc_before,
                    "log_overwrite_unconfirmed")
            return {"file_index": self.tc_target_index, "file_size": size,
                    "after_hex": data.hex(), "received_at": datetime.fromtimestamp(received, timezone.utc).isoformat(),
                    "message": "Same onboard log path now contains PNG bytes", "telemetryConfirmed": True}
        if phase == "confirm-continuity":
            values = self._tc_status().values
            require(values["WRITE_ERRORS"] == 0 and values["ACTIVE_INDEX"] > self.tc_target_index and
                    values["ACTIVE_RECORDS"] > 0 and values["TOTAL_LOGGED"] > self.tc_total_before,
                    "logging_not_continuing")
            return {"active_index": values["ACTIVE_INDEX"], "total_logged": values["TOTAL_LOGGED"],
                    "write_errors": values["WRITE_ERRORS"],
                    "message": "Later TC packets continue in the next onboard log",
                    "commandAccepted": True, "telemetryConfirmed": True}
        raise ScenarioError("invalid_log_phase")

    def run(self):
        try:
            context = self._call(self.management.context, "context")
            definition = pin_definition(context, self.catalog, self.expected_hash)
            self.target = context["target"]
            self._context(context)
            try:
                remote_deadline = datetime.fromisoformat(context["deadline"].replace("Z", "+00:00"))
                require(remote_deadline.tzinfo is not None, "invalid_deadline")
                seconds = remote_deadline.timestamp() - self.wall_time()
            except (KeyError, TypeError, ValueError):
                raise ScenarioError("invalid_deadline") from None
            require(seconds > 0, "deadline_exceeded")
            self.deadline = self.monotonic() + min(definition["timeoutSec"], seconds)
            self._preflight(definition)
            self._emit("started", {"message": "Definition and installed packet validation passed"})
            for step in definition["steps"]:
                self.step_id = step["id"]
                self._emit("step", {"step_id": step["id"], "status": "running"})
                if step["type"] == "command":
                    data = self._command(step)
                elif step["type"] == "delay":
                    self._delay(step["seconds"])
                    data = {}
                elif step["type"] == "resolveAddress":
                    data = self._resolve_address(step)
                elif step["type"] == "crcByte":
                    data = self._crc_byte(step)
                elif step["type"] == "tcLogPhase":
                    data = self._tc_log_phase(step)
                else:
                    data = self._wait_telemetry(step)
                self._emit("step", dict(data, step_id=step["id"], status="succeeded"))
            if hasattr(self, "recovered"):
                require(len(self.recovered) == ORACLE["keyBytes"], "incomplete_key")
                message = "Recovered X-band lab key: " + self.recovered.hex()
            elif hasattr(self, "tc_target_index"):
                message = f"Onboard TC log tc{self.tc_target_index:04d}.log replaced by the demo photo"
            else:
                message = "All steps completed with fresh telemetry"
            self._emit("result", {"status": "succeeded", "message": message})
            return {"status": "succeeded"}
        except Exception as error:
            code = str(error) if isinstance(error, ScenarioError) else "runtime_error"
            # Final reporting is best effort, bounded, never sends commands and
            # never prints upstream exception messages (which can embed auth).
            if hasattr(self, "target"):
                if self.step_id:
                    try:
                        self.call(lambda: self.management.emit("step", {"step_id": self.step_id, "status": "failed", "message": code}), 0.5, "failure_callback")
                    except Exception:
                        pass
                try:
                    self.call(lambda: self.management.emit("result", {"status": "failed", "message": code}), 0.5, "failure_callback")
                except Exception:
                    pass
            raise ScenarioError(code) from None


def run_from_environment():
    """Script Runner bootstrap. Credentials remain in its existing auth object."""
    import openc3.script
    from openc3.environment import OPENC3_SCOPE
    from openc3.utilities.running_script import RunningScript

    try:
        require(os.environ.get("SCENARIO_CONTRACT_VERSION") == "1", "contract_mismatch")
        running = RunningScript.instance
        require(running is not None, "script_runner_required")
        RunningScript.pause_on_error = False
        running.continue_after_error = False
        adapter = OpenC3Adapter(openc3.script.API_SERVER, OPENC3_SCOPE, openc3.script.DISCONNECT)
        management = ManagementClient(
            os.environ.get("SCENARIO_API_URL", ""), os.environ.get("SCENARIO_RUN_ID", ""),
            OPENC3_SCOPE, running.script_status.name, openc3.script.API_SERVER.json_drb.authentication,
        )
        return ScenarioRunner(adapter, management, load_catalog(), os.environ.get("SCENARIO_DEFINITION_HASH", "")).run()
    except Exception as error:
        code = str(error) if isinstance(error, ScenarioError) else "bootstrap_error"
        raise ScenarioError(code) from None
