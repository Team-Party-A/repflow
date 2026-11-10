import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from release_metrics import network_delta, snapshot_network, utc_now


class NetworkSnapshotTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.proc = Path(temporary.name)
        self.patch = patch("release_metrics.PROC_ROOT", self.proc)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.command_patch = patch(
            "release_metrics.subprocess.run",
            return_value=SimpleNamespace(stdout="100\n"),
        )
        self.command = self.command_patch.start()
        self.addCleanup(self.command_patch.stop)

    def process(self, pid, name, children=""):
        path = self.proc / str(pid)
        (path / "task" / str(pid)).mkdir(parents=True)
        (path / "comm").write_text(name + "\n")
        (path / "task" / str(pid) / "children").write_text(children)
        return path

    def counters(self, path, rx=100, tx=20):
        (path / "net").mkdir(parents=True)
        (path / "ns").mkdir()
        (path / "ns/net").write_text("")
        (path / "net/route").write_text(
            "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n"
            "slow0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n"
            "eth0 00000000 0100000A 0003 0 0 10 00000000 0 0 0\n"
            "down0 00000000 0100000A 0000 0 0 0 00000000 0 0 0\n"
        )
        (path / "net/dev").write_text(
            "Inter-| Receive | Transmit\n"
            " face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"
            f" eth0: {rx} 1 0 0 0 0 0 0 {tx} 1 0 0 0 0 0 0\n"
            " slow0: 999 1 0 0 0 0 0 0 888 1 0 0 0 0 0 0\n"
        )

    def test_reads_daemon_namespace_instead_of_wrapper_or_host(self):
        wrapper = self.process(100, "rootlesskit", "101 999")
        daemon = self.process(101, "dockerd")
        self.counters(wrapper, rx=9000, tx=8000)
        self.counters(daemon, rx=300, tx=70)
        self.counters(self.proc / "self", rx=6000, tx=5000)

        result = snapshot_network()

        self.assertEqual(
            result["scope"], f"docker_netns:{(daemon / 'ns/net').stat().st_ino}"
        )
        self.assertEqual(result["interface"], "eth0")
        self.assertEqual((result["rx_bytes"], result["tx_bytes"]), (300, 70))
        self.command.assert_called_once_with(
            [
                "systemctl",
                "--user",
                "show",
                "docker.service",
                "-p",
                "MainPID",
                "--value",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_service_failures_use_explicit_host_fallback(self):
        host = self.proc / "self"
        self.counters(host, rx=650, tx=190)
        for error in [
            FileNotFoundError(),
            subprocess.CalledProcessError(1, "systemctl"),
            subprocess.TimeoutExpired("systemctl", 5),
        ]:
            with self.subTest(error=type(error).__name__):
                self.command.side_effect = error
                result = snapshot_network()
                self.assertEqual(
                    result["scope"], f"host:{(host / 'ns/net').stat().st_ino}"
                )
                self.assertEqual((result["rx_bytes"], result["tx_bytes"]), (650, 190))

    def test_incomplete_daemon_statistics_fall_back_to_host(self):
        daemon = self.process(100, "dockerd")
        self.counters(daemon)
        (daemon / "net/dev").unlink()
        self.counters(self.proc / "self", rx=450, tx=80)
        result = snapshot_network()
        self.assertTrue(result["scope"].startswith("host:"))
        self.assertEqual(result["rx_bytes"], 450)

    def test_missing_proc_statistics_are_unavailable_without_raising(self):
        self.command.return_value.stdout = "0\n"
        result = snapshot_network()
        self.assertEqual(result["scope"], "unavailable")
        self.assertIsNone(result["rx_bytes"])
        self.assertIsNone(result["tx_bytes"])
        self.assertIsNone(result["interface"])


class NetworkDeltaTests(unittest.TestCase):
    def setUp(self):
        self.before = {
            "scope": "docker_netns:123",
            "interface": "eth0",
            "rx_bytes": 100,
            "tx_bytes": 50,
        }
        self.after = dict(self.before, rx_bytes=225, tx_bytes=100)

    def test_reports_actual_counter_changes(self):
        self.assertEqual(
            network_delta(self.before, self.after),
            dict(self.before, rx_bytes=125, tx_bytes=50),
        )

    def test_namespace_or_interface_changes_invalidate_the_comparison(self):
        for changes in [
            {"scope": "docker_netns:124"},
            {"scope": "host:123"},
            {"interface": "ens3"},
            {"scope": "unavailable"},
        ]:
            with self.subTest(changes=changes):
                self.assertEqual(
                    network_delta(self.before, dict(self.after, **changes))["scope"],
                    "unavailable",
                )

    def test_reset_or_malformed_counters_do_not_become_transfer_bytes(self):
        for changes in [
            {"rx_bytes": 99},
            {"tx_bytes": 49},
            {"rx_bytes": -1},
            {"rx_bytes": True},
            {"tx_bytes": "100"},
            {"tx_bytes": None},
        ]:
            with self.subTest(changes=changes):
                result = network_delta(self.before, dict(self.after, **changes))
                self.assertEqual(result["scope"], "unavailable")
                self.assertIsNone(result["rx_bytes"])

    def test_utc_timestamp_is_aware(self):
        self.assertEqual(datetime.fromisoformat(utc_now()).utcoffset(), timedelta(0))


if __name__ == "__main__":
    unittest.main()
