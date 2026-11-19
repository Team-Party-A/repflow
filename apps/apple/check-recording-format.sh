#!/bin/sh
# 用生产 Swift 编码器生成合成录制，再交给现有 Python 检查器；不读取真机数据。
set -eu
apple_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
recording_check_dir=$(mktemp -d)
trap 'rm -rf "$recording_check_dir"' EXIT HUP INT TERM
cat > "$recording_check_dir/main.swift" <<'SWIFT'
import Foundation

for kind in ["exercise_set", "negative"] {
    let metadata = SensorRecording.Metadata(
        participantId: "p000", recordingKind: kind, activity: "dumbbell_curl",
        wornWrist: "left", crownOrientation: "right",
        device: .init(model: "synthetic", osVersion: "not_applicable"),
        recorderVersion: "format-check", requestedHz: 50)
    var draft = RecordingDraft(metadata: metadata)
    for index in 0...150 {
        try draft.append(timestamp: 100 + Double(index) / 50,
                         acceleration: [0.1, -0.2, 0.3], rotation: [1, 2, -3], gravity: [0, 0, -1])
    }
    if kind == "exercise_set" {
        try draft.beginSet(at: 101)
        try draft.endSet(at: 102)
    }
    let recording = try draft.finish(at: 103.5, dataKind: "synthetic")
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(kind + ".json")
    try recording.jsonData().write(to: url)
}
SWIFT
xcrun swiftc "$apple_dir/Shared/SensorRecording.swift" "$recording_check_dir/main.swift" \
    -module-cache-path "$recording_check_dir/ModuleCache" -o "$recording_check_dir/check"
"$recording_check_dir/check" "$recording_check_dir"
python3 "$apple_dir/../../ml/inspect_recording.py" "$recording_check_dir/exercise_set.json"
python3 "$apple_dir/../../ml/inspect_recording.py" "$recording_check_dir/negative.json"
