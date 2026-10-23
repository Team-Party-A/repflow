"""在发布前后核实 GHCR 包可见性，遇到权限或网络错误直接失败。"""

import argparse
import json
import logging
import os
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PACKAGE_URL = "https://api.github.com/orgs/Team-Party-A/packages/container/repflow-api"
logger = logging.getLogger(__name__)


def require_private(allow_missing=False):
    request = Request(
        PACKAGE_URL,
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
    try:
        require_private(parser.parse_args().allow_missing)
    except RuntimeError as error:
        logger.error("%s", error)
        raise SystemExit(1) from None
