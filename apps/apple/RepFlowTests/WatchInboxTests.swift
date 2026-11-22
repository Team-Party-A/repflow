import SwiftData
import XCTest

@testable import RepFlow

private final class RecordingSender: WatchMessageSender {
    var isActivated = true
    var outstandingTypes: Set<String> = []
    private(set) var sent: [(type: String, payload: [String: Any])] = []

    func transfer(_ userInfo: [String: Any]) {
        let payload = try! JSONSerialization.jsonObject(with: userInfo["payload"] as! Data)
        XCTAssertEqual(userInfo["version"] as? Int, 1)
        sent.append((userInfo["type"] as! String, payload as! [String: Any]))
    }

    func hasOutstanding(type: String) -> Bool { outstandingTypes.contains(type) }
}

/// 契约第 4 节的合成示例
private let workoutID = "11111111-1111-4111-8111-111111111111"
private let firstSetID = "22222222-2222-4222-8222-222222222222"
private let secondSetID = "33333333-3333-4333-8333-333333333333"

private func setSaved(
    setID: String = firstSetID, index: Int = 1, workout: String = workoutID,
    _ changes: (inout [String: Any]) -> Void = { _ in }
) -> [String: Any] {
    var payload: [String: Any] = [
        "workout_id": workout,
        "set_id": setID,
        "started_at": "2026-10-24T10:00:00.000Z",
        "time_zone": "Asia/Shanghai",
        "set_started_at": "2026-10-24T10:00:00.000Z",
        "set_ended_at": "2026-10-24T10:00:42.000Z",
        "set_index": index,
        "exercise_id": "dumbbell_curl",
        "final_rep_count": 10,
        "estimated_rep_count": 9,
        "record_source": "automatic",
        "weight_grams": NSNull(),
    ]
    changes(&payload)
    return envelope("set_saved", payload)
}

private func workoutEnded(setIDs: [String] = [firstSetID]) -> [String: Any] {
    envelope(
        "workout_ended",
        [
            "workout_id": workoutID,
            "started_at": "2026-10-24T10:00:00.000Z",
            "time_zone": "Asia/Shanghai",
            "ended_at": "2026-10-24T10:02:00.000Z",
            "saved_set_ids": setIDs,
        ])
}

private func envelope(_ type: String, _ payload: [String: Any], version: Any = 1) -> [String: Any] {
    [
        "type": type, "version": version,
        "payload": try! JSONSerialization.data(withJSONObject: payload),
    ]
}

@MainActor
final class WatchInboxTests: XCTestCase {
    private let userA = UUID()
    private let userB = UUID()
    private var loggedIn: UUID?
    private var container: ModelContainer!
    private var context: ModelContext!
    private var sender: RecordingSender!
    private var inbox: WatchInbox!
    private var storedFor: [UUID] = []

    override func setUp() async throws {
        container = try WorkoutStore.makeContainer(inMemory: true)
        context = ModelContext(container)
        sender = RecordingSender()
        loggedIn = userA
        storedFor = []
        inbox = WatchInbox(
            context: context, sender: sender, currentUserID: { [unowned self] in loggedIn },
            onStored: { [unowned self] in storedFor.append($0) })
    }

    private func workouts(of userID: UUID) throws -> [Workout] {
        try WorkoutStore(context: context, userID: userID).workouts()
    }

    private func tasks() throws -> [UploadTask] {
        try context.fetch(FetchDescriptor<UploadTask>())
    }

    private var acks: [[String: Any]] {
        sender.sent.filter { $0.type == "ack" }.map(\.payload)
    }

    func testFirstSetCreatesWatchWorkoutAndAcksAfterSave() throws {
        inbox.receive(setSaved())

        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertEqual(workout.workoutID.uuidString.lowercased(), workoutID)
        XCTAssertEqual(workout.origin, .watch)
        XCTAssertEqual(workout.timeZone, "Asia/Shanghai")
        XCTAssertNil(workout.endedAt)
        let set = try XCTUnwrap(workout.sets.first)
        XCTAssertEqual(set.setID.uuidString.lowercased(), firstSetID)
        XCTAssertEqual(set.finalRepCount, 10)
        XCTAssertEqual(set.estimatedRepCount, 9)
        XCTAssertEqual(set.recordSource, .automatic)
        XCTAssertNil(set.weightGrams)
        XCTAssertEqual(set.watchSetIndex, 1)
        XCTAssertEqual(set.setEndedAt?.timeIntervalSince(set.setStartedAt!), 42)

        let task = try XCTUnwrap(try tasks().first)
        XCTAssertEqual(task.userID, userA)
        XCTAssertEqual(task.revision, 1)
        XCTAssertEqual(workout.syncStatus, .pending)
        XCTAssertEqual(storedFor, [userA])

        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks[0]["ack_type"] as? String, "set_saved")
        XCTAssertEqual(acks[0]["workout_id"] as? String, workoutID)
        XCTAssertEqual(acks[0]["set_id"] as? String, firstSetID)
    }

    func testDuplicateSetOnlyAcksAgain() throws {
        inbox.receive(setSaved())
        inbox.receive(setSaved())

        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertEqual(workout.sets.count, 1)
        XCTAssertEqual(workout.revision, 1)
        XCTAssertEqual(acks.count, 2)
    }

    /// 联调清单：断连保存 8、10 次两组后恢复，乱序到达也按 set_index 排
    func testOutOfOrderSetsAreOrderedBySetIndex() throws {
        inbox.receive(setSaved(setID: secondSetID, index: 2) { $0["final_rep_count"] = 10 })
        inbox.receive(setSaved(setID: firstSetID, index: 1) { $0["final_rep_count"] = 8 })

        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertEqual(workout.orderedSets.map(\.finalRepCount), [8, 10])
        XCTAssertEqual(workout.totalReps, 18)
        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(try tasks().count, 1)
    }

    func testLoggedOutNeitherStoresNorAcksThenLoginAsksForRetry() throws {
        loggedIn = nil
        inbox.receive(setSaved())
        inbox.requestRetry()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(sender.sent.isEmpty)

        loggedIn = userA
        inbox.requestRetry()
        XCTAssertEqual(sender.sent.map(\.type), ["retry_pending"])
        XCTAssertTrue(sender.sent[0].payload.isEmpty)

        // 系统队列里还有一条在途时不再排
        sender.outstandingTypes = ["retry_pending"]
        inbox.requestRetry()
        XCTAssertEqual(sender.sent.count, 1)
    }

    func testKnownWorkoutStaysWithOriginalAccount() throws {
        inbox.receive(setSaved())
        loggedIn = userB
        inbox.receive(setSaved(setID: secondSetID, index: 2))

        XCTAssertTrue(try workouts(of: userB).isEmpty)
        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertEqual(workout.sets.count, 2)
        XCTAssertEqual(try tasks().map(\.userID), [userA])
        XCTAssertEqual(acks.count, 2)
    }

    /// 联调清单：手机编辑 10→12、补重量后重发旧组
    func testResentSetDoesNotOverwritePhoneEdit() throws {
        inbox.receive(setSaved())
        let workout = try XCTUnwrap(try workouts(of: userA).first)
        let set = try XCTUnwrap(workout.sets.first)
        try WorkoutStore(context: context, userID: userA).updateSet(
            set, in: workout,
            to: DraftSet(exerciseID: "dumbbell_curl", reps: 12, weightGrams: 8000))

        inbox.receive(setSaved())

        XCTAssertEqual(set.finalRepCount, 12)
        XCTAssertEqual(set.weightGrams, 8000)
        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(acks.count, 2)
    }

    func testDeletedSetIsNotRestored() throws {
        inbox.receive(setSaved())
        inbox.receive(setSaved(setID: secondSetID, index: 2))
        let workout = try XCTUnwrap(try workouts(of: userA).first)
        let second = try XCTUnwrap(workout.orderedSets.last)
        try WorkoutStore(context: context, userID: userA).deleteSet(second, of: workout)

        inbox.receive(setSaved(setID: secondSetID, index: 2))

        XCTAssertEqual(workout.sets.count, 1)
        XCTAssertEqual(acks.count, 3)
    }

    func testDeletedWorkoutIsNotRestoredByLateSetOrEnd() throws {
        inbox.receive(setSaved())
        let workout = try XCTUnwrap(try workouts(of: userA).first)
        try WorkoutStore(context: context, userID: userA).delete(workout)

        inbox.receive(setSaved())
        inbox.receive(setSaved(setID: secondSetID, index: 2))
        inbox.receive(workoutEnded(setIDs: [firstSetID, secondSetID]))
        inbox.receive(workoutEnded(setIDs: [firstSetID, secondSetID]))

        XCTAssertTrue(try workouts(of: userA).isEmpty)
        let marker = try XCTUnwrap(try context.fetch(FetchDescriptor<DeletedWorkout>()).first)
        XCTAssertTrue(marker.endHandoffReceived)
        XCTAssertEqual(acks.count, 5)
        XCTAssertEqual(try tasks().map(\.kind), [.delete])
    }

    func testEndWritesEndedAtOnceAndRepeatOnlyAcks() throws {
        inbox.receive(setSaved())
        inbox.receive(workoutEnded())

        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertEqual(
            workout.endedAt?.timeIntervalSince(workout.startedAt), 120)
        XCTAssertTrue(workout.endHandoffReceived)
        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(try tasks().first?.revision, 2)
        XCTAssertEqual(acks.last?["ack_type"] as? String, "workout_ended")
        XCTAssertNil(acks.last?["set_id"])

        inbox.receive(workoutEnded())
        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(acks.count, 3)

        // 结束交接后的未知手表组不接收
        inbox.receive(setSaved(setID: secondSetID, index: 2))
        XCTAssertEqual(workout.sets.count, 1)
        XCTAssertEqual(acks.count, 3)
        XCTAssertNotNil(inbox.problem)
    }

    func testEndForUnknownWorkoutOrMissingSetIsNotAcked() throws {
        inbox.receive(workoutEnded())
        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertNotNil(inbox.problem)

        inbox.receive(setSaved())
        XCTAssertNil(inbox.problem)
        inbox.receive(workoutEnded(setIDs: [firstSetID, secondSetID]))

        let workout = try XCTUnwrap(try workouts(of: userA).first)
        XCTAssertNil(workout.endedAt)
        XCTAssertEqual(acks.count, 1)
    }

    func testSetIDReusedAcrossWorkoutsIsNotAcked() throws {
        inbox.receive(setSaved())
        inbox.receive(setSaved(workout: "44444444-4444-4444-8444-444444444444"))

        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1)
        XCTAssertEqual(acks.count, 1)
    }

    func testInvalidMessagesAreNeitherStoredNorAcked() throws {
        let invalid: [[String: Any]] = [
            envelope("set_saved", [:], version: true),
            envelope("set_saved", [:], version: 2),
            envelope("set_paused", [:]),
            setSaved { $0["final_rep_count"] = 0 },
            setSaved { $0["final_rep_count"] = 10.5 },
            setSaved { $0["final_rep_count"] = "10" },
            setSaved { $0["weight_grams"] = 5000 },
            setSaved { $0.removeValue(forKey: "weight_grams") },
            setSaved { $0["set_id"] = "AAAAAAAA-2222-4222-8222-222222222222" },
            setSaved { $0["time_zone"] = "Mars/Base" },
            setSaved { $0["started_at"] = "2026-10-24T10:00:00Z" },
            setSaved { $0["set_ended_at"] = "2026-10-24T09:59:00.000Z" },
            setSaved { $0["record_source"] = "manual" },
            setSaved { $0["exercise_id"] = "unknown_lift" },
        ]
        for message in invalid { inbox.receive(message) }

        XCTAssertTrue(try context.fetch(FetchDescriptor<Workout>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SetIDRecord>()).isEmpty)
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertNotNil(inbox.problem)
    }

    func testExtraFieldsAreIgnoredAndPhoneBoundTypesAreNotProcessed() throws {
        inbox.receive(setSaved { $0["future_field"] = "x" })
        inbox.receive(envelope("ack", ["ack_type": "set_saved"]))
        inbox.receive(envelope("retry_pending", [:]))

        XCTAssertEqual(try workouts(of: userA).count, 1)
        XCTAssertEqual(sender.sent.count, 1)
    }

    func testHistoryShowsWatchSource() throws {
        inbox.receive(setSaved())
        let workout = try XCTUnwrap(try workouts(of: userA).first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        XCTAssertEqual(
            HistoryFormat.rowSubtitle(of: workout, calendar: calendar), "18:00 · 手表 · 1 个动作 · 1 组")
        XCTAssertEqual(HistoryFormat.timeSpan(of: workout, calendar: calendar), "18:00 · 手表记录")
        inbox.receive(workoutEnded())
        XCTAssertEqual(
            HistoryFormat.timeSpan(of: workout, calendar: calendar), "18:00 – 18:02 · 2 分钟 · 手表记录")
    }
}
