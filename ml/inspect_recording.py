"""读取传感器格式 v1.0，检查关键约束并报告真实时间戳的采样统计。"""

import argparse
import json
import logging
import math
import re
import statistics
import sys
from pathlib import Path

VECTOR_FIELDS = ("user_acceleration_g", "rotation_rate_rad_s", "gravity_g")
INTERVAL_TYPES = ("pause", "incomplete", "ambiguous")
logger = logging.getLogger(__name__)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, name):
    require(type(value) in (int, float), f"{name}: 必须是数值，不能是布尔值")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    require(finite, f"{name}: 必须是可表示的有限数值")
    return value


def object_value(value, name):
    require(isinstance(value, dict), f"{name}: 必须是对象")
    return value


def text_value(value, name):
    require(isinstance(value, str) and bool(value.strip()), f"{name}: 必须是非空字符串")
    return value


def vector(value, length, name):
    require(
        isinstance(value, list) and len(value) == length,
        f"{name}: 需要 {length} 个分量",
    )
    for component in value:
        number(component, name)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"JSON 重复字段: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"JSON 不允许 {value}")


def validate_metadata(metadata):
    metadata = object_value(metadata, "metadata")
    participant = text_value(metadata.get("participant_id"), "participant_id")
    require(
        re.fullmatch(r"p[0-9]{3,}", participant), "participant_id: 使用 p001 等匿名编号"
    )
    for field in ("activity", "recorder_version"):
        text_value(metadata.get(field), field)
    for field in ("worn_wrist", "crown_orientation"):
        require(
            metadata.get(field) in ("left", "right"), f"{field}: 需要 left 或 right"
        )
    require(
        metadata.get("recording_kind") in ("exercise_set", "negative"),
        "recording_kind: 需要 exercise_set 或 negative",
    )
    device = object_value(metadata.get("device"), "device")
    for field in ("model", "os_version"):
        text_value(device.get(field), "device." + field)
    require(
        number(metadata.get("requested_hz"), "requested_hz") > 0,
        "requested_hz: 必须大于 0",
    )
    require(
        metadata.get("time_origin") == "first_motion_sample",
        "时间原点必须是首个运动样本",
    )
    require(
        metadata.get("coordinate_frame") == "core_motion_device", "坐标系必须原样保留"
    )
    require(
        metadata.get("attitude_reference_frame") == "xArbitraryZVertical",
        "姿态参考系不符",
    )
    require(
        type(metadata.get("attitude_recorded")) is bool, "attitude_recorded: 需要布尔值"
    )
    return metadata


def validate_samples(samples, duration, attitude_recorded):
    require(
        isinstance(samples, list) and len(samples) >= 2, "samples: 至少需要两个样本"
    )
    times = []
    for index, sample in enumerate(samples):
        name = f"samples[{index}]"
        sample = object_value(sample, name)
        timestamp = number(sample.get("t_s"), name + ".t_s")
        require(timestamp >= 0, name + ": 时间不能为负")
        require(not times or timestamp > times[-1], name + ": 时间戳必须严格递增")
        times.append(timestamp)
        for field in VECTOR_FIELDS:
            vector(sample.get(field), 3, name + "." + field)
        require(
            ("attitude_xyzw" in sample) == attitude_recorded,
            name + ": 四元数是否存在必须与 metadata 一致",
        )
        if attitude_recorded:
            quaternion = sample["attitude_xyzw"]
            vector(quaternion, 4, name + ".attitude_xyzw")
            require(
                math.isclose(
                    sum(c * c for c in quaternion), 1, abs_tol=0.001, rel_tol=0
                ),
                name + ": 四元数必须近似单位长度",
            )
    require(times[0] == 0, "第一个样本 t_s 必须是 0")
    require(times[-1] <= duration, "duration_s 不能早于末样本")
    return times


def validate_annotations(recording, duration, kind):
    require("set" in recording, "缺少 set；负样本需显式写 null")
    group = recording["set"]
    if kind == "exercise_set":
        group = object_value(group, "set")
        start = number(group.get("start_s"), "set.start_s")
        end = number(group.get("end_s"), "set.end_s")
        require(0 <= start < end <= duration, "set: 边界必须在录制时间内")
        require(
            "ground_truth_count" in group, "缺少 ground_truth_count；未确认需写 null"
        )
        truth = group["ground_truth_count"]
        require(
            truth is None or (type(truth) is int and truth >= 0),
            "ground_truth_count: 需要非负整数或 null",
        )
    else:
        require(group is None, "negative 录制的 set 必须是 null")
        start, end, truth = 0, duration, None

    annotations = recording.get("annotations")
    require(isinstance(annotations, list), "annotations: 必须是数组，可为空")
    completed, intervals = [], []
    previous = -1
    for index, annotation in enumerate(annotations):
        name = f"annotations[{index}]"
        annotation = object_value(annotation, name)
        annotation_type = annotation.get("type")
        if annotation_type == "rep_complete":
            timestamp = number(annotation.get("t_s"), name + ".t_s")
            require(
                kind == "exercise_set" and start <= timestamp <= end,
                name + ": 完成事件必须在组内",
            )
            require(timestamp not in completed, name + ": 完成事件时间重复")
            completed.append(timestamp)
            position = timestamp
        else:
            require(annotation_type in INTERVAL_TYPES, name + ": 未知标注类型")
            left = number(annotation.get("start_s"), name + ".start_s")
            right = number(annotation.get("end_s"), name + ".end_s")
            require(0 <= left < right <= duration, name + ": 区间必须在录制时间内")
            text_value(annotation.get("reason"), name + ".reason")
            if annotation_type == "incomplete":
                require(
                    kind == "exercise_set" and start <= left < right <= end,
                    name + ": 半次必须在组内",
                )
            intervals.append((annotation_type, left, right))
            position = left
        require(position >= previous, name + ": 标注必须按事件/区间起点排序")
        previous = position

    for timestamp in completed:
        require(
            not any(left <= timestamp < right for _, left, right in intervals),
            "完成事件不能位于暂停、半次或真值不确定区间内",
        )
    ambiguous = sum(
        t == "ambiguous" and left < end and right > start
        for t, left, right in intervals
    )
    if kind == "negative":
        ambiguous = 0
    if kind == "exercise_set":
        require(
            not ambiguous or truth is None, "组内有 ambiguous 时真值总数必须为 null"
        )
        require(truth is None or truth == len(completed), "真值总数与完成事件数量不符")
    return completed, truth, ambiguous


def inspect_recording(path):
    recording = json.loads(
        Path(path).read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )
    object_value(recording, "recording")
    require(recording.get("format_version") == "1.0", "不支持的 format_version")
    require(
        recording.get("data_kind") in ("synthetic", "recorded"),
        "data_kind: 需要 synthetic 或 recorded",
    )
    text_value(recording.get("recording_id"), "recording_id")
    duration = number(recording.get("duration_s"), "duration_s")
    require(duration > 0, "duration_s: 必须大于 0")
    metadata = validate_metadata(recording.get("metadata"))
    times = validate_samples(
        recording.get("samples"), duration, metadata["attitude_recorded"]
    )
    completed, truth, ambiguous = validate_annotations(
        recording, duration, metadata["recording_kind"]
    )
    intervals = [times[index] - times[index - 1] for index in range(1, len(times))]
    return {
        "recording_id": recording["recording_id"],
        "data_kind": recording["data_kind"],
        "sample_count": len(times),
        "duration_s": duration,
        "observed_span_s": times[-1] - times[0],
        "tail_gap_s": duration - times[-1],
        "requested_hz": metadata["requested_hz"],
        "effective_hz": number(
            (len(times) - 1) / (times[-1] - times[0]), "effective_hz"
        ),
        "interval_min_s": min(intervals),
        "interval_median_s": statistics.median(intervals),
        "interval_max_s": max(intervals),
        "known_complete_events": len(completed),
        "ground_truth_count": truth,
        "ambiguous_intervals_in_set": ambiguous,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    arguments = parser.parse_args()
    try:
        report = inspect_recording(arguments.recording)
    except (OSError, UnicodeError, ValueError) as error:
        logger.error("录制文件检查失败: %s", error)
        return 2
    json.dump(report, sys.stdout, ensure_ascii=False, allow_nan=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    raise SystemExit(main())
