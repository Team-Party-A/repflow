import SwiftData
import XCTest

@testable import RepFlow

@MainActor
final class TrainingStatsTests: XCTestCase {
    private let userID = UUID()
    private var store: WorkoutStore!
    // 固定时区和周起始，测试不随运行机器变化
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    override func setUp() async throws {
        let container = try WorkoutStore.makeContainer(inMemory: true)
        store = WorkoutStore(context: ModelContext(container), userID: userID)
    }

    private func date(_ day: Int, _ hour: Int = 10, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 2026-11-26 周四；本周为 11-23（周一）到 11-29（周日）
    private var now: Date { date(26) }

    private func set(_ exerciseID: String = "dumbbell_curl", reps: Int, weight: Int? = nil)
        -> WorkoutSet
    {
        WorkoutSet(
            position: 0, exerciseID: exerciseID, finalRepCount: reps, recordSource: .manual,
            weightGrams: weight)
    }

    @discardableResult
    private func workout(at startedAt: Date, minutes: Int? = nil, _ sets: [WorkoutSet]) throws
        -> Workout
    {
        let workout = try store.create(
            startedAt: startedAt, timeZone: "Asia/Shanghai", origin: .phone, sets: sets)
        if let minutes {
            workout.endedAt = startedAt.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return workout
    }

    private func weekTotals() throws -> StatsTotals {
        TrainingStats.summary(of: try store.workouts(), period: .week, now: now, calendar: calendar)
            .totals
    }

    // MARK: REQ-IOS-009

    /// 第 1 条：本周 2 次训练、3 组，次数 8、10、12
    private func makeRequirementExample() throws -> Workout {
        try workout(at: date(24), [set(reps: 8)])
        return try workout(at: date(26), [set(reps: 10), set(reps: 12)])
    }

    func testRequirementExample() throws {
        try makeRequirementExample()
        let totals = try weekTotals()
        XCTAssertEqual(totals.workoutCount, 2)
        XCTAssertEqual(totals.setCount, 3)
        XCTAssertEqual(totals.totalReps, 30)
    }

    func testEditingRepsRecomputes() throws {
        let second = try makeRequirementExample()
        let ten = second.orderedSets.first { $0.finalRepCount == 10 }!
        try store.updateSet(
            ten, in: second,
            to: DraftSet(id: ten.setID, exerciseID: ten.exerciseID, reps: 9, weightGrams: nil))

        XCTAssertEqual(try weekTotals().totalReps, 29)
    }

    func testDeletingSetRecomputes() throws {
        let second = try makeRequirementExample()
        let twelve = second.orderedSets.first { $0.finalRepCount == 12 }!
        try store.deleteSet(twelve, of: second)

        let totals = try weekTotals()
        XCTAssertEqual(totals.workoutCount, 2)
        XCTAssertEqual(totals.setCount, 2)
        XCTAssertEqual(totals.totalReps, 18)
    }

    // MARK: 空数据

    func testEmptyData() {
        let summary = TrainingStats.summary(of: [], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.totals, StatsTotals())
        XCTAssertEqual(summary.days.count, 7)
        XCTAssertTrue(summary.days.allSatisfy { $0.totals == StatsTotals() })
        XCTAssertEqual(summary.average(of: .reps), 0)

        let load = TrainingStats.muscleLoad(of: [], metric: .sets)
        XCTAssertEqual(load.count, 6)
        XCTAssertTrue(load.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(TrainingStats.exerciseSummaries(of: []), [])
        XCTAssertEqual(TrainingStats.maxWeightSeries(of: "dumbbell_curl", in: []), [])
    }

    // MARK: 区间

    func testWeekBoundarySundayInMondayOut() throws {
        try workout(at: date(23, 0, 0), [set(reps: 1)])  // 本周一 00:00，计入
        try workout(at: date(22, 23, 59), [set(reps: 2)])  // 上周日 23:59，不计
        try workout(at: date(29, 23, 59), [set(reps: 4)])  // 本周日 23:59，计入
        try workout(at: date(30, 0, 0), [set(reps: 8)])  // 下周一 00:00，不计

        let summary = TrainingStats.summary(
            of: try store.workouts(), period: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.interval.start, date(23, 0, 0))
        XCTAssertEqual(summary.totals.totalReps, 5)
        XCTAssertEqual(summary.days.first?.totals.totalReps, 1)
        XCTAssertEqual(summary.days.last?.totals.totalReps, 4)
    }

    func testMonthPeriodHasEveryDay() throws {
        try workout(at: date(1), [set(reps: 3)])
        try workout(at: date(31, month: 10), [set(reps: 5)])

        let summary = TrainingStats.summary(
            of: try store.workouts(), period: .month, now: now, calendar: calendar)
        XCTAssertEqual(summary.days.count, 30)
        XCTAssertEqual(summary.totals.totalReps, 3)
    }

    // MARK: 时长、总重量、按天分布

    func testDurationSkipsWorkoutsWithoutEnd() throws {
        try workout(at: date(24), minutes: 45, [set(reps: 1)])
        try workout(at: date(25), [set(reps: 1)])

        XCTAssertEqual(try weekTotals().durationSeconds, 45 * 60)
    }

    func testVolumeCountsOnlyWeightedSets() throws {
        try workout(
            at: date(24),
            [
                set(reps: 10, weight: 5000),  // 50 000
                set("push_up", reps: 20, weight: 0),  // 徒手
                set(reps: 8),  // 未填重量
                set("bench_press", reps: 5, weight: 60000),  // 300 000
            ])

        XCTAssertEqual(try weekTotals().volumeGrams, 350_000)
    }

    func testDailyDistributionAndAverage() throws {
        try workout(at: date(24, 9), [set(reps: 10)])
        try workout(at: date(24, 18), [set(reps: 6)])
        try workout(at: date(26), [set(reps: 8)])

        let summary = TrainingStats.summary(
            of: try store.workouts(), period: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.days.map(\.totals.totalReps), [0, 16, 0, 8, 0, 0, 0])
        XCTAssertEqual(summary.days[1].totals.workoutCount, 2)
        // 按有训练的 2 天平均，不是 7 天
        XCTAssertEqual(summary.average(of: .reps), 12)
        XCTAssertEqual(summary.average(of: .sets), 1.5)
    }

    // MARK: 肌群加权

    func testMuscleLoadPrimaryFullSecondaryHalf() throws {
        // 卧推：主 胸；次 肩、手臂
        let bench = try workout(at: date(24), [set("bench_press", reps: 10, weight: 40000)])
        // 弯举：主 手臂；字典里没有的动作不计
        let curl = try workout(
            at: date(25), [set(reps: 6, weight: 10000), set("unknown_move", reps: 99)])
        let workouts = [bench, curl]

        let reps = TrainingStats.muscleLoad(of: workouts, metric: .reps)
        XCTAssertEqual(reps[.chest], 10)
        XCTAssertEqual(reps[.shoulders], 5)
        XCTAssertEqual(reps[.arms], 11)
        XCTAssertEqual(reps[.legs], 0)

        let sets = TrainingStats.muscleLoad(of: workouts, metric: .sets)
        XCTAssertEqual(sets[.chest], 1)
        XCTAssertEqual(sets[.arms], 1.5)

        let volume = TrainingStats.muscleLoad(of: workouts, metric: .volume)
        XCTAssertEqual(volume[.chest], 400_000)
        XCTAssertEqual(volume[.arms], 200_000 + 60_000)
    }

    // MARK: 单动作

    func testExerciseSummariesSortedBySetCount() throws {
        try workout(
            at: date(24),
            [set("bench_press", reps: 5), set(reps: 10), set(reps: 10), set("push_up", reps: 30)])

        let summaries = TrainingStats.exerciseSummaries(of: try store.workouts())
        XCTAssertEqual(
            summaries,
            [
                ExerciseSummary(exerciseID: "dumbbell_curl", setCount: 2, totalReps: 20),
                ExerciseSummary(exerciseID: "push_up", setCount: 1, totalReps: 30),
                ExerciseSummary(exerciseID: "bench_press", setCount: 1, totalReps: 5),
            ])
    }

    func testExerciseSessionsNewestFirstAndMaxWeightSeries() throws {
        let first = try workout(at: date(20), [set(reps: 10, weight: 5000), set(reps: 8)])
        let noWeight = try workout(at: date(22), [set(reps: 12), set("push_up", reps: 20)])
        let latest = try workout(
            at: date(25), [set(reps: 8, weight: 7500), set(reps: 6, weight: 10000)])
        try workout(at: date(26), [set("push_up", reps: 15)])

        let sessions = TrainingStats.sessions(of: "dumbbell_curl", in: try store.workouts())
        XCTAssertEqual(
            sessions.map(\.workout.workoutID),
            [latest.workoutID, noWeight.workoutID, first.workoutID])
        XCTAssertEqual(sessions[0].sets.map(\.finalRepCount), [8, 6])
        XCTAssertEqual(sessions[1].sets.map(\.finalRepCount), [12])

        XCTAssertEqual(
            TrainingStats.maxWeightSeries(of: "dumbbell_curl", in: try store.workouts()),
            [
                MaxWeightPoint(startedAt: date(20), weightGrams: 5000),
                MaxWeightPoint(startedAt: date(25), weightGrams: 10000),
            ])
        // 只有徒手或未填重量时没有折线
        XCTAssertEqual(TrainingStats.maxWeightSeries(of: "push_up", in: try store.workouts()), [])
    }
}
