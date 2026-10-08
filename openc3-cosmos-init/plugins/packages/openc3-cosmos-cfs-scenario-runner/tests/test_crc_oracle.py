import copy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cfs_scenario_runner as runner


KEY = bytes.fromhex("2c9a017e54e3b860114dfa820c9735d6")


class Clock:
    def __init__(self):
        self.now = 1000.0

    def tick(self, seconds):
        self.now += seconds


class Adapter:
    def __init__(self, clock, *, stale=False, old_receipt_once=False, reject_command=False):
        self.clock = clock
        self.stale = stale
        self.old_receipt_once = old_receipt_once
        self.reject_command = reject_command
        self.sent = []
        self.sent_targets = []
        self.polls_after_send = 0
        self.xband_reads = 0

    def targets(self):
        return ["CFS-1_QEMU", "CFS-1_BBB", "CFS-1_QEMU_XBAND", "CFS-1_BBB_XBAND"]

    def command_definition(self, target, packet):
        assert packet == runner.ORACLE["command"]
        defaults = dict(runner.HEADER_DEFAULTS, CCSDS_FC=runner.ORACLE["functionCode"])
        fields = [{"name": name, "default": value} for name, value in defaults.items()]
        fields += [{"name": "CCSDS_STREAMID", "default": runner.ORACLE["streamId"], "id_value": runner.ORACLE["streamId"]}]
        fields += [{"name": name, "data_type": "UINT", "bit_size": 32} for name in ("ADDRESS", "SIZE", "MAX_BYTES_PER_CYCLE")]
        fields += [{"name": name, "data_type": "DERIVED"} for name in runner.RESERVED_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": fields}

    def telemetry_definition(self, target, packet):
        if packet == runner.ORACLE["xbandPacket"]:
            assert target in runner.ORACLE["xbandTargets"].values()
        else:
            assert target in runner.ALLOWED_TARGETS
        items = [{"name": name, "data_type": "UINT", "bit_size": width}
                 for pair, width in runner.TELEMETRY_TYPES.items()
                 for name in [pair.split(".", 1)[1]] if pair.startswith(packet + ".")]
        if packet == runner.ORACLE["xbandPacket"]:
            next(item for item in items if item["name"] == "MAGIC")["id_value"] = runner.ORACLE["xbandMagic"]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def command(self, target, packet, parameters, timeout):
        self.sent.append(copy.deepcopy(parameters))
        self.sent_targets.append(target)
        self.polls_after_send = 0
        self.clock.tick(0.1)
        return {"target_name": target, "cmd_name": packet}

    def sample_fields(self, target, packet, fields):
        if packet == "XKEY_HK":
            values = {"KEY_ADDRESS": 0x100000, "KEY_LENGTH": 16, "CHANNEL_READY": 1}
            return runner.PacketSample(values, 1, self.clock.now)
        if packet == "XBAND_FRAME":
            assert target in runner.ORACLE["xbandTargets"].values()
            self.xband_reads += 1
            self.clock.tick(0.1)
            values = {name: 0 for name in runner.XBAND_FIELDS}
            values["MAGIC"] = runner.ORACLE["xbandMagic"]
            return runner.PacketSample(values, self.xband_reads, self.clock.now)
        index = len(self.sent) - 1
        if index < 0:
            values = {"LAST_ONE_SHOT_ADDRESS": 0, "LAST_ONE_SHOT_SIZE": 0,
                      "LAST_ONE_SHOT_CHECKSUM": 0, "ONE_SHOT_IN_PROGRESS": 0,
                      "COMMAND_COUNTER": 0, "COMMAND_ERROR_COUNTER": 0}
        else:
            self.polls_after_send += 1
            command_counter = len(self.sent)
            error_counter = 0
            if self.old_receipt_once and self.polls_after_send == 1:
                command_counter -= 1
            if self.reject_command:
                command_counter -= 1
                error_counter = 1
            values = {"LAST_ONE_SHOT_ADDRESS": 0x100000 + index, "LAST_ONE_SHOT_SIZE": 1,
                      "LAST_ONE_SHOT_CHECKSUM": runner.cfe_crc16(KEY[index:index + 1]), "ONE_SHOT_IN_PROGRESS": 0,
                      "COMMAND_COUNTER": command_counter, "COMMAND_ERROR_COUNTER": error_counter}
        return runner.PacketSample(values, 10 + len(self.sent), self.clock.now, self.stale)


class Management:
    run_id = "test_run"
    scope = "DEFAULT"

    def __init__(self, definition, clock):
        self.events = []
        self.context_data = {
            "run_id": self.run_id, "scope": self.scope, "target": definition["supportedTargets"][0],
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

    def engine(self, stale=False, scenario_id="qemu-cs-crc-key-oracle", **adapter_options):
        definition = self.catalog[scenario_id]
        adapter = Adapter(self.clock, stale=stale, **adapter_options)
        management = Management(definition, self.clock)
        engine = runner.ScenarioRunner(adapter, management, self.catalog,
                                       runner.canonical_hash(definition),
                                       monotonic=lambda: self.clock.now,
                                       wall_time=lambda: self.clock.now,
                                       sleep=self.clock.tick)
        return engine, adapter, management

    def test_16_one_byte_commands_recover_key(self):
        for scenario_id, target in (("qemu-cs-crc-key-oracle", "CFS-1_QEMU"),
                                    ("bbb-cs-crc-key-oracle", "CFS-1_BBB")):
            with self.subTest(target=target):
                self.clock = Clock()
                engine, adapter, management = self.engine(scenario_id=scenario_id)
                with patch.object(runner, "decode_xband_frame", return_value={
                    "sequence": 1, "cfe_seconds": 2, "temperature_centi_c": 2151,
                    "bus_voltage_mv": 7401, "status_flags": 3}) as decode:
                    self.assertEqual(engine.run()["status"], "succeeded")
                    self.assertEqual(decode.call_args.args[0], KEY)
                self.assertEqual(adapter.sent_targets, [target] * 16)
                self.assertEqual([command["ADDRESS"] for command in adapter.sent],
                                 list(range(0x100000, 0x100010)))
                self.assertTrue(all(command["SIZE"] == command["MAX_BYTES_PER_CYCLE"] == 1
                                    for command in adapter.sent))
                self.assertEqual(management.events[-1][1]["message"],
                                 "Recovered 16-byte X-band lab key and decrypted an authenticated XBD1 telemetry frame")
                self.assertNotIn(KEY.hex(), str(management.events))

    def test_oracle_scenario_cannot_switch_target(self):
        engine, adapter, management = self.engine()
        management.context_data["target"] = "CFS-1_BBB"
        with self.assertRaisesRegex(runner.ScenarioError, "invalid_target"):
            engine.run()
        self.assertEqual(adapter.sent, [])

    def test_wrong_oracle_function_code_is_rejected_before_commands(self):
        engine, adapter, _ = self.engine()
        original = adapter.command_definition

        def wrong_function_code(target, packet):
            definition = original(target, packet)
            next(item for item in definition["items"] if item["name"] == "CCSDS_FC")["default"] = 0
            return definition

        adapter.command_definition = wrong_function_code
        with self.assertRaisesRegex(runner.ScenarioError, "command_definition_mismatch"):
            engine.run()
        self.assertEqual(adapter.sent, [])

    def test_stale_checksum_stops_before_second_probe(self):
        engine, adapter, _ = self.engine(stale=True)
        with self.assertRaisesRegex(runner.ScenarioError, "crc_telemetry_timeout"):
            engine.run()
        self.assertEqual(len(adapter.sent), 1)

    def test_new_hk_with_old_same_address_crc_waits_for_command_counter(self):
        engine, adapter, _ = self.engine(old_receipt_once=True)
        with patch.object(runner, "decode_xband_frame", return_value={
            "sequence": 1, "cfe_seconds": 2, "temperature_centi_c": 2151,
            "bus_voltage_mv": 7401, "status_flags": 3}):
            self.assertEqual(engine.run()["status"], "succeeded")
        self.assertEqual(len(adapter.sent), 16)
        self.assertGreaterEqual(adapter.polls_after_send, 2)

    def test_rejected_command_fails_on_error_counter(self):
        engine, adapter, _ = self.engine(reject_command=True)
        with self.assertRaisesRegex(runner.ScenarioError, "crc_command_rejected"):
            engine.run()
        self.assertEqual(len(adapter.sent), 1)

    def test_single_byte_crc_is_injective(self):
        self.assertEqual(len(runner.CRC_BYTE_LOOKUP), 256)
        self.assertEqual(runner.CRC_BYTE_LOOKUP[0xC0C1], 1)

    @unittest.skipUnless(importlib.util.find_spec("cryptography"), "cryptography not installed")
    def test_xbd1_aes_gcm_decrypt_and_wrong_key_rejection(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        counter = 7
        iv = b"\x11\x22\x33\x44" + counter.to_bytes(8, "big")
        header = b"XBD1" + iv
        plaintext = (counter.to_bytes(4, "big") + (1234).to_bytes(4, "big") +
                     (2150 + counter % 11).to_bytes(2, "big") +
                     (7400 + counter % 17).to_bytes(2, "big") +
                     (3).to_bytes(4, "big"))
        encrypted = AESGCM(KEY).encrypt(iv, plaintext, header)
        frame = header + encrypted
        values = {"MAGIC": int.from_bytes(frame[0:4], "big"),
                  "IV_PREFIX": int.from_bytes(frame[4:8], "big"),
                  "COUNTER": int.from_bytes(frame[8:16], "big")}
        for prefix, start in (("CIPHERTEXT", 16), ("TAG", 32)):
            for index in range(4):
                values[f"{prefix}_{index}"] = int.from_bytes(
                    frame[start + index * 4:start + (index + 1) * 4], "big")
        decoded = runner.decode_xband_frame(KEY, values)
        self.assertEqual(decoded["sequence"], counter)
        self.assertEqual(decoded["bus_voltage_mv"], 7407)
        wrong = bytearray(KEY)
        wrong[0] ^= 1
        with self.assertRaisesRegex(runner.ScenarioError, "xband_auth_failed"):
            runner.decode_xband_frame(wrong, values)


if __name__ == "__main__":
    unittest.main()
