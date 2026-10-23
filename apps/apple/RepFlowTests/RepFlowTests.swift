import XCTest

@testable import RepFlow

final class RepFlowTests: XCTestCase {
    // 骨架阶段只验证测试宿主能加载 App 模块，业务测试从第 8 周开始补
    func testContentViewLoads() {
        XCTAssertNotNil(ContentView().body)
    }
}
