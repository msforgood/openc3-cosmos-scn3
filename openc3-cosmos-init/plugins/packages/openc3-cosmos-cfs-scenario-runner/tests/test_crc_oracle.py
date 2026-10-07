import copy
from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cfs_scenario_runner as runner


KEY = bytes.fromhex("2c9a017e54e3b860114dfa820c9735d6")


class Clock:
    def __init__(self):
        self.now = 1000.0

    def tick(self, seconds):
        self.now += seconds


class Adapter:
    def __init__(self, clock, *, stale=False):
        self.clock = clock
        self.stale = stale
        self.sent = []

    def targets(self):
        return ["CFS-1_QEMU"]

    def command_definition(self, target, packet):
        assert packet == runner.ORACLE["command"]
        fields = [{"name": name, "default": value} for name, value in runner.HEADER_DEFAULTS.items()]
        fields += [{"name": "CCSDS_STREAMID", "default": runner.ORACLE["streamId"], "id_value": runner.ORACLE["streamId"]}]
        fields += [{"name": name, "data_type": "UINT", "bit_size": 32} for name in ("ADDRESS", "SIZE", "MAX_BYTES_PER_CYCLE")]
        fields += [{"name": name, "data_type": "DERIVED"} for name in runner.RESERVED_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": fields}

    def telemetry_definition(self, target, packet):
        items = [{"name": name, "data_type": "UINT", "bit_size": width}
                 for pair, width in runner.TELEMETRY_TYPES.items()
                 for name in [pair.split(".", 1)[1]] if pair.startswith(packet + ".")]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def command(self, target, packet, parameters, timeout):
        self.sent.append(copy.deepcopy(parameters))
        self.clock.tick(0.1)
        return {"target_name": target, "cmd_name": packet}

    def sample_fields(self, target, packet, fields):
        if packet == "XKEY_HK":
            values = {"KEY_ADDRESS": 0x100000, "KEY_LENGTH": 16, "CHANNEL_READY": 1}
            return runner.PacketSample(values, 1, self.clock.now)
        index = len(self.sent) - 1
        if index < 0:
            values = {"LAST_ONE_SHOT_ADDRESS": 0, "LAST_ONE_SHOT_SIZE": 0,
                      "LAST_ONE_SHOT_CHECKSUM": 0, "ONE_SHOT_IN_PROGRESS": 0}
        else:
            values = {"LAST_ONE_SHOT_ADDRESS": 0x100000 + index, "LAST_ONE_SHOT_SIZE": 1,
                      "LAST_ONE_SHOT_CHECKSUM": runner.cfe_crc16(KEY[index:index + 1]), "ONE_SHOT_IN_PROGRESS": 0}
        return runner.PacketSample(values, 10 + len(self.sent), self.clock.now, self.stale)


class Management:
    run_id = "test_run"
    scope = "DEFAULT"

    def __init__(self, definition, clock):
        self.events = []
        self.context_data = {
            "run_id": self.run_id, "scope": self.scope, "target": "CFS-1_QEMU",
            "definition": definition, "definition_hash": runner.canonical_hash(definition),
            "stop_requested": False, "prompt": None,
            "deadline": datetime.fromtimestamp(clock.now + 120, timezone.utc).isoformat(),
        }

    def context(self):
        return self.context_data

    def emit(self, kind, data):
        self.events.append((kind, data))
        return self.context()


class OracleTests(unittest.TestCase):
    def setUp(self):
        self.catalog = runner.load_catalog()
        self.definition = self.catalog["qemu-cs-crc-key-oracle"]
        self.clock = Clock()

    def engine(self, stale=False):
        adapter = Adapter(self.clock, stale=stale)
        management = Management(self.definition, self.clock)
        engine = runner.ScenarioRunner(adapter, management, self.catalog,
                                       runner.canonical_hash(self.definition),
                                       monotonic=lambda: self.clock.now,
                                       wall_time=lambda: self.clock.now,
                                       sleep=self.clock.tick)
        return engine, adapter, management

    def test_16_one_byte_commands_recover_key(self):
        engine, adapter, management = self.engine()
        self.assertEqual(engine.run()["status"], "succeeded")
        self.assertEqual(len(adapter.sent), 16)
        self.assertEqual([command["ADDRESS"] for command in adapter.sent],
                         list(range(0x100000, 0x100010)))
        self.assertTrue(all(command["SIZE"] == command["MAX_BYTES_PER_CYCLE"] == 1
                            for command in adapter.sent))
        self.assertEqual(management.events[-1][1]["message"],
                         "Recovered X-band lab key: " + KEY.hex())

    def test_stale_checksum_stops_before_second_probe(self):
        engine, adapter, _ = self.engine(stale=True)
        with self.assertRaisesRegex(runner.ScenarioError, "crc_telemetry_timeout"):
            engine.run()
        self.assertEqual(len(adapter.sent), 1)

    def test_single_byte_crc_is_injective(self):
        self.assertEqual(len(runner.CRC_BYTE_LOOKUP), 256)
        self.assertEqual(runner.CRC_BYTE_LOOKUP[0xC0C1], 1)


if __name__ == "__main__":
    unittest.main()
