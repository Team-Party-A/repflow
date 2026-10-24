"""使用现有 Docker/Buildx 同步官方固定摘要镜像；默认仅检查本地源镜像。"""

import argparse
import json
import logging
import os
import re
import subprocess
from pathlib import Path

from registry_guard import require_private

COMPOSE_FILE = Path(__file__).with_name("compose.yaml")
MIRRORS = (
    ("db", "postgres", "repflow-postgres", "POSTGRES_IMAGE"),
    ("nginx", "nginx", "repflow-nginx", "NGINX_IMAGE"),
)
logger = logging.getLogger(__name__)


def docker_json(*arguments, environment=None):
    result = subprocess.run(
        ["docker", *arguments],
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def source_images():
    # 版本以主 Compose 为唯一来源，隔离真实部署配置和密码。
    environment = dict(os.environ, API_IMAGE="unused", POSTGRES_PASSWORD="source-check")
    config = docker_json(
        "compose",
        "--env-file",
        os.devnull,
        "-f",
        str(COMPOSE_FILE),
        "config",
        "--format",
        "json",
        environment=environment,
    )
    sources = []
    for service, upstream, package, variable in MIRRORS:
        source = config["services"][service]["image"]
        if not re.fullmatch(rf"{upstream}:[\w.-]+@sha256:[0-9a-f]{{64}}", source):
            raise RuntimeError(f"Expected a pinned official image for {service}")
        sources.append((source, package, variable))
    return sources


def require_release_environment():
    if os.environ.get("GITHUB_EVENT_NAME") != "push" or os.environ.get(
        "GITHUB_REF"
    ) not in ("refs/heads/dev", "refs/heads/main"):
        raise RuntimeError("Mirror publication requires a dev/main push")
    commit = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("Expected a full Git commit SHA")
    return commit


def image_identity(metadata, architecture):
    if metadata.get("Architecture") != architecture or metadata.get("Os") != "linux":
        raise RuntimeError("Source image platform does not match the native runner")
    identity = metadata.get("Id", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", identity):
        raise RuntimeError("Source image has no valid configuration digest")
    return identity


def verify_copy(manifest, identity):
    if manifest.get("config", {}).get("digest") != identity:
        raise RuntimeError("Mirror configuration differs from the official image")


def verify_index(manifest):
    entries = manifest.get("manifests", [])
    platforms = {
        (
            item.get("platform", {}).get("os"),
            item.get("platform", {}).get("architecture"),
        )
        for item in entries
    }
    if len(entries) != 2 or platforms != {("linux", "amd64"), ("linux", "arm64")}:
        raise RuntimeError("Mirror index must contain both native architectures")


def check_or_publish(publish):
    commit = require_release_environment() if publish else None
    architecture = os.environ.get("IMAGE_ARCH")
    if architecture not in ("amd64", "arm64"):
        raise RuntimeError("Set IMAGE_ARCH to amd64 or arm64")
    for source, package, _ in source_images():
        if publish:
            require_private(allow_missing=True, package_name=package)
            subprocess.run(
                ["docker", "pull", "--platform", f"linux/{architecture}", source],
                check=True,
            )
        identity = image_identity(
            docker_json("image", "inspect", source)[0], architecture
        )
        if publish:
            target = f"ghcr.io/team-party-a/{package}:sha-{commit}-{architecture}"
            subprocess.run(["docker", "tag", source, target], check=True)
            subprocess.run(
                ["docker", "push", "--platform", f"linux/{architecture}", target],
                check=True,
            )
            verify_copy(
                docker_json("buildx", "imagetools", "inspect", "--raw", target),
                identity,
            )
            require_private(package_name=package)
        logger.info(
            "official image verified: source=%s platform=linux/%s", source, architecture
        )


def publish_indexes():
    commit = require_release_environment()
    for source, package, variable in source_images():
        require_private(package_name=package)
        target = f"ghcr.io/team-party-a/{package}:sha-{commit}"
        subprocess.run(
            [
                "docker",
                "buildx",
                "imagetools",
                "create",
                "-t",
                target,
                target + "-amd64",
                target + "-arm64",
            ],
            check=True,
        )
        verify_index(docker_json("buildx", "imagetools", "inspect", "--raw", target))
        metadata = docker_json(
            "buildx", "imagetools", "inspect", target, "--format", "{{json .Manifest}}"
        )
        digest = metadata.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise RuntimeError("Mirror index has no valid digest")
        require_private(package_name=package)
        reference = f"ghcr.io/team-party-a/{package}@{digest}"
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"{variable}={reference}\n\nSource: `{source}`\n\n")
        logger.info("mirror index verified: %s=%s", variable, reference)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--publish", action="store_true")
    mode.add_argument("--manifest", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.manifest:
            publish_indexes()
        else:
            check_or_publish(arguments.publish)
    except (RuntimeError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        logger.error("mirror verification failed: %s", error)
        raise SystemExit(1) from None
