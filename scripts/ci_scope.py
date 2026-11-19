"""按实际检出的 Git 树判断固定 CI 门禁是否需要运行完整测试。"""

import json
import os
import re
import subprocess
import sys

SHA = re.compile(r"[0-9a-f]{40}")
SHARED = {b"scripts/ci_scope.py", b"scripts/test_ci_scope.py"}


def git(*args):
    return subprocess.check_output(["git", *args])


def needs_checks(module, event, payload, head):
    if event == "pull_request":
        base = payload["pull_request"]["base"]["sha"]
    elif event == "merge_group":
        base = payload["merge_group"]["base_sha"]
    elif event == "push":
        base = payload["before"]
    else:
        raise ValueError("unexpected workflow event")

    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise ValueError("expected full Git SHAs")
    if git("rev-parse", "HEAD").strip().decode() != head:
        raise ValueError("the checkout does not match GITHUB_SHA")
    if event == "push" and base == "0" * 40:
        return True

    git("merge-base", "--is-ancestor", base, head)
    paths = git("diff", "--name-only", "-z", "--no-renames", base, head, "--")
    prefixes = (b"apps/apple/",) if module == "apple" else (b"backend/", b"deploy/")
    workflow = f".github/workflows/{module}.yml".encode()
    return any(
        path in SHARED or path == workflow or path.startswith(prefixes)
        for path in paths.split(b"\0")
    )


if __name__ == "__main__":
    module = sys.argv[1]
    if module not in {"apple", "backend"}:
        raise SystemExit("unknown CI module")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
        required = needs_checks(
            module,
            os.environ["GITHUB_EVENT_NAME"],
            json.load(source),
            os.environ["GITHUB_SHA"],
        )
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"required={str(required).lower()}\n")
