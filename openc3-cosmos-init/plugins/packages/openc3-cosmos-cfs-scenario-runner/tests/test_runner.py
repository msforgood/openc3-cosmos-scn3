import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import cfs_scenario_runner as runner


class Clock:
    def __init__(self):
        self.now = 1000.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        if seconds < 0:
            raise ValueError("negative sleep")
        self.sleeps.append(seconds)
        self.now += seconds


def command_definition(packet):
    items = [{"name": k, "default": v} for k, v in runner.HEADER_DEFAULTS.items()]
    items.append({"name": "CCSDS_STREAMID", "default": runner.COMMANDS[packet][1], "id_value": runner.COMMANDS[packet][1]})
    items.extend({"name": key} for key in runner.RESERVED_ITEMS)
    return {"target_name": "CFS-1_QEMU", "packet_name": packet, "items": items}


def telemetry_definition(packet):
    items = [{"name": k, "data_type": "UINT", "bit_size": 8} for k in runner.ITEMS]
    items.extend({"name": k, "data_type": "DERIVED", "bit_size": 0} for k in runner.RECEIPT_ITEMS)
    return {"target_name": "CFS-1_QEMU", "packet_name": packet, "items": items}


class Adapter:
    def __init__(self, clock):
        self.clock = clock
        self.events = []
        self.sent = []
        self.installed = ["CFS-1_BBB", "CFS-1_QEMU", "SCENARIO_RUNNER"]
        self.command_error = None
        self.command_edit = lambda d: d
        self.telemetry_edit = lambda d: d
        self.sample_mode = "fresh"

    def targets(self):
        self.events.append("targets")
        return self.installed

    def command_definition(self, target, packet):
        self.events.append("command_definition")
        return self.command_edit(command_definition(packet))

    def telemetry_definition(self, target, packet):
        self.events.append("telemetry_definition")
        return self.telemetry_edit(telemetry_definition(packet))

    def command(self, target, packet, parameters, timeout):
        self.events.append("command")
        self.sent.append((target, packet, parameters, timeout, self.clock.now))
        if self.command_error:
            raise self.command_error
        self.clock.now += 0.1
        return {"target_name": target, "cmd_name": packet}

    def sample(self, target, packet, item):
        self.events.append("sample")
        if not self.sent:
            return runner.Sample(0, 10, 990)
        if self.sample_mode == "stale":
            return runner.Sample(0, 10, 990)
        if self.sample_mode == "same-count":
            return runner.Sample(0, 10, self.clock.now)
        if self.sample_mode == "same-time":
            return runner.Sample(0, 11, 990)
        if self.sample_mode == "reset-count":
            return runner.Sample(0, 1, self.clock.now)
        if self.sample_mode == "old-after-baseline":
            return runner.Sample(0, 11, 999)
        if self.sample_mode == "future":
            return runner.Sample(0, 11, self.clock.now + 20)
        if self.sample_mode == "flagged-stale":
            return runner.Sample(0, 11, self.clock.now, True)
        if self.sample_mode == "null":
            return runner.Sample(None, 11, self.clock.now)
        if self.sample_mode == "wrong-value":
            return runner.Sample(-1, 11, self.clock.now)
        return runner.Sample(0, 11 + len(self.sent), self.clock.now)


class Management:
    run_id = "test_run"
    scope = "DEFAULT"

    def __init__(self, definition, clock):
        self.clock = clock
        self.events = []
        self.fail_on = None
        self.ctx = {
            "run_id": self.run_id, "scope": self.scope, "target": "CFS-1_QEMU",
            "definition": copy.deepcopy(definition), "definition_hash": runner.canonical_hash(definition),
            "stop_requested": False, "prompt": None,
            "deadline": datetime.fromtimestamp(clock.now + definition["timeoutSec"], timezone.utc).isoformat(),
        }

    def context(self):
        return copy.deepcopy(self.ctx)

    def emit(self, kind, data):
        self.events.append((kind, data))
        if self.fail_on and self.fail_on(kind, data):
            raise RuntimeError("Authorization: SECRET_DO_NOT_LOG")
        return self.context()


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.catalog = runner.load_catalog()
        self.definition = copy.deepcopy(self.catalog["qemu-es-housekeeping"])
        self.build()

    def build(self, definition=None):
        self.definition = definition or self.definition
        self.catalog[self.definition["id"]] = copy.deepcopy(self.definition)
        self.clock = Clock()
        self.adapter = Adapter(self.clock)
        self.management = Management(self.definition, self.clock)
        self.engine = runner.ScenarioRunner(self.adapter, self.management, self.catalog, runner.canonical_hash(self.definition), monotonic=self.clock.monotonic, wall_time=self.clock.monotonic, sleep=self.clock.sleep)

    def two_commands(self):
        first = copy.deepcopy(self.definition)
        second = copy.deepcopy(self.catalog["qemu-evs-housekeeping"])
        for step in second["steps"]:
            step["id"] = "evs-" + step["id"]
        first["steps"] += second["steps"]
        first["telemetryItems"] += second["telemetryItems"]
        first["timeoutSec"] = 60
        self.build(first)

    def assert_failure(self, code, no_sends=True):
        with self.assertRaisesRegex(runner.ScenarioError, code):
            self.engine.run()
        if no_sends:
            self.assertEqual(self.adapter.sent, [])

    def test_order_and_command_vs_telemetry(self):
        self.assertEqual(self.engine.run(), {"status": "succeeded"})
        self.assertEqual(self.adapter.events[:5], ["targets", "command_definition", "telemetry_definition", "sample", "command"])
        self.assertEqual(len(self.adapter.sent), 1)
        completed = [d for k, d in self.management.events if k == "step" and d["status"] == "succeeded"]
        self.assertTrue(completed[0]["commandAccepted"])
        self.assertFalse(completed[0]["telemetryConfirmed"])
        self.assertTrue(completed[1]["telemetryConfirmed"])

    def test_second_scenario_works_without_engine_changes(self):
        self.build(copy.deepcopy(self.catalog["qemu-evs-housekeeping"]))
        self.engine.run()
        self.assertEqual(self.adapter.sent[0][1], "CFE_EVS_SEND_HK_CMD")
        self.assertTrue(self.clock.sleeps)

    def test_command_error_prevents_later_commands_and_redacts(self):
        self.two_commands()
        self.adapter.command_error = RuntimeError("Authorization: SECRET_DO_NOT_LOG")
        self.assert_failure("command_error", no_sends=False)
        self.assertEqual(len(self.adapter.sent), 1)
        self.assertNotIn("SECRET", json.dumps(self.management.events))

    def test_command_timeout_prevents_later_commands(self):
        self.two_commands()
        original = self.adapter.command
        release = threading.Event()

        def stalled(*args):
            original(*args)
            release.wait(1)

        self.adapter.command = stalled
        self.engine.call = lambda f, t, label: runner.bounded_call(f, 0.02 if label == "command" else t, label)
        try:
            self.assert_failure("command_timeout", no_sends=False)
            self.assertEqual(len(self.adapter.sent), 1)
        finally:
            release.set()

    def test_all_stale_or_invalid_samples_fail_with_bounded_wait(self):
        for mode in ("stale", "same-count", "same-time", "reset-count", "old-after-baseline", "future", "flagged-stale", "null", "wrong-value"):
            with self.subTest(mode=mode):
                self.build()
                self.adapter.sample_mode = mode
                self.assert_failure("telemetry_timeout", no_sends=False)
                self.assertLessEqual(self.clock.now, 1011)
                self.assertLessEqual(self.adapter.events.count("sample"), 22)

    def test_telemetry_timeout_blocks_later_send(self):
        self.two_commands()
        self.adapter.sample_mode = "stale"
        self.assert_failure("telemetry_timeout", no_sends=False)
        self.assertEqual(len(self.adapter.sent), 1)

    def test_unchanged_counter_value_can_confirm_fresh_hk(self):
        # HK requests need not increment COMMAND_COUNTER; receipt metadata proves freshness.
        self.engine.run()
        self.assertEqual(self.management.events[-2][1]["value"], 0)

    def test_snapshot_content_mismatch(self):
        self.management.ctx["definition"]["name"] += " changed"
        self.assert_failure("definition_mismatch")

    def test_local_content_mismatch(self):
        self.catalog[self.definition["id"]]["name"] += " changed"
        self.assert_failure("definition_mismatch")

    def test_version_mismatch(self):
        self.management.ctx["definition"]["version"] = "2.0.0"
        self.assert_failure("definition_mismatch")

    def test_hash_mismatch(self):
        self.engine.expected_hash = "0" * 64
        self.assert_failure("definition_mismatch")

    def test_unknown_scenario(self):
        self.management.ctx["definition"]["id"] = "unknown"
        self.assert_failure("definition_mismatch")

    def test_bbb_target_refused(self):
        self.management.ctx["target"] = "CFS-1_BBB"
        self.assert_failure("invalid_target")

    def test_uninstalled_target_refused(self):
        self.adapter.installed = ["CFS-1_BBB"]
        self.assert_failure("target_not_installed")

    def test_command_definition_mutation_refused(self):
        def mutate(d):
            d["items"][0]["default"] = 1
            return d
        self.adapter.command_edit = mutate
        self.assert_failure("command_definition_mismatch")

    def test_added_command_payload_refused(self):
        def mutate(d):
            d["items"].append({"name": "ADDRESS", "default": 0})
            return d
        self.adapter.command_edit = mutate
        self.assert_failure("command_definition_mismatch")

    def test_hazardous_command_refused(self):
        self.adapter.command_edit = lambda d: dict(d, hazardous=True)
        self.assert_failure("invalid_command")

    def test_missing_telemetry_item_refused(self):
        self.adapter.telemetry_edit = lambda d: dict(d, items=[])
        self.assert_failure("invalid_telemetry_item")

    def test_wrong_telemetry_width_refused(self):
        def mutate(d):
            for item in d["items"]:
                item["bit_size"] = 16
            return d
        self.adapter.telemetry_edit = mutate
        self.assert_failure("telemetry_definition_mismatch")

    def test_initial_callback_error_blocks_first_command(self):
        self.management.fail_on = lambda kind, data: kind == "started"
        self.assert_failure("callback_error")

    def test_callback_error_after_command_blocks_next_send(self):
        self.two_commands()
        self.management.fail_on = lambda kind, data: bool(data.get("commandAccepted"))
        self.assert_failure("callback_error", no_sends=False)
        self.assertEqual(len(self.adapter.sent), 1)

    def test_context_cancel_blocks_first_command(self):
        self.management.ctx["stop_requested"] = True
        self.assert_failure("stop_requested")

    def test_callback_cancel_blocks_first_command(self):
        original = self.management.emit
        def cancel(kind, data):
            result = original(kind, data)
            result["stop_requested"] = True
            return result
        self.management.emit = cancel
        self.assert_failure("stop_requested")

    def test_native_prompt_context_is_refused(self):
        self.management.ctx["prompt"] = {"message": "continue?"}
        self.assert_failure("unsupported_prompt")

    def test_deadline_expired_blocks_command(self):
        self.management.ctx["deadline"] = "1970-01-01T00:00:00Z"
        self.assert_failure("deadline_exceeded")

    def test_minimum_command_spacing(self):
        self.two_commands()
        self.engine.run()
        self.assertGreaterEqual(self.adapter.sent[1][-1] - self.adapter.sent[0][-1], 1)

    def test_result_callback_failure_never_success(self):
        self.management.fail_on = lambda kind, data: kind == "result"
        self.assert_failure("callback_error", no_sends=False)


class ValidationTests(unittest.TestCase):
    def test_strict_invalid_definitions(self):
        original = runner.load_catalog()["qemu-es-housekeeping"]
        variants = []
        for path, value in [("timeoutSec", 1000), ("timeoutSec", True), ("timeoutSec", float("nan")), ("supportedTargets", ["CFS-1_BBB"]), ("schemaVersion", True), ("shell", "whoami")]:
            d = copy.deepcopy(original)
            d[path] = value
            variants.append(d)
        for key, value in [("packet", "CFE_ES_CMD_RESET_COUNTERS"), ("parameters", {"CCSDS_STREAMID": 123}), ("timeoutSec", 99)]:
            d = copy.deepcopy(original)
            d["steps"][0][key] = value
            variants.append(d)
        for key, value in [("item", "DOES_NOT_EXIST"), ("operator", "eval"), ("pollIntervalSec", 0), ("timeoutSec", 1000), ("value", "__import__('os')")]:
            d = copy.deepcopy(original)
            d["steps"][1][key] = value
            variants.append(d)
        for d in variants:
            with self.subTest(definition=d), self.assertRaises(runner.ScenarioError):
                runner.validate_definition(d)

    def test_command_must_have_corresponding_wait(self):
        d = runner.load_catalog()["qemu-es-housekeeping"]
        d["steps"][1]["packet"] = "CFE_EVS_HK"
        with self.assertRaises(runner.ScenarioError):
            runner.validate_definition(d)

    def test_canonical_hash_ignores_key_order(self):
        d = runner.load_catalog()["qemu-es-housekeeping"]
        self.assertEqual(runner.canonical_hash(d), runner.canonical_hash(dict(reversed(list(d.items())))))

    def test_catalog_agrees_with_bundled_cfs_definition_snapshot(self):
        # Versioned reference definitions make this check work in a standalone
        # scn3 checkout. Runtime checks still use the actual installed Target.
        definitions = ROOT / "tests/fixtures/cfs-definitions"
        for prefix in ("es", "evs"):
            self.assertIn(f"CFE_{prefix.upper()}_SEND_HK_CMD", (definitions / f"cfe_{prefix}_cmd_def.txt").read_text())
            text = (definitions / f"cfe_{prefix}_tlm_def.txt").read_text()
            self.assertIn(f"CFE_{prefix.upper()}_HK", text)
            self.assertIn("APPEND_ITEM COMMAND_COUNTER 8 UINT", text)


class AdapterTests(unittest.TestCase):
    def test_checked_rpc_is_used_and_receipt_sample_is_one_uncached_call(self):
        calls = []
        class Api:
            json_drb = types.SimpleNamespace(timeout=99)
            def cmd(self, *args, **kwargs):
                calls.append(("cmd", args, kwargs))
                return {}
            def get_tlm_values(self, *args, **kwargs):
                calls.append(("get_tlm_values", args, kwargs))
                return [[0, None], [11, None], [1000.0, None]]
        a = runner.OpenC3Adapter(Api(), "DEFAULT")
        a.command("CFS-1_QEMU", "CFE_ES_SEND_HK_CMD", {}, 2)
        sample = a.sample("CFS-1_QEMU", "CFE_ES_HK", "COMMAND_COUNTER")
        self.assertEqual(sample, runner.Sample(0, 11, 1000))
        self.assertEqual(calls[0][0], "cmd")
        self.assertEqual(calls[1][2]["cache_timeout"], 0)
        self.assertEqual(len(calls[1][1][0]), 3)

    def test_disconnected_mode_is_never_success(self):
        with self.assertRaisesRegex(runner.ScenarioError, "disconnected_mode"):
            runner.OpenC3Adapter(None, "DEFAULT", True)

    def test_management_reuses_auth_without_putting_it_in_body(self):
        calls = []
        class Response:
            status_code = 200
            def iter_content(self, size):
                yield b'{"stop_requested":false}'
            def close(self):
                pass
        class Session:
            def request(self, *args, **kwargs):
                calls.append((args, kwargs))
                return Response()
        auth = types.SimpleNamespace(token=lambda: "private-test-token")
        client = runner.ManagementClient("http://scenario-api:2910/scenario-api", "run1", "DEFAULT", 1, auth, Session())
        client.emit("started", {"message": "safe"})
        kwargs = calls[0][1]
        self.assertEqual(kwargs["headers"]["Authorization"], "private-test-token")
        self.assertEqual(kwargs["json"]["script_id"], "1")
        self.assertNotIn("private-test-token", json.dumps(kwargs["json"]))
        self.assertFalse(kwargs["allow_redirects"])

    def test_credential_forwarding_to_unknown_origin_refused(self):
        for url in ("http://example.com:2910/scenario-api", "http://scenario-api:2910/scenario-api?token=x", "http://user:pass@scenario-api:2910/scenario-api", "http://scenario-api:2910/other"):
            with self.subTest(url=url), self.assertRaises(runner.ScenarioError):
                runner.ManagementClient(url, "run", "DEFAULT", 1, None)

    def test_bounded_call_timeout_and_error_are_sanitized(self):
        started = time.monotonic()
        release = threading.Event()
        try:
            with self.assertRaisesRegex(runner.ScenarioError, "callback_timeout"):
                runner.bounded_call(lambda: release.wait(1), 0.02, "callback")
            self.assertLess(time.monotonic() - started, 0.5)
        finally:
            release.set()
        with self.assertRaisesRegex(runner.ScenarioError, "command_error"):
            runner.bounded_call(lambda: (_ for _ in ()).throw(ValueError("SECRET")), 1, "command")

    def test_entrypoint_disables_pause_and_continue_before_runtime(self):
        running = types.SimpleNamespace(pause_on_error=True, instance=types.SimpleNamespace(continue_after_error=True))
        module = types.ModuleType("openc3.utilities.running_script")
        module.RunningScript = running
        seen = []
        def invoke():
            seen.append((running.pause_on_error, running.instance.continue_after_error))
            raise runner.ScenarioError("command_error")
        with patch.dict(sys.modules, {"openc3.utilities.running_script": module}), patch.object(runner, "run_from_environment", invoke):
            with self.assertRaisesRegex(runner.ScenarioError, "command_error"):
                exec(compile((ROOT / "targets/SCENARIO_RUNNER/procedures/run_scenario.py").read_text(), "run_scenario.py", "exec"), {})
        self.assertEqual(seen, [(False, False)])


if __name__ == "__main__":
    unittest.main()
