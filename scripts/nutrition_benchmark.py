"""在独立 RepFlow 环境采样并分别统计原始和人工确认的结果。"""

import argparse
import csv
import getpass
import json
import math
import secrets
import subprocess
import sys
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from uuid import UUID, uuid4

DATA = Path(__file__).resolve().parents[1] / "docs/acceptance/nutrition"
FIELDS = ("carbs_g", "protein_g", "fat_g", "energy_kcal")


def rows(path):
    with path.open(newline="", encoding="utf-8-sig") as source:
        return list(csv.DictReader(source))


def write(path, records):
    with path.open("w", newline="", encoding="utf-8") as destination:
        writer = csv.DictWriter(destination, fieldnames=records[0])
        writer.writeheader()
        writer.writerows(records)


def api(base, path, *, token=None, body=None, key=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if isinstance(body, dict):
        body = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif body is not None:
        headers["Content-Type"] = "image/jpeg"
    if key:
        headers["Idempotency-Key"] = str(key)
    request = Request(base + "/api/v1/" + path, data=body, headers=headers)
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def reference_photo(row):
    url = row["rgb_source"]
    if urlparse(url).hostname != "storage.googleapis.com" or not url.startswith(
        "https://storage.googleapis.com/nutrition5k_dataset/"
    ):
        raise ValueError("参考餐盘图片地址不在数据集内")
    with tempfile.TemporaryDirectory(prefix="repflow-plate-") as scratch:
        path = Path(scratch)
        with urlopen(url, timeout=30) as response:
            raw = response.read(16 * 1024 * 1024 + 1)
        if len(raw) != int(row["rgb_bytes"]) or not raw.startswith(
            b"\x89PNG\r\n\x1a\n"
        ):
            raise ValueError("参考餐盘图片与选样记录不符")
        (path / "image.png").write_bytes(raw)
        subprocess.run(
            [
                "sips",
                "-Z",
                "1600",
                "-s",
                "format",
                "jpeg",
                "-s",
                "formatOptions",
                "78",
                str(path / "image.png"),
                "--out",
                str(path / "photo.jpg"),
            ],
            capture_output=True,
            check=True,
        )
        return (path / "photo.jpg").read_bytes()


def capture(args, samples, meals):
    base = args.api.rstrip("/")
    address = urlparse(base)
    if address.scheme != "https" and not (
        address.scheme == "http"
        and address.hostname in ("localhost", "127.0.0.1", "::1")
    ):
        raise ValueError("测试服务须使用 HTTPS 或本机回环地址")
    if args.confirmed and not args.username:
        raise ValueError("读取确认后的餐次需使用其所属测试账号")
    if args.username:
        credentials = {
            "username": args.username,
            "password": getpass.getpass("测试账号密码："),
        }
        token = api(base, "auth/login", body=credentials)["access_token"]
    else:
        token = api(
            base,
            "auth/register",
            body={
                "username": "plate_" + uuid4().hex[:16],
                "password": secrets.token_urlsafe(32),
            },
        )["access_token"]
    meal_ids = json.loads(args.confirmed.read_text()) if args.confirmed else {}
    by_sample = {row["sample"]: row for row in samples}
    for row in meals:
        sample, stage = row["sample"], row["stage"]
        if args.command == "confirm" and stage == "raw":
            continue
        if stage == "user_confirmed" and sample not in meal_ids:
            continue
        accepted_at = None
        receipt_path = args.output / (sample + "-" + stage + ".json")
        try:
            if stage == "raw":
                photo = reference_photo(by_sample[sample])
                job = api(
                    base, "nutrition/analyses", token=token, body=photo, key=uuid4()
                )
                del photo
                accepted_at = time.monotonic()
                receipt = {"analysis_id": str(UUID(job["id"]))}
                receipt_path.write_text(json.dumps(receipt))
                while job["status"] in ("queued", "processing"):
                    if time.monotonic() - accepted_at > 115:
                        raise TimeoutError
                    time.sleep(2)
                    job = api(
                        base, "nutrition/analyses/" + str(UUID(job["id"])), token=token
                    )
                if job["status"] != "ready":
                    row.update(status=job["status"], failure_reason=job["failure_code"])
                    continue
                items = job["items"]
                for field in FIELDS:
                    measures = [
                        None
                        if item["grams"] is None
                        or item["food"]["per_100g"][field] is None
                        else item["grams"] * item["food"]["per_100g"][field] / 100
                        for item in items
                    ]
                    row[field] = "" if None in measures else sum(measures)
                receipt["items"] = items
            else:
                meal = api(
                    base, "nutrition/meals/" + str(UUID(meal_ids[sample])), token=token
                )
                for field in FIELDS:
                    row[field] = (
                        meal["totals"][field]
                        if meal["totals"][field] is not None
                        else ""
                    )
                receipt = {"items": meal["items"]}
            row["status"] = "ok"
            receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
        except (
            OSError,
            HTTPError,
            URLError,
            ValueError,
            KeyError,
            subprocess.CalledProcessError,
        ) as error:
            row["status"] = "failed"
            row["failure_reason"] = (
                f"HTTP {error.code}"
                if isinstance(error, HTTPError)
                else type(error).__name__
            )
        finally:
            if accepted_at is not None:
                row["latency_ms"] = round(1000 * (time.monotonic() - accepted_at))
            row["run_id"] = args.output.name
            write(args.output / "observations-meals.csv", meals)


def attach_metrics(directory, source):
    observations = rows(directory / "observations-meals.csv")
    for row in observations:
        receipt = directory / (row["sample"] + "-raw.json")
        if row["stage"] != "raw" or not receipt.is_file():
            continue
        ident = UUID(json.loads(receipt.read_text())["analysis_id"])
        metrics = source / (str(ident) + ".json")
        if not metrics.is_file():
            continue
        values = json.loads(metrics.read_text())
        for key in (
            "lookups_unique",
            "cache_hits_unique",
            "vision_model",
            "text_model",
        ):
            row[key] = values.get(key, "")
        for model in ("vision", "text"):
            for key, direction in (
                ("prompt_tokens", "input"),
                ("completion_tokens", "output"),
            ):
                row[f"{model}_{direction}_tokens"] = values.get(
                    model + "_usage", {}
                ).get(key, "")
        row["cost"] = values.get("cost_cny")
        row["currency"], row["rate_reference"] = (
            "CNY",
            json.dumps(values.get("rates_cny_per_million", {})),
        )
    write(directory / "observations-meals.csv", observations)


def number(value):
    if value in (None, ""):
        return None
    value = float(value)
    if not math.isfinite(value) or value < 0:
        raise ValueError("测量值须为非负有限数")
    return value


def score(reference, ref_items, meals, items):
    dish = {r["sample"]: r for r in reference}
    weights = {(r["sample"], r["ingredient_id"]): float(r["grams"]) for r in ref_items}
    report = {}
    for stage in ("raw", "user_confirmed"):
        for group in ["all", *sorted({r["group"] for r in reference})]:
            selected = {
                sample
                for sample, r in dish.items()
                if group == "all" or r["group"] == group
            }
            observations = [
                r for r in meals if r["stage"] == stage and r["sample"] in selected
            ]
            totals = {k: [] for k in FIELDS}
            percentages = defaultdict(list)
            elapsed, costs, hits, lookups = [], [], 0, 0
            states = Counter()
            for r in observations:
                states[r["status"] or "unmeasured"] += 1
                if number(r["latency_ms"]) is not None:
                    elapsed.append(number(r["latency_ms"]))
                if r["currency"] == "CNY" and number(r["cost"]) is not None:
                    costs.append(number(r["cost"]))
                if (
                    number(r["cache_hits_unique"]) is not None
                    and number(r["lookups_unique"]) is not None
                ):
                    hits += number(r["cache_hits_unique"])
                    lookups += number(r["lookups_unique"])
                if r["status"] != "ok":
                    continue
                for field in FIELDS:
                    actual = number(r[field])
                    if actual is None:
                        continue
                    expected = float(dish[r["sample"]][field])
                    delta = abs(expected - actual)
                    totals[field].append(delta)
                    if expected > 0:
                        percentages[field].append(100 * delta / expected)
            counts = Counter()
            mass = []
            seen = set()
            visibility = defaultdict(Counter)
            for r in items:
                if (
                    r["sample"] not in selected
                    or r["stage"] != stage
                    or not r["matched_or_missed_or_extra"]
                ):
                    continue
                outcome = r["matched_or_missed_or_extra"]
                if outcome not in ("matched", "missed", "extra"):
                    raise ValueError("逐项对齐请使用 matched、missed 或 extra")
                ident = (r["sample"], r["reference_ingredient_id"])
                if outcome != "extra":
                    if ident not in weights or ident in seen:
                        raise ValueError("逐项对齐有重复或无效的参考食材")
                    seen.add(ident)
                counts[outcome] += 1
                visibility[r["visible_before_inference"] or "unlabelled"][outcome] += 1
                observed = number(r["observed_g"])
                if outcome == "matched" and observed is not None:
                    mass.append(abs(observed - weights[ident]))
            report[stage + "/" + group] = {
                "plates": len(selected),
                "states": states,
                "ingredients": counts,
                "visibility": visibility,
                "mass_mae_g": mean(mass) if mass else None,
                "mass_n": len(mass),
                "nutrients": {
                    f: {
                        "mae": mean(v) if v else None,
                        "n": len(v),
                        "mape_pct": mean(percentages[f]) if percentages[f] else None,
                        "mape_n": len(percentages[f]),
                    }
                    for f, v in totals.items()
                },
                "latency_ms_mean": mean(elapsed) if elapsed else None,
                "latency_n": len(elapsed),
                "cache_hits": hits,
                "lookups": lookups,
                "cache_hit_rate": hits / lookups if lookups else None,
                "cost_cny_mean": mean(costs) if costs else None,
                "cost_n": len(costs),
            }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_args = commands.add_parser("capture")
    capture_args.add_argument("--api", required=True)
    capture_args.add_argument("--output", type=Path, required=True)
    capture_args.add_argument("--username")
    capture_args.add_argument(
        "--confirmed", type=Path, help="sample 到已确认餐次 UUID 的 JSON"
    )
    confirmation = commands.add_parser("confirm")
    confirmation.add_argument("--api", required=True)
    confirmation.add_argument("--username", required=True)
    confirmation.add_argument("--confirmed", type=Path, required=True)
    confirmation.add_argument(
        "--output", type=Path, required=True, help="原始采样运行目录"
    )
    enrich = commands.add_parser("metrics")
    enrich.add_argument("run", type=Path)
    enrich.add_argument(
        "source", type=Path, help="服务端导出的 <analysis_id>.json 目录"
    )
    scoring = commands.add_parser("score")
    scoring.add_argument("run", type=Path)
    args = parser.parse_args()
    references = rows(DATA / "reference-meals.csv")
    if args.command == "capture":
        args.output.mkdir(parents=True, exist_ok=False)
        meals = rows(DATA / "observations-meals.csv")
        write(
            args.output / "observations-items.csv",
            rows(DATA / "observations-items.csv"),
        )
        capture(args, references, meals)
    elif args.command == "confirm":
        capture(args, references, rows(args.output / "observations-meals.csv"))
    elif args.command == "metrics":
        attach_metrics(args.run, args.source)
    else:
        report = score(
            references,
            rows(DATA / "reference-items.csv"),
            rows(args.run / "observations-meals.csv"),
            rows(args.run / "observations-items.csv"),
        )
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
