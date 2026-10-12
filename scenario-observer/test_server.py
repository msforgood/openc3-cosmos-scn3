import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from server import Observer, parse_show, read_secret


class FakeBackend:
    def __init__(self, records):
        self.records = iter(records)

    def status(self):
        return next(self.records)


class ObserverTest(unittest.TestCase):
    def test_credential_file_path_is_read_directly(self):
        with TemporaryDirectory() as directory:
            credential = Path(directory) / "credential"
            credential.write_text("test-credential\n", encoding="utf-8")
            self.assertEqual(read_secret(str(credential)), "test-credential")
            self.assertIsNone(read_secret(str(credential) + ".missing"))

    def test_signal_evidence_matches_baseline_instance(self):
        running = {
            "ActiveState": "active", "MainPID": "273", "ExecMainPID": "273",
            "ExecMainCode": "0", "ExecMainStatus": "0", "Result": "success",
            "InvocationID": "abc123",
        }
        crashed = {
            "ActiveState": "failed", "MainPID": "0", "ExecMainPID": "273",
            "ExecMainCode": "3", "ExecMainStatus": "11", "Result": "core-dump",
            "InvocationID": "abc123",
        }
        observer = Observer({"CFS-1_QEMU": FakeBackend([("boot-1", running), ("boot-1", crashed)])})
        baseline = observer.status("CFS-1_QEMU")
        outcome = observer.status("CFS-1_QEMU")
        self.assertTrue(baseline["running"])
        self.assertEqual(baseline["instance_id"], outcome["last_exit"]["instance_id"])
        self.assertEqual(outcome["last_exit"]["signal"], 11)
        self.assertFalse(outcome["running"])

    def test_plain_exit_139_is_not_signal_evidence(self):
        stopped = {
            "ActiveState": "failed", "MainPID": "0", "ExecMainPID": "273",
            "ExecMainCode": "1", "ExecMainStatus": "139", "Result": "exit-code",
            "InvocationID": "abc123",
        }
        observer = Observer({"CFS-1_QEMU": FakeBackend([("boot-1", stopped)])})
        self.assertIsNone(observer.status("CFS-1_QEMU")["last_exit"])

    def test_status_requires_systemd_fields(self):
        with self.assertRaises(ValueError):
            parse_show("ActiveState=active\n")


if __name__ == "__main__":
    unittest.main()
