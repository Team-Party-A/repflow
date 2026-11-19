import copy
import json
import subprocess
import sys
from pathlib import Path

import pytest
from inspect_recording import inspect_recording

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "docs/data/samples/synthetic-v1.json"


@pytest.fixture
def recording():
    return json.loads(SAMPLE.read_text(encoding="utf-8"))


def inspect_fixture(tmp_path, recording):
    path = tmp_path / "recording.json"
    path.write_text(json.dumps(recording), encoding="utf-8")
    return inspect_recording(path)


def test_sample_rate_and_unknown_total_are_not_invented():
    result = inspect_recording(SAMPLE)
    assert result["sample_count"] == 151
    assert result["duration_s"] == 3
    assert result["effective_hz"] == 50
    assert result["interval_median_s"] == pytest.approx(0.02)
    assert result["known_complete_events"] == 2
    assert result["ground_truth_count"] is None
    assert result["ambiguous_intervals_in_set"] == 1


def test_gaps_use_observed_timestamps_instead_of_requested_rate(tmp_path, recording):
    recording["samples"] = recording["samples"][::2]
    recording["samples"] = [s for s in recording["samples"] if not 1 < s["t_s"] < 1.4]
    result = inspect_fixture(tmp_path, recording)
    assert result["requested_hz"] == 50
    assert result["effective_hz"] < 25
    assert result["interval_max_s"] == pytest.approx(0.4)
    assert result["interval_median_s"] == pytest.approx(0.04)


@pytest.mark.parametrize("timestamp", [0, -0.02, True, float("nan")])
def test_duplicate_reversed_boolean_and_nonfinite_times_fail(
    tmp_path, recording, timestamp
):
    recording["samples"][1]["t_s"] = timestamp
    with pytest.raises(ValueError):
        inspect_fixture(tmp_path, recording)


@pytest.mark.parametrize(
    "field", ["user_acceleration_g", "rotation_rate_rad_s", "gravity_g"]
)
def test_vectors_require_three_finite_components(tmp_path, recording, field):
    recording["samples"][0][field] = [0, 0, float("inf")]
    with pytest.raises(ValueError):
        inspect_fixture(tmp_path, recording)
    recording["samples"][0][field] = [0, 0]
    with pytest.raises(ValueError):
        inspect_fixture(tmp_path, recording)


def test_optional_quaternion_is_all_or_none_and_normalized(tmp_path, recording):
    recording["metadata"]["attitude_recorded"] = True
    for sample in recording["samples"]:
        sample["attitude_xyzw"] = [0, 0, 0, 1]
    assert inspect_fixture(tmp_path, recording)["sample_count"] == 151
    recording["samples"][0]["attitude_xyzw"] = [0, 0, 0, 2]
    with pytest.raises(ValueError, match="单位长度"):
        inspect_fixture(tmp_path, recording)
    del recording["samples"][0]["attitude_xyzw"]
    with pytest.raises(ValueError, match="metadata"):
        inspect_fixture(tmp_path, recording)


@pytest.mark.parametrize(
    "mode", ["outside", "pause", "duplicate", "unsorted", "interval"]
)
def test_invalid_annotations_fail(tmp_path, recording, mode):
    if mode == "outside":
        recording["annotations"][-2]["t_s"] = 3
    elif mode == "pause":
        recording["annotations"][1]["t_s"] = 1.3
    elif mode == "duplicate":
        recording["annotations"].insert(2, copy.deepcopy(recording["annotations"][1]))
    elif mode == "unsorted":
        recording["annotations"].reverse()
    else:
        recording["annotations"][0]["end_s"] = 4
    if mode in ("outside", "pause"):
        recording["annotations"].sort(key=lambda a: a.get("t_s", a.get("start_s")))
    errors = {
        "outside": "完成事件必须在组内",
        "pause": "完成事件不能位于",
        "duplicate": "完成事件时间重复",
        "unsorted": "标注必须按",
        "interval": "区间必须在录制时间内",
    }
    with pytest.raises(ValueError, match=errors[mode]):
        inspect_fixture(tmp_path, recording)


def test_verified_total_matches_events_and_ambiguous_total_stays_null(
    tmp_path, recording
):
    recording["set"]["ground_truth_count"] = 2
    with pytest.raises(ValueError, match="ambiguous"):
        inspect_fixture(tmp_path, recording)
    recording["annotations"] = [
        a for a in recording["annotations"] if a["type"] != "ambiguous"
    ]
    assert inspect_fixture(tmp_path, recording)["ground_truth_count"] == 2
    recording["set"]["ground_truth_count"] = 3
    with pytest.raises(ValueError, match="数量"):
        inspect_fixture(tmp_path, recording)


def test_negative_recording_does_not_turn_activity_into_repetitions(
    tmp_path, recording
):
    recording["metadata"].update(recording_kind="negative", activity="walking")
    recording["set"] = None
    recording["annotations"] = []
    result = inspect_fixture(tmp_path, recording)
    assert result["known_complete_events"] == 0
    assert result["ground_truth_count"] is None
    recording["annotations"] = [
        {"type": "ambiguous", "start_s": 1, "end_s": 2, "reason": "uncertain"}
    ]
    assert inspect_fixture(tmp_path, recording)["ambiguous_intervals_in_set"] == 0
    recording["annotations"] = [{"type": "rep_complete", "t_s": 1}]
    with pytest.raises(ValueError):
        inspect_fixture(tmp_path, recording)


@pytest.mark.parametrize(
    "mutation", ["version", "participant", "duration", "origin", "metadata"]
)
def test_version_metadata_and_time_origin_fail_closed(tmp_path, recording, mutation):
    if mutation == "version":
        recording["format_version"] = "2.0"
    elif mutation == "participant":
        recording["metadata"]["participant_id"] = "real-person@example.com"
    elif mutation == "duration":
        recording["duration_s"] = 2.5
    elif mutation == "origin":
        recording["samples"][0]["t_s"] = 0.001
    else:
        del recording["metadata"]["device"]
    with pytest.raises(ValueError):
        inspect_fixture(tmp_path, recording)


def test_cli_reports_json_and_rejects_duplicate_keys(tmp_path):
    command = [sys.executable, str(ROOT / "ml/inspect_recording.py")]
    result = subprocess.run(
        command + [str(SAMPLE)], check=False, text=True, capture_output=True
    )
    assert result.returncode == 0
    assert json.loads(result.stdout)["effective_hz"] == 50
    broken = tmp_path / "duplicate.json"
    broken.write_text(
        '{"format_version":"1.0","format_version":"2.0"}', encoding="utf-8"
    )
    result = subprocess.run(
        command + [str(broken)], check=False, text=True, capture_output=True
    )
    assert result.returncode == 2
    assert "重复字段" in result.stderr
    assert not result.stdout


def test_tail_gap_is_reported_without_inventing_samples(tmp_path, recording):
    recording["duration_s"] = 4
    result = inspect_fixture(tmp_path, recording)
    assert result["effective_hz"] == 50
    assert result["tail_gap_s"] == 1
    assert result["sample_count"] == 151


@pytest.mark.parametrize("mode", ["huge_integer", "unrepresentable_frequency"])
def test_unrepresentable_numbers_are_validation_errors(tmp_path, recording, mode):
    if mode == "huge_integer":
        recording["metadata"]["requested_hz"] = 10**1000
    else:
        recording["metadata"]["recording_kind"] = "negative"
        recording["set"] = None
        recording["annotations"] = []
        for sample in recording["samples"]:
            sample["t_s"] *= 1e-320
        recording["duration_s"] = recording["samples"][-1]["t_s"]
    with pytest.raises(ValueError, match="有限数值"):
        inspect_fixture(tmp_path, recording)
