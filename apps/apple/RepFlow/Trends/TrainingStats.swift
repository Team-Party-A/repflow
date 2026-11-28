import Foundation

// 趋势页的全部计算。只读传进来的训练，不碰界面和存储，口径由 TrainingStatsTests 钉死。
//
// REQ-IOS-009 第 3 条「回放数据和未确认的组不计入」：本机 Workout 表里只有实际记录
// （record_kind 恒为 actual，见 LocalModels），手表的候选组确认后才发到手机，回放数据不入库，
// 所以这里不需要再过滤；以后本地表若混入其他来源，要在 `workouts(in:)` 里排除。

/// 统计区间。周一为一周第一天，按设备当前时区。
enum StatsPeriod: CaseIterable {
    case week
    case month

    var title: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        }
    }

    /// 包含 `now` 的本周或本月，左闭右开
    func interval(containing now: Date, calendar: Calendar = .stats) -> DateInterval {
        let component: Calendar.Component = self == .week ? .weekOfYear : .month
        guard let interval = calendar.dateInterval(of: component, for: now) else {
            preconditionFailure("无法计算 \(self) 区间，now=\(now)")
        }
        return interval
    }
}

extension Calendar {
    /// 统计用日历：设备当前日历和时区，周一起算
    static var stats: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }
}

/// 柱状图可切换的指标
enum DailyMetric: CaseIterable {
    case duration
    case volume
    case sets
    case reps
}

/// 一天或一整期的汇总。时长单位秒，重量单位克（与 `weight_grams` 一致，展示时再换算）
struct StatsTotals: Equatable {
    var workoutCount = 0
    var durationSeconds: TimeInterval = 0
    var setCount = 0
    var totalReps = 0
    var volumeGrams = 0

    func value(of metric: DailyMetric) -> Double {
        switch metric {
        case .duration: durationSeconds
        case .volume: Double(volumeGrams)
        case .sets: Double(setCount)
        case .reps: Double(totalReps)
        }
    }

    mutating func add(_ workout: Workout) {
        workoutCount += 1
        durationSeconds += TrainingStats.duration(of: workout) ?? 0
        setCount += workout.sets.count
        for set in workout.sets {
            totalReps += set.finalRepCount
            volumeGrams += TrainingStats.volumeGrams(of: set)
        }
    }
}

struct DayStats: Equatable {
    /// 当天 0 点
    let day: Date
    var totals: StatsTotals
}

struct PeriodSummary: Equatable {
    let interval: DateInterval
    let totals: StatsTotals
    /// 区间内每天一项，没训练的天各项为 0（柱状图留空）
    let days: [DayStats]

    /// 本期平均值虚线：按有训练的天平均，空白天不拉低均值；没有训练时为 0
    func average(of metric: DailyMetric) -> Double {
        let trained = days.filter { $0.totals.workoutCount > 0 }
        guard !trained.isEmpty else { return 0 }
        return trained.reduce(0) { $0 + $1.totals.value(of: metric) } / Double(trained.count)
    }
}

/// 肌群雷达图的口径
enum MuscleMetric: CaseIterable {
    case reps
    case sets
    case volume
}

struct ExerciseSummary: Equatable {
    let exerciseID: String
    let setCount: Int
    let totalReps: Int
}

/// 某个动作在一次训练里的全部组
struct ExerciseSession {
    let workout: Workout
    /// 按 position 排序
    let sets: [WorkoutSet]

    /// 本次该动作的最大重量；没有填过正数重量时为 nil
    var maxWeightGrams: Int? {
        sets.compactMap(\.weightGrams).filter { $0 > 0 }.max()
    }
}

struct MaxWeightPoint: Equatable {
    let startedAt: Date
    let weightGrams: Int
}

enum TrainingStats {
    /// 开始时间落在区间内的训练
    static func workouts(_ workouts: [Workout], in interval: DateInterval) -> [Workout] {
        // DateInterval.contains 含右端点，这里要左闭右开，下周一 00:00 不算本周
        workouts.filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }
    }

    /// 没有结束时间（或结束不晚于开始）的训练不计时长
    static func duration(of workout: Workout) -> TimeInterval? {
        guard let endedAt = workout.endedAt, endedAt > workout.startedAt else { return nil }
        return endedAt.timeIntervalSince(workout.startedAt)
    }

    /// 重量 × 次数；未填重量（nil）和徒手（0）都是 0
    static func volumeGrams(of set: WorkoutSet) -> Int {
        (set.weightGrams ?? 0) * set.finalRepCount
    }

    static func summary(
        of allWorkouts: [Workout], period: StatsPeriod, now: Date = Date(),
        calendar: Calendar = .stats
    ) -> PeriodSummary {
        let interval = period.interval(containing: now, calendar: calendar)
        let inPeriod = workouts(allWorkouts, in: interval)

        var totals = StatsTotals()
        var byDay: [Date: StatsTotals] = [:]
        for workout in inPeriod {
            totals.add(workout)
            byDay[calendar.startOfDay(for: workout.startedAt), default: StatsTotals()].add(
                workout)
        }

        var days: [DayStats] = []
        var day = interval.start
        while day < interval.end {
            days.append(DayStats(day: day, totals: byDay[day] ?? StatsTotals()))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return PeriodSummary(interval: interval, totals: totals, days: days)
    }

    /// 六个肌群各一项（没练到的为 0）。主肌群计全量，次肌群计一半；字典里没有的动作不计
    static func muscleLoad(of workouts: [Workout], metric: MuscleMetric) -> [MuscleGroup: Double] {
        var load = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { ($0, 0.0) })
        for set in workouts.flatMap(\.sets) {
            guard let exercise = ExerciseCatalog.exercise(id: set.exerciseID) else { continue }
            let amount: Double =
                switch metric {
                case .reps: Double(set.finalRepCount)
                case .sets: 1
                case .volume: Double(volumeGrams(of: set))
                }
            for muscle in exercise.primaryMuscles { load[muscle, default: 0] += amount }
            for muscle in exercise.secondaryMuscles { load[muscle, default: 0] += amount / 2 }
        }
        return load
    }

    /// 本期练过的动作，按组数降序；组数相同按总次数降序，再按 exercise_id 保证顺序稳定
    static func exerciseSummaries(of workouts: [Workout]) -> [ExerciseSummary] {
        var sets: [String: Int] = [:]
        var reps: [String: Int] = [:]
        for set in workouts.flatMap(\.sets) {
            sets[set.exerciseID, default: 0] += 1
            reps[set.exerciseID, default: 0] += set.finalRepCount
        }
        return sets.map { id, count in
            ExerciseSummary(exerciseID: id, setCount: count, totalReps: reps[id] ?? 0)
        }
        .sorted {
            ($0.setCount, $0.totalReps, $1.exerciseID) > ($1.setCount, $1.totalReps, $0.exerciseID)
        }
    }

    /// 某动作历次训练的所有组，训练按开始时间倒序，同一次训练内按 position
    static func sessions(of exerciseID: String, in workouts: [Workout]) -> [ExerciseSession] {
        workouts
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { workout in
                let sets = workout.orderedSets.filter { $0.exerciseID == exerciseID }
                return sets.isEmpty ? nil : ExerciseSession(workout: workout, sets: sets)
            }
    }

    /// 最大重量折线，按时间正序；没有重量记录的训练不出点，整个动作都没有时为空数组
    static func maxWeightSeries(of exerciseID: String, in workouts: [Workout]) -> [MaxWeightPoint] {
        sessions(of: exerciseID, in: workouts).reversed().compactMap { session in
            session.maxWeightGrams.map {
                MaxWeightPoint(startedAt: session.workout.startedAt, weightGrams: $0)
            }
        }
    }
}
