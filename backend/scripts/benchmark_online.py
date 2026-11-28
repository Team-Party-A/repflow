"""由负责人启动一轮线上基线，并保存该轮的监控、报告和清理回执。"""

import argparse
import asyncio
import fcntl
import json
import logging
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID

import httpx

from scripts.benchmark_api import execute, validate_origin

SCRIPTS = Path(__file__).resolve().parent
SSH = ("ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "swe")
STATE = Path.home() / ".local" / "state" / "repflow" / "benchmark"
LOG = logging.getLogger(__name__)
# 读取已登记的发布和公开证书。地址仅用于本轮 HTTPS 连接。
PROBE = """\
import ipaddress, json, ssl, subprocess, sys
from pathlib import Path
root = Path.home() / ".local/state/repflow"
release = json.loads((root / "auto-deploy/releases.json").read_text())
current = release["current"]
def inspect(name, template):
    return subprocess.check_output(
        ["docker", "--context", "rootless", "inspect", "-f", template, "repflow-" + name + "-1"],
        text=True, timeout=8,
    ).strip()
certificate = ssl._ssl._test_decode_cert(str(root / "tls/letsencrypt/live/repflow-ip/fullchain.pem"))
addresses = [value for kind, value in certificate["subjectAltName"] if kind == "IP Address"]
if len(addresses) != 1 or not ipaddress.ip_address(addresses[0]).is_global:
    raise ValueError("unexpected certificate identity")
if release["pending"] or inspect("api", '{{.State.Health.Status}} {{.Config.Image}} {{index .Config.Labels "org.opencontainers.image.revision"}}') != " ".join(("healthy", current["image"], current["commit"])):
    raise RuntimeError("release pending, identity changed or api unhealthy")
if inspect("db", "{{.State.Health.Status}}") != "healthy" or inspect("nginx", "{{.State.Status}}") != "running":
    raise RuntimeError("database or nginx unavailable")
address = ipaddress.ip_address(addresses[0])
host = str(address) if address.version == 4 else "[" + str(address) + "]"
sys.stdout.write(json.dumps({"origin": "https://" + host + ":8080", "commit": current["commit"],
                            "image": current["image"].split("@")[-1]}))
"""


def remote(command, data):
    result = subprocess.run(
        [*SSH, shlex.join(command)], input=data, capture_output=True, timeout=30
    )
    if result.returncode:
        raise RuntimeError("SSH 检查或清理失败，请查本轮回执")
    return result.stdout.decode()


def probe():
    data = json.loads(remote(["python3", "-"], PROBE.encode()))
    origin = validate_origin(data.pop("origin"), None)
    if not re.fullmatch(r"[0-9a-f]{40}", data["commit"]) or not re.fullmatch(
        r"sha256:[0-9a-f]{64}", data["image"]
    ):
        raise ValueError("发布标识无效")
    with httpx.Client(trust_env=False, timeout=5) as client:
        response = client.get(origin + "/health")
        if response.status_code != 200 or response.json() != {"status": "ok"}:
            raise RuntimeError("公网健康检查失败")
    return origin, data


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def cleanup(directory):
    manifest = directory / "identity.json"
    if not manifest.exists() or not manifest.stat().st_size:
        return {"registered": False}
    identity = json.loads(manifest.read_text())
    if identity["collision"]:
        return {"registered": False, "collision": True}
    if not identity["user_id"] or not re.fullmatch(
        r"rfbench_[0-9a-f]{20}", identity["username"]
    ):
        raise RuntimeError("注册归属待核对，已保留本轮私有清单")
    user_id = str(UUID(identity["user_id"]))
    command = [
        "docker",
        "--context",
        "rootless",
        "exec",
        "-i",
        "repflow-db-1",
        "sh",
        "-ceu",
        'exec psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v bench_username="$1" '
        '-v bench_user_id="$2" -v bench_apply="$3"',
        "-",
        identity["username"],
        user_id,
    ]
    sql = (SCRIPTS / "benchmark_cleanup.sql").read_bytes()
    receipt = {}
    for mode in ("off", "on"):
        output = remote([*command, mode], sql)
        counts = re.search(
            r"Verified test account\. Sessions (\d+) Workouts (\d+) Sets (\d+)", output
        )
        if not counts or (mode == "on" and "Verified no remaining rows." not in output):
            raise RuntimeError("定向清理回执不完整")
        receipt[mode] = dict(
            zip(
                ("sessions", "workouts", "sets"), map(int, counts.groups()), strict=True
            )
        )
    return {
        "registered": True,
        "dry_run": receipt["off"],
        "cleared": receipt["on"],
        "verified": True,
    }


async def measure(origin, directory, sampler, ca_file=None):
    with (
        (directory / "report.json").open("x") as report,
        (directory / "identity.json").open("x") as identity,
    ):
        task = asyncio.create_task(
            execute(
                SimpleNamespace(samples=50, ca_file=ca_file), origin, report, identity
            )
        )
        try:
            while not task.done():
                if sampler.poll() is not None:
                    raise RuntimeError("监控中断或发布发生变化")
                await asyncio.wait({task}, timeout=1)
            return await task
        finally:
            if not task.done():
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)


def start(origin, release, directory):
    save(directory / "release-before.json", release)
    resources = directory / "resources.jsonl"
    args = ["python3", "-u", "-", "--seconds", "690", "--commit", release["commit"]]
    with (
        (SCRIPTS / "benchmark_resources.py").open("rb") as script,
        resources.open("xb") as output,
    ):
        sampler = subprocess.Popen(
            [*SSH, shlex.join(args)],
            stdin=script,
            stdout=output,
            stderr=subprocess.DEVNULL,
        )
        try:
            # 首行是机器配置。另取三次负载前采样，再发业务请求。
            deadline = time.monotonic() + 30
            while resources.read_bytes().count(b"\n") < 4:
                if sampler.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("未收到三组服务器资源样本")
                time.sleep(0.25)
            code = asyncio.run(measure(origin, directory, sampler))
        finally:
            if sampler.poll() is None:
                sampler.terminate()
            try:
                sampler.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sampler.kill()
                sampler.wait(timeout=5)
            try:
                save(directory / "cleanup.json", cleanup(directory))
            finally:
                _, after = probe()
                save(directory / "release-after.json", after)
                if after != release:
                    raise RuntimeError("测量期间发布版本发生变化")
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--start", action="store_true", help="由负责人在终端启动新的一轮测量"
    )
    args = parser.parse_args()
    if args.start and not sys.stdin.isatty():
        parser.error("启动需要负责人操作交互终端")
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        origin, release = probe()
        LOG.info("线上版本 %s，HTTPS、服务和发布状态已检查。", release["commit"][:12])
        if not args.start:
            return 0
        if (
            input(
                "本轮并发 1/2/4，每档每场景 50 个样本。输入 START 130 启动，回车退出："
            ).strip()
            != "START 130"
        ):
            return 0
        os.umask(0o077)
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (STATE / "active.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            origin, current = probe()
            if current != release:
                raise RuntimeError("确认期间发布版本发生变化")
            prefix = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-")
            directory = Path(tempfile.mkdtemp(prefix=prefix, dir=STATE))
            LOG.info("本轮私有结果目录 %s", directory)
            return start(origin, release, directory)
    except KeyboardInterrupt:
        return 130
    except (
        OSError,
        ValueError,
        RuntimeError,
        httpx.HTTPError,
        subprocess.SubprocessError,
    ) as error:
        # 第三方异常可携带实际 HTTPS 地址；业务错误仅含固定文本。
        detail = str(error) if type(error) is RuntimeError else type(error).__name__
        LOG.error("基线未完成，原因 %s。请检查本轮私有结果目录。", detail)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
