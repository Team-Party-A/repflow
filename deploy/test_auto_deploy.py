import json
import stat
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from auto_deploy import (
    IMAGE,
    REPOSITORY,
    WORKFLOW,
    DeployError,
    Deployment,
    Stack,
    discover,
    verification_result,
)
from github_poll import PollDeferred
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
        due = max(time.time(), self.deployment.state.get("poll_after", 0))
        with (
            patch("auto_deploy.discover", return_value=REQUEST),
            patch("auto_deploy.verification_result", return_value=None),
            patch("auto_deploy.time.time", return_value=due),
        ):
            self.deployment.tick()
        self.assertEqual(
            json.loads(self.status_path.read_text()), dict(IDENTITY, state="candidate")
        )

    def resume(self, result):
        deployment = Deployment(self.stack)
        due = max(time.time(), deployment.state.get("poll_after", 0))
        with (
            patch("auto_deploy.verification_result", return_value=result),
            patch("auto_deploy.time.time", return_value=due),
        ):
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

    def test_idle_wakeup_does_not_query_before_two_minutes(self):
        with patch("auto_deploy.discover", return_value=None) as discover:
            self.deployment.tick()
            Deployment(self.stack).tick()
            discover.assert_called_once()

    def test_four_fast_checks_then_backoff_survives_restart(self):
        self.begin()
        for interval in [30, 30, 30, 120]:
            due = json.loads(self.deployment.path.read_text())["poll_after"]
            state = self.resume(None)
            self.assertEqual(state["poll_after"], due + interval)

    def test_quota_wait_cannot_prevent_expired_candidate_rollback(self):
        self.begin()
        due = self.deployment.state["poll_after"]
        with (
            patch("auto_deploy.time.time", return_value=due),
            patch(
                "auto_deploy.verification_result",
                side_effect=PollDeferred(due + 3600, "budget"),
            ),
        ):
            self.deployment.tick()
        self.assertIsNotNone(self.deployment.state["pending"])
        self.assertEqual(self.deployment.state["current"], CURRENT)
        self.deployment.state["pending"]["deadline"] = time.time() - 1
        self.deployment.save()
        with patch("auto_deploy.verification_result") as network:
            Deployment(self.stack).tick()
            network.assert_not_called()
        self.stack.activate.assert_called_with(CURRENT, rollback=True)

    def test_verification_budget_unavailable_before_cutover_keeps_current(self):
        with (
            patch("auto_deploy.discover", return_value=REQUEST),
            patch(
                "auto_deploy.verification_result",
                side_effect=PollDeferred(time.time() + 60, "budget"),
            ),
            self.assertRaisesRegex(DeployError, "before cutover"),
        ):
            self.deployment.tick()
        self.stack.activate.assert_not_called()
        self.assertEqual(self.deployment.state["current"], CURRENT)
        self.assertIsNone(self.deployment.state["pending"])


class PreparationTests(unittest.TestCase):
    def test_cached_candidate_still_checks_schema_and_writes_backup(self):
        with (
            tempfile.TemporaryDirectory() as folder,
            patch.dict("os.environ", PUBLIC_IP="192.0.2.1"),
        ):
            root = Path(folder)
            stack = Stack(root, root, root, root / "unused.env")
            stack.git = Mock(return_value="")
            stack.verify = Mock()
            stack.run = Mock(return_value=REQUEST["commit"])

            def compose(*args, **options):
                if "output_file" in options:
                    options["output_file"].write(b"test-backup")
                if (
                    args[:2] == ("exec", "-T")
                    and "input_file" not in options
                    and "output_file" not in options
                ):
                    return "0002_workouts"
                return "0002_workouts (head)"

            stack.compose_run = Mock(side_effect=compose)
            with (
                patch("auto_deploy.image_cached", return_value=True),
                patch("auto_deploy.snapshot_network", return_value={}),
                patch(
                    "auto_deploy.network_delta", return_value={"scope": "unavailable"}
                ),
            ):
                stack.prepare(CURRENT, CANDIDATE, REQUEST)
            self.assertFalse(
                any("pull" in row.args[0] for row in stack.run.call_args_list)
            )
            self.assertTrue((root / "backup-18-2.dump").exists())
            self.assertTrue((root / "backup-18-2.sha256").exists())
            self.assertTrue(
                any(
                    "input_file" in row.kwargs
                    for row in stack.compose_run.call_args_list
                )
            )
            self.assertTrue(
                json.loads((root / "metrics-18-2.json").read_text())["download"][
                    "cache_hit"
                ]
            )


class ProtocolTests(unittest.TestCase):
    def test_only_running_verifier_allows_cutover(self):
        job = {
            "run_id": REQUEST["run_id"],
            "head_sha": REQUEST["commit"],
            "name": f"Verify swe HTTPS ({REQUEST['digest']})",
            "conclusion": None,
        }
        for status in ["queued", "completed"]:
            with patch("auto_deploy.api", return_value=dict(job, status=status)):
                self.assertIsNotNone(verification_result(REQUEST))
        with patch("auto_deploy.api", return_value=dict(job, status="in_progress")):
            self.assertIsNone(verification_result(REQUEST))

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
