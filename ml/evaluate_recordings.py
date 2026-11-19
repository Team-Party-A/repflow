"""按真实时间轴运行峰值/回位计次基线，输出分段与分层评估 JSON。"""

import argparse
import json
import logging
import math
import statistics
import sys
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path

from inspect_recording import VECTOR_FIELDS, inspect_recording

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class Parameters:
    field: str = "user_acceleration_g"
    axis: int = 0
    sign: int = 1
    window_s: float = 0.1
    peak: float = 0.15
    release: float = 0.05
    min_interval_s: float = 0.4
    max_gap_s: float = 0.2

    def validate(self):
        if self.field not in VECTOR_FIELDS[:2] or self.axis not in (0, 1, 2):
            raise ValueError("信号必须是用户加速度或角速度的 x/y/z 轴")
        if self.sign not in (-1, 1):
            raise ValueError("sign 必须为 -1 或 1")
        values = (
            self.window_s,
            self.peak,
            self.release,
            self.min_interval_s,
            self.max_gap_s,
        )
        if not all(math.isfinite(value) for value in values):
            raise ValueError("参数必须是有限数值")
        if self.window_s < 0 or self.min_interval_s < 0 or self.max_gap_s <= 0:
            raise ValueError("平滑窗口/最小间隔须非负，采样缺口阈值须大于 0")
        if self.peak <= self.release:
            raise ValueError("peak 必须大于 release")


def count_reps(recording, parameters):
    """低位出发、达到峰阈值、回到低位才加一；每段新建状态。"""
    group = recording["set"]
    start, end = (
        (group["start_s"], group["end_s"]) if group else (0, recording["duration_s"])
    )
    window = deque()
    total = 0.0
    previous = None
    last_event = None
    armed = reached_peak = False
    events = []
    gaps = 0
    processed = 0
    for sample in recording["samples"]:
        time = sample["t_s"]
        if not start <= time <= end:
            continue
        processed += 1
        if previous is not None and time - previous > parameters.max_gap_s:
            window.clear()
            total = 0.0
            armed = reached_peak = False
            gaps += 1
        previous = time
        value = sample[parameters.field][parameters.axis] * parameters.sign
        window.append((time, value))
        total += value
        while window[0][0] < time - parameters.window_s:
            total -= window.popleft()[1]
        smooth = total / len(window)
        if smooth <= parameters.release:
            if reached_peak and (
                last_event is None or time - last_event >= parameters.min_interval_s
            ):
                events.append({"t_s": time, "confirmed_at_s": time})
                last_event = time
            armed, reached_peak = True, False
        elif armed and smooth >= parameters.peak:
            reached_peak = True
    if processed < 2:
        raise ValueError("有效组内至少需要两个样本，不能把缺少输入解释为 0 次")
    return {
        "estimated_count": len(events),
        "events": events,
        "gap_count": gaps,
        "processed_sample_count": processed,
    }


def match_events(predicted, truth, tolerance):
    """有序事件一对一匹配；同一预测或真值最多使用一次。"""
    i = j = matched = 0
    while i < len(predicted) and j < len(truth):
        if predicted[i] < truth[j] - tolerance:
            i += 1
        elif truth[j] < predicted[i] - tolerance:
            j += 1
        else:
            matched += 1
            i += 1
            j += 1
    fp, fn = len(predicted) - matched, len(truth) - matched
    return {
        "tp": matched,
        "fp": fp,
        "fn": fn,
        "precision": matched / len(predicted) if predicted else None,
        "recall": matched / len(truth) if truth else None,
    }


def evaluate(path, parameters, tolerance):
    inspection = inspect_recording(path)
    recording = json.loads(Path(path).read_text(encoding="utf-8"))
    result = count_reps(recording, parameters)
    metadata = recording["metadata"]
    truth = inspection["ground_truth_count"]
    result.update(
        recording_id=recording["recording_id"],
        data_kind=recording["data_kind"],
        participant_id=metadata["participant_id"],
        activity=metadata["activity"],
        recording_kind=metadata["recording_kind"],
        duration_s=recording["duration_s"],
        ground_truth_count=truth,
        absolute_error=abs(result["estimated_count"] - truth)
        if truth is not None
        else None,
        event_scores=None,
        negative_scored=metadata["recording_kind"] == "negative"
        and not any(a["type"] == "ambiguous" for a in recording["annotations"]),
        interval_max_s=inspection["interval_max_s"],
        tail_gap_s=inspection["tail_gap_s"],
    )
    if truth is not None:
        result["event_scores"] = match_events(
            [event["t_s"] for event in result["events"]],
            [a["t_s"] for a in recording["annotations"] if a["type"] == "rep_complete"],
            tolerance,
        )
    return result


def summarize(rows):
    errors = [
        row["absolute_error"] for row in rows if row["absolute_error"] is not None
    ]
    negatives = [row for row in rows if row["negative_scored"]]
    negative_seconds = sum(row["duration_s"] for row in negatives)
    negative_count = sum(row["estimated_count"] for row in negatives)
    scored = [row["event_scores"] for row in rows if row["event_scores"] is not None]
    tp, fp, fn = (sum(score[key] for score in scored) for key in ("tp", "fp", "fn"))
    return {
        "recording_count": len(rows),
        "scored_set_count": len(errors),
        "unscored_set_count": sum(
            row["recording_kind"] == "exercise_set" and row["absolute_error"] is None
            for row in rows
        ),
        "mae": statistics.mean(errors) if errors else None,
        "within_one_fraction": sum(error <= 1 for error in errors) / len(errors)
        if errors
        else None,
        "worst_error": max(errors) if errors else None,
        "event_scores": {
            "tp": tp,
            "fp": fp,
            "fn": fn,
            "precision": tp / (tp + fp) if tp + fp else None,
            "recall": tp / (tp + fn) if tp + fn else None,
        },
        "negative_recording_count": len(negatives),
        "negative_seconds": negative_seconds,
        "negative_count": negative_count,
        "negative_count_per_minute": negative_count * 60 / negative_seconds
        if negative_seconds
        else None,
    }


def make_report(paths, parameters, tolerance):
    parameters.validate()
    if not math.isfinite(tolerance) or tolerance < 0:
        raise ValueError("事件匹配容差须为非负有限秒数")
    rows = [evaluate(path, parameters, tolerance) for path in paths]
    ids = [(row["data_kind"], row["recording_id"]) for row in rows]
    if len(set(ids)) != len(ids):
        raise ValueError("录制编号重复：不要将同一片段重复纳入评估")
    cohorts = []
    for kind in sorted({row["data_kind"] for row in rows}):
        subset = [row for row in rows if row["data_kind"] == kind]
        cohorts.append(
            {
                "data_kind": kind,
                "summary": summarize(subset),
                "by_activity": {
                    key: summarize([row for row in subset if row["activity"] == key])
                    for key in sorted({row["activity"] for row in subset})
                },
                "by_participant": {
                    key: summarize(
                        [row for row in subset if row["participant_id"] == key]
                    )
                    for key in sorted({row["participant_id"] for row in subset})
                },
                "by_truth_count": {
                    str(key): summarize(
                        [row for row in subset if row["ground_truth_count"] == key]
                    )
                    for key in sorted(
                        {
                            row["ground_truth_count"]
                            for row in subset
                            if row["ground_truth_count"] is not None
                        }
                    )
                },
            }
        )
    return {
        "baseline_version": "peak-return-v1",
        "parameters": asdict(parameters),
        "event_tolerance_s": tolerance,
        "recordings": rows,
        "cohorts": cohorts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings", nargs="+", type=Path)
    parser.add_argument(
        "--field", choices=VECTOR_FIELDS[:2], default="user_acceleration_g"
    )
    parser.add_argument("--axis", choices=("x", "y", "z"), default="x")
    parser.add_argument("--sign", type=int, choices=(-1, 1), default=1)
    parser.add_argument("--window-s", type=float, default=0.1)
    parser.add_argument("--peak", type=float, default=0.15)
    parser.add_argument("--release", type=float, default=0.05)
    parser.add_argument("--min-interval-s", type=float, default=0.4)
    parser.add_argument("--max-gap-s", type=float, default=0.2)
    parser.add_argument("--event-tolerance-s", type=float, default=0.2)
    args = parser.parse_args()
    parameters = Parameters(
        field=args.field,
        axis="xyz".index(args.axis),
        sign=args.sign,
        window_s=args.window_s,
        peak=args.peak,
        release=args.release,
        min_interval_s=args.min_interval_s,
        max_gap_s=args.max_gap_s,
    )
    try:
        report = make_report(args.recordings, parameters, args.event_tolerance_s)
    except (OSError, UnicodeError, ValueError) as error:
        logger.error("评估失败：%s", error)
        return 2
    json.dump(report, sys.stdout, ensure_ascii=False, allow_nan=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    raise SystemExit(main())
