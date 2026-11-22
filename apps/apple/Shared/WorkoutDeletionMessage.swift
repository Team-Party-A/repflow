import CoreFoundation
import Foundation

/// 新通知独立使用 v2，组、结束及其确认继续使用 v1。
enum WorkoutDeletionMessage: String {
    case notification = "workout_deleted"
    case receipt = "workout_deletion_ack"

    func envelope(for id: UUID) -> [String: Any] {
        // UUID 的规范字符串只含十六进制字符和连字符。
        let payload = Data(#"{"workout_id":"\#(id.uuidString.lowercased())"}"#.utf8)
        return ["type": rawValue, "version": 2, "payload": payload]
    }

    func workoutID(in info: [String: Any]) -> UUID? {
        guard info["type"] as? String == rawValue, let version = info["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(version as CFNumber), version == 2,
            let data = info["payload"] as? Data, data.count <= 65536,
            String(data: data, encoding: .utf8) != nil,
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = fields["workout_id"] as? String, let id = UUID(uuidString: text),
            text == id.uuidString.lowercased(), id.uuid.6 >> 4 == 4, id.uuid.8 >> 6 == 2
        else { return nil }
        return id
    }
}
