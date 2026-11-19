import SwiftData
import XCTest

@testable import RepFlow

@MainActor
final class HistoryTests: XCTestCase {
    private let userA = UUID()
    private let userB = UUID()
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try WorkoutStore.makeContainer(inMemory: true)
    }

    private func store(for userID: UUID) -> WorkoutStore {
        WorkoutStore(context: ModelContext(container), userID: userID)
    }

    @discardableResult
    private func create(
        in store: WorkoutStore, startedAt: Date = Date(), reps: Int = 10
    ) throws -> Workout {
        try store.create(
            startedAt: startedAt, timeZone: "Asia/Shanghai", origin: .phone,
            sets: [
                WorkoutSet(
                    position: 0, exerciseID: "dumbbell_curl", finalRepCount: reps,
                    recordSource: .manual, weightGrams: 5000)
            ])
    }

    private func draft(of set: WorkoutSet, reps: Int? = nil) -> DraftSet {
        DraftSet(
            id: set.setID, exerciseID: set.exerciseID, reps: reps ?? set.finalRepCount,
            weightGrams: set.weightGrams)
    }

    // MARK: 列表

    func testHistoryIsNewestFirstRegardlessOfInsertOrder() throws {
        let store = store(for: userA)
        let now = Date()
        let older = try create(in: store, startedAt: now.addingTimeInterval(-86_400 * 2))
        let newest = try create(in: store, startedAt: now)
        let middle = try create(in: store, startedAt: now.addingTimeInterval(-86_400))

        let ids = try store.workouts().map(\.workoutID)
        XCTAssertEqual(ids, [newest.workoutID, middle.workoutID, older.workoutID])
    }

    func testHistoryShowsOnlyCurrentAccountEvenWhenOtherIsNewer() throws {
        let now = Date()
        let mine = try create(in: store(for: userA), startedAt: now.addingTimeInterval(-3600))
        try create(in: store(for: userB), startedAt: now)

        XCTAssertEqual(try store(for: userA).workouts().map(\.workoutID), [mine.workoutID])
    }

    func testDeletedWorkoutLeavesHistory() throws {
        let store = store(for: userA)
        let kept = try create(in: store, startedAt: Date())
        let removed = try create(in: store, startedAt: Date().addingTimeInterval(-60))
        try store.delete(removed)

        XCTAssertEqual(try store.workouts().map(\.workoutID), [kept.workoutID])
    }

    // MARK: 编辑与 revision

    func testSavingSetWithoutChangesKeepsRevisionAndTask() throws {
        let store = store(for: userA)
        let workout = try create(in: store)
        let set = workout.orderedSets[0]

        try store.updateSet(set, in: workout, to: draft(of: set))

        XCTAssertEqual(workout.revision, 1)
        let tasks = try store.context.fetch(FetchDescriptor<UploadTask>())
        XCTAssertEqual(tasks.map(\.revision), [1])
    }

    func testSavingUnchangedSetKeepsSyncedStatus() throws {
        let store = store(for: userA)
        let workout = try create(in: store)
        workout.confirmedRevision = 1
        let set = workout.orderedSets[0]

        try store.updateSet(set, in: workout, to: draft(of: set))

        XCTAssertEqual(workout.syncStatus, .synced)
    }

    func testChangingSetAddsExactlyOneRevision() throws {
        let store = store(for: userA)
        let workout = try create(in: store)
        workout.confirmedRevision = 1
        let set = workout.orderedSets[0]

        try store.updateSet(set, in: workout, to: draft(of: set, reps: 12))

        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(set.finalRepCount, 12)
        XCTAssertEqual(workout.syncStatus, .pending)
        let tasks = try store.context.fetch(FetchDescriptor<UploadTask>())
        XCTAssertEqual(tasks.map(\.revision), [2])
    }

    func testAddedSetGoesLastAndBumpsRevision() throws {
        let store = store(for: userA)
        let workout = try create(in: store)

        try store.addSet(
            DraftSet(exerciseID: "push_up", reps: 20, weightGrams: nil), to: workout)

        XCTAssertEqual(workout.revision, 2)
        XCTAssertEqual(workout.orderedSets.map(\.exerciseID), ["dumbbell_curl", "push_up"])
        XCTAssertEqual(workout.orderedSets.last?.recordSource, .manual)
    }

    func testDeletingLastSetRemovesWorkoutFromHistory() throws {
        let store = store(for: userA)
        let workout = try create(in: store)

        try store.deleteSet(workout.orderedSets[0], of: workout)

        XCTAssertTrue(try store.workouts().isEmpty)
    }

    // MARK: 状态与文案

    func testFailureHintDistinguishesRejectionFromNetworkFailure() {
        XCTAssertEqual(
            FailureHint.detail(state: .failed, errorCode: "VALIDATION_ERROR"),
            "网络或服务器暂时不可用，可以点重试")
        XCTAssertTrue(
            FailureHint.detail(state: .rejected, errorCode: "VALIDATION_ERROR").contains("请修改"))
        XCTAssertTrue(
            FailureHint.detail(state: .rejected, errorCode: "WORKOUT_DELETED").contains("已在后端删除"))
        XCTAssertTrue(
            FailureHint.detail(state: .rejected, errorCode: "REVISION_CONFLICT").contains("其他版本"))
        XCTAssertTrue(
            FailureHint.detail(state: .rejected, errorCode: "SET_ID_CONFLICT").contains("重复"))
    }

    func testSyncStatusFollowsConfirmedRevisionAndFailure() throws {
        let workout = try create(in: store(for: userA))
        XCTAssertEqual(workout.syncStatus, .pending)

        workout.uploadState = .failed
        XCTAssertEqual(workout.syncStatus, .failed)

        workout.confirmedRevision = workout.revision
        XCTAssertEqual(workout.syncStatus, .synced)
    }

    func testDayHeaders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
        func header(daysAgo: Int) -> String {
            HistoryFormat.dayHeader(
                now.addingTimeInterval(-86_400 * Double(daysAgo)), now: now, calendar: calendar)
        }

        XCTAssertEqual(header(daysAgo: 0), "今天")
        XCTAssertEqual(header(daysAgo: 1), "昨天")
        XCTAssertEqual(header(daysAgo: 4), "10月16日 周五")
    }

    /// 时长四舍五入到分钟，与原型一致；截断会把 42 分 40 秒显示成 42 分钟
    func testDurationRoundsToNearestMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 10, day: 20, hour: 18, minute: 30, second: 10)
            ))
        let workout = try create(in: store(for: userA), startedAt: start)
        workout.endedAt = start.addingTimeInterval(42 * 60 + 40)

        XCTAssertEqual(
            HistoryFormat.timeSpan(of: workout, calendar: calendar), "18:30 – 19:12 · 43 分钟")
    }
}
