"""GitHub runner 验证从公网实际切换的 swe 版本。"""

import http.client
import ipaddress
import logging
import os
import re
import sys
import time

from https_probe import TLSCheckError, get_https_json, probe

COMMIT = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
FAILED_STATES = {"failed", "rolled_back", "rollback_failed"}


def status_path(run_id, attempt):
    if type(run_id) is not int or type(attempt) is not int or run_id < 0 or attempt < 0:
        raise ValueError("invalid release run")
    return f"/.well-known/repflow-deploy/{run_id}-{attempt}.json"


def status_of(address, port, release, **options):
    path = status_path(release["run_id"], release["attempt"])
    data, _ = get_https_json(address, port, path, allow_missing=True, **options)
    if not isinstance(data, dict) or any(
        data.get(key) != value for key, value in release.items()
    ):
        return None
    state = data.get("state")
    return (
        state
        if isinstance(state, str) and state in {"candidate", "deployed", *FAILED_STATES}
        else None
    )


def check_release(
    address, port, release, action, *, expect_deployed, force_failure=False
):
    deadline = time.monotonic() + (18 * 60 if action == "verify" else 11 * 60)
    candidate_seen = False
    while time.monotonic() < deadline:
        try:
            state = status_of(address, port, release)
            if action == "verify" and state == "candidate":
                if not candidate_seen:
                    deadline = min(deadline, time.monotonic() + 45)
                    candidate_seen = True
                if force_failure:
                    raise RuntimeError("intentional failure for this release")
                probe(address, port)
                if status_of(address, port, release) == "candidate":
                    return "public HTTPS and candidate identity verified"
            if action == "confirm" and expect_deployed and state == "deployed":
                return "server recorded the verified release"
            if state in FAILED_STATES:
                if (
                    action == "confirm"
                    and not expect_deployed
                    and state != "rollback_failed"
                ):
                    return f"server reported {state}"
                raise RuntimeError(f"server reported {state}")
        except (OSError, ValueError, TLSCheckError, http.client.HTTPException):
            # 在候选上线、nginx 换容器或回退期间，入口可能短暂不可用。
            pass
        time.sleep(10)
    reason = (
        "public HTTPS remained unavailable"
        if candidate_seen
        else "timed out waiting for the matching release state"
    )
    raise RuntimeError(reason)


def main():
    action = sys.argv[1]
    if action not in {"verify", "confirm"}:
        raise ValueError("unknown release probe action")
    address = ipaddress.IPv4Address(os.environ["HTTPS_MONITOR_IP"])
    port = int(os.environ.get("HTTPS_MONITOR_PORT", "8080"))
    release = {
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
        "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "commit": os.environ["GITHUB_SHA"],
        "digest": os.environ["RELEASE_DIGEST"],
    }
    if (
        not address.is_global
        or not COMMIT.fullmatch(release["commit"])
        or not DIGEST.fullmatch(release["digest"])
    ):
        raise ValueError("invalid release identity or public address")
    result = check_release(
        str(address),
        port,
        release,
        action,
        expect_deployed=os.environ.get("VERIFY_RESULT") == "success",
        force_failure=os.environ.get("TEST_FAIL_COMMIT") == release["commit"],
    )
    logging.info("%s", result)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        main()
    except RuntimeError as error:
        logging.error("Release probe failed: %s", error)
        raise SystemExit(1) from None
    except Exception as error:
        logging.error("Release probe failed: kind=%s", type(error).__name__)
        raise SystemExit(1) from None
