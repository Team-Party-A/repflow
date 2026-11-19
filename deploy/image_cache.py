"""只读检查 Rootless Docker 中目标摘要及本机平台内容是否完整。"""

import http.client
import json
import platform as host_platform
import re
import socket
import subprocess
from urllib.parse import quote, urlencode, urlsplit

IMAGE = re.compile(r"ghcr\.io/team-party-a/repflow-api@(sha256:[0-9a-f]{64})")
COMMIT = re.compile(r"[0-9a-f]{40}")
MAX_RESPONSE_BYTES = 1024 * 1024


class ImageCacheError(RuntimeError):
    pass


class ImageIdentityError(ImageCacheError):
    pass


class _DockerConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def _inspect(socket_path, image, query, timeout):
    connection = _DockerConnection(socket_path, timeout)
    try:
        path = f"/v1.56/images/{quote(image, safe='')}/json?{urlencode(query)}"
        connection.request("GET", path)
        with connection.getresponse() as response:
            if response.status == 404:
                return None
            if response.status != 200:
                raise ImageCacheError(
                    f"local image inspection returned HTTP {response.status}"
                )
            payload = response.read(MAX_RESPONSE_BYTES + 1)
        if len(payload) > MAX_RESPONSE_BYTES:
            raise ImageCacheError("local image inspection response is too large")
        data = json.loads(payload)
        if not isinstance(data, dict):
            raise ImageCacheError("local image inspection returned invalid metadata")
        return data
    except (OSError, ValueError, http.client.HTTPException) as error:
        raise ImageCacheError(
            f"local image inspection failed: {type(error).__name__}"
        ) from None
    finally:
        connection.close()


def image_cached(
    image, expected_commit, *, context="rootless", platform=None, timeout=5
):
    """完整且身份一致才命中；缺失返回 False，未知状态和身份冲突抛异常。"""
    if not isinstance(image, str) or not isinstance(expected_commit, str):
        raise ValueError("expected an immutable RepFlow image and full commit")
    match = IMAGE.fullmatch(image)
    if not match or not COMMIT.fullmatch(expected_commit) or timeout <= 0:
        raise ValueError(
            "expected an immutable RepFlow image, full commit and positive timeout"
        )
    if platform is None:
        architecture = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(
            host_platform.machine().lower()
        )
        if host_platform.system() != "Linux" or architecture is None:
            raise ImageCacheError("local image checks require a supported Linux host")
        platform = f"linux/{architecture}"
    if platform not in {"linux/amd64", "linux/arm64"}:
        raise ValueError("unsupported deployment platform")
    operating_system, architecture = platform.split("/")
    expected_platform = {"os": operating_system, "architecture": architecture}
    try:
        result = subprocess.run(
            [
                "docker",
                "context",
                "inspect",
                context,
                "--format",
                "{{json .Endpoints.docker.Host}}",
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=timeout,
        )
        endpoint_value = json.loads(result.stdout)
        if not isinstance(endpoint_value, str):
            raise ImageCacheError("Docker context returned an invalid endpoint")
        endpoint = urlsplit(endpoint_value)
    except (OSError, ValueError, subprocess.SubprocessError, TypeError) as error:
        raise ImageCacheError(
            f"Docker context inspection failed: {type(error).__name__}"
        ) from None
    if (
        endpoint.scheme != "unix"
        or endpoint.netloc
        or endpoint.query
        or endpoint.fragment
        or not endpoint.path.startswith("/")
    ):
        raise ImageCacheError("Docker context must use a local Unix socket")

    # Engine 仅在未指定 platform 时返回各 manifest 的本地完整性。
    metadata = _inspect(endpoint.path, image, {"manifests": "true"}, timeout)
    if metadata is None:
        return False
    descriptor = metadata.get("Descriptor")
    if not isinstance(descriptor, dict) or descriptor.get("digest") != match[1]:
        raise ImageIdentityError("cached image root digest differs from the release")
    manifests = metadata.get("Manifests")
    if not isinstance(manifests, list) or any(
        not isinstance(item, dict) for item in manifests
    ):
        raise ImageCacheError("Docker did not return manifest availability")
    targets = []
    for item in manifests:
        if item.get("Kind") != "image":
            continue
        descriptor = item.get("Descriptor")
        item_platform = (
            descriptor.get("platform") if isinstance(descriptor, dict) else None
        )
        if not isinstance(item_platform, dict):
            raise ImageCacheError("Docker did not return image platform metadata")
        if all(
            item_platform.get(key) == value for key, value in expected_platform.items()
        ):
            targets.append(item)
    if len(targets) != 1:
        raise ImageIdentityError("cached image does not identify one matching platform")
    available = targets[0].get("Available")
    if type(available) is not bool:
        raise ImageCacheError("Docker did not provide complete-content availability")
    if not available:
        return False

    # 多架构索引的默认 inspect 可能选到其他平台，配置身份须显式指定平台。
    selected = _inspect(
        endpoint.path, image, {"platform": json.dumps(expected_platform)}, timeout
    )
    if selected is None:
        return False
    if (
        selected.get("Os") != operating_system
        or selected.get("Architecture") != architecture
    ):
        raise ImageIdentityError(
            "cached image platform differs from the deployment host"
        )
    config = selected.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    if (
        not isinstance(labels, dict)
        or labels.get("org.opencontainers.image.revision") != expected_commit
    ):
        raise ImageIdentityError("cached image revision differs from the release")
    return True
