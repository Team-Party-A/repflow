import Combine
import Foundation

/// 历史手动组没有训练消息，读取旧快照时保持本地记录。
struct ManualTrainingSet: Codable, Identifiable {
    var id = UUID()
    let exerciseID: String
    let startedAt: Date
    var endedAt: Date?
    var message: TrainingMessage?
    var reps = 0
}

struct ManualWorkout: Codable, Identifiable {
    var id = UUID()
    let startedAt: Date
    let timeZone: String
    var endedAt: Date?
    var sets: [ManualTrainingSet] = []
    var candidate: ManualTrainingSet?

    var endMessage: TrainingMessage?

    var readyMessages: [TrainingMessage] {
        let groups = sets.compactMap(\.message).filter { $0.delivery != .delivered }
        if groups.isEmpty, let endMessage, endMessage.delivery != .delivered { return [endMessage] }
        return groups
    }

    var totalReps: Int { sets.reduce(0) { $0 + $1.reps } }
}

struct ManualTrainingSnapshot: Codable {
    var version = 1
    var workouts: [ManualWorkout] = []
    var currentID: UUID?
}

final class ManualTraining: ObservableObject {
    enum Phase { case choose, active, review, rest, summary }

    @Published private(set) var snapshot = ManualTrainingSnapshot()
    @Published private(set) var errorMessage = ""
    @Published private(set) var storageReady = false
    var outboxChanged: (() -> Void)?
    private let fileURL: URL
    private let write: (Data, URL) throws -> Void

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("manual-training.json")
    }

    init(
        fileURL: URL = ManualTraining.defaultFileURL,
        write: @escaping (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.write = write
        reload()
    }

    var current: ManualWorkout? { snapshot.workouts.first { $0.id == snapshot.currentID } }
    var phase: Phase {
        guard let current else { return .choose }
        if current.endedAt != nil { return .summary }
        if let candidate = current.candidate {
            return candidate.endedAt == nil ? .active : .review
        }
        return .rest
    }

    func reload() {
        do {
            let loaded: ManualTrainingSnapshot
            do {
                loaded = try JSONDecoder().decode(
                    ManualTrainingSnapshot.self, from: Data(contentsOf: fileURL))
            } catch CocoaError.fileReadNoSuchFile {
                loaded = ManualTrainingSnapshot()
            }
            guard loaded.version == 1,
                loaded.currentID == nil
                    || loaded.workouts.contains(where: { $0.id == loaded.currentID })
            else { throw CocoaError(.fileReadCorruptFile) }
            for workout in loaded.workouts {
                guard
                    workout.sets.allSatisfy({ (1...9999).contains($0.reps) && $0.endedAt != nil }),
                    workout.candidate.map({ (0...9999).contains($0.reps) }) ?? true,
                    workout.endedAt == nil || workout.candidate == nil
                else { throw CocoaError(.fileReadCorruptFile) }
            }
            snapshot = loaded
            storageReady = true
            errorMessage = ""
            outboxChanged?()
        } catch {
            storageReady = false
            errorMessage = "读取手表训练记录失败，原文件已保留。请重试：\(error.localizedDescription)"
        }
    }

    func startSet(exerciseID: String, at date: Date = Date()) {
        guard storageReady, phase == .choose || phase == .rest,
            ExerciseCatalog.exercise(id: exerciseID) != nil
        else { return }
        var next = snapshot
        if current == nil {
            let workout = ManualWorkout(startedAt: date, timeZone: TimeZone.current.identifier)
            next.workouts.append(workout)
            next.currentID = workout.id
        }
        guard let index = next.workouts.firstIndex(where: { $0.id == next.currentID }) else {
            return
        }
        next.workouts[index].candidate = ManualTrainingSet(exerciseID: exerciseID, startedAt: date)
        persist(next)
    }

    func endSet(at date: Date = Date()) {
        guard phase == .active, let candidate = current?.candidate else { return }
        guard date >= candidate.startedAt else {
            clockError()
            return
        }
        updateCurrent { $0.candidate?.endedAt = date }
    }

    func adjustReps(by delta: Int) {
        guard phase == .review, let count = current?.candidate?.reps, delta == -1 || delta == 1,
            (0...9999).contains(count + delta)
        else { return }
        updateCurrent { $0.candidate?.reps += delta }
    }

    func saveSet(estimatedRepCount: Int? = nil) {
        guard phase == .review, let current, var candidate = current.candidate else { return }
        guard (1...9999).contains(candidate.reps) else {
            errorMessage = "0 次不能保存，请增加次数或放弃本组。"
            return
        }
        // v1 的结束清单必须包含全部组。同次训练不能混合手动组和自动组。
        if let first = current.sets.first, (first.message == nil) != (estimatedRepCount == nil) {
            errorMessage = "请结束本次训练，再切换记录方式。"
            return
        }
        if let estimate = estimatedRepCount {
            do {
                guard current.sets.count < 1000 else { throw MessageError.limit }
                candidate.message = try TrainingMessage.saved(
                    candidate, in: current, estimate: estimate)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        updateCurrent {
            $0.sets.append(candidate)
            $0.candidate = nil
        }
    }

    /// 调用方先展示破坏性操作确认；此处只丢弃候选，已确认组不变。
    func discardSet() {
        guard phase == .review || phase == .active else { return }
        updateCurrent { $0.candidate = nil }
    }

    func finishWorkout(discardCandidate: Bool = false, at date: Date = Date()) {
        guard let current, current.endedAt == nil else { return }
        guard current.candidate == nil || discardCandidate else {
            errorMessage = "请先结束本组并核对，或确认放弃本组后再结束训练。"
            return
        }
        guard date >= current.startedAt,
            current.sets.allSatisfy({ date >= ($0.endedAt ?? $0.startedAt) })
        else {
            clockError()
            return
        }
        let endMessage: TrainingMessage?
        do {
            endMessage =
                current.sets.first?.message == nil
                ? nil : try TrainingMessage.ended(current, at: date)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // 结束消息和结束状态同时落盘，是否可投递由组 ack 推导。
        updateCurrent {
            $0.candidate = nil
            $0.endedAt = date
            $0.endMessage = endMessage
        }
    }

    func prepareNewWorkout() {
        guard phase == .summary else { return }
        var next = snapshot
        next.currentID = nil
        persist(next)
    }

    func updateDelivery(workoutID: UUID, setID: UUID?, to status: TrainingMessage.Delivery) {
        var next = snapshot
        guard let w = next.workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        if let setID {
            guard let i = next.workouts[w].sets.firstIndex(where: { $0.id == setID }),
                let message = next.workouts[w].sets[i].message,
                message.delivery != .delivered, message.delivery != status
            else { return }
            next.workouts[w].sets[i].message?.delivery = status
        } else {
            guard let message = next.workouts[w].endMessage,
                message.delivery != .delivered, message.delivery != status,
                next.workouts[w].sets.allSatisfy({ $0.message?.delivery == .delivered })
            else { return }
            next.workouts[w].endMessage?.delivery = status
        }
        persist(next)
    }

    func reportInvalidMessage(_ error: Error) { errorMessage = error.localizedDescription }

    private func updateCurrent(_ change: (inout ManualWorkout) -> Void) {
        guard let index = snapshot.workouts.firstIndex(where: { $0.id == snapshot.currentID })
        else {
            return
        }
        var next = snapshot
        change(&next.workouts[index])
        persist(next)
    }

    private func persist(_ next: ManualTrainingSnapshot) {
        guard storageReady else { return }
        do {
            try write(JSONEncoder().encode(next), fileURL)
            snapshot = next
            errorMessage = ""
            outboxChanged?()
        } catch {
            errorMessage = "保存失败，当前内容已保留。请重试刚才的操作：\(error.localizedDescription)"
        }
    }

    private func clockError() {
        errorMessage = "系统时间早于本组或训练开始时间，请检查手表时间后重试。"
    }
}
