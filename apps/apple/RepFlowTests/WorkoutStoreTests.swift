import SwiftData
import XCTest

@testable import RepFlow

@MainActor
final class WorkoutStoreTests: XCTestCase {
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
    private func createCurlWorkout(in store: WorkoutStore) throws -> Workout {
        try store.create(
            startedAt: Date(), timeZone: "Asia/Shanghai", origin: .phone,
            sets: [
                WorkoutSet(
                    position: 0, exerciseID: "dumbbell_curl", finalRepCount: 10,
                    recordSource: .manual, weightGrams: 0),
                WorkoutSet(
                    position: 0, exerciseID: "push_up", finalRepCount: 20, recordSource: .manual),
            ])
    }

    func testAccountsCannotSeeEachOthersWorkouts() throws {
        try createCurlWorkout(in: store(for: userA))
        try createCurlWorkout(in: store(for: userB))
        try createCurlWorkout(in: store(for: userB))

        XCTAssertEqual(try store(for: userA).workouts().count, 1)
        XCTAssertEqual(try store(for: userB).workouts().count, 2)
        XCTAssertTrue(try store(for: userA).workouts().allSatisfy { $0.userID == userA })
    }

    func testWorkoutsSurviveLogoutAndReturnOnRelogin() throws {
        let created = try createCurlWorkout(in: store(for: userA))
        // 退出后 B 登录，再换回 A：中间不删任何数据，A 用新的上下文读回
        XCTAssertTrue(try store(for: userB).workouts().isEmpty)

        let reloaded = try store(for: userA).workouts()
        XCTAssertEqual(reloaded.map(\.workoutID), [created.workoutID])
        XCTAssertEqual(reloaded[0].orderedSets.map(\.exerciseID), ["dumbbell_curl", "push_up"])
        XCTAssertEqual(reloaded[0].orderedSets.map(\.position), [1, 2])
        // null 与 0 是不同的重量
        XCTAssertEqual(reloaded[0].orderedSets.map(\.weightGrams), [0, nil])
    }

    func testSaveIncrementsRevisionAndMarksPending() throws {
        let store = store(for: userA)
        let workout = try createCurlWorkout(in: store)
        XCTAssertEqual(workout.revision, 1)

        workout.confirmedRevision = 1
        XCTAssertTrue(workout.isSynced)

        try store.update(workout) { $0.orderedSets[0].finalRepCount = 12 }
        try store.update(workout) { $0.endedAt = Date() }

        let reloaded = try XCTUnwrap(self.store(for: userA).workouts().first)
        XCTAssertEqual(reloaded.revision, 3)
        XCTAssertEqual(reloaded.uploadState, .pending)
        XCTAssertEqual(reloaded.orderedSets[0].finalRepCount, 12)
        XCTAssertFalse(reloaded.isSynced)
    }
}
