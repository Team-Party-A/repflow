import copy
import json
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs, unquote, urlsplit

from image_cache import ImageCacheError, ImageIdentityError, image_cached

IMAGE = "ghcr.io/team-party-a/repflow-api@sha256:" + "1" * 64
COMMIT = "2" * 40


def metadata(available=True):
    return {
        "Descriptor": {"digest": IMAGE.split("@")[1]},
        "Manifests": [
            {
                "Kind": "image",
                "Available": available,
                "Descriptor": {
                    "platform": {"os": "linux", "architecture": "amd64"},
                },
            }
        ],
    }


def selected():
    return {
        "Os": "linux",
        "Architecture": "amd64",
        "Config": {
            "Labels": {"org.opencontainers.image.revision": COMMIT},
        },
    }


class ImageCacheTests(unittest.TestCase):
    def setUp(self):
        context = patch(
            "image_cache.subprocess.run",
            return_value=SimpleNamespace(stdout='"unix:///run/user/1000/docker.sock"'),
        )
        self.context = context.start()
        self.addCleanup(context.stop)
        connection = patch("image_cache._DockerConnection")
        self.connection = connection.start().return_value
        self.addCleanup(connection.stop)

    def responses(self, *items):
        responses = []
        for status, data in items:
            response = MagicMock(status=status)
            response.read.return_value = json.dumps(data).encode()
            response.__enter__.return_value = response
            responses.append(response)
        self.connection.getresponse.side_effect = responses
        return responses

    def check(self):
        return image_cached(IMAGE, COMMIT, platform="linux/amd64")

    def test_complete_matching_platform_skips_registry_access(self):
        data = metadata()
        data["Manifests"].append(
            {
                "Kind": "image",
                "Available": False,
                "Descriptor": {
                    "platform": {"os": "linux", "architecture": "arm64"},
                },
            }
        )
        self.responses((200, data), (200, selected()))
        self.assertTrue(self.check())
        arguments = self.context.call_args.args[0]
        self.assertEqual(arguments[:4], ["docker", "context", "inspect", "rootless"])
        self.assertNotIn("pull", arguments)
        first, second = [
            urlsplit(call.args[1]) for call in self.connection.request.call_args_list
        ]
        self.assertEqual(unquote(first.path), "/v1.56/images/" + IMAGE + "/json")
        self.assertEqual(parse_qs(first.query), {"manifests": ["true"]})
        self.assertEqual(
            json.loads(parse_qs(second.query)["platform"][0]),
            {"os": "linux", "architecture": "amd64"},
        )
        self.assertEqual(self.connection.close.call_count, 2)

    def test_partial_image_and_missing_image_need_pull(self):
        for status, data in ((404, {}), (200, metadata(False))):
            with self.subTest(status=status):
                self.responses((status, data))
                self.assertFalse(self.check())

    def test_image_removed_between_inspections_needs_pull(self):
        self.responses((200, metadata()), (404, {}))
        self.assertFalse(self.check())

    def test_other_platform_does_not_count_as_a_hit(self):
        data = metadata()
        data["Manifests"][0]["Descriptor"]["platform"]["architecture"] = "arm64"
        self.responses((200, data))
        with self.assertRaises(ImageIdentityError):
            self.check()

    def test_revision_and_platform_identity_must_match(self):
        cases = [selected(), selected(), selected()]
        cases[0]["Config"]["Labels"]["org.opencontainers.image.revision"] = "3" * 40
        cases[1]["Architecture"] = "arm64"
        cases[2]["Os"] = "windows"
        for data in cases:
            with self.subTest(data=data):
                self.responses((200, metadata()), (200, data))
                with self.assertRaises(ImageIdentityError):
                    self.check()

    def test_wrong_root_digest_is_rejected(self):
        data = metadata()
        data["Descriptor"]["digest"] = "sha256:" + "4" * 64
        self.responses((200, data))
        with self.assertRaises(ImageIdentityError):
            self.check()

    def test_unknown_availability_and_daemon_errors_fail_closed(self):
        missing = metadata()
        missing["Manifests"][0].pop("Available")
        for status, data in (
            (500, {"message": "private sentinel"}),
            (200, missing),
            (200, {}),
        ):
            with self.subTest(status=status, data=data):
                self.responses((status, data))
                with self.assertRaises(ImageCacheError) as failure:
                    self.check()
                self.assertNotIn("private sentinel", str(failure.exception))

    def test_malformed_manifest_metadata_fails_closed(self):
        cases = []
        for platform in (None, [], "linux/amd64"):
            data = metadata()
            data["Manifests"][0]["Descriptor"]["platform"] = platform
            cases.append(data)
        data = metadata()
        data["Manifests"] = [None]
        cases.append(data)
        for data in cases:
            with self.subTest(data=data):
                self.responses((200, data))
                with self.assertRaises(ImageCacheError):
                    self.check()

    def test_invalid_and_oversized_responses_fail_closed(self):
        for payload in (b"not JSON", b"[]", b"x" * (1024 * 1024 + 1)):
            with self.subTest(size=len(payload)):
                response = self.responses((200, {}))[0]
                response.read.return_value = payload
                with self.assertRaises(ImageCacheError):
                    self.check()

    def test_context_failure_and_socket_timeout_are_not_cache_misses(self):
        self.context.side_effect = subprocess.TimeoutExpired(["docker"], 5)
        with self.assertRaises(ImageCacheError):
            self.check()
        self.context.side_effect = None
        self.connection.request.side_effect = TimeoutError("private socket path")
        with self.assertRaises(ImageCacheError) as failure:
            self.check()
        self.assertNotIn("private socket path", str(failure.exception))

    def test_remote_context_and_invalid_digest_are_rejected(self):
        self.context.return_value.stdout = '"tcp://private.invalid:2375"'
        with self.assertRaises(ImageCacheError):
            self.check()
        self.context.reset_mock()
        for image in (
            "repflow-api:latest",
            IMAGE + "/../other",
            IMAGE.replace("repflow-api", "other"),
        ):
            with self.subTest(image=image), self.assertRaises(ValueError):
                image_cached(image, COMMIT, platform="linux/amd64")
        self.context.assert_not_called()

    def test_malformed_context_endpoint_fails_closed(self):
        for endpoint in (
            None,
            [],
            {},
            "unix://remote/socket",
            "unix:///socket?query=1",
        ):
            with self.subTest(endpoint=endpoint):
                self.context.return_value.stdout = json.dumps(endpoint)
                with self.assertRaises(ImageCacheError):
                    self.check()

    def test_native_linux_arm64_mapping(self):
        data, chosen = copy.deepcopy(metadata()), selected()
        data["Manifests"][0]["Descriptor"]["platform"]["architecture"] = "arm64"
        chosen["Architecture"] = "arm64"
        for machine in ("aarch64", "arm64"):
            with (
                self.subTest(machine=machine),
                patch("image_cache.host_platform.system", return_value="Linux"),
                patch("image_cache.host_platform.machine", return_value=machine),
            ):
                self.responses((200, data), (200, chosen))
                self.assertTrue(image_cached(IMAGE, COMMIT))
