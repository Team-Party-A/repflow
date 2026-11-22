import Foundation
import WatchConnectivity

/// UI 操作、后台回执和定时补发都在主队列访问同一份训练状态。
final class TrainingOutbox {
    static let shared = TrainingOutbox(training: ManualTraining())
    let training: ManualTraining
    private var attempts: [UUID: (next: Date, delay: TimeInterval)] = [:]
    private var wakeup: DispatchWorkItem?

    struct Transport {
        var inFlight: () -> Set<UUID>?
        var send: ([String: Any]) -> Void

        static let session = Transport(
            inFlight: {
                guard WCSession.isSupported(), WCSession.default.activationState == .activated
                else { return nil }
                return Set(
                    WCSession.default.outstandingUserInfoTransfers.compactMap {
                        identity($0.userInfo)?.id
                    })
            },
            send: { WCSession.default.transferUserInfo($0) })
    }
    private let transport: Transport

    init(training: ManualTraining, transport: Transport = .session) {
        self.training = training
        self.transport = transport
        training.outboxChanged = { [weak self] in self?.check() }
    }

    func check(force: Bool = false) {
        guard let inFlight = transport.inFlight() else { return }
        drain(at: Date(), force: force, inFlight: inFlight, send: transport.send)
    }

    func drain(at now: Date, force: Bool, inFlight: Set<UUID>, send: ([String: Any]) -> Void) {
        wakeup?.cancel()
        guard training.storageReady else { return }
        let ready = training.snapshot.workouts.flatMap(\.readyMessages)
        let keys = Set(ready.map(\.id))
        attempts = attempts.filter { keys.contains($0.key) }
        guard !ready.isEmpty else { return }
        var nextWake: TimeInterval = 300
        for message in ready {
            if inFlight.contains(message.id) {
                nextWake = min(nextWake, 30)
                continue
            }
            if let attempt = attempts[message.id], !force, attempt.next > now {
                nextWake = min(nextWake, attempt.next.timeIntervalSince(now))
                continue
            }
            let delay = min(300, (attempts[message.id]?.delay ?? 5) * 2)
            attempts[message.id] = (now.addingTimeInterval(delay), delay)
            send(message.userInfo)
            nextWake = min(nextWake, delay)
        }
        let work = DispatchWorkItem { [weak self] in self?.check() }
        wakeup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nextWake, execute: work)
    }

    func receive(_ userInfo: [String: Any]) {
        do {
            if userInfo["type"] as? String == WorkoutDeletionMessage.notification.rawValue {
                guard let id = WorkoutDeletionMessage.notification.workoutID(in: userInfo) else {
                    throw MessageError.invalid
                }
                if training.applyDeletion(id), transport.inFlight() != nil {
                    transport.send(WorkoutDeletionMessage.receipt.envelope(for: id))
                }
                return
            }
            switch try PhoneSignal(userInfo) {
            case .ack(let workout, let set):
                training.updateDelivery(workoutID: workout, setID: set, to: .delivered)
            case .retry: check(force: true)
            }
        } catch { training.reportInvalidMessage(error) }
    }

    func transferFinished(_ info: [String: Any], error: Error?) {
        if error != nil, let key = Self.identity(info) {
            training.updateDelivery(workoutID: key.workout, setID: key.set, to: .failed)
        }
        check()
    }

    private static func identity(_ info: [String: Any]) -> (workout: UUID, set: UUID?, id: UUID)? {
        guard let data = info["payload"] as? Data,
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = fields["workout_id"] as? String, let workout = UUID(uuidString: raw)
        else { return nil }
        switch info["type"] as? String {
        case "workout_ended": return (workout, nil, workout)
        case "set_saved":
            guard let raw = fields["set_id"] as? String, let set = UUID(uuidString: raw) else {
                return nil
            }
            return (workout, set, set)
        default: return nil
        }
    }
}
