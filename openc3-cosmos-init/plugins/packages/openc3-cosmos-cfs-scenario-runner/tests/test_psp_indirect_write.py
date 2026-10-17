"""Scenario 3 edits one permitted pointer and proves the original cFS process SIGSEGV."""

import copy
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cfs_scenario_runner as runner


class Clock:
    def __init__(self):
        self.now = 1000.0

    def sleep(self, seconds):
        self.now += seconds


class Management:
    run_id = "psp_indirect_write"
    scope = "DEFAULT"

    def __init__(self, definition, clock, target="CFS-1_QEMU"):
        self.events = []
        self.data = {
            "run_id": self.run_id, "scope": self.scope,
            "target": target, "definition": copy.deepcopy(definition),
            "definition_hash": runner.canonical_hash(definition), "stop_requested": False,
            "execution_mode": "automatic", "prompt": None,
            "deadline": datetime.fromtimestamp(clock.now + 120, timezone.utc).isoformat(),
        }

    def context(self):
        return copy.deepcopy(self.data)

    def emit(self, kind, data):
        self.events.append((kind, data))
        return self.context()


class Observer:
    INSTANCE = "boot-a:123:456"

    def __init__(self, target, clock, *, signal=11, exit_after_resume=True, exit_instance=None,
                 initially_running=True, failure=False):
        self.target, self.clock = target, clock
        self.signal = signal
        self.exit_after_resume = exit_after_resume
        self.exit_instance = exit_instance or self.INSTANCE
        self.running = initially_running
        self.last_exit = None
        self.failure = failure
        self.reads = 0

    def crash(self):
        if self.exit_after_resume:
            self.running = False
            self.last_exit = {
                "instance_id": self.exit_instance,
                "signal": self.signal,
                "signal_name": "SIGSEGV" if self.signal == 11 else "SIGABRT",
                "observed_at": datetime.fromtimestamp(self.clock.now, timezone.utc).isoformat(),
            }

    def status(self, target):
        self.reads += 1
        if self.failure:
            raise RuntimeError("observer down")
        return {"target": self.target, "running": self.running,
                "instance_id": self.INSTANCE if self.running else None,
                "pid": 123 if self.running else None,
                "last_exit": copy.deepcopy(self.last_exit)}


class Adapter:
    BUFFER = 0x120000
    CODE = 0x200100
    SLOT = 0x300080

    def __init__(self, clock, observer, *, direct_denied=True, code_address=CODE,
                 reserved_word=0, drop_debug_once_for=(), wrong_operation_once_for=()):
        self.clock = clock
        self.observer = observer
        self.direct_denied = direct_denied
        self.code_address = code_address
        self.reserved_word = reserved_word
        self.sent = []
        self.samples = {}
        self.pointer = self.BUFFER
        self.sample_count = 10
        self.state = 1
        self.action = 1
        self.resumed_without_tm = False
        self.drop_debug_once_for = set(drop_debug_once_for)
        self.wrong_operation_once_for = set(wrong_operation_once_for)

    def targets(self):
        return ["CFS-1_QEMU", "CFS-1_BBB"]

    def command_definition(self, target, packet):
        fields = {
            "MM_CMD_DEBUG_MAP": (13, {"REQUEST_ID": 32}),
            "MM_CMD_DEBUG_READ": (14, {"REQUEST_ID": 32, "WIDTH_BYTES": 32, "ADDRESS": 64}),
            "MM_CMD_DEBUG_WRITE": (15, {"REQUEST_ID": 32, "WIDTH_BYTES": 32, "ADDRESS": 64,
                                         "VALUE": 32, "RESERVED": 32}),
            "PAYLOAD_DATA_PAUSE_CMD": (2, {}),
            "PAYLOAD_DATA_RESUME_CMD": (3, {}),
            "PAYLOAD_DATA_STATUS_CMD": (4, {}),
        }
        fc, payload = fields[packet]
        header = dict(runner.HEADER_DEFAULTS, CCSDS_STREAMID=runner.COMMANDS[packet][1], CCSDS_FC=fc)
        items = [{"name": name, "default": value, "id_value": value} for name, value in header.items()]
        items += [{"name": name, "data_type": "UINT", "bit_size": size} for name, size in payload.items()]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RESERVED_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def telemetry_definition(self, target, packet):
        fields = {
            "MM_DEBUG": {"REQUEST_ID": 32, "OPERATION": 32, "STATUS": 32, "WIDTH_BYTES": 32,
                         "MODULE_START": 64, "MODULE_END": 64, "POINTER_SLOT": 64,
                         "ADDRESS": 64, "VALUE": 64},
            "PAYLOAD_DATA_STATE": {"STATE": 8, "LAST_SAMPLE": 8, "RESERVED": 16,
                                   "SAMPLE_COUNT": 32, "POINTER_SLOT": 32,
                                   "WRITE_TARGET_ADDRESS": 32, "BUFFER_ADDRESS": 32,
                                   "RESERVED_WORD": 32, "LAST_ACTION": 32, "LAST_ERROR": 32},
        }[packet]
        items = [{"name": name, "data_type": "UINT", "bit_size": size}
                 for name, size in fields.items()]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def sample_fields(self, target, packet, fields):
        sample = self.samples.get(packet)
        if sample is None:
            return runner.PacketSample({name: None for name in fields}, 0, 0)
        return runner.PacketSample({name: sample.values.get(name) for name in fields},
                                   sample.count, sample.received, sample.stale)

    def _publish(self, packet, values):
        previous = self.samples.get(packet)
        self.samples[packet] = runner.PacketSample(
            values, (previous.count if previous else 0) + 1, self.clock.now)

    def command(self, target, packet, parameters, timeout):
        self.sent.append((packet, parameters))
        self.clock.now += 0.1
        if packet == "PAYLOAD_DATA_PAUSE_CMD":
            self.state, self.action = 2, 2
        elif packet == "PAYLOAD_DATA_RESUME_CMD":
            self.resumed_without_tm = True
            self.observer.crash()
            return {"target_name": target, "cmd_name": packet}
        if packet.startswith("PAYLOAD_DATA_"):
            self._publish("PAYLOAD_DATA_STATE", self._data_values())
        elif packet.startswith("MM_CMD_DEBUG_"):
            status, value = 0, 0
            if packet == "MM_CMD_DEBUG_READ":
                value = self.pointer
            elif packet == "MM_CMD_DEBUG_WRITE":
                if parameters["ADDRESS"] == self.BUFFER:
                    status = 3 if self.direct_denied else 0
                elif parameters["ADDRESS"] == self.SLOT:
                    self.pointer = parameters["VALUE"]
                value = parameters["VALUE"]
            operation = {"MM_CMD_DEBUG_MAP": 13, "MM_CMD_DEBUG_READ": 14,
                         "MM_CMD_DEBUG_WRITE": 15}[packet]
            debug_key = (packet, parameters.get("ADDRESS"))
            if debug_key in self.drop_debug_once_for:
                self.drop_debug_once_for.remove(debug_key)
                return {"target_name": target, "cmd_name": packet}
            if debug_key in self.wrong_operation_once_for:
                self.wrong_operation_once_for.remove(debug_key)
                operation = 99
            self._publish("MM_DEBUG", {"REQUEST_ID": parameters["REQUEST_ID"],
                                       "OPERATION": operation, "STATUS": status,
                                       "WIDTH_BYTES": parameters.get("WIDTH_BYTES", 4),
                                       "MODULE_START": 0x300000, "MODULE_END": 0x301000,
                                       "POINTER_SLOT": self.SLOT,
                                       "ADDRESS": self.code_address if packet == "MM_CMD_DEBUG_MAP"
                                                  else parameters.get("ADDRESS", 0),
                                       "VALUE": value})
        return {"target_name": target, "cmd_name": packet}

    def _data_values(self):
        return {"STATE": self.state, "LAST_SAMPLE": 0x5a, "RESERVED": 0,
                "SAMPLE_COUNT": self.sample_count, "POINTER_SLOT": self.SLOT,
                "WRITE_TARGET_ADDRESS": self.pointer, "BUFFER_ADDRESS": self.BUFFER,
                "RESERVED_WORD": self.reserved_word, "LAST_ACTION": self.action,
                "LAST_ERROR": 0}


class PspIndirectWriteTests(unittest.TestCase):
    def build(self, target="CFS-1_QEMU", **options):
        catalog = runner.load_catalog()
        definition = catalog[runner.PSP["scenarioId"]]
        clock = Clock()
        observer_options = {key: options.pop(key) for key in list(options)
                            if key in ("signal", "exit_after_resume", "exit_instance",
                                       "initially_running", "failure")}
        observer = Observer(target, clock, **observer_options)
        adapter = Adapter(clock, observer, **options)
        management = Management(definition, clock, target=target)
        engine = runner.ScenarioRunner(adapter, management, catalog, runner.canonical_hash(definition),
                                       observer=observer, monotonic=lambda: clock.now,
                                       wall_time=lambda: clock.now, sleep=clock.sleep,
                                       call=lambda fn, _seconds, _label: fn())
        return engine, adapter, observer, management

    def test_both_targets_deny_direct_write_then_write_full_pointer_and_confirm_signal(self):
        for target in ("CFS-1_QEMU", "CFS-1_BBB"):
            with self.subTest(target=target):
                engine, adapter, observer, management = self.build(target)
                self.assertEqual(engine.run(), {"status": "succeeded"})
                commands = [name for name, _args in adapter.sent]
                self.assertLess(commands.index("MM_CMD_DEBUG_MAP"),
                                commands.index("PAYLOAD_DATA_PAUSE_CMD"))
                writes = [args for name, args in adapter.sent if name == "MM_CMD_DEBUG_WRITE"]
                self.assertEqual([(x["WIDTH_BYTES"], x["ADDRESS"], x["VALUE"])
                                  for x in writes], [(1, Adapter.BUFFER, 0),
                                                     (4, Adapter.SLOT, Adapter.CODE)])
                self.assertEqual(adapter.pointer, Adapter.CODE)
                self.assertTrue(adapter.resumed_without_tm)
                self.assertGreater(observer.reads, 2)
                accepted = [data for kind, data in management.events if kind == "command" and
                            data["step_id"] == "write-pointer"]
                self.assertEqual(len(accepted), 1)
                self.assertEqual(accepted[0]["packet"], "MM_CMD_DEBUG_WRITE")
                self.assertEqual(json.loads(accepted[0]["parameters_json"])["VALUE"], Adapter.CODE)
                steps = {data["step_id"]: data for kind, data in management.events
                         if kind == "step" and data["status"] == "succeeded"}
                self.assertEqual(steps["map"]["code_address"], Adapter.CODE)
                self.assertFalse(steps["resume"]["telemetryConfirmed"])
                self.assertEqual(steps["confirm-sigsegv"]["exit_signal"], 11)
                self.assertEqual(steps["confirm-sigsegv"]["process_instance"], Observer.INSTANCE)

    def test_direct_write_not_denied_stops_before_pointer_edit(self):
        engine, adapter, _observer, _management = self.build(direct_denied=False)
        with self.assertRaisesRegex(runner.ScenarioError, "debug_status_0"):
            engine.run()
        denied_probe = [args for name, args in adapter.sent
                        if name == "MM_CMD_DEBUG_WRITE" and args["ADDRESS"] == Adapter.BUFFER]
        self.assertEqual(len(denied_probe), 1)
        self.assertFalse(any(name == "PAYLOAD_DATA_PAUSE_CMD" for name, _args in adapter.sent))
        self.assertEqual(adapter.pointer, Adapter.BUFFER)

    def test_lost_debug_tm_retries_with_new_request_ids(self):
        dropped = {("MM_CMD_DEBUG_READ", Adapter.SLOT),
                   ("MM_CMD_DEBUG_WRITE", Adapter.SLOT)}
        engine, adapter, _observer, management = self.build(drop_debug_once_for=dropped)
        self.assertEqual(engine.run(), {"status": "succeeded"})
        for packet in ("MM_CMD_DEBUG_READ", "MM_CMD_DEBUG_WRITE"):
            requests = [args["REQUEST_ID"] for name, args in adapter.sent
                        if name == packet and args.get("ADDRESS") == Adapter.SLOT]
            expected_count = 3 if packet == "MM_CMD_DEBUG_READ" else 2
            self.assertEqual(len(requests), expected_count)
            self.assertEqual(len(set(requests)), expected_count)
        self.assertEqual(adapter.pointer, Adapter.CODE)
        accepted = [data for kind, data in management.events if kind == "command" and
                    data["step_id"] == "write-pointer"]
        self.assertEqual(len(accepted), 2)
        self.assertNotEqual(json.loads(accepted[0]["parameters_json"])["REQUEST_ID"],
                            json.loads(accepted[1]["parameters_json"])["REQUEST_ID"])

    def test_wrong_debug_operation_fails_without_retry(self):
        engine, adapter, _observer, _management = self.build(
            wrong_operation_once_for={("MM_CMD_DEBUG_MAP", None)})
        with self.assertRaisesRegex(runner.ScenarioError, "invalid_debug_operation"):
            engine.run()
        self.assertEqual(sum(name == "MM_CMD_DEBUG_MAP" for name, _args in adapter.sent), 1)

    def test_invalid_code_address_blocks_pointer_edit(self):
        for code_address in (0, Adapter.SLOT, 0xffffff80):
            with self.subTest(code_address=code_address):
                engine, adapter, _observer, _management = self.build(code_address=code_address)
                with self.assertRaisesRegex(runner.ScenarioError,
                                            "invalid_debug_map|target_inside_debug_range"):
                    engine.run()
                self.assertFalse(any(name == "PAYLOAD_DATA_PAUSE_CMD" for name, _ in adapter.sent))
                self.assertEqual(adapter.pointer, Adapter.BUFFER)

    def test_old_guard_telemetry_fails_before_map(self):
        engine, adapter, _observer, _management = self.build(reserved_word=0x121000)
        with self.assertRaisesRegex(runner.ScenarioError, "invalid_payload_layout"):
            engine.run()
        self.assertFalse(any(name == "MM_CMD_DEBUG_MAP" for name, _ in adapter.sent))

    def test_wrong_signal_fails_closed(self):
        engine, _adapter, _observer, _management = self.build(signal=6)
        with self.assertRaisesRegex(runner.ScenarioError, "wrong_exit_signal"):
            engine.run()

    def test_unmatched_process_exit_fails_closed(self):
        engine, _adapter, _observer, _management = self.build(exit_instance="other-boot:123:456")
        with self.assertRaisesRegex(runner.ScenarioError, "sigsegv_unconfirmed"):
            engine.run()

    def test_no_process_exit_fails_closed(self):
        engine, _adapter, _observer, _management = self.build(exit_after_resume=False)
        with self.assertRaisesRegex(runner.ScenarioError, "sigsegv_unconfirmed"):
            engine.run()

    def test_observer_unavailable_blocks_before_any_tc(self):
        engine, adapter, observer, _management = self.build(failure=True)
        with self.assertRaisesRegex(runner.ScenarioError, "runtime_error"):
            engine.run()
        self.assertEqual(adapter.sent, [])
        self.assertEqual(observer.reads, 1)

    def test_observer_client_uses_only_fixed_private_status_route(self):
        class Response:
            status_code = 200

            def iter_content(self, _size):
                yield b'{"target":"CFS-1_QEMU","running":true,"instance_id":"a","pid":2,"last_exit":null}'

            def close(self):
                pass

        class Session:
            def __init__(self):
                self.calls = []

            def request(self, *args, **kwargs):
                self.calls.append((args, kwargs))
                return Response()

        with self.assertRaisesRegex(runner.ScenarioError, "invalid_observer_url"):
            runner.ObserverClient("http://public.example:2911")
        session = Session()
        client = runner.ObserverClient("http://scenario-observer:2911", "local-test-token", session)
        self.assertTrue(client.status("CFS-1_QEMU")["running"])
        self.assertEqual(session.calls[0][0],
                         ("GET", "http://scenario-observer:2911/v1/targets/CFS-1_QEMU/status"))
        self.assertEqual(session.calls[0][1]["headers"]["Authorization"], "Bearer local-test-token")
        with self.assertRaisesRegex(runner.ScenarioError, "unsupported_target"):
            client.status("other-host")


if __name__ == "__main__":
    unittest.main()
