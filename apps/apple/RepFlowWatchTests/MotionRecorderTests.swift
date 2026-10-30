import XCTest

@testable import RepFlowWatch

final class MotionRecorderTests: XCTestCase {
    func testIdleActionsCannotCreateARecordingOrAdvancePhase() {
        let recorder = MotionRecorder()
        recorder.beginSet()
        recorder.endSet()
        XCTAssertNil(recorder.stopAndSave())
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(recorder.sampleCount, 0)
    }

    func testInvalidParticipantIsRejectedBeforeRequestingDeviceAccess() {
        let recorder = MotionRecorder()
        recorder.start(
            participant: "Alice", activity: "dumbbell_curl", negative: false, frequency: 50)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(recorder.message.contains("匿名编号"))
    }
}
