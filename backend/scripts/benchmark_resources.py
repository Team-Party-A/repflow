"""Sample existing Docker resource counters for a bounded benchmark window."""

import argparse
import json
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path


def emit(record):
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", default="rootless")
    parser.add_argument("--project", default="repflow")
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("--commit", help="在部署开始或当前提交变化时停止采样")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 720:
        parser.error("--seconds must be between 5 and 720")

    docker = ["docker", "--context", args.context]
    names = {
        f"{args.project}-{service}-1": service for service in ("api", "db", "nginx")
    }
    host = subprocess.check_output(
        [
            *docker,
            "info",
            "-f",
            "{{.NCPU}} {{.MemTotal}} {{.Architecture}} {{.ServerVersion}}",
        ],
        text=True,
        timeout=10,
    ).split()
    cores, memory, architecture, version = host
    emit(
        {
            "host_logical_cpus": int(cores),
            "host_memory_bytes": int(memory),
            "architecture": architecture,
            "docker_version": version,
        }
    )
    deadline = time.monotonic() + args.seconds
    command = [
        *docker,
        "stats",
        "--no-stream",
        "--format",
        "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}",
        *names,
    ]
    while time.monotonic() < deadline:
        if args.commit:
            release = json.loads(
                (
                    Path.home() / ".local/state/repflow/auto-deploy/releases.json"
                ).read_text()
            )
            if release["pending"] or release["current"]["commit"] != args.commit:
                raise RuntimeError("deployment changed during the benchmark")
        data = subprocess.check_output(command, text=True, timeout=8).splitlines()
        snapshot = {}
        for line in data:
            name, cpu, memory = line.split("|")
            snapshot[names[name]] = {
                "cpu_percent": float(cpu.rstrip("%")),
                "memory": memory,
            }
        if set(snapshot) != set(names.values()):
            raise RuntimeError("Docker stats did not return all three services")
        emit({"at": datetime.now(UTC).isoformat(), "services": snapshot})
        time.sleep(1)


if __name__ == "__main__":
    main()
