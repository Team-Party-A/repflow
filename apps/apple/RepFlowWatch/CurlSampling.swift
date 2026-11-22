import Combine
import CoreMotion
import HealthKit

/// 每组独占一个运动会话。主队列串行处理样本、结束和权限回调。
final class CurlSampling: NSObject, ObservableObject, HKWorkoutSessionDelegate {
    enum Phase: Equatable {
        case idle, preparing, counting
        case stopped(Date)
        case interrupted(String, Date)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var count = 0
    private(set) var hasSample = false
    private(set) var setID: UUID?
    private var counter = CurlRepCounter()
    private let motion = CMMotionManager()
    private let health = HKHealthStore()
    private var session: HKWorkoutSession?
    private var watchdog: Timer?
    private var lastSampleAt: TimeInterval = 0

    func start(_ id: UUID) {
        reset(for: id)
        guard motion.isDeviceMotionAvailable, HKHealthStore.isHealthDataAvailable() else {
            interrupt("当前设备无法读取运动样本，请在 Apple Watch 上重新开组。")
            return
        }
        health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { _, error in
            DispatchQueue.main.async {
                guard self.setID == id, self.phase == .preparing else { return }
                if let error {
                    self.interrupt(error.localizedDescription)
                    return
                }
                guard
                    self.health.authorizationStatus(for: HKObjectType.workoutType())
                        == .sharingAuthorized
                else {
                    self.interrupt("需要运动权限，请在健康权限中允许 RepFlow 写入体能训练后重新开组。")
                    return
                }
                do {
                    let config = HKWorkoutConfiguration()
                    config.activityType = .traditionalStrengthTraining
                    config.locationType = .indoor
                    let session = try HKWorkoutSession(
                        healthStore: self.health, configuration: config)
                    self.session = session
                    session.delegate = self
                    session.startActivity(with: Date())
                    self.monitorSamples()
                } catch { self.interrupt(error.localizedDescription) }
            }
        }
    }

    func reset(for id: UUID) {
        cancel()
        counter.reset()
        setID = id
        count = 0
        hasSample = false
        phase = .preparing
    }

    private func monitorSamples() {
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let limit: TimeInterval = self.hasSample ? 2 : 10
            if ProcessInfo.processInfo.systemUptime - self.lastSampleAt >= limit {
                self.interrupt(self.hasSample ? "运动样本已中断，请核对已记录的次数。" : "未收到运动样本，请检查权限后重新开组。")
            }
        }
    }

    private func beginMotion(_ id: UUID) {
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) {
            [weak self] value, error in
            guard let self, self.setID == id else { return }
            if let error {
                self.interrupt(error.localizedDescription)
                return
            }
            guard let value else { return }
            let a = value.userAcceleration
            let r = value.rotationRate
            let g = value.gravity
            self.append(
                .init(
                    timestamp: value.timestamp, userAccelerationG: .init(a.x, a.y, a.z),
                    rotationRateRadS: .init(r.x, r.y, r.z), gravityG: .init(g.x, g.y, g.z)), for: id
            )
        }
    }

    func append(_ sample: CurlRepCounter.Sample, for id: UUID) {
        guard setID == id, phase == .preparing || phase == .counting else { return }
        let previousGaps = counter.gapCount
        counter.append(sample)
        if counter.gapCount != previousGaps {
            interrupt("运动样本出现间断，本组已停止计次。")
            return
        }
        hasSample = true
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        if phase != .counting { phase = .counting }
        if count != counter.count { count = counter.count }
    }

    func stop() {
        guard phase == .counting else { return }
        phase = .stopped(Date())
        count = counter.finish()
        stopSensors()
    }

    func interrupt(_ reason: String) {
        guard phase == .preparing || phase == .counting else { return }
        phase = .interrupted(reason, Date())
        count = counter.finish()
        stopSensors()
    }

    func cancel() {
        setID = nil
        phase = .idle
        stopSensors()
    }

    private func stopSensors() {
        watchdog?.invalidate()
        watchdog = nil
        motion.stopDeviceMotionUpdates()
        let previous = session
        session = nil
        previous?.end()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo state: HKWorkoutSessionState,
        from oldState: HKWorkoutSessionState, date: Date
    ) {
        DispatchQueue.main.async {
            guard self.session === workoutSession, let id = self.setID else { return }
            if state == .running && self.phase == .preparing {
                self.beginMotion(id)
            } else if [.paused, .ended, .stopped].contains(state) {
                self.interrupt("运动会话已暂停或结束。")
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            if self.session === workoutSession { self.interrupt(error.localizedDescription) }
        }
    }
}
