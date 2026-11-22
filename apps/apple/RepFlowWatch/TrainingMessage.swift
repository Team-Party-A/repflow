import CoreFoundation
import Foundation

/// 保存时冻结 JSON 字节。后台重试直接使用这些字节，避免重新生成时间或身份。
struct TrainingMessage: Codable {
    enum Kind: String, Codable {
        case setSaved = "set_saved"
        case workoutEnded = "workout_ended"
    }
    enum Delivery: String, Codable {
        case pending, failed, delivered

        var label: String {
            switch self {
            case .pending: "待同步 · 待传到手机"
            case .failed: "传到手机失败 · 重试"
            case .delivered: "已同步到手机"
            }
        }
    }
    let kind: Kind
    let id: UUID
    let payload: Data
    var delivery = Delivery.pending

    var userInfo: [String: Any] { ["type": kind.rawValue, "version": 1, "payload": payload] }

    private static func timestamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    private init(_ kind: Kind, _ id: UUID, _ fields: [String: Any]) throws {
        self.kind = kind
        self.id = id
        payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard payload.count <= 65536 else { throw MessageError.limit }
    }

    static func saved(_ set: ManualTrainingSet, in workout: ManualWorkout, estimate: Int) throws
        -> Self
    {
        guard let end = set.endedAt, workout.startedAt <= set.startedAt, set.startedAt <= end,
            (0...Int(Int32.max)).contains(estimate), (1...9999).contains(set.reps)
        else { throw MessageError.invalid }
        return try Self(
            .setSaved, set.id,
            [
                "workout_id": workout.id.uuidString.lowercased(),
                "set_id": set.id.uuidString.lowercased(),
                "started_at": timestamp(workout.startedAt), "time_zone": workout.timeZone,
                "set_started_at": timestamp(set.startedAt), "set_ended_at": timestamp(end),
                "set_index": workout.sets.count + 1, "exercise_id": set.exerciseID,
                "final_rep_count": set.reps, "estimated_rep_count": estimate,
                "record_source": "automatic", "weight_grams": NSNull(),
            ])
    }

    static func ended(_ workout: ManualWorkout, at end: Date) throws -> Self {
        guard workout.sets.count <= 1000 else { throw MessageError.limit }
        return try Self(
            .workoutEnded, workout.id,
            [
                "workout_id": workout.id.uuidString.lowercased(),
                "started_at": timestamp(workout.startedAt),
                "time_zone": workout.timeZone, "ended_at": timestamp(end),
                "saved_set_ids": workout.sets.map { $0.id.uuidString.lowercased() },
            ])
    }
}

enum MessageError: LocalizedError {
    case invalid, limit
    var errorDescription: String? {
        switch self {
        case .invalid: "训练消息格式、版本或时间无效，请检查数据或更新 App。"
        case .limit: "训练超过消息大小或 1000 组上限，请保留本地记录。"
        }
    }
}

enum PhoneSignal {
    case retry
    case ack(UUID, UUID?)

    init(_ info: [String: Any]) throws {
        guard let version = info["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: version.objCType)), version == 1,
            let data = info["payload"] as? Data, data.count <= 65536,
            String(data: data, encoding: .utf8) != nil,
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MessageError.invalid }
        switch info["type"] as? String {
        case "retry_pending": self = .retry
        case "ack":
            guard let workout = Self.uuid(fields["workout_id"]) else { throw MessageError.invalid }
            switch fields["ack_type"] as? String {
            case "set_saved":
                guard let set = Self.uuid(fields["set_id"]) else { throw MessageError.invalid }
                self = .ack(workout, set)
            case "workout_ended" where fields["set_id"] == nil: self = .ack(workout, nil)
            default: throw MessageError.invalid
            }
        default: throw MessageError.invalid
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String, let id = UUID(uuidString: string),
            id.uuidString.lowercased() == string, id.uuid.6 >> 4 == 4, id.uuid.8 >> 6 == 2
        else { return nil }
        return id
    }
}
