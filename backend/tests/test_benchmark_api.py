import asyncio
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

from app.workout_schemas import WorkoutInput
from scripts import benchmark_online, benchmark_resources
from scripts.benchmark_api import (
    BenchmarkError,
    measure,
    percentiles,
    validate_origin,
    workout_payload,
)


@pytest.mark.asyncio
async def test_benchmark_measures_requested_samples_with_a_concurrency_ceiling():
    active = peak = 0

    async def sample():
        nonlocal active, peak
        active += 1
        peak = max(active, peak)
        await asyncio.sleep(0)
        active -= 1

    result = await measure(sample, concurrency=4, count=9)

    assert peak == result["max_in_flight"] == 4
    assert result["attempted"] == result["successful"] == 9
    assert result["errors"] == {}
    assert result["latency_ms"]["p99"] >= result["latency_ms"]["p50"] >= 0


@pytest.mark.asyncio
async def test_benchmark_stops_after_three_consecutive_failures():
    async def fail():
        raise BenchmarkError("http_503")

    result = await measure(fail, concurrency=1, count=50)

    assert result["attempted"] == 3
    assert result["errors"] == {"http_503": 3}
    assert result["stopped"]
    assert result["error_rate_percent"] == 100.0
    assert result["latency_ms"] == dict.fromkeys(("p50", "p95", "p99"))


def test_benchmark_inputs_match_contract_and_require_https():
    payload = workout_payload(datetime(2026, 11, 20, tzinfo=UTC))
    assert len(WorkoutInput.model_validate(payload).sets) == 3
    assert percentiles(range(1, 51)) == {"p50": 25, "p95": 48, "p99": 50}
    assert (
        validate_origin("https://example.test:8080/", None)
        == "https://example.test:8080"
    )
    for rejected in (
        "http://example.test",
        "https://user@example.test",
        "https://example.test/path",
    ):
        with pytest.raises(BenchmarkError):
            validate_origin(rejected, None)
    with pytest.raises(BenchmarkError):
        validate_origin("https://192.0.2.1", True)


@pytest.mark.parametrize(
    "args,confirmation,expected",
    [([], "", 0), (["--start"], "", 0), (["--start"], "START 130", 1)],
)
def test_owner_starts_one_new_run_only_after_confirmation(
    monkeypatch, tmp_path, args, confirmation, expected
):
    runs = []
    monkeypatch.setattr(sys, "argv", ["benchmark_online", *args])
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda prompt: confirmation)
    monkeypatch.setattr(benchmark_online, "STATE", tmp_path)
    monkeypatch.setattr(
        benchmark_online,
        "probe",
        lambda: ("https://test.invalid", {"commit": "a" * 40}),
    )
    monkeypatch.setattr(
        benchmark_online,
        "start",
        lambda origin, release, directory: runs.append(directory) or 0,
    )
    assert benchmark_online.main() == 0
    assert benchmark_online.main() == 0
    assert len(set(runs)) == 2 * expected
    assert all(directory.parent == tmp_path for directory in runs)


def test_headless_start_exits_before_connecting(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["benchmark_online", "--start"])
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    monkeypatch.setattr(
        benchmark_online, "probe", lambda: pytest.fail("unexpected connection")
    )
    with pytest.raises(SystemExit) as error:
        benchmark_online.main()
    assert error.value.code == 2


def test_cleanup_ignores_collisions_and_refuses_unknown_identity(monkeypatch, tmp_path):
    monkeypatch.setattr(
        benchmark_online, "remote", lambda *args: pytest.fail("unexpected SQL")
    )
    path = tmp_path / "identity.json"
    assert benchmark_online.cleanup(tmp_path) == {"registered": False}
    path.write_text(json.dumps({"user_id": None, "collision": True}))
    assert benchmark_online.cleanup(tmp_path) == {
        "registered": False,
        "collision": True,
    }
    path.write_text(json.dumps({"user_id": None, "collision": False}))
    with pytest.raises(RuntimeError, match="归属"):
        benchmark_online.cleanup(tmp_path)


def test_resource_sampler_exits_when_a_deploy_is_preparing(monkeypatch, tmp_path):
    state = tmp_path / ".local/state/repflow/auto-deploy"
    state.mkdir(parents=True)
    (state / "releases.json").write_text(
        json.dumps({"current": {"commit": "a" * 40}, "pending": {"phase": "prepare"}})
    )
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(sys, "argv", ["benchmark_resources", "--commit", "a" * 40])

    def docker_version(command, **kwargs):
        assert "info" in command
        return "2 1000000 x86_64 test"

    monkeypatch.setattr(benchmark_resources.subprocess, "check_output", docker_version)
    with pytest.raises(RuntimeError, match="deployment changed"):
        benchmark_resources.main()
