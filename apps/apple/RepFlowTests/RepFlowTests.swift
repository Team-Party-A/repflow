import XCTest

@testable import RepFlow

final class RepFlowTests: XCTestCase {
    // 骨架阶段只验证测试宿主能加载 App 模块，业务测试从第 8 周开始补
    func testContentViewLoads() {
        XCTAssertNotNil(ContentView().body)
    }

    // exercise_id 进契约，重复或不合 openapi 的 pattern 会让上传被拒
    func testExerciseIDsAreUniqueAndMatchContract() {
        let ids = ExerciseCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertNotNil(id.wholeMatch(of: /[a-z][a-z0-9_]{0,63}/), id)
        }
        XCTAssertNil(ExerciseCatalog.exercise(id: "curl"))
    }

    // 已发布的 id 和显示名进了历史记录和后端，改了旧记录会变成「未知动作」
    func testPublishedExercisesUnchangedAndNewOnesManual() {
        let published = [
            "dumbbell_curl": "哑铃弯举", "dumbbell_shoulder_press": "哑铃肩推",
            "dumbbell_squat": "持哑铃深蹲", "bench_press": "卧推", "deadlift": "硬拉",
            "pull_up": "引体向上", "push_up": "俯卧撑",
        ]
        for (id, name) in published {
            XCTAssertEqual(ExerciseCatalog.exercise(id: id)?.displayName, name, id)
        }
        for exercise in ExerciseCatalog.all where published[exercise.id] == nil {
            XCTAssertFalse(exercise.isAutoCounted, exercise.id)
        }
    }

    func testMuscleAnnotationsAndPickerSections() {
        for exercise in ExerciseCatalog.all {
            XCTAssertTrue((1...2).contains(exercise.primaryMuscles.count), exercise.id)
            XCTAssertTrue((0...3).contains(exercise.secondaryMuscles.count), exercise.id)
            XCTAssertTrue(
                Set(exercise.primaryMuscles).isDisjoint(with: exercise.secondaryMuscles),
                exercise.id)
        }
        for group in MuscleGroup.allCases {
            let count = ExerciseCatalog.all.filter { $0.primaryMuscles.contains(group) }.count
            XCTAssertGreaterThanOrEqual(count, 2, group.rawValue)
        }

        let sections = ExerciseCatalog.pickerSections
        XCTAssertEqual(sections.first?.title, "自动计次")
        XCTAssertTrue(sections.first?.exercises.allSatisfy(\.isAutoCounted) ?? false)
        let listed = sections.flatMap(\.exercises).map(\.id)
        XCTAssertEqual(listed.sorted(), ExerciseCatalog.all.map(\.id).sorted())
    }
}
