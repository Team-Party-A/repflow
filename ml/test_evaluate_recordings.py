import copy
import json
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest
from evaluate_recordings import Parameters, count_reps, make_report, match_events

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "docs/data/samples/synthetic-v1.json"
PARAMETERS = Parameters(window_s=0, peak=0.3, release=0.05, min_interval_s=0)


def recording(values, times=None):
    data = json.loads(SAMPLE.read_text())
    times = times if times is not None else [i * 0.1 for i in range(len(values))]
    data.update(recording_id="test", duration_s=times[-1] + 0.1, annotations=[])
    data["set"] = {"start_s": 0, "end_s": times[-1], "ground_truth_count": None}
    data["samples"] = [
        {
            "t_s": time,
            "user_acceleration_g": [value, 0, 0],
            "rotation_rate_rad_s": [0, 0, -value],
            "gravity_g": [0, 0, -1],
        }
        for time, value in zip(times, values)
    ]
    return data


def write(tmp_path, data, name="recording.json"):
    path = tmp_path / name
    path.write_text(json.dumps(data))
    return path


@pytest.mark.parametrize(
    "values,expected",
    [
        ([0, 0.5, 0], 1),
        ([0, 0.5, 0, 0.5, 0], 2),
        ([0, 0.5, 0.5], 0),
        ([0.5, 0, 0.5, 0], 1),
        ([0, 0.02, 0, 0.03, 0], 0),
    ],
)
def test_complete_short_cycles_not_peaks_or_unfinished_halves(values, expected):
    assert count_reps(recording(values), PARAMETERS)["estimated_count"] == expected


def test_pause_does_not_duplicate_and_refractory_uses_real_time():
    data = recording([0, 0.5, 0.5, 0.5, 0, 0.5, 0, 0.5, 0])
    result = count_reps(data, replace(PARAMETERS, min_interval_s=0.3))
    assert [e["t_s"] for e in result["events"]] == pytest.approx([0.4, 0.8])


def test_gap_breaks_incomplete_cycle_and_group_boundary_excludes_tail():
    data = recording([0, 0.5, 0, 0.5, 0], [0, 0.1, 1, 1.1, 1.2])
    result = count_reps(data, PARAMETERS)
    assert result["gap_count"] == 1
    assert [e["t_s"] for e in result["events"]] == [1.2]
    data["set"]["end_s"] = 1.1
    assert count_reps(data, PARAMETERS)["estimated_count"] == 0


def test_no_samples_inside_group_is_not_a_zero_count_result():
    data = recording([0, 0.5, 0])
    data["set"].update(start_s=0.21, end_s=0.25)
    with pytest.raises(ValueError, match="缺少输入"):
        count_reps(data, PARAMETERS)


def test_signed_axis_and_causal_smoothing_preserve_prefix_result():
    data = recording([0, 0.5, 0, 0.5, 0])
    params = replace(PARAMETERS, field="rotation_rate_rad_s", axis=2, sign=-1)
    assert count_reps(data, params) == count_reps(data, PARAMETERS)
    params = replace(PARAMETERS, window_s=0.1, peak=0.2)
    prefix = recording([0, 0.5, 0, 0])
    extended = recording([0, 0.5, 0, 0, 0.9, 0])
    before = count_reps(prefix, params)["events"]
    assert len(before) == 1
    after = [
        e
        for e in count_reps(extended, params)["events"]
        if e["t_s"] <= prefix["samples"][-1]["t_s"]
    ]
    assert before == after


def test_one_to_one_matching_exposes_duplicate_and_missed_events():
    scores = match_events([1, 1.05, 4], [1, 2], 0.1)
    assert scores == {"tp": 1, "fp": 2, "fn": 1, "precision": 1 / 3, "recall": 0.5}
    assert match_events([], [], 0.1)["precision"] is None


def test_report_scores_verified_truth_and_keeps_unverified_sets_separate(tmp_path):
    data = recording([0, 0.5, 0, 0.5, 0])
    data["set"]["ground_truth_count"] = 1
    data["annotations"] = [{"type": "rep_complete", "t_s": 0.2}]
    original = copy.deepcopy(data)
    verified = write(tmp_path, data)
    unknown = copy.deepcopy(data)
    unknown["recording_id"] = "unreviewed"
    unknown["set"]["ground_truth_count"] = None
    report = make_report(
        [verified, write(tmp_path, unknown, "unknown.json")], PARAMETERS, 0.1
    )
    summary = report["cohorts"][0]["summary"]
    assert summary["mae"] == 1
    assert summary["within_one_fraction"] == 1
    assert summary["scored_set_count"] == summary["unscored_set_count"] == 1
    assert summary["event_scores"]["fp"] == 1
    assert report["cohorts"][0]["by_truth_count"]["1"]["mae"] == 1
    assert report["recordings"][1]["event_scores"] is None
    assert json.loads(verified.read_text()) == original


def test_verified_zero_is_scored_not_treated_as_unknown(tmp_path):
    data = recording([0, 0.01, 0])
    data["set"]["ground_truth_count"] = 0
    report = make_report([write(tmp_path, data)], PARAMETERS, 0.1)
    summary = report["cohorts"][0]["summary"]
    assert summary["scored_set_count"] == 1
    assert summary["unscored_set_count"] == 0
    assert summary["mae"] == 0
    assert summary["event_scores"]["precision"] is None


def test_synthetic_and_recorded_metrics_not_mixed_and_negative_duration_correct(
    tmp_path,
):
    data = recording([0, 0.5, 0])
    data["metadata"].update(recording_kind="negative", activity="handling_equipment")
    data["set"] = None
    other = copy.deepcopy(data)
    other.update(data_kind="recorded", recording_id="other", duration_s=60)
    # 数学构造的测试夹具，仅验证分组逻辑，不代表真实采集。
    paths = [write(tmp_path, data), write(tmp_path, other, "other.json")]
    report = make_report(paths, PARAMETERS, 0.1)
    cohorts = {c["data_kind"]: c for c in report["cohorts"]}
    assert cohorts["recorded"]["summary"]["negative_count_per_minute"] == 1
    assert cohorts["synthetic"]["summary"][
        "negative_count_per_minute"
    ] == pytest.approx(200)
    assert all(c["summary"]["mae"] is None for c in cohorts.values())


def test_cli_existing_sample_and_error_no_partial_json(tmp_path):
    command = [sys.executable, str(ROOT / "ml/evaluate_recordings.py")]
    result = subprocess.run(
        command + [str(SAMPLE)], check=False, capture_output=True, text=True
    )
    assert result.returncode == 0
    report = json.loads(result.stdout)
    assert report["cohorts"][0]["summary"]["mae"] is None
    assert report["cohorts"][0]["data_kind"] == "synthetic"
    for args in [
        [str(SAMPLE), str(SAMPLE)],
        [str(SAMPLE), "--peak", "nan"],
        [str(tmp_path / "missing.json")],
    ]:
        result = subprocess.run(
            command + args, check=False, capture_output=True, text=True
        )
        assert result.returncode == 2
        assert not result.stdout
