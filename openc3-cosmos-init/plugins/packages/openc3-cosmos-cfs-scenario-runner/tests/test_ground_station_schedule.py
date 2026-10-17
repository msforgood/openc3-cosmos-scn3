"""Scenario 4 saves the operator TC sequence and registers it on the Calendar five minutes ahead."""

import ast
import copy
from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import cfs_scenario_runner as runner

START = 1791856800.0  # 2026-10-13 03:20:00 UTC


class Clock:
    def __init__(self):
        self.now = START

    def sleep(self, seconds):
        self.now += seconds


class Management:
    run_id = "ground_station_tc_schedule"
    scope = "DEFAULT"

    def __init__(self, definition, clock, target="INST"):
        self.events = []
        self.data = {
            "run_id": self.run_id, "scope": self.scope,
            "target": target, "definition": copy.deepcopy(definition),
            "definition_hash": runner.canonical_hash(definition), "stop_requested": False,
            "execution_mode": "automatic", "prompt": None,
            "deadline": datetime.fromtimestamp(clock.now + 60, timezone.utc).isoformat(),
        }

    def context(self):
        return copy.deepcopy(self.data)

    def emit(self, kind, data):
        self.events.append((kind, data))
        return self.context()


class Adapter:
    """INST with HEALTH_STATUS at 1 Hz plus in-memory target files and Calendar."""

    def __init__(self, clock, *, live=True, hazardous=None, timelines=("GROUND_OPS",), lose_activity=False):
        self.clock, self.live, self.hazardous = clock, live, hazardous
        self.lose_activity = lose_activity
        self.files, self.timeline_names, self.activities = {}, list(timelines), {}
        self.created_timelines, self.commands = [], []
        self.health = (0, clock.now - 0.5)

    def targets(self):
        return ["INST", "INST2", "CFS-1_QEMU"]

    def command_definition(self, target, packet):
        return {"target_name": target, "packet_name": packet, "hazardous": packet == self.hazardous, "items": []}

    def telemetry_definition(self, target, packet):
        fields = {"HEALTH_STATUS": {"CMD_ACPT_CNT": ("UINT", 32), "ATT_MODE": ("UINT", 8)},
                  "MESSAGE": {"SEQ": ("UINT", 8), "TEXT": ("STRING", 512)}}[packet]
        items = [{"name": k, "data_type": kind, "bit_size": size} for k, (kind, size) in fields.items()]
        items += [{"name": k, "data_type": "DERIVED"} for k in runner.RECEIPT_ITEMS]
        return {"target_name": target, "packet_name": packet, "items": items}

    def sample(self, target, packet, item):
        if self.live:
            ticks = int(self.clock.now - self.health[1])
            if ticks >= 1:
                self.health = (self.health[0] + ticks, self.health[1] + ticks)
        count, received = self.health
        return runner.Sample(3, count, received)

    def command(self, target, packet, parameters, timeout):
        self.commands.append(packet)
        return {"target_name": target, "cmd_name": packet}

    def put_target_file(self, path, text):
        self.files[path] = text

    def timelines(self):
        return list(self.timeline_names)

    def create_timeline(self, name, color):
        self.created_timelines.append((name, color))
        self.timeline_names.append(name)

    def create_activity(self, timeline, start, stop, data):
        activity = {"name": timeline, "uuid": "a1b2", "start": start, "stop": stop, "kind": "script", "data": data}
        self.activities[(timeline, start, "a1b2")] = activity
        return copy.deepcopy(activity)

    def activity(self, timeline, start, uuid):
        if self.lose_activity:
            return None
        return copy.deepcopy(self.activities.get((timeline, start, uuid)))


class GroundStationScheduleTests(unittest.TestCase):
    def build(self, **options):
        catalog = runner.load_catalog()
        definition = catalog[runner.SCHEDULE["scenarioId"]]
        clock = Clock()
        adapter = Adapter(clock, **options)
        management = Management(definition, clock)
        engine = runner.ScenarioRunner(adapter, management, catalog, runner.canonical_hash(definition),
                                       monotonic=lambda: clock.now, wall_time=lambda: clock.now,
                                       sleep=clock.sleep, call=lambda fn, _seconds, _label: fn())
        return engine, adapter, management, clock

    def test_sequence_is_saved_and_scheduled_five_minutes_ahead(self):
        engine, adapter, management, clock = self.build()
        self.assertEqual(engine.run(), {"status": "succeeded"})
        # Nothing is commanded now; the sequence runs later from the Calendar.
        self.assertEqual(adapter.commands, [])
        (path, text), = adapter.files.items()
        self.assertRegex(path, r"^INST/procedures/INST_20261013_\d{6}\.py$")
        ast.parse(text)
        for line in ('cmd("INST ATT_CTRL with MODE NADIR")', 'cmd("INST COLLECT with TYPE NORMAL, DURATION 1.0")',
                     'wait_check_packet("INST", "HEALTH_STATUS", 3, 10)'):
            self.assertIn(line, text)
        self.assertNotIn("DOWNLINK_MSG", text)
        (timeline, start, _uuid), = adapter.activities
        activity = adapter.activities[(timeline, start, _uuid)]
        self.assertEqual(timeline, "GROUND_OPS")
        self.assertEqual(activity["data"], {"script": path, "environment": []})
        self.assertGreaterEqual(start - START, 300)
        self.assertLess(start - START, 305)
        self.assertEqual(activity["stop"] - start, 60)
        # The name is the satellite plus the KST execution time.
        kst = datetime.fromtimestamp(start, runner.timezone(runner.timedelta(hours=9)))
        self.assertEqual(path, f"INST/procedures/INST_{kst.strftime('%Y%m%d_%H%M%S')}.py")
        self.assertEqual(adapter.created_timelines, [])
        steps = [data for kind, data in management.events if kind == "step" and data["status"] == "succeeded"]
        self.assertEqual([step["step_id"] for step in steps], runner.SCHEDULE["phases"])
        result = management.events[-1]
        self.assertEqual(result[0], "result")
        self.assertRegex(result[1]["message"], r"^Scheduled INST_\d{8}_\d{6} on GROUND_OPS at .* \+0900$")

    def test_missing_timeline_is_created(self):
        engine, adapter, _management, _clock = self.build(timelines=())
        self.assertEqual(engine.run(), {"status": "succeeded"})
        self.assertEqual(adapter.created_timelines, [("GROUND_OPS", runner.SCHEDULE["timelineColor"])])

    def test_dead_link_schedules_nothing(self):
        engine, adapter, _management, _clock = self.build(live=False)
        with self.assertRaisesRegex(runner.ScenarioError, "link_not_live"):
            engine.run()
        self.assertEqual((adapter.files, adapter.activities), ({}, {}))

    def test_hazardous_sequence_command_is_refused(self):
        engine, adapter, _management, _clock = self.build(hazardous="COLLECT")
        with self.assertRaisesRegex(runner.ScenarioError, "invalid_command"):
            engine.run()
        self.assertEqual(adapter.files, {})

    def test_unverifiable_activity_fails(self):
        engine, _adapter, _management, _clock = self.build(lose_activity=True)
        with self.assertRaisesRegex(runner.ScenarioError, "schedule_mismatch"):
            engine.run()

    def test_definition_is_pinned_to_inst(self):
        definition = copy.deepcopy(runner.load_catalog()[runner.SCHEDULE["scenarioId"]])
        for change in (lambda d: d.update(supportedTargets=["CFS-1_QEMU"]),
                       lambda d: d.update(supportedTargets=["INST", "INST2"]),
                       lambda d: d["steps"].reverse(),
                       lambda d: d["telemetryItems"].pop(),
                       lambda d: d.update(timeoutSec=120)):
            candidate = copy.deepcopy(definition)
            change(candidate)
            with self.assertRaises(runner.ScenarioError):
                runner.validate_definition(candidate)
        other = copy.deepcopy(runner.load_catalog()[runner.PSP["scenarioId"]])
        other["supportedTargets"] = ["INST"]
        with self.assertRaises(runner.ScenarioError):
            runner.validate_definition(other)


if __name__ == "__main__":
    unittest.main()
