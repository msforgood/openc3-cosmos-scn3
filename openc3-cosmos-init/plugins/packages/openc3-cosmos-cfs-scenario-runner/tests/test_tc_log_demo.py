"""The fixed TC log demonstration checks the same file before and after capture."""

from datetime import datetime, timezone
import copy
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
    run_id = "tc_log_demo"
    scope = "DEFAULT"

    def __init__(self, definition, clock):
        self.events = []
        self.context_data = {
            "run_id": self.run_id, "scope": self.scope,
            "target": definition["supportedTargets"][0], "definition": copy.deepcopy(definition),
            "definition_hash": runner.canonical_hash(definition), "stop_requested": False,
            "prompt": None, "deadline": datetime.fromtimestamp(clock.now + 120, timezone.utc).isoformat(),
        }

    def context(self):
        return copy.deepcopy(self.context_data)

    def emit(self, kind, data):
        self.events.append((kind, data))
        return self.context()


class Adapter:
    def __init__(self, clock, *, replacement=True, stale=False):
        self.clock, self.replacement, self.stale = clock, replacement, stale
        self.sent = []
        self.packet_samples = {}
        self.active_index, self.last_closed, self.total_logged, self.active_records = 1, 0, 0, 0
        self.target_log = (b"TCLOG v1\n" + b"seq=00000001 mid=0x1884 fc=3 raw=AABB\n" +
                           b"seq=00000002 mid=0x18E2 fc=2 raw=CCDD\n")
        self.photo = bytes.fromhex("89504e470d0a1a0a") + b"P" * 728

    def targets(self):
        return ["CFS-1_QEMU", "CFS-1_BBB"]

    def command_definition(self, target, packet):
        fc_fields = {
            "CI_LOG_STATUS_CMD": (2, {"REQUEST_ID": ("UINT", 16), "RESERVED": ("UINT", 16)}),
            "CI_LOG_SEAL_CMD": (3, {"REQUEST_ID": ("UINT", 16), "RESERVED": ("UINT", 16)}),
            "CI_LOG_READ_CMD": (4, {"REQUEST_ID": ("UINT", 16), "FILE_INDEX": ("UINT", 16), "OFFSET": ("UINT", 32)}),
            "TC_CAMERA_CAPTURE_CMD": (2, {"REQUEST_ID": ("UINT", 16), "FILENAME": ("STRING", 256)}),
            "CFE_ES_SEND_HK_CMD": (0, {}),
        }
        fc, fields = fc_fields[packet]
        header = dict(runner.HEADER_DEFAULTS, CCSDS_STREAMID=runner.COMMANDS[packet][1], CCSDS_FC=fc)
        items = [{"name": name, "default": value, "id_value": value} for name, value in header.items()]
        items += [{"name": name, "data_type": kind, "bit_size": size} for name, (kind, size) in fields.items()]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RESERVED_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def telemetry_definition(self, target, packet):
        fields = {
            "CI_LOG_STATUS": {"REQUEST_ID": 16, "RESULT": 16, "ACTIVE_INDEX": 16,
                              "LAST_CLOSED_INDEX": 16, "ACTIVE_RECORDS": 32, "TOTAL_LOGGED": 32,
                              "WRITE_ERRORS": 32, "READ_ERRORS": 32},
            "CI_LOG_CHUNK": {"REQUEST_ID": 16, "RESULT": 16, "FILE_INDEX": 16,
                             "DATA_LENGTH": 16, "OFFSET": 32, "FILE_SIZE": 32, "DATA": 8},
            "TC_CAMERA_RESULT": {"REQUEST_ID": 16, "STATUS": 16, "BYTES_WRITTEN": 32, "FILENAME": 256},
        }[packet]
        items = [{"name": name, "data_type": "STRING" if name == "FILENAME" else "UINT", "bit_size": size}
                 for name, size in fields.items()]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def sample_fields(self, target, packet, fields):
        sample = self.packet_samples.get(packet)
        if sample is None:
            return runner.PacketSample({name: None for name in fields}, 0, 0)
        return runner.PacketSample({name: sample.values.get(name) for name in fields},
                                   sample.count, sample.received, sample.stale)

    def command(self, target, packet, parameters, timeout):
        self.sent.append((packet, parameters))
        self.clock.now += 0.1
        self.total_logged += 1
        self.active_records += 1
        request_id = parameters.get("REQUEST_ID", 0)
        values = {}
        response = None
        if packet == "CI_LOG_SEAL_CMD":
            self.last_closed = self.active_index
            self.active_index += 1
            self.active_records = 0
            response = "CI_LOG_STATUS"
        elif packet == "CI_LOG_STATUS_CMD":
            response = "CI_LOG_STATUS"
        if response:
            values = {"REQUEST_ID": request_id, "RESULT": 0, "ACTIVE_INDEX": self.active_index,
                      "LAST_CLOSED_INDEX": self.last_closed, "ACTIVE_RECORDS": self.active_records,
                      "TOTAL_LOGGED": self.total_logged, "WRITE_ERRORS": 0, "READ_ERRORS": 0}
        elif packet == "TC_CAMERA_CAPTURE_CMD":
            response = "TC_CAMERA_RESULT"
            filename = parameters["FILENAME"]
            if filename.startswith("../log/") and self.replacement:
                self.target_log = self.photo
            values = {"REQUEST_ID": request_id, "STATUS": 0, "BYTES_WRITTEN": len(self.photo), "FILENAME": filename}
        elif packet == "CI_LOG_READ_CMD":
            response = "CI_LOG_CHUNK"
            chunk = self.target_log[:256]
            values = {"REQUEST_ID": request_id, "RESULT": 0, "FILE_INDEX": parameters["FILE_INDEX"],
                      "DATA_LENGTH": len(chunk), "OFFSET": 0, "FILE_SIZE": len(self.target_log),
                      "DATA": list(chunk.ljust(256, b"\x00"))}
        if response:
            previous = self.packet_samples.get(response)
            count = (previous.count if previous else 0) + (0 if self.stale else 1)
            self.packet_samples[response] = runner.PacketSample(values, count, self.clock.now)
        return {"target_name": target, "cmd_name": packet}


class TcLogDemoTests(unittest.TestCase):
    def build(self, target="CFS-1_QEMU", **adapter_options):
        catalog = runner.load_catalog()
        scenario_id = runner.TCLOG["scenarioIds"][target]
        definition = catalog[scenario_id]
        clock = Clock()
        adapter = Adapter(clock, **adapter_options)
        management = Management(definition, clock)
        engine = runner.ScenarioRunner(adapter, management, catalog, runner.canonical_hash(definition),
                                       monotonic=lambda: clock.now, wall_time=lambda: clock.now,
                                       sleep=clock.sleep, call=lambda fn, _seconds, _label: fn())
        return engine, adapter, management

    def test_both_targets_show_same_file_replaced_and_logging_continues(self):
        for target in ("CFS-1_QEMU", "CFS-1_BBB"):
            with self.subTest(target=target):
                engine, adapter, management = self.build(target)
                self.assertEqual(engine.run(), {"status": "succeeded"})
                steps = {data["step_id"]: data for kind, data in management.events if kind == "step" and data["status"] == "succeeded"}
                self.assertEqual(steps["read-before"]["file_index"], steps["read-after"]["file_index"])
                self.assertTrue(steps["read-before"]["before_text"].startswith("TCLOG v1"))
                self.assertTrue(steps["read-after"]["after_hex"].startswith("89504e470d0a1a0a"))
                self.assertEqual(steps["overwrite-log"]["filename"], "../log/tc0002.log")
                self.assertGreater(steps["confirm-continuity"]["active_index"], 2)
                self.assertEqual(adapter.sent[0][0], "CI_LOG_SEAL_CMD")

    def test_camera_success_without_file_change_does_not_claim_success(self):
        engine, adapter, _management = self.build(replacement=False)
        with self.assertRaisesRegex(runner.ScenarioError, "log_overwrite_unconfirmed"):
            engine.run()
        self.assertEqual(adapter.sent[-1][0], "CI_LOG_READ_CMD")

    def test_stale_result_stops_before_normal_activity(self):
        engine, adapter, _management = self.build(stale=True)
        with self.assertRaisesRegex(runner.ScenarioError, "tc_telemetry_timeout"):
            engine.run()
        self.assertEqual([packet for packet, _ in adapter.sent], ["CI_LOG_SEAL_CMD"])


if __name__ == "__main__":
    unittest.main()
