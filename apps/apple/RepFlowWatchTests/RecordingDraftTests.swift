import XCTest

@testable import RepFlowWatch

final class RecordingDraftTests: XCTestCase {
    private func makeDraft(negative: Bool = false) -> RecordingDraft {
        RecordingDraft(
            metadata: .init(
                participantId: "p000", recordingKind: negative ? "negative" : "exercise_set",
                activity: negative ? "walking" : "dumbbell_curl", wornWrist: "left",
                crownOrientation: "right",
                device: .init(model: "synthetic", osVersion: "not_applicable"),
                recorderVersion: "test", requestedHz: 50))
    }

    private func append(_ time: Double, to draft: inout RecordingDraft) throws {
        try draft.append(
            timestamp: time, acceleration: [-0.3, 0.2, 0.7],
            rotation: [1.2, -2.5, 3], gravity: [0, 0, -1])
    }

    func testPreservesIrregularIntervalsAxesAndTailGap() throws {
        var draft = makeDraft()
        for time in [100.0, 100.02, 100.07, 106.0] { try append(time, to: &draft) }
        try draft.beginSet(at: 103)
        try draft.endSet(at: 105)
        let recording = try draft.finish(at: 109, dataKind: "synthetic")
        XCTAssertEqual(recording.samples[0].tS, 0)
        XCTAssertEqual(recording.samples[2].tS, 0.07, accuracy: 0.000001)
        XCTAssertEqual(recording.samples[2].userAccelerationG, [-0.3, 0.2, 0.7])
        XCTAssertEqual(recording.samples[2].rotationRateRadS, [1.2, -2.5, 3])
        XCTAssertEqual(recording.samples[2].gravityG, [0, 0, -1])
        XCTAssertEqual(recording.durationS - recording.samples.last!.tS, 3)
        XCTAssertEqual(recording.set?.startS, 3)
        XCTAssertEqual(recording.set?.endS, 5)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recording.jsonData()) as? [String: Any])
        XCTAssertEqual(json["format_version"] as? String, "1.0")
        let group = try XCTUnwrap(json["set"] as? [String: Any])
        XCTAssertTrue(group["ground_truth_count"] is NSNull)
        XCTAssertEqual((json["annotations"] as? [Any])?.count, 0)
        let sample = try XCTUnwrap((json["samples"] as? [[String: Any]])?.first)
        XCTAssertNotNil(sample["user_acceleration_g"])
        XCTAssertNotNil(sample["rotation_rate_rad_s"])
        XCTAssertNil(sample["attitude_xyzw"])
    }

    func testNegativeHasExplicitNullSetAndFreshTimeOrigin() throws {
        var draft = makeDraft(negative: true)
        try append(900, to: &draft)
        try append(900.04, to: &draft)
        XCTAssertThrowsError(try draft.beginSet(at: 900.01))
        let recording = try draft.finish(at: 901, dataKind: "synthetic")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recording.jsonData()) as? [String: Any])
        XCTAssertTrue(json["set"] is NSNull)
        XCTAssertEqual(recording.samples.first?.tS, 0)
    }

    func testRejectsDuplicateReverseAndNonfiniteSamplesWithoutChangingBuffer() throws {
        var draft = makeDraft()
        try append(100, to: &draft)
        for time in [100, 99, .nan, .infinity, -1] {
            XCTAssertThrowsError(try append(time, to: &draft))
        }
        XCTAssertThrowsError(
            try draft.append(
                timestamp: 101, acceleration: [0, .nan, 0],
                rotation: [0, 0, 0], gravity: [0, 0, -1]))
        XCTAssertThrowsError(
            try draft.append(
                timestamp: 101, acceleration: [0, 0],
                rotation: [0, 0, 0], gravity: [0, 0, -1]))
        XCTAssertEqual(draft.samples.count, 1)
    }

    func testRequiresSamplesAndOrderedSetBoundaries() throws {
        var draft = makeDraft()
        XCTAssertThrowsError(try draft.beginSet(at: 100))
        XCTAssertThrowsError(try draft.finish(at: 100))
        try append(100, to: &draft)
        XCTAssertThrowsError(try draft.finish(at: 101))
        try append(100.02, to: &draft)
        XCTAssertThrowsError(try draft.endSet(at: 101))
        XCTAssertThrowsError(try draft.beginSet(at: 99))
        try draft.beginSet(at: 101)
        XCTAssertThrowsError(try draft.beginSet(at: 102))
        XCTAssertThrowsError(try draft.endSet(at: 101))
        XCTAssertThrowsError(try draft.finish(at: 102))
        try draft.endSet(at: 102)
        XCTAssertThrowsError(try draft.endSet(at: 103))
        XCTAssertThrowsError(try draft.finish(at: 101.5))
        XCTAssertThrowsError(try draft.finish(at: .infinity))
        XCTAssertNoThrow(try draft.finish(at: 103))
    }

    func testEndTimeCannotHideLastSample() throws {
        var draft = makeDraft(negative: true)
        try append(100, to: &draft)
        try append(102, to: &draft)
        XCTAssertThrowsError(try draft.finish(at: 101))
    }
}
