import XCTest

@testable import RepFlowWatch

final class CurlTrainingTests: XCTestCase {
    func testRealTimeCycleFreezeCorrectionRecoveryAndNextSet() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let training = ManualTraining(fileURL: file)
        training.startSet(exerciseID: "dumbbell_curl", automaticCurl: true)
        let id = try XCTUnwrap(training.current?.candidate?.id)
        let sampling = CurlSampling()
        sampling.reset(for: id)
        var tick = 0
        for (rate, frames) in [(0.0, 15), (2.0, 30), (-2.0, 30), (0, 15)] {
            for _ in 0..<frames {
                sampling.append(
                    .init(
                        timestamp: Double(tick) / 50, userAccelerationG: .zero,
                        rotationRateRadS: .init(0, -rate, 0), gravityG: .zero), for: id)
                tick += 1
            }
        }
        XCTAssertEqual(sampling.count, 1)
        sampling.stop()
        guard case .stopped(let end) = sampling.phase else { return XCTFail("应冻结估计") }
        training.freezeCurl(setID: id, estimate: sampling.count, at: end)
        training.adjustReps(by: -1)
        training.saveSet()
        XCTAssertEqual(training.phase, .review)
        training.adjustReps(by: 1)
        training.adjustReps(by: 1)
        let restored = ManualTraining(fileURL: file)
        XCTAssertEqual(restored.current?.candidate?.frozenEstimate, 1)
        restored.saveSet()
        let payload = try XCTUnwrap(restored.current?.readyMessages.first?.payload)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(fields["estimated_rep_count"] as? Int, 1)
        XCTAssertEqual(fields["final_rep_count"] as? Int, 2)
        restored.startSet(exerciseID: "dumbbell_curl", automaticCurl: true)
        let next = try XCTUnwrap(restored.current?.candidate?.id)
        sampling.reset(for: next)
        sampling.append(
            .init(timestamp: 1, userAccelerationG: .zero, rotationRateRadS: .zero, gravityG: .zero),
            for: id)
        XCTAssertEqual(sampling.count, 0)
        XCTAssertFalse(sampling.hasSample)
        XCTAssertNotEqual(next, id)
    }

    func testUnavailableAndInterruptedSamplesAreDistinctFromCountingZero() {
        let sampling = CurlSampling()
        let id = UUID()
        sampling.reset(for: id)
        sampling.interrupt("无权限")
        XCTAssertFalse(sampling.hasSample)
        guard case .interrupted("无权限", _) = sampling.phase else { return XCTFail("须显示原因") }
        sampling.reset(for: id)
        for t in [1.0, 1.4] {
            sampling.append(
                .init(
                    timestamp: t, userAccelerationG: .zero, rotationRateRadS: .zero, gravityG: .zero
                ), for: id)
        }
        XCTAssertTrue(sampling.hasSample)
        guard case .interrupted = sampling.phase else { return XCTFail("间断后应停止计次") }
        sampling.stop()
        guard case .interrupted = sampling.phase else { return XCTFail("不能当作正常结束") }
    }
}
