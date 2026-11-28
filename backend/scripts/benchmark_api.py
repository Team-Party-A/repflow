"""Measure the RepFlow API with one disposable account per run."""

import argparse
import asyncio
import ipaddress
import json
import logging
import math
import os
import secrets
import ssl
from collections import Counter
from datetime import UTC, datetime, timedelta
from getpass import getpass
from pathlib import Path
from time import perf_counter
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import httpx

logger = logging.getLogger(__name__)
CONCURRENCY = (1, 2, 4)
SAMPLE_TIMEOUT = 12
QUERY_LIMIT = 10
QUERY_FIXTURES = 21
WORKOUTS = "/api/v1/workouts"
AUTH = "/api/v1/auth"


class BenchmarkError(Exception):
    """A short, safe error code for the results."""


def utc_now():
    return datetime.now(UTC)


def utc_text(timestamp):
    return timestamp.isoformat().replace("+00:00", "Z")


def validate_origin(origin, local_ca):
    parsed = urlsplit(origin)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise BenchmarkError("invalid_https_origin")
    if local_ca and not (
        parsed.hostname == "localhost"
        or ipaddress.ip_address(parsed.hostname).is_loopback
    ):
        raise BenchmarkError("custom_ca_requires_loopback")
    return origin.rstrip("/")


def percentiles(samples):
    if not samples:
        return dict.fromkeys(("p50", "p95", "p99"))
    ordered = sorted(samples)
    return {
        f"p{rank}": round(ordered[math.ceil(len(ordered) * rank / 100) - 1], 3)
        for rank in (50, 95, 99)
    }


async def measure(sample, concurrency, count):
    started = utc_now()
    durations = []
    errors = Counter()
    consecutive_errors = 0
    stopped = False
    in_flight = 0
    max_in_flight = 0
    tickets = iter(range(count))

    async def worker():
        nonlocal consecutive_errors, stopped, in_flight, max_in_flight
        for _ in tickets:
            if stopped:
                return
            start = perf_counter()
            in_flight += 1
            max_in_flight = max(in_flight, max_in_flight)
            try:
                async with asyncio.timeout(SAMPLE_TIMEOUT):
                    await sample()
            except (BenchmarkError, TimeoutError, httpx.TransportError) as error:
                code = (
                    str(error)
                    if isinstance(error, BenchmarkError)
                    else type(error).__name__
                )
                errors[code] += 1
                consecutive_errors += 1
                if consecutive_errors == 3:
                    stopped = True
            else:
                durations.append((perf_counter() - start) * 1000)
                consecutive_errors = 0
            finally:
                in_flight -= 1

    async with asyncio.TaskGroup() as workers:
        for _ in range(concurrency):
            workers.create_task(worker())
    failures = sum(errors.values())
    attempted = len(durations) + failures
    return {
        "started_at": started.isoformat(),
        "finished_at": utc_now().isoformat(),
        "concurrency": concurrency,
        "max_in_flight": max_in_flight,
        "attempted": attempted,
        "successful": len(durations),
        "errors": dict(errors),
        "error_rate_percent": round(100 * failures / attempted, 2),
        "latency_ms": percentiles(durations),
        "stopped": stopped,
    }


def workout_payload(started):
    return {
        "revision": 1,
        "record_kind": "actual",
        "started_at": utc_text(started),
        "ended_at": utc_text(started + timedelta(minutes=2)),
        "time_zone": "UTC",
        "sets": [
            {
                "set_id": str(uuid4()),
                "exercise_id": "dumbbell_curl",
                "final_rep_count": 8,
                "estimated_rep_count": None,
                "record_source": "manual",
                "weight_grams": 5000,
            }
            for _ in range(3)
        ],
    }


class Benchmark:
    def __init__(self, client, manifest):
        self.client = client
        self.manifest = manifest
        self.username = "rfbench_" + secrets.token_hex(10)
        self.credentials = {
            "username": self.username,
            "password": secrets.token_urlsafe(24),
        }
        self.token = None
        self.login_tokens = []
        self.uploaded_ids = []
        self.seed_ids = set()
        self.seed_start = utc_now().replace(microsecond=0) - timedelta(days=1)
        self.query_params = {
            "limit": QUERY_LIMIT,
            "started_from": utc_text(self.seed_start),
            "started_before": utc_text(self.seed_start + timedelta(hours=1)),
        }

    async def request(self, method, path, status, *, token=None, **kwargs):
        headers = {"Authorization": f"Bearer {token}"} if token else None
        response = await self.client.request(method, path, headers=headers, **kwargs)
        if response.status_code != status:
            raise BenchmarkError(f"http_{response.status_code}")
        if status == 204:
            return None
        try:
            payload = response.json()
        except ValueError:
            raise BenchmarkError("invalid_json") from None
        if not isinstance(payload, dict):
            raise BenchmarkError("invalid_response")
        return payload

    async def health(self):
        if await self.request("GET", "/health", 200) != {"status": "ok"}:
            raise BenchmarkError("unhealthy")

    def save_identity(self, user_id, *, collision=False):
        self.manifest.seek(0)
        self.manifest.truncate()
        json.dump(
            {"username": self.username, "user_id": user_id, "collision": collision},
            self.manifest,
        )
        self.manifest.write("\n")
        self.manifest.flush()

    async def setup(self):
        await self.health()
        self.save_identity(None)
        try:
            response = await self.request(
                "POST", f"{AUTH}/register", 201, json=self.credentials
            )
        except BenchmarkError as error:
            if str(error) == "http_409":
                self.save_identity(None, collision=True)
            raise
        try:
            self.user_id = str(UUID(response["user_id"]))
        except KeyError, ValueError, TypeError, AttributeError:
            raise BenchmarkError("invalid_user_id") from None
        self.save_identity(self.user_id)
        self.token = self.get_token(response)
        for minute in range(QUERY_FIXTURES):
            self.seed_ids.add(
                await self.upload(self.seed_start + timedelta(minutes=minute))
            )

    @staticmethod
    def get_token(response):
        token = response.get("access_token")
        if not isinstance(token, str) or not token:
            raise BenchmarkError("invalid_token_response")
        return token

    async def login(self):
        response = await self.request(
            "POST", f"{AUTH}/login", 200, json=self.credentials
        )
        token = self.get_token(response)
        self.login_tokens.append(token)
        if response.get("user_id") != self.user_id:
            raise BenchmarkError("unexpected_user_id")

    async def upload(self, started=None):
        workout_id = str(uuid4())
        response = await self.request(
            "PUT",
            f"{WORKOUTS}/{workout_id}",
            200,
            token=self.token,
            json=workout_payload(started or utc_now() - timedelta(minutes=2)),
        )
        self.uploaded_ids.append(workout_id)
        if response != {
            "workout_id": workout_id,
            "accepted_revision": 1,
            "deleted": False,
        }:
            raise BenchmarkError("invalid_upload_receipt")
        return workout_id

    async def paginated_query(self):
        first = await self.request(
            "GET", WORKOUTS, 200, token=self.token, params=self.query_params
        )
        cursor = first.get("next_cursor")
        if not isinstance(cursor, str) or not cursor:
            raise BenchmarkError("missing_cursor")
        second = await self.request(
            "GET",
            WORKOUTS,
            200,
            token=self.token,
            params={**self.query_params, "cursor": cursor},
        )
        seen = set()
        for page in (first, second):
            items = page.get("items")
            if not isinstance(items, list) or len(items) != QUERY_LIMIT:
                raise BenchmarkError("invalid_page_size")
            ids = {
                item.get("workout_id")
                for item in items
                if isinstance(item, dict) and isinstance(item.get("workout_id"), str)
            }
            if len(ids) != QUERY_LIMIT or not ids <= self.seed_ids or seen & ids:
                raise BenchmarkError("unexpected_page_items")
            seen.update(ids)

    async def run(self, count, stages):
        await self.setup()
        for concurrency in CONCURRENCY:
            for name in ("login", "upload", "paginated_query"):
                await self.health()
                sample = getattr(self, name)
                warmup = await measure(sample, concurrency, concurrency)
                if warmup["errors"]:
                    raise BenchmarkError("warmup_failed")
                result = await measure(sample, concurrency, count)
                stages.append(
                    {"scenario": name, "warmup_samples": concurrency, **result}
                )
                if result["stopped"]:
                    raise BenchmarkError("consecutive_errors")
                await self.health()

    async def cleanup(self, results):
        targets = [
            ("DELETE", f"{WORKOUTS}/{workout_id}", 200, self.token, {"revision": 2})
            for workout_id in self.uploaded_ids
        ]
        tokens = self.login_tokens + ([self.token] if self.token else [])
        targets.extend(("POST", f"{AUTH}/logout", 204, token, None) for token in tokens)
        results["api_attempts_planned"] = len(targets)
        results["api_successful"] = 0
        try:
            async with asyncio.timeout(45):
                for method, path, status, token, params in targets:
                    try:
                        await self.request(
                            method, path, status, token=token, params=params
                        )
                    except BenchmarkError, httpx.TransportError:
                        continue
                    results["api_successful"] += 1
        except TimeoutError:
            results["api_timed_out"] = True


async def execute(args, origin, report, manifest):
    verification = (
        ssl.create_default_context(cafile=str(args.ca_file)) if args.ca_file else True
    )
    timeout = httpx.Timeout(8, connect=3)
    async with httpx.AsyncClient(
        base_url=origin, timeout=timeout, verify=verification, trust_env=False
    ) as client:
        benchmark = Benchmark(client, manifest)
        results = {
            "started_at": utc_now().isoformat(),
            "sample_count_target": args.samples,
            "stages": [],
            "cleanup": {},
        }
        try:
            async with asyncio.timeout(600):
                await benchmark.run(args.samples, results["stages"])
        except (BenchmarkError, httpx.TransportError, TimeoutError) as error:
            results["error"] = (
                str(error)
                if isinstance(error, BenchmarkError)
                else type(error).__name__
            )
        except BaseException as error:
            results["error"] = type(error).__name__
            raise
        finally:
            await benchmark.cleanup(results["cleanup"])
            results["finished_at"] = utc_now().isoformat()
            json.dump(results, report, indent=2)
            report.write("\n")
    if "error" in results:
        logger.warning("benchmark stopped: %s", results["error"])
    return int("error" in results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cleanup-manifest", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=50)
    parser.add_argument("--ca-file", type=Path, help="本机独立测试库的临时 CA")
    args = parser.parse_args()
    if not 4 <= args.samples <= 50:
        parser.error("--samples must be between 4 and 50")
    logging.basicConfig(level=logging.WARNING)
    os.umask(0o077)
    try:
        origin = validate_origin(
            getpass("HTTPS 入口（隐去输入）: ").strip(), args.ca_file
        )
        with (
            args.output.open("x") as report,
            args.cleanup_manifest.open("x") as manifest,
        ):
            return asyncio.run(execute(args, origin, report, manifest))
    except (BenchmarkError, OSError, ValueError) as error:
        logger.error("benchmark could not start: %s", type(error).__name__)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
