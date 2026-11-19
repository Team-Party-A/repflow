"""读取发布窗口内的网络计数，结果包含同一接口上的背景流量。"""

import subprocess
from datetime import UTC, datetime
from pathlib import Path

PROC_ROOT = Path("/proc")


def _unavailable(reason):
    return {
        "scope": "unavailable",
        "interface": None,
        "rx_bytes": None,
        "tx_bytes": None,
        "reason": reason,
    }


def _dockerd_process():
    result = subprocess.run(
        ["systemctl", "--user", "show", "docker.service", "-p", "MainPID", "--value"],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    pending = [int(result.stdout.strip())]
    seen = set()
    while pending:
        pid = pending.pop()
        if pid <= 0 or pid in seen:
            continue
        seen.add(pid)
        process = PROC_ROOT / str(pid)
        try:
            if (process / "comm").read_text().strip() == "dockerd":
                return process
            children = process / "task" / str(pid) / "children"
            pending.extend(int(value) for value in children.read_text().split())
        except FileNotFoundError:
            # 子进程可在两次读取之间退出，继续检查其余子进程。
            continue
    raise ValueError("dockerd process unavailable")


def _interface_snapshot(process, scope):
    routes = []
    for line in (process / "net/route").read_text().splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 8 and fields[1] == "00000000" and int(fields[3], 16) & 1:
            routes.append((int(fields[6]), fields[0]))
    if not routes:
        raise ValueError("default route unavailable")
    interface = min(routes)[1]
    for line in (process / "net/dev").read_text().splitlines()[2:]:
        name, values = line.split(":", 1)
        if name.strip() == interface:
            counters = values.split()
            rx_bytes, tx_bytes = int(counters[0]), int(counters[8])
            if rx_bytes < 0 or tx_bytes < 0:
                raise ValueError("invalid network counters")
            namespace = (process / "ns/net").stat().st_ino
            return {
                "scope": f"{scope}:{namespace}",
                "interface": interface,
                "rx_bytes": rx_bytes,
                "tx_bytes": tx_bytes,
            }
    raise ValueError("default interface counters unavailable")


def snapshot_network():
    """优先读取 dockerd 网络空间，宿主回退及不可用情况均显式标记。"""
    try:
        return _interface_snapshot(_dockerd_process(), "docker_netns")
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        try:
            return _interface_snapshot(PROC_ROOT / "self", "host")
        except (OSError, ValueError, IndexError):
            return _unavailable("network_statistics_unavailable")


def network_delta(before, after):
    """只比较同一网络空间与接口，计数重置时不生成流量值。"""
    if (
        not isinstance(before.get("scope"), str)
        or before["scope"] == "unavailable"
        or not before.get("interface")
        or before["scope"] != after.get("scope")
        or before["interface"] != after.get("interface")
    ):
        return _unavailable("network_scope_changed_or_unavailable")
    counters = [
        before.get("rx_bytes"),
        before.get("tx_bytes"),
        after.get("rx_bytes"),
        after.get("tx_bytes"),
    ]
    if any(type(value) is not int or value < 0 for value in counters):
        return _unavailable("invalid_network_counters")
    if after["rx_bytes"] < before["rx_bytes"] or after["tx_bytes"] < before["tx_bytes"]:
        return _unavailable("network_counters_reset")
    return {
        "scope": before["scope"],
        "interface": before["interface"],
        "rx_bytes": after["rx_bytes"] - before["rx_bytes"],
        "tx_bytes": after["tx_bytes"] - before["tx_bytes"],
    }


def utc_now():
    return datetime.now(UTC).isoformat()
