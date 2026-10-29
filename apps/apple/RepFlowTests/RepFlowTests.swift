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
}
