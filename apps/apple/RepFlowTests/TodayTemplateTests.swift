import Foundation
import SwiftData
import XCTest

@testable import RepFlow

@MainActor
final class TodayTemplateTests: XCTestCase {
    func testMondayBoundaryAndIncompleteWeek() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12)))
        let monday = calendar.startOfDay(for: now)
        let sunday = monday.addingTimeInterval(-600)
        let priorSunday = sunday.addingTimeInterval(-7 * 86400)
        let sessions: [(start: Date, end: Date?)] = [
            (sunday, monday.addingTimeInterval(900)), (priorSunday, nil),
        ]
        let week = TrainingWeek(sessions: sessions, now: now, calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first, monday)
        XCTAssertEqual(week.minutes, 15)
        XCTAssertEqual(week.streak, 2)
        let started = TrainingWeek(sessions: sessions + [(now, nil)], now: now, calendar: calendar)
        XCTAssertEqual(started.streak, 3)
        XCTAssertEqual(started.minutes, 15)
        let empty = TrainingWeek(sessions: [], now: now, calendar: calendar)
        XCTAssertEqual(empty.streak, 0)
        XCTAssertEqual(empty.minutes, 0)
    }

    func testTemplateOwnershipAndPrefillSnapshots() throws {
        let container = try WorkoutStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let owner = UUID()
        let other = UUID()
        let sets = [
            DraftSet(exerciseID: "push_up", reps: 8, weightGrams: nil),
            DraftSet(exerciseID: "push_up", reps: 8, weightGrams: nil),
            DraftSet(exerciseID: "dumbbell_curl", reps: 6, weightGrams: 5000),
            DraftSet(exerciseID: "push_up", reps: 9, weightGrams: 0),
        ]
        let template = TrainingTemplate(
            userID: owner, name: "周末", targets: TemplateTarget.from(sets))
        context.insert(template)
        context.insert(TrainingTemplate(userID: other, name: "周末", targets: []))
        try context.save()
        let mine = try context.fetch(FetchDescriptor(predicate: TrainingTemplate.owned(by: owner)))
        XCTAssertEqual(mine.map(\.templateID), [template.templateID])
        let targets = template.orderedTargets
        XCTAssertEqual(targets.map(\.sets), [2, 1, 1])
        let actual = TemplateTarget.prefill(targets)
        XCTAssertEqual(Set(actual.map(\.id)).count, 4)
        XCTAssertEqual(actual.map(\.exerciseID), sets.map(\.exerciseID))
        XCTAssertEqual(actual.map(\.weightGrams), [nil, nil, 5000, 0])
        template.targets.first?.reps = 50
        context.delete(template)
        try context.save()
        XCTAssertEqual(actual.map(\.reps), [8, 8, 6, 9])
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor(predicate: TrainingTemplate.owned(by: other))), 1
        )
    }
}
