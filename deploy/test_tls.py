import fcntl
import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from https_probe import TLSCheckError, check_renewal_status
from tls import DEPLOY, TLSManager, main


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="repflow-tls-unit-")
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name)
        self.manager = TLSManager(self.state, "192.0.2.1", ["docker", "compose"], {})
        self.manager.initialize()

    def test_private_state_and_public_status_permissions(self):
        self.manager.status(False)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(
            stat.S_IMODE((self.state / "letsencrypt").stat().st_mode), 0o700
        )
        path = self.state / "status/status.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        self.assertEqual(set(json.loads(path.read_text())), {"ok", "checked_at"})
        self.assertNotIn(self.manager.ip, path.read_text())

    def test_production_requires_completed_staging_for_same_public_ip(self):
        self.manager.ip = "1.1.1.1"
        with patch.object(self.manager, "certbot") as certbot:
            with self.assertRaises(TLSCheckError):
                self.manager.issue()
            certbot.assert_not_called()
            self.manager.issue(staging=True)
            self.assertIn("--staging", certbot.call_args.args)
            self.assertIn("--force-renewal", certbot.call_args.args)
            self.assertEqual(
                certbot.call_args.kwargs["TLS_CERT_DIR"], str(self.state / "staging")
            )
            with patch.object(self.manager, "activate") as activate:
                self.manager.issue()
                self.assertNotIn("--staging", certbot.call_args.args)
                activate.assert_called_once_with(recreate=True)
            self.manager.ip = "8.8.8.8"
            with self.assertRaises(TLSCheckError):
                self.manager.issue()

    def test_private_ip_is_rejected_before_certbot(self):
        with patch.object(self.manager, "certbot") as certbot:
            with self.assertRaises(TLSCheckError):
                self.manager.issue(staging=True)
            certbot.assert_not_called()

    def test_renewal_failure_marks_status_failed_without_touching_nginx(self):
        environment = {"TLS_STATE_DIR": str(self.state), "PUBLIC_IP": "192.0.2.1"}
        with (
            patch.dict(os.environ, environment),
            patch("sys.argv", ["tls.py", "renew"]),
            patch.object(
                TLSManager, "certbot", side_effect=TLSCheckError("renewal failed")
            ),
            patch.object(TLSManager, "activate") as activate,
        ):
            with self.assertRaises(TLSCheckError):
                main()
        activate.assert_not_called()
        self.assertFalse(
            json.loads((self.state / "status/status.json").read_text())["ok"]
        )

    def test_reload_failure_retains_marker_then_retries_when_not_due(self):
        self.manager.pending.touch()
        (self.state / "applied-fingerprint").write_text("new-certificate")
        with (
            patch.object(
                self.manager, "validate_candidate", return_value="new-certificate"
            ),
            patch.object(self.manager, "certbot"),
            patch.object(
                self.manager, "compose_run", side_effect=TLSCheckError("reload failed")
            ),
        ):
            with self.assertRaises(TLSCheckError):
                self.manager.renew()
        self.assertTrue(self.manager.pending.exists())
        with (
            patch.object(
                self.manager, "validate_candidate", return_value="new-certificate"
            ),
            patch.object(self.manager, "certbot"),
            patch.object(self.manager, "compose_run") as commands,
            patch("tls.probe", return_value="new-certificate"),
        ):
            self.manager.renew()
        self.assertIn(
            ("exec", "-T", "nginx", "nginx", "-s", "reload"),
            [call.args for call in commands.call_args_list],
        )
        self.assertFalse(self.manager.pending.exists())
        self.assertTrue(
            json.loads((self.state / "status/status.json").read_text())["ok"]
        )

    def test_candidate_failure_does_not_reload_or_record_success(self):
        with (
            patch.object(
                self.manager,
                "validate_candidate",
                side_effect=TLSCheckError("expired or untrusted"),
            ),
            patch.object(self.manager, "compose_run") as commands,
        ):
            with self.assertRaises(TLSCheckError):
                self.manager.activate()
        commands.assert_not_called()
        self.assertFalse((self.state / "applied-fingerprint").exists())

    def test_wrong_served_certificate_does_not_mark_success(self):
        with (
            patch.object(self.manager, "validate_candidate", return_value="new"),
            patch.object(self.manager, "compose_run"),
            patch("tls.probe", return_value="old"),
            patch("tls.time.sleep"),
        ):
            with self.assertRaises(TLSCheckError):
                self.manager.activate()
        self.assertTrue(self.manager.pending.exists())
        self.assertFalse((self.state / "applied-fingerprint").exists())

    def test_dry_run_executes_hook_and_verifies_current_certificate(self):
        with (
            patch.object(self.manager, "certbot") as certbot,
            patch.object(self.manager, "activate") as activate,
        ):
            self.manager.renew(dry_run=True)
        self.assertIn("--dry-run", certbot.call_args.args)
        self.assertIn("--run-deploy-hooks", certbot.call_args.args)
        self.assertIn("--no-random-sleep-on-renew", certbot.call_args.args)
        activate.assert_called_once_with()

    def test_no_change_still_checks_real_certificate_and_health(self):
        (self.state / "applied-fingerprint").write_text("current")
        with (
            patch.object(self.manager, "validate_candidate", return_value="current"),
            patch.object(self.manager, "compose_run") as commands,
            patch("tls.probe", return_value="current") as check,
        ):
            self.manager.activate()
        commands.assert_not_called()
        check.assert_called_once()
        self.assertTrue(
            json.loads((self.state / "status/status.json").read_text())["ok"]
        )

    def test_failed_command_does_not_echo_arguments(self):
        with self.assertRaises(TLSCheckError) as caught:
            self.manager.run(["sh", "-c", "echo synthetic-private-value; exit 2"])
        self.assertNotIn("synthetic-private-value", str(caught.exception))
        path = self.state / "last-command.log"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_concurrent_operation_does_not_run_certbot_or_overwrite_status(self):
        self.manager.status(True)
        environment = {"TLS_STATE_DIR": str(self.state), "PUBLIC_IP": "192.0.2.1"}
        with (
            (self.state / "operation.lock").open("w") as lock,
            patch.dict(os.environ, environment),
            patch("sys.argv", ["tls.py", "renew"]),
            patch.object(TLSManager, "certbot") as certbot,
        ):
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                main()
        certbot.assert_not_called()
        self.assertTrue(
            json.loads((self.state / "status/status.json").read_text())["ok"]
        )

    def test_certificate_state_in_repository_is_rejected_before_writing(self):
        environment = {"TLS_STATE_DIR": str(DEPLOY / "must-not-create")}
        with (
            patch.dict(os.environ, environment),
            patch("sys.argv", ["tls.py", "renew"]),
            patch.object(TLSManager, "initialize") as initialize,
            self.assertRaises(TLSCheckError),
        ):
            main()
        initialize.assert_not_called()

    def test_unreachable_nginx_retains_a_retry_marker(self):
        (self.state / "applied-fingerprint").write_text("current")
        with (
            patch.object(self.manager, "validate_candidate", return_value="current"),
            patch.object(self.manager, "compose_run"),
            patch("tls.probe", side_effect=OSError("unreachable")),
            patch("tls.time.sleep"),
            self.assertRaises(OSError),
        ):
            self.manager.activate()
        self.assertTrue(self.manager.pending.exists())

    def test_false_stale_future_or_invalid_status_fails(self):
        now = int(time.time())
        check_renewal_status({"ok": True, "checked_at": now})
        for data in (
            {"ok": False, "checked_at": now},
            {"ok": True, "checked_at": now - 27 * 3600},
            {"ok": True, "checked_at": now + 301},
            {"ok": True, "checked_at": True},
            {"ok": True, "checked_at": "not-a-timestamp"},
            [],
        ):
            with self.subTest(data=data), self.assertRaises(TLSCheckError):
                check_renewal_status(data)
