import os
import unittest
from unittest.mock import patch

from mirror_images import (
    check_or_publish,
    image_identity,
    publish_indexes,
    require_release_environment,
    source_images,
    verify_copy,
    verify_index,
)


class MirrorImageTests(unittest.TestCase):
    def test_publication_rejects_pull_requests_and_feature_pushes_before_docker(self):
        for event, branch in (
            ("pull_request", "refs/heads/dev"),
            ("push", "refs/heads/feature/backend-skeleton"),
        ):
            with (
                self.subTest(event=event, branch=branch),
                patch.dict(os.environ, GITHUB_EVENT_NAME=event, GITHUB_REF=branch),
                patch("mirror_images.docker_json") as docker,
            ):
                for publish in (
                    lambda: check_or_publish(publish=True),
                    publish_indexes,
                ):
                    with self.assertRaises(RuntimeError):
                        publish()
                docker.assert_not_called()

    @patch.dict(os.environ, IMAGE_ARCH="arm64", GITHUB_EVENT_NAME="pull_request")
    @patch("mirror_images.require_private")
    @patch("mirror_images.subprocess.run")
    @patch("mirror_images.docker_json")
    @patch("mirror_images.source_images")
    def test_default_check_neither_publishes_nor_uses_registry_credentials(
        self, sources, docker, commands, registry_guard
    ):
        sources.return_value = [
            ("postgres:18.6@sha256:" + "a" * 64, "repflow-postgres", "POSTGRES_IMAGE")
        ]
        docker.return_value = [
            {"Id": "sha256:" + "b" * 64, "Architecture": "arm64", "Os": "linux"}
        ]
        check_or_publish(publish=False)
        commands.assert_not_called()
        registry_guard.assert_not_called()

    def test_release_requires_full_commit_identity(self):
        with (
            patch.dict(
                os.environ,
                GITHUB_EVENT_NAME="push",
                GITHUB_REF="refs/heads/dev",
                GITHUB_SHA="short",
            ),
            self.assertRaises(RuntimeError),
        ):
            require_release_environment()

    @patch("mirror_images.docker_json")
    def test_source_configuration_excludes_real_credentials_and_requires_digest(
        self, docker
    ):
        for source in ("postgres:latest", "other.example/postgres@sha256:" + "a" * 64):
            with self.subTest(source=source):
                docker.return_value = {"services": {"db": {"image": source}}}
                with patch.dict(os.environ, POSTGRES_PASSWORD="must-stay-private"):
                    with self.assertRaises(RuntimeError):
                        source_images()
                    self.assertEqual(
                        docker.call_args.kwargs["environment"]["POSTGRES_PASSWORD"],
                        "source-check",
                    )
                    self.assertIn(os.devnull, docker.call_args.args)

    def test_copy_rejects_different_configuration_and_wrong_platform(self):
        identity = "sha256:" + "a" * 64
        metadata = {"Id": identity, "Architecture": "arm64", "Os": "linux"}
        self.assertEqual(image_identity(metadata, "arm64"), identity)
        with self.assertRaises(RuntimeError):
            image_identity(metadata, "amd64")
        verify_copy({"config": {"digest": identity}}, identity)
        with self.assertRaises(RuntimeError):
            verify_copy({"config": {"digest": "sha256:" + "b" * 64}}, identity)

    def test_index_rejects_missing_or_duplicate_architectures(self):
        amd64 = {"platform": {"os": "linux", "architecture": "amd64"}}
        arm64 = {"platform": {"os": "linux", "architecture": "arm64"}}
        verify_index({"manifests": [amd64, arm64]})
        for entries in ([amd64], [amd64, amd64], [amd64, arm64, arm64]):
            with self.subTest(entries=entries), self.assertRaises(RuntimeError):
                verify_index({"manifests": entries})
