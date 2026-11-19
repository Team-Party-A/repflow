import json
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

from auto_deploy import REPOSITORY, WORKFLOW, atomic_write, discover
from github_poll import PollDeferred, get
from test_auto_deploy import REQUEST


class PollTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "poll.json"
        self.clock = patch("github_poll.time.time", return_value=5000)
        self.clock.start()
        self.addCleanup(self.clock.stop)

    def response(self, body, **headers):
        response = Mock(headers=headers)
        response.read.return_value = json.dumps(body).encode()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        return response

    def fetch(self, path="jobs/123"):
        return get(path, self.path, atomic_write)

    def test_discovery_quota_reserves_control_and_survives_client_restart(self):
        atomic_write(self.path, json.dumps({"calls": [[4900, "discovery"]] * 36}))
        with patch("github_poll.urlopen", return_value=self.response({})) as network:
            with self.assertRaises(PollDeferred):
                self.fetch("workflows/backend.yml/runs")
            network.assert_not_called()
            for _ in range(12):
                self.fetch()
            self.assertEqual(network.call_count, 12)
            with self.assertRaises(PollDeferred):
                self.fetch()
        state = json.loads(self.path.read_text())
        self.assertEqual(len(state["calls"]), 48)
        self.assertEqual(state["request_count"], 12)

    def test_304_reuses_only_the_same_endpoint_and_still_consumes_quota(self):
        original = {"status": "in_progress"}
        with patch(
            "github_poll.urlopen", return_value=self.response(original, ETag='"one"')
        ):
            self.assertEqual(self.fetch(), original)
        unchanged = HTTPError(
            "https://api.github.com/", 304, "unchanged", {}, BytesIO()
        )
        with patch("github_poll.urlopen", side_effect=unchanged) as network:
            self.assertEqual(self.fetch(), original)
            self.assertEqual(
                network.call_args.args[0].get_header("If-none-match"), '"one"'
            )
        state = json.loads(self.path.read_text())
        self.assertEqual(len(state["calls"]), 2)
        self.assertEqual(state["not_modified"], 1)
        with patch("github_poll.urlopen", side_effect=unchanged):
            with self.assertRaises(HTTPError):
                self.fetch("jobs/456")

    def test_network_failure_cannot_reuse_cached_success(self):
        with patch(
            "github_poll.urlopen",
            return_value=self.response({"conclusion": "success"}, ETag='"old"'),
        ):
            self.fetch()
        with patch("github_poll.urlopen", side_effect=URLError("offline")):
            with self.assertRaises(PollDeferred):
                self.fetch()
        with patch("github_poll.urlopen") as network:
            with self.assertRaises(PollDeferred):
                self.fetch()
            network.assert_not_called()
        self.assertEqual(len(json.loads(self.path.read_text())["calls"]), 2)

    def test_rate_limit_headers_delay_all_endpoints_without_probing(self):
        headers = {
            "Retry-After": "300",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "5600",
        }
        limited = HTTPError(
            "https://api.github.com/", 429, "limited", headers, BytesIO()
        )
        with patch("github_poll.urlopen", side_effect=limited):
            with self.assertRaises(PollDeferred) as raised:
                self.fetch()
            self.assertEqual(raised.exception.until, 5600)
        with patch("github_poll.urlopen") as network:
            with self.assertRaises(PollDeferred):
                self.fetch("workflows/backend.yml/runs")
            network.assert_not_called()

    def test_expired_calls_release_the_budget(self):
        atomic_write(self.path, json.dumps({"calls": [[1000, "control"]] * 48}))
        with patch("github_poll.urlopen", return_value=self.response({})):
            self.fetch()
        self.assertEqual(len(json.loads(self.path.read_text())["calls"]), 1)

    def test_retry_after_starts_when_response_arrives(self):
        limited = HTTPError(
            "https://api.github.com/", 429, "limited", {"Retry-After": "120"}, BytesIO()
        )
        with (
            patch("github_poll.time.time", side_effect=[5000, 5009]),
            patch("github_poll.urlopen", side_effect=limited),
            self.assertRaises(PollDeferred) as raised,
        ):
            self.fetch()
        self.assertEqual(raised.exception.until, 5129)

    def test_poll_interval_applies_only_to_the_matching_endpoint(self):
        with patch(
            "github_poll.urlopen",
            return_value=self.response({}, **{"X-Poll-Interval": "90"}),
        ):
            self.fetch()
        with patch("github_poll.urlopen", return_value=self.response({})) as network:
            self.fetch("jobs/456")
            with self.assertRaises(PollDeferred):
                self.fetch()
            self.assertEqual(network.call_count, 1)
        with (
            patch("github_poll.time.time", return_value=5090),
            patch("github_poll.urlopen", return_value=self.response({})),
        ):
            self.fetch()

    def test_unchanged_runs_still_discovers_new_verifier_job(self):
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
        job = {
            "id": 123,
            "name": f"Verify swe HTTPS ({REQUEST['digest']})",
            "head_sha": REQUEST["commit"],
            "status": "in_progress",
        }
        responses = [
            self.response({"workflow_runs": [run]}, ETag='"runs"'),
            self.response({"jobs": []}, ETag='"queued"'),
            HTTPError("https://api.github.com/", 304, "unchanged", {}, BytesIO()),
            self.response({"jobs": [job]}, ETag='"running"'),
        ]
        with (
            patch("github_poll.urlopen", side_effect=responses) as network,
            patch("auto_deploy.api", side_effect=lambda path: self.fetch(path)),
        ):
            self.assertIsNone(discover([0, 0]))
            self.assertEqual(discover([0, 0]), REQUEST)
            self.assertEqual(network.call_count, 4)
