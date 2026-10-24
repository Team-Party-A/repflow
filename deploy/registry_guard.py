"""在发布前后核实 GHCR 包可见性，遇到权限或网络错误直接失败。"""

import argparse
import json
import logging
import os
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PACKAGE_NAMES = ("repflow-api", "repflow-postgres", "repflow-nginx")
PACKAGE_ROOT = "https://api.github.com/orgs/Team-Party-A/packages/container/"
PACKAGE_URL = PACKAGE_ROOT + "repflow-api"
logger = logging.getLogger(__name__)


def require_private(allow_missing=False, package_name="repflow-api"):
    if package_name not in PACKAGE_NAMES:
        raise RuntimeError("Unexpected GHCR package name")
    request = Request(
        PACKAGE_ROOT + package_name,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            package = json.load(response)
    except HTTPError as error:
        if error.code == 404 and allow_missing:
            return
        raise RuntimeError(f"GHCR metadata request failed: HTTP {error.code}") from None
    except (URLError, ValueError) as _:
        raise RuntimeError("GHCR metadata could not be verified") from None
    if not isinstance(package, dict) or package.get("visibility") != "private":
        raise RuntimeError("GHCR package visibility must be private")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-missing", action="store_true")
    parser.add_argument("--package", choices=PACKAGE_NAMES, default="repflow-api")
    try:
        arguments = parser.parse_args()
        require_private(arguments.allow_missing, arguments.package)
    except RuntimeError as error:
        logger.error("%s", error)
        raise SystemExit(1) from None
