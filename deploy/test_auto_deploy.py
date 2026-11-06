import json
import stat
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from auto_deploy import IMAGE, REPOSITORY, WORKFLOW, DeployError, Deployment, discover
from release_probe import check_release, status_of

CURRENT = {
    "commit": "1" * 40,
    "config": "0" * 40,
    "image": IMAGE + "sha256:" + "1" * 64,
}
REQUEST = {
    "order": [8, 2],
    "run_id": 18,
    "attempt": 2,
    "job_id": 123,
    "commit": "2" * 40,
    "digest": "sha256:" + "2" * 64,
}
CANDIDATE = {
    "commit": REQUEST["commit"],
    "config": REQUEST["commit"],
    "image": IMAGE + REQUEST["digest"],
}
IDENTITY = {key: REQUEST[key] for key in ("run_id", "attempt", "commit", "digest")}


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / "status").mkdir()
        self.status_path = root / "status/deploy-18-2.json"
        self.stack = SimpleNamespace(
            state=root, tls_state=root, prepare=Mock(), activate=Mock(), verify=Mock()
        )
        self.deployment = Deployment(self.stack)
        self.deployment.state = {
            "current": CURRENT,
            "previous": None,
            "last": [0, 0],
            "pending": None,
            "status": None,
        }
        self.deployment.save()

    def begin(self):
        self.deployment = Deployment(self.stack)
        with (
            patch("auto_deploy.discover", return_value=REQUEST),
            patch("auto_deploy.verification_result", return_value=None),
        ):
            self.deployment.tick()
        self.assertEqual(
            json.loads(self.status_path.read_text()), dict(IDENTITY, state="candidate")
        )

    def resume(self, result):
        deployment = Deployment(self.stack)
        with patch("auto_deploy.verification_result", return_value=result):
            deployment.tick()
        return deployment.state

    def test_external_success_records_current_and_previous(self):
        self.begin()
        self.stack.prepare.assert_called_once_with(CURRENT, CANDIDATE, REQUEST)
        self.stack.activate.assert_called_once_with(CANDIDATE)
        self.assertEqual(self.deployment.state["current"], CURRENT)
        self.assertEqual(self.resume(None)["current"], CURRENT)
        state = self.resume("success")
        self.assertEqual(state["current"], CANDIDATE)
        self.assertEqual(state["previous"], CURRENT)
        self.assertIsNone(state["pending"])
        self.assertEqual(json.loads(self.status_path.read_text())["state"], "deployed")
        self.assertEqual(stat.S_IMODE(self.deployment.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.status_path.stat().st_mode), 0o644)

    def test_cancelled_run_restores_image_and_configuration(self):
        self.begin()
        self.assertEqual(self.resume("cancelled")["current"], CURRENT)
        self.stack.activate.assert_called_with(CURRENT, rollback=True)
        self.assertEqual(
            json.loads(self.status_path.read_text())["state"], "rolled_back"
        )

    def test_backup_failure_leaves_running_version_untouched(self):
        self.stack.prepare.side_effect = DeployError("backup failed")
        with (
            patch("auto_deploy.discover", return_value=REQUEST),
            self.assertRaises(DeployError),
        ):
            self.deployment.tick()
        self.stack.activate.assert_not_called()
        self.assertEqual(self.deployment.state["last"], REQUEST["order"])
        self.assertEqual(json.loads(self.status_path.read_text())["state"], "failed")

    def test_external_verifier_cancelled_during_preparation_stops_the_switch(self):
        with (
            patch("auto_deploy.discover", return_value=REQUEST),
            patch("auto_deploy.verification_result", return_value="cancelled"),
            self.assertRaises(DeployError),
        ):
            self.deployment.tick()
        self.stack.activate.assert_not_called()

    def test_lost_process_and_expired_external_check_restore_old_release(self):
        for phase in ("apply", "candidate"):
            with self.subTest(phase=phase):
                self.begin()
                self.deployment.state["pending"].update(
                    phase=phase, deadline=time.time() - 1
                )
                self.deployment.save()
                with patch("auto_deploy.verification_result") as result:
                    Deployment(self.stack).tick()
                    result.assert_not_called()
                self.stack.activate.assert_called_with(CURRENT, rollback=True)

    def test_failed_rollback_is_retried_after_restart(self):
        self.begin()
        self.stack.activate.side_effect = DeployError("cannot restore")
        with self.assertRaises(DeployError):
            self.resume("failure")
        self.assertEqual(
            json.loads(self.status_path.read_text())["state"], "rollback_failed"
        )
        self.stack.activate.side_effect = None
        self.assertIsNone(self.resume(None)["pending"])
        self.stack.activate.assert_called_with(CURRENT, rollback=True)

    def test_status_write_failure_does_not_prevent_rollback(self):
        self.begin()
        with (
            patch.object(Deployment, "write_status", side_effect=OSError),
            self.assertRaises(OSError),
        ):
            self.resume("failure")
        self.stack.activate.assert_called_with(CURRENT, rollback=True)
        state = Deployment(self.stack).state
        self.assertEqual(state["current"], CURRENT)
        self.assertIsNone(state["pending"])
        self.assertEqual(state["status"]["state"], "rolled_back")


class ProtocolTests(unittest.TestCase):
    def test_discovery_accepts_only_the_new_matching_dev_run(self):
        run = {
            "run_number": 8,
            "run_attempt": 2,
            "id": 18,
            "head_sha": REQUEST["commit"],
            "event": "push",
            "head_branch": "dev",
            "path": WORKFLOW,
            "repository": {"full_name": REPOSITORY},
            "head_repository": {"full_name": REPOSITORY},
        }
        runs = {"workflow_runs": [dict(run, event="pull_request"), run]}
        jobs = {
            "jobs": [
                dict(
                    id=123,
                    name=f"Verify swe HTTPS ({REQUEST['digest']})",
                    head_sha=REQUEST["commit"],
                    status="in_progress",
                )
            ]
        }
        with patch("auto_deploy.api", side_effect=[runs, jobs, runs]) as api:
            self.assertEqual(discover([8, 1]), REQUEST)
            self.assertIsNone(discover(REQUEST["order"]))
            self.assertEqual(api.call_count, 3)

    def test_probe_rejects_wrong_release_and_reports_real_rollbacks(self):
        with patch(
            "release_probe.get_https_json",
            return_value=(dict(IDENTITY, digest="wrong", state="candidate"), None),
        ):
            self.assertIsNone(status_of("192.0.2.1", 8080, IDENTITY))
        with (
            patch("release_probe.status_of", return_value="candidate"),
            patch("release_probe.probe") as health,
        ):
            check_release("192.0.2.1", 8080, IDENTITY, "verify", expect_deployed=False)
            health.assert_called_once_with("192.0.2.1", 8080)
            with self.assertRaisesRegex(RuntimeError, "intentional failure"):
                check_release(
                    "192.0.2.1",
                    8080,
                    IDENTITY,
                    "verify",
                    expect_deployed=False,
                    force_failure=True,
                )
        with patch("release_probe.status_of", return_value="rolled_back"):
            self.assertIn(
                "rolled_back",
                check_release(
                    "192.0.2.1", 8080, IDENTITY, "confirm", expect_deployed=False
                ),
            )
            with self.assertRaisesRegex(RuntimeError, "rolled_back"):
                check_release(
                    "192.0.2.1", 8080, IDENTITY, "confirm", expect_deployed=True
                )
