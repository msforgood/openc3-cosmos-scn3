"""Scenario 3 must prove a denied direct write before an indirect pointer edit."""

import copy
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

    def __init__(self, definition, clock):
        self.events = []
        self.data = {
            "run_id": self.run_id, "scope": self.scope,
            "target": definition["supportedTargets"][0], "definition": copy.deepcopy(definition),
            "definition_hash": runner.canonical_hash(definition), "stop_requested": False,
            "prompt": None, "deadline": datetime.fromtimestamp(clock.now + 120, timezone.utc).isoformat(),
        }

    def context(self):
        return copy.deepcopy(self.data)

    def emit(self, kind, data):
        self.events.append((kind, data))
        return self.context()


class Adapter:
    KICK = 0x120040
    MODE = 0x1200FF
    SLOT = 0x300080

    def __init__(self, clock, *, direct_denied=True, bury_es_exit=False, publish_es_exit=True,
                 event_burst_before_exit=0):
        self.clock = clock
        self.direct_denied = direct_denied
        self.bury_es_exit = bury_es_exit
        self.publish_es_exit = publish_es_exit
        self.event_burst_before_exit = event_burst_before_exit
        self.sent = []
        self.samples = {}
        self.event_stream = []
        self.subscribed_before_resume = False
        self.pointer = self.KICK
        self.pulse_count = 10
        self.pulse_state = 1
        self.pulse_action = 2
        self.fault = 0
        self.acked = 0
        self.mode = 1

    def targets(self):
        return ["CFS-1_QEMU", "CFS-1_BBB"]

    def command_definition(self, target, packet):
        fields = {
            "MM_CMD_DEBUG_MAP": (13, {"REQUEST_ID": 32}),
            "MM_CMD_DEBUG_READ": (14, {"REQUEST_ID": 32, "WIDTH_BYTES": 32, "ADDRESS": 64}),
            "MM_CMD_DEBUG_WRITE": (15, {"REQUEST_ID": 32, "WIDTH_BYTES": 32, "ADDRESS": 64,
                                         "VALUE": 32, "RESERVED": 32}),
            "PAYLOAD_PULSE_PAUSE_CMD": (2, {}),
            "PAYLOAD_PULSE_RESUME_CMD": (3, {}),
            "PAYLOAD_PULSE_STATUS_CMD": (4, {}),
            "PAYLOAD_CTRL_STATUS_CMD": (2, {}),
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
                         "MODULE_START": 64, "MODULE_END": 64, "POINTER_SLOT": 64, "ADDRESS": 64, "VALUE": 64},
            "PAYLOAD_PULSE_STATE": {"STATE": 8, "BOUND": 8, "LAST_VALUE": 8, "FAULT_LATCH": 8,
                                    "PULSE_COUNT": 32, "SLOT_ADDRESS": 32, "FEED_TARGET_ADDRESS": 32,
                                    "AUTHORIZED_KICK_ADDRESS": 32, "BIND_COUNT": 32, "LAST_ACTION": 32,
                                    "LAST_ERROR": 32},
            "PAYLOAD_CTRL_STATE": {"MODE": 8, "KICK": 8, "FAULT": 8, "HALT_ACKED": 8,
                                   "SEEN_TRANSITIONS": 32, "FAULT_COUNT": 32, "KICK_ADDRESS": 32,
                                   "MODE_ADDRESS": 32, "LAST_FAULT_VALUE": 32,
                                   "LAST_CONTROL_SEQUENCE": 32},
            "CFE_EVS_LONG_EVENT_MSG": {"PACKET_ID_APP_NAME": 160, "PACKET_ID_EVENT_ID": 16,
                                       "MESSAGE": 976},
        }[packet]
        items = [{"name": name, "data_type": "STRING" if name in ("PACKET_ID_APP_NAME", "MESSAGE")
                  else "UINT", "bit_size": size} for name, size in fields.items()]
        items += [{"name": name, "data_type": "DERIVED"} for name in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def sample_fields(self, target, packet, fields):
        sample = self.samples.get(packet)
        if sample is None:
            return runner.PacketSample({name: None for name in fields}, 0, 0)
        return runner.PacketSample({name: sample.values.get(name) for name in fields},
                                   sample.count, sample.received, sample.stale)

    def subscribe_packets(self, target, packet):
        self.event_target = target
        self.subscribed_before_resume = not any(name == "PAYLOAD_PULSE_RESUME_CMD" for name, _ in self.sent)
        return str(len(self.event_stream))

    def get_packets(self, cursor):
        start = int(cursor)
        packets = self.event_stream[start:start + 256]
        return str(start + len(packets)), packets

    def _publish(self, packet, values):
        previous = self.samples.get(packet)
        self.samples[packet] = runner.PacketSample(values, (previous.count if previous else 0) + 1, self.clock.now)
        if packet == "CFE_EVS_LONG_EVENT_MSG":
            self.event_stream.append({"target_name": self.event_target, "packet_name": packet, **values})

    def command(self, target, packet, parameters, timeout):
        self.sent.append((packet, parameters))
        self.clock.now += 0.1
        if packet == "PAYLOAD_PULSE_PAUSE_CMD":
            self.pulse_state, self.pulse_action = 2, 3
        if packet == "PAYLOAD_PULSE_RESUME_CMD":
            self.pulse_state, self.pulse_action = 3, 5
            self.pulse_count += 1
            self.mode, self.fault, self.acked = 0xA5, 1, 1
            self._publish("PAYLOAD_CTRL_STATE", self._ctrl_values())
            for _ in range(self.event_burst_before_exit):
                self._publish("CFE_EVS_LONG_EVENT_MSG", {"PACKET_ID_APP_NAME": "PAYLOAD_PULSE_APP",
                                                          "PACKET_ID_EVENT_ID": 3,
                                                          "MESSAGE": "Pulse event before controller exit"})
            if self.publish_es_exit:
                self._publish("CFE_EVS_LONG_EVENT_MSG", {"PACKET_ID_APP_NAME": "CFE_ES",
                                                          "PACKET_ID_EVENT_ID": 14,
                                                          "MESSAGE": "Exit Application PAYLOAD_CTRL_APP Completed."})
            if self.bury_es_exit:
                self._publish("CFE_EVS_LONG_EVENT_MSG", {"PACKET_ID_APP_NAME": "PAYLOAD_PULSE_APP",
                                                          "PACKET_ID_EVENT_ID": 3,
                                                          "MESSAGE": "Pulse halted after controller fault"})
        if packet.startswith("PAYLOAD_PULSE_"):
            self._publish("PAYLOAD_PULSE_STATE", self._pulse_values())
        elif packet == "PAYLOAD_CTRL_STATUS_CMD":
            self._publish("PAYLOAD_CTRL_STATE", self._ctrl_values())
        elif packet.startswith("MM_CMD_DEBUG_"):
            status, value = 0, 0
            if packet == "MM_CMD_DEBUG_READ":
                value = self.pointer
            if packet == "MM_CMD_DEBUG_WRITE":
                if parameters["ADDRESS"] == self.MODE:
                    status = 3 if self.direct_denied else 0
                elif parameters["ADDRESS"] == self.SLOT:
                    self.pointer = (self.pointer & ~0xff) | parameters["VALUE"]
            operation = {"MM_CMD_DEBUG_MAP": 13, "MM_CMD_DEBUG_READ": 14,
                         "MM_CMD_DEBUG_WRITE": 15}[packet]
            self._publish("MM_DEBUG", {"REQUEST_ID": parameters["REQUEST_ID"],
                                       "OPERATION": operation, "STATUS": status,
                                       "WIDTH_BYTES": parameters.get("WIDTH_BYTES", 4),
                                       "MODULE_START": 0x300000, "MODULE_END": 0x301000,
                                       "POINTER_SLOT": self.SLOT, "ADDRESS": parameters.get("ADDRESS", 0),
                                       "VALUE": value})
        return {"target_name": target, "cmd_name": packet}

    def _pulse_values(self):
        return {"STATE": self.pulse_state, "BOUND": 1, "LAST_VALUE": 0x5A,
                "FAULT_LATCH": int(self.fault > 0), "PULSE_COUNT": self.pulse_count,
                "SLOT_ADDRESS": self.SLOT, "FEED_TARGET_ADDRESS": self.pointer,
                "AUTHORIZED_KICK_ADDRESS": self.KICK, "BIND_COUNT": 1,
                "LAST_ACTION": self.pulse_action, "LAST_ERROR": 0}

    def _ctrl_values(self):
        return {"MODE": self.mode, "KICK": 0x5A, "FAULT": self.fault,
                "HALT_ACKED": self.acked, "SEEN_TRANSITIONS": 10,
                "FAULT_COUNT": self.fault, "KICK_ADDRESS": self.KICK,
                "MODE_ADDRESS": self.MODE, "LAST_FAULT_VALUE": self.mode if self.fault else 0,
                "LAST_CONTROL_SEQUENCE": self.fault}


class PspIndirectWriteTests(unittest.TestCase):
    def build(self, target="CFS-1_QEMU", **options):
        catalog = runner.load_catalog()
        definition = catalog[runner.PSP["scenarioIds"][target]]
        clock = Clock()
        adapter = Adapter(clock, **options)
        management = Management(definition, clock)
        engine = runner.ScenarioRunner(adapter, management, catalog, runner.canonical_hash(definition),
                                       monotonic=lambda: clock.now, wall_time=lambda: clock.now,
                                       sleep=clock.sleep, call=lambda fn, _seconds, _label: fn())
        return engine, adapter, management

    def test_both_targets_deny_direct_write_then_redirect_one_byte(self):
        for target in ("CFS-1_QEMU", "CFS-1_BBB"):
            with self.subTest(target=target):
                engine, adapter, management = self.build(target)
                self.assertEqual(engine.run(), {"status": "succeeded"})
                commands = [name for name, _args in adapter.sent]
                self.assertLess(commands.index("MM_CMD_DEBUG_MAP"), commands.index("PAYLOAD_PULSE_PAUSE_CMD"))
                self.assertEqual(adapter.sent[3][1]["ADDRESS"], Adapter.MODE)  # denied control
                self.assertEqual(adapter.pointer, Adapter.MODE)
                self.assertEqual([args["VALUE"] for name, args in adapter.sent
                                  if name == "MM_CMD_DEBUG_WRITE"], [1, 0xFF])
                steps = {data["step_id"]: data for kind, data in management.events
                         if kind == "step" and data["status"] == "succeeded"}
                self.assertEqual(steps["observe-fault"]["halt_acked"], 1)
                self.assertEqual(steps["confirm-es-exit"]["es_event_id"], 14)
                self.assertEqual(steps["confirm-pulse"]["pulse_target"], Adapter.MODE)

    def test_es_exit_survives_newer_evs_packet_replacing_latest_value(self):
        engine, adapter, management = self.build(bury_es_exit=True)
        self.assertEqual(engine.run(), {"status": "succeeded"})
        self.assertTrue(adapter.subscribed_before_resume)
        self.assertEqual(adapter.samples["CFE_EVS_LONG_EVENT_MSG"].values["PACKET_ID_EVENT_ID"], 3)
        steps = {data["step_id"]: data for kind, data in management.events
                 if kind == "step" and data["status"] == "succeeded"}
        self.assertEqual(steps["confirm-es-exit"]["es_event_id"], 14)

    def test_missing_es_exit_fails_closed(self):
        engine, _adapter, _management = self.build(publish_es_exit=False, bury_es_exit=True)
        with self.assertRaisesRegex(runner.ScenarioError, "es_app_error_unconfirmed"):
            engine.run()

    def test_es_exit_after_first_stream_batch(self):
        engine, adapter, management = self.build(event_burst_before_exit=300)
        self.assertEqual(engine.run(), {"status": "succeeded"})
        self.assertEqual(len(adapter.event_stream), 301)
        steps = {data["step_id"]: data for kind, data in management.events
                 if kind == "step" and data["status"] == "succeeded"}
        self.assertEqual(steps["confirm-es-exit"]["es_event_id"], 14)

    def test_direct_write_not_denied_stops_before_pointer_edit(self):
        engine, adapter, _management = self.build(direct_denied=False)
        with self.assertRaisesRegex(runner.ScenarioError, "debug_status_0"):
            engine.run()
        self.assertFalse(any(name == "PAYLOAD_PULSE_PAUSE_CMD" for name, _args in adapter.sent))
        self.assertEqual(adapter.pointer, Adapter.KICK)


if __name__ == "__main__":
    unittest.main()
