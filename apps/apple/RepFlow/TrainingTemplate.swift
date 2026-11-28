import Foundation
import SwiftData

struct TemplateTarget: Identifiable, Equatable {
    var id = UUID()
    var exerciseID: String
    var sets: Int
    var reps: Int
    var weightGrams: Int?

    static func from(_ rows: [DraftSet]) -> [Self] {
        var targets: [Self] = []
        for row in rows {
            if let last = targets.indices.last, targets[last].exerciseID == row.exerciseID,
                targets[last].reps == row.reps, targets[last].weightGrams == row.weightGrams
            {
                targets[last].sets += 1
            } else {
                targets.append(
                    Self(
                        exerciseID: row.exerciseID, sets: 1, reps: row.reps,
                        weightGrams: row.weightGrams))
            }
        }
        return targets
    }

    static func prefill(_ targets: [Self]) -> [DraftSet] {
        targets.flatMap { target in
            (0..<target.sets).map { _ in
                DraftSet(
                    exerciseID: target.exerciseID, reps: target.reps,
                    weightGrams: target.weightGrams)
            }
        }
    }
}

@Model
final class TrainingTemplate {
    @Attribute(.unique) var templateID: UUID
    var userID: UUID
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \TrainingTarget.template)
    var targets: [TrainingTarget]

    init(userID: UUID, name: String, targets: [TemplateTarget]) {
        templateID = UUID()
        self.userID = userID
        self.name = name
        self.targets = targets.enumerated().map {
            TrainingTarget(position: $0.offset, target: $0.element)
        }
    }

    var orderedTargets: [TemplateTarget] {
        targets.sorted { $0.position < $1.position }.map(\.value)
    }

    static func owned(by userID: UUID) -> Predicate<TrainingTemplate> {
        #Predicate { $0.userID == userID }
    }
}

@Model
final class TrainingTarget {
    var position: Int
    var exerciseID: String
    var sets: Int
    var reps: Int
    var weightGrams: Int?
    var template: TrainingTemplate?

    init(position: Int, target: TemplateTarget) {
        self.position = position
        exerciseID = target.exerciseID
        sets = target.sets
        reps = target.reps
        weightGrams = target.weightGrams
    }

    var value: TemplateTarget {
        TemplateTarget(exerciseID: exerciseID, sets: sets, reps: reps, weightGrams: weightGrams)
    }
}

struct TrainingWeek {
    let days: [Date]
    let trained: Set<Date>
    let streak: Int
    let minutes: Int

    init(sessions: [(start: Date, end: Date?)], now: Date, calendar input: Calendar) {
        var calendar = input
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -offset, to: today)!
        days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: monday)! }
        let started = sessions.filter { $0.start <= now }
        trained = Set(started.map { calendar.startOfDay(for: $0.start) })
        let weeks = Set(
            trained.map { day in
                let offset = (calendar.component(.weekday, from: day) + 5) % 7
                return calendar.date(byAdding: .day, value: -offset, to: day)!
            })
        var week =
            weeks.contains(monday) ? monday : calendar.date(byAdding: .day, value: -7, to: monday)!
        var consecutive = 0
        while weeks.contains(week) {
            consecutive += 1
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }
        streak = consecutive
        // 跨周训练只取落在本周并且已经结束的那段。
        let seconds = started.reduce(0.0) { total, session in
            guard let end = session.end, end <= now else { return total }
            return total + max(0, end.timeIntervalSince(max(session.start, monday)))
        }
        minutes = Int(seconds / 60)
    }
}
