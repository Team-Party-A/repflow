import XCTest

@testable import RepFlowWatch

final class TrainingOutboxTests: XCTestCase {
    private let workoutID = "11111111-1111-4111-8111-111111111111"
    private let setID = "22222222-2222-4222-8222-222222222222"
    private let start = ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z")!
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func prepare() throws -> ManualTraining {
        var set = ManualTrainingSet(
            id: UUID(uuidString: setID)!, exerciseID: "dumbbell_curl", startedAt: start)
        set.endedAt = start.addingTimeInterval(42)
        set.reps = 10
        let workout = ManualWorkout(
            id: UUID(uuidString: workoutID)!, startedAt: start, timeZone: "Asia/Shanghai",
            candidate: set)
        let snapshot = ManualTrainingSnapshot(workouts: [workout], currentID: workout.id)
        try JSONEncoder().encode(snapshot).write(to: file)
        return ManualTraining(fileURL: file)
    }

    private func envelope(_ type: String, _ fields: [String: Any]) throws -> [String: Any] {
        ["type": type, "version": 1, "payload": try JSONSerialization.data(withJSONObject: fields)]
    }

    func testContractExampleOfflineRestartRetryAndAck() throws {
        let training = try prepare()
        training.saveSet(estimatedRepCount: 9)
        training.finishWorkout(at: start.addingTimeInterval(120))
        training.prepareNewWorkout()
        let restored = ManualTraining(fileURL: file)
        var outstanding: Set<UUID>? = nil
        var sent: [[String: Any]] = []
        let queue = TrainingOutbox(
            training: restored,
            transport: .init(inFlight: { outstanding }, send: { sent.append($0) }))
        queue.check()
        XCTAssertTrue(sent.isEmpty)
        outstanding = []
        let retry = try envelope("retry_pending", [:])
        queue.receive(retry)
        let first = try XCTUnwrap(sent.first)
        let expected = try envelope(
            "set_saved",
            [
                "workout_id": workoutID, "set_id": setID, "time_zone": "Asia/Shanghai",
                "started_at": "2026-10-24T10:00:00.000Z",
                "set_started_at": "2026-10-24T10:00:00.000Z",
                "set_ended_at": "2026-10-24T10:00:42.000Z", "exercise_id": "dumbbell_curl",
                "set_index": 1, "estimated_rep_count": 9, "final_rep_count": 10,
                "record_source": "automatic", "weight_grams": NSNull(),
            ])
        func fields(_ info: [String: Any]) throws -> NSDictionary {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(info["payload"] as? Data))
                    as? NSDictionary)
        }
        XCTAssertEqual(first["version"] as? Int, 1)
        XCTAssertEqual(first["type"] as? String, "set_saved")
        XCTAssertEqual(try fields(first), try fields(expected))
        outstanding = [UUID(uuidString: setID)!]
        queue.receive(retry)
        XCTAssertEqual(sent.count, 1)
        outstanding = []
        queue.transferFinished(first, error: CocoaError(.fileWriteUnknown))
        XCTAssertEqual(restored.snapshot.workouts[0].sets[0].message?.delivery, .failed)
        queue.receive(retry)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?["payload"] as? Data, first["payload"] as? Data)
        queue.transferFinished(first, error: nil)
        let endAck = try envelope("ack", ["ack_type": "workout_ended", "workout_id": workoutID])
        queue.receive(endAck)
        queue.receive(
            try envelope("ack", ["ack_type": "set_saved", "workout_id": setID, "set_id": setID]))
        XCTAssertEqual(restored.snapshot.workouts[0].readyMessages.first?.kind, .setSaved)
        let ack = try envelope(
            "ack", ["ack_type": "set_saved", "workout_id": workoutID, "set_id": setID])
        queue.receive(ack)
        queue.receive(ack)
        XCTAssertEqual(sent.count, 3)
        let end = try XCTUnwrap(sent.last)
        XCTAssertEqual(end["type"] as? String, "workout_ended")
        XCTAssertEqual(
            try fields(end),
            [
                "workout_id": workoutID, "started_at": "2026-10-24T10:00:00.000Z",
                "time_zone": "Asia/Shanghai", "ended_at": "2026-10-24T10:02:00.000Z",
                "saved_set_ids": [setID],
            ] as NSDictionary)
        queue.receive(endAck)
        queue.receive(retry)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(
            ManualTraining(fileURL: file).snapshot.workouts[0].endMessage?.delivery, .delivered)
    }

    func testEndWaitsForEveryGroupAcrossRestartAndIncludesAcknowledgedGroups() throws {
        let model = try prepare()
        model.saveSet(estimatedRepCount: 9)
        model.startSet(exerciseID: "dumbbell_curl", at: start.addingTimeInterval(60))
        model.endSet(at: start.addingTimeInterval(90))
        model.adjustReps(by: 1)
        model.saveSet(estimatedRepCount: 2)
        let workout = try XCTUnwrap(model.current)
        let second = try XCTUnwrap(workout.sets.last?.id)
        model.updateDelivery(workoutID: workout.id, setID: second, to: .delivered)
        model.finishWorkout(at: start.addingTimeInterval(120))
        let restored = ManualTraining(fileURL: file)
        XCTAssertEqual(restored.current?.readyMessages.map(\.id), [UUID(uuidString: setID)!])
        restored.updateDelivery(workoutID: workout.id, setID: workout.sets[0].id, to: .delivered)
        let restarted = ManualTraining(fileURL: file)
        XCTAssertEqual(restarted.current?.readyMessages.count, 1)
        let end = try XCTUnwrap(restarted.current?.readyMessages.first)
        XCTAssertEqual(end.kind, .workoutEnded)
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: end.payload) as? [String: Any])
        XCTAssertEqual(
            fields["saved_set_ids"] as? [String], [setID, second.uuidString.lowercased()])
    }

    func testWriteFailureKeepsCandidateAndNeverQueues() throws {
        _ = try prepare()
        let model = ManualTraining(fileURL: file) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let queue = TrainingOutbox(
            training: model, transport: .init(inFlight: { [] }, send: { _ in XCTFail("未落盘不得发送") }))
        model.saveSet(estimatedRepCount: 9)
        queue.check()
        XCTAssertEqual(ManualTraining(fileURL: file).phase, .review)
        XCTAssertTrue(model.current!.sets.isEmpty)
    }

    func testLegacyManualAndInvalidReceipts() throws {
        let model = try prepare()
        model.saveSet()
        model.finishWorkout(at: start.addingTimeInterval(120))
        XCTAssertTrue(ManualTraining(fileURL: file).current!.readyMessages.isEmpty)
        XCTAssertNil(model.current?.endMessage)
        var wrong = try envelope("retry_pending", [:])
        wrong["version"] = true
        XCTAssertThrowsError(try PhoneSignal(wrong))
        XCTAssertThrowsError(
            try PhoneSignal(
                envelope(
                    "ack",
                    ["ack_type": "workout_ended", "workout_id": workoutID, "set_id": NSNull()])))
    }
}
