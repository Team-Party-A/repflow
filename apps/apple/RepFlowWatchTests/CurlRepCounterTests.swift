import XCTest

@testable import RepFlowWatch

final class CurlRepCounterTests: XCTestCase {
    private var counter = CurlRepCounter()
    private var tick = 0

    private func append(rate: Double, frames: Int) {
        for _ in 0..<frames {
            counter.append(
                .init(
                    timestamp: Double(tick) / 50, userAccelerationG: .zero,
                    rotationRateRadS: SIMD3(0, -rate, 0), gravityG: .zero))
            tick += 1
        }
    }

    private func lift() {
        append(rate: 0, frames: 15)
        append(rate: 2, frames: 30)
    }

    private func lower() {
        append(rate: -2, frames: 30)
        append(rate: 0, frames: 15)
    }

    func testCountsEachCompletedCycleDuringTheSet() {
        for expected in 1...2 {
            lift()
            XCTAssertEqual(counter.count, expected - 1)
            lower()
            XCTAssertEqual(counter.count, expected)
        }
    }

    func testTopHoldAndPartialReturnDoNotCount() {
        lift()
        append(rate: 0, frames: 40)
        append(rate: -2, frames: 8)
        append(rate: 0, frames: 20)
        XCTAssertEqual(counter.finish(), 0)
    }

    func testPauseAtTopStillAllowsAFullReturn() {
        lift()
        append(rate: 0, frames: 40)
        XCTAssertEqual(counter.count, 0)
        lower()
        XCTAssertEqual(counter.finish(), 1)
    }

    func testFinishFreezesTheEstimateEvenIfSamplesArriveLater() {
        lift()
        lower()
        lift()
        XCTAssertEqual(counter.finish(), 1)
        lower()
        XCTAssertEqual(counter.finish(), 1)
    }

    func testGapKeepsConfirmedCountButDiscardsThePartialCycle() {
        lift()
        lower()
        lift()
        tick += 20
        lower()
        XCTAssertEqual(counter.gapCount, 1)
        XCTAssertEqual(counter.count, 1)
        lift()
        lower()
        XCTAssertEqual(counter.finish(), 2)
    }

    func testResetStartsAnEmptyGroupOnANewTimeAxis() {
        lift()
        lower()
        tick += 20
        append(rate: 0, frames: 1)
        XCTAssertEqual(counter.gapCount, 1)
        XCTAssertEqual(counter.finish(), 1)
        counter.reset()
        tick = 0
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.gapCount, 0)
        lift()
        lower()
        XCTAssertEqual(counter.finish(), 1)
    }
}
