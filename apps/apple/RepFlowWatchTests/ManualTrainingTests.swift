import XCTest

@testable import RepFlowWatch

final class ManualTrainingTests: XCTestCase {
    private var fileURL: URL!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("manual-training.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testAllSharedExercisesCanCompleteManualSetsWithoutDuplicateSaves() throws {
        let training = ManualTraining(fileURL: fileURL)
        XCTAssertTrue(training.storageReady)
        training.startSet(exerciseID: "unknown", at: start)
        XCTAssertEqual(training.phase, .choose)
        for exercise in ExerciseCatalog.all {
            training.startSet(exerciseID: exercise.id, at: start)
            let candidateID = training.current?.candidate?.id
            training.startSet(exerciseID: "push_up", at: start)
            XCTAssertEqual(training.current?.candidate?.id, candidateID)
            training.adjustReps(by: 1)
            XCTAssertEqual(training.current?.candidate?.reps, 0)
            training.endSet(at: start.addingTimeInterval(30))
            training.adjustReps(by: -1)
            training.saveSet()
            XCTAssertEqual(training.phase, .review)
            XCTAssertEqual(training.current?.candidate?.reps, 0)
            training.adjustReps(by: 1)
            training.saveSet()
            training.saveSet()
            XCTAssertEqual(training.phase, .rest)
        }
        XCTAssertEqual(training.current?.sets.map(\.exerciseID), ExerciseCatalog.all.map(\.id))
        XCTAssertEqual(training.current?.sets.count, 7)
        XCTAssertEqual(training.current?.totalReps, 7)
        XCTAssertEqual(ManualTraining(fileURL: fileURL).current?.totalReps, 7)
    }

    func testRestartRestoresCandidateThenSavedWorkoutAndKeepsHistory() throws {
        var training = ManualTraining(fileURL: fileURL)
        training.startSet(exerciseID: "dumbbell_curl", at: start)
        let workoutID = training.current?.id
        let setID = training.current?.candidate?.id
        training = ManualTraining(fileURL: fileURL)
        XCTAssertEqual(training.phase, .active)
        XCTAssertEqual(training.current?.candidate?.id, setID)
        training.endSet(at: start.addingTimeInterval(10))
        training.adjustReps(by: 1)
        training.adjustReps(by: 1)
        training = ManualTraining(fileURL: fileURL)
        XCTAssertEqual(training.phase, .review)
        XCTAssertEqual(training.current?.candidate?.reps, 2)
        training.saveSet()
        training.finishWorkout(at: start.addingTimeInterval(20))
        training = ManualTraining(fileURL: fileURL)
        XCTAssertEqual(training.phase, .summary)
        XCTAssertEqual(training.current?.sets.first?.id, setID)
        XCTAssertEqual(training.current?.totalReps, 2)
        training.prepareNewWorkout()
        training.startSet(exerciseID: "deadlift", at: start.addingTimeInterval(30))
        XCTAssertNotEqual(training.current?.id, workoutID)
        XCTAssertEqual(training.snapshot.workouts.first?.totalReps, 2)
        XCTAssertEqual(training.current?.candidate?.reps, 0)
    }

    func testFailedSaveAndEndKeepCandidateAndDiskUntilRetry() throws {
        var failWrite = false
        let training = ManualTraining(fileURL: fileURL) { data, url in
            if failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        training.startSet(exerciseID: "push_up", at: start)
        training.endSet(at: start.addingTimeInterval(10))
        training.adjustReps(by: 1)
        let savedData = try Data(contentsOf: fileURL)
        failWrite = true
        training.saveSet()
        XCTAssertEqual(training.phase, .review)
        XCTAssertEqual(training.current?.candidate?.reps, 1)
        XCTAssertEqual(training.current?.sets.count, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), savedData)
        XCTAssertTrue(training.errorMessage.contains("保存失败"))
        training.finishWorkout(discardCandidate: true, at: start.addingTimeInterval(20))
        XCTAssertEqual(training.phase, .review)
        XCTAssertNotNil(training.current?.candidate)
        XCTAssertNil(training.current?.endedAt)
        failWrite = false
        training.saveSet()
        training.saveSet()
        XCTAssertEqual(training.current?.sets.count, 1)
        XCTAssertEqual(training.errorMessage, "")
    }

    func testEndRequiresExplicitDiscardAndNeverDeletesConfirmedSets() throws {
        let training = ManualTraining(fileURL: fileURL)
        training.startSet(exerciseID: "bench_press", at: start)
        training.endSet(at: start.addingTimeInterval(10))
        training.adjustReps(by: 1)
        training.saveSet()
        let savedID = training.current?.sets.first?.id
        training.startSet(exerciseID: "pull_up", at: start.addingTimeInterval(20))
        training.finishWorkout(at: start.addingTimeInterval(30))
        XCTAssertEqual(training.phase, .active)
        training.endSet(at: start.addingTimeInterval(30))
        training.finishWorkout(at: start.addingTimeInterval(40))
        XCTAssertEqual(training.phase, .review)
        training.finishWorkout(discardCandidate: true, at: start.addingTimeInterval(40))
        XCTAssertEqual(training.phase, .summary)
        XCTAssertEqual(training.current?.sets.map(\.id), [savedID].compactMap { $0 })
        XCTAssertNil(training.current?.candidate)
    }

    func testDiscardKeepsWorkoutAndNextSetHasNewIdentity() throws {
        let training = ManualTraining(fileURL: fileURL)
        training.startSet(exerciseID: "dumbbell_curl", at: start)
        let previousID = training.current?.candidate?.id
        let workoutID = training.current?.id
        training.endSet(at: start.addingTimeInterval(10))
        training.discardSet()
        training.startSet(exerciseID: "dumbbell_shoulder_press", at: start.addingTimeInterval(20))
        XCTAssertEqual(training.current?.id, workoutID)
        XCTAssertNotEqual(training.current?.candidate?.id, previousID)
        XCTAssertEqual(training.current?.sets.count, 0)
    }

    func testUpperBoundAndBackwardClockDoNotCorruptCandidate() throws {
        let training = ManualTraining(fileURL: fileURL)
        training.startSet(exerciseID: "dumbbell_squat", at: start)
        training.endSet(at: start.addingTimeInterval(-1))
        XCTAssertEqual(training.phase, .active)
        training.endSet(at: start.addingTimeInterval(10))
        var snapshot = training.snapshot
        snapshot.workouts[0].candidate?.reps = 9999
        try JSONEncoder().encode(snapshot).write(to: fileURL)
        training.reload()
        training.adjustReps(by: 1)
        XCTAssertEqual(training.current?.candidate?.reps, 9999)
        training.adjustReps(by: -1)
        XCTAssertEqual(training.current?.candidate?.reps, 9998)
        training.saveSet()
        training.finishWorkout(at: start)
        XCTAssertEqual(training.phase, .rest)
    }

    func testUnreadableOrFutureVersionStorageIsPreservedAndBlocksWrites() throws {
        for data in [Data("invalid JSON".utf8), Data("{\"version\":2,\"workouts\":[]}".utf8)] {
            try data.write(to: fileURL)
            let training = ManualTraining(fileURL: fileURL)
            XCTAssertFalse(training.storageReady)
            training.startSet(exerciseID: "push_up", at: start)
            XCTAssertEqual(try Data(contentsOf: fileURL), data)
            XCTAssertFalse(training.errorMessage.isEmpty)
        }
    }
}
