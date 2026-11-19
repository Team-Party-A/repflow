import Combine
import CoreMotion
import HealthKit
import WatchKit

final class MotionRecorder: NSObject, ObservableObject, HKWorkoutSessionDelegate {
    enum Phase { case idle, preparing, leadIn, activeSet, tail, stopped, failed }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var sampleCount = 0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var message = ""
    private let motion = CMMotionManager()
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var draft: RecordingDraft?
    private var pendingData: Data?
    private var attempt = UUID()

    func start(participant: String, activity: String, negative: Bool, frequency: Double) {
        guard phase == .idle else { return }
        guard participant.wholeMatch(of: /p[0-9]{3,}/) != nil, !activity.isEmpty else {
            message = "请填写 p001 等匿名编号，并选择动作或场景。"
            return
        }
        guard motion.isDeviceMotionAvailable, HKHealthStore.isHealthDataAvailable() else {
            message = "当前设备不支持运动录制，请使用真实 Apple Watch。"
            return
        }
        let device = WKInterfaceDevice.current()
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        draft = RecordingDraft(
            metadata: .init(
                participantId: participant, recordingKind: negative ? "negative" : "exercise_set",
                activity: activity, wornWrist: device.wristLocation == .left ? "left" : "right",
                crownOrientation: device.crownOrientation == .left ? "left" : "right",
                device: .init(model: Self.hardwareModel(), osVersion: device.systemVersion),
                recorderVersion: "\(version)(\(build))", requestedHz: frequency))
        phase = .preparing
        sampleCount = 0
        elapsed = 0
        message = "正在请求运动权限…"
        let token = UUID()
        attempt = token
        health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { _, error in
            DispatchQueue.main.async {
                guard self.attempt == token, self.phase == .preparing else { return }
                if let error {
                    self.fail(error)
                    return
                }
                guard
                    self.health.authorizationStatus(for: HKObjectType.workoutType())
                        == .sharingAuthorized
                else {
                    self.fail(RecordingError(message: "需要运动权限以支持落腕采样，请在健康权限中允许。"))
                    return
                }
                self.beginWorkout()
            }
        }
    }

    private func beginWorkout() {
        do {
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            session.delegate = self
            workout = session
            session.startActivity(with: Date())
        } catch { fail(error) }
    }

    private func beginMotion() {
        guard let draft else { return }
        motion.deviceMotionUpdateInterval = 1 / draft.metadata.requestedHz
        phase = .leadIn
        message = "等待首个样本；动作组请先静止约 3 秒。"
        let token = attempt
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) {
            [weak self] value, error in
            guard let self, self.attempt == token,
                [.leadIn, .activeSet, .tail].contains(self.phase)
            else { return }
            if let error {
                self.fail(error)
                return
            }
            guard let value else { return }
            do {
                let acceleration = value.userAcceleration
                let rotation = value.rotationRate
                let gravity = value.gravity
                try self.draft?.append(
                    timestamp: value.timestamp,
                    acceleration: [acceleration.x, acceleration.y, acceleration.z],
                    rotation: [rotation.x, rotation.y, rotation.z],
                    gravity: [gravity.x, gravity.y, gravity.z])
                let count = self.draft?.samples.count ?? 0
                if count <= 2 || count.isMultiple(of: 25) {
                    self.sampleCount = count
                    self.elapsed = self.draft?.samples.last?.tS ?? 0
                }
            } catch { self.fail(error) }
        }
    }

    func beginSet() {
        guard phase == .leadIn else { return }
        do {
            try draft?.beginSet(at: ProcessInfo.processInfo.systemUptime)
            phase = .activeSet
            message = "有效组录制中；完成后点结束本组。"
        } catch { message = error.localizedDescription }
    }

    func endSet() {
        guard phase == .activeSet else { return }
        do {
            try draft?.endSet(at: ProcessInfo.processInfo.systemUptime)
            phase = .tail
            message = "有效组已结束，请继续静止约 3 秒再停止录制。"
        } catch { message = error.localizedDescription }
    }

    func stopAndSave() -> URL? {
        guard
            phase == .tail || phase == .stopped
                || (phase == .leadIn && draft?.metadata.recordingKind == "negative")
        else { return nil }
        do {
            if pendingData == nil {
                guard let draft else { return nil }
                let recording = try draft.finish(at: ProcessInfo.processInfo.systemUptime)
                pendingData = try recording.jsonData()
                stopSensors()
                phase = .stopped
                sampleCount = recording.samples.count
                elapsed = recording.durationS
            }
            guard let pendingData else { return nil }
            let file = try RecordingFiles().save(pendingData)
            self.pendingData = nil
            draft = nil
            phase = .idle
            message = "已保存到手表，可发送到手机。"
            return file
        } catch {
            message = "保存未完成：\(error.localizedDescription)"
            return nil
        }
    }

    func discard() {
        stopSensors()
        draft = nil
        pendingData = nil
        phase = .idle
        message = "已放弃本次未保存的录制。"
    }

    private func stopSensors() {
        attempt = UUID()
        motion.stopDeviceMotionUpdates()
        let session = workout
        workout = nil
        session?.end()
    }

    private func fail(_ error: Error) {
        stopSensors()
        phase = .failed
        message = "录制中断，请放弃后重录：\(error.localizedDescription)"
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        DispatchQueue.main.async {
            guard self.workout === workoutSession else { return }
            if toState == .running && self.phase == .preparing {
                self.beginMotion()
            } else if [.paused, .ended, .stopped].contains(toState) {
                self.fail(RecordingError(message: "运动会话已暂停或结束。"))
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            guard self.workout === workoutSession else { return }
            self.fail(error)
        }
    }

    private static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}
