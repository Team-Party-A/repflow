import json
import shutil
import subprocess
from pathlib import Path

import pytest
from curl_rep_counter import replay_curl
from inspect_recording import VECTOR_FIELDS

SWIFT_REPLAY = """
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
let recordings = try JSONDecoder().decode([[[Double]]].self, from: input)
let output = recordings.map { samples in
    var counter = CurlRepCounter()
    return samples.map { row in
        counter.append(.init(
            timestamp: row[0],
            userAccelerationG: SIMD3(row[1], row[2], row[3]),
            rotationRateRadS: SIMD3(row[4], row[5], row[6]),
            gravityG: SIMD3(row[7], row[8], row[9])
        ))
        return [counter.count, counter.gapCount]
    }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(output))
"""


def trace(*segments, offset=0):
    rates = [rate for rate, frames in segments for _ in range(frames)]
    return [
        {
            "t_s": (offset + index) / 50,
            "user_acceleration_g": [0, 0, 0],
            "rotation_rate_rad_s": [0, -rate, 0],
            "gravity_g": [0, 0, 0],
        }
        for index, rate in enumerate(rates)
    ]


REST = (0, 15)
LIFT = (2, 30)
LOWER = (-2, 30)
CYCLE = (REST, LIFT, LOWER, REST)


def gravity_return_trace(returns_to_start):
    samples = trace(REST, LIFT, (-2, 24), REST)
    for index, sample in enumerate(samples):
        if index < 22:
            sample["gravity_g"] = [0, 0, -1]
        elif index >= 65 and returns_to_start:
            sample["gravity_g"] = [0.2, 0, -0.98]
        else:
            sample["gravity_g"] = [0.9, 0, -0.44]
    return samples


def fixed_replays():
    complete = trace(*CYCLE)
    duplicate = {**complete[20], "rotation_rate_rad_s": [0, -25, 0]}
    return [
        (trace(REST), (0, 0)),
        (trace(*CYCLE, *CYCLE), (2, 0)),
        (trace(REST, LIFT, (0, 40)), (0, 0)),
        (trace(REST, LIFT, (0, 40), LOWER, REST), (1, 0)),
        (trace(REST, LIFT, (-2, 8), REST), (0, 0)),
        (trace(REST, LIFT) + trace(LOWER, REST, offset=70), (0, 1)),
        (complete[:21] + [duplicate, complete[19]] + complete[21:], (1, 0)),
        (trace(REST, (2, 5), (-2, 5), REST), (0, 0)),
        (gravity_return_trace(False), (0, 0)),
        (gravity_return_trace(True), (1, 0)),
    ]


@pytest.fixture(scope="module")
def swift_replay(tmp_path_factory):
    compiler = shutil.which("swiftc")
    if compiler is None:
        pytest.skip("Swift compiler is required for cross-language replay")
    directory = tmp_path_factory.mktemp("curl_replay")
    main = directory / "main.swift"
    main.write_text(SWIFT_REPLAY, encoding="utf-8")
    executable = directory / "curl_replay"
    source = (
        Path(__file__).resolve().parents[1] / "apps/apple/Shared/CurlRepCounter.swift"
    )
    subprocess.run(
        [compiler, str(source), str(main), "-o", str(executable)], check=True
    )
    return executable


def run_swift(executable, recordings):
    input_rows = [
        [
            [
                sample["t_s"],
                *(value for field in VECTOR_FIELDS for value in sample[field]),
            ]
            for sample in samples
        ]
        for samples in recordings
    ]
    result = subprocess.run(
        [str(executable)],
        input=json.dumps(input_rows),
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def test_fixed_counts_and_swift_parity(swift_replay):
    cases = fixed_replays()
    python_results = [list(replay_curl(samples)) for samples, _ in cases]
    assert [result[-1] for result in python_results] == [
        expected for _, expected in cases
    ]
    assert run_swift(swift_replay, [samples for samples, _ in cases]) == [
        [list(snapshot) for snapshot in result] for result in python_results
    ]
