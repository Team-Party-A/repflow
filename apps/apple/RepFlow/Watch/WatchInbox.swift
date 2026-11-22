import Foundation
import SwiftData
import WatchConnectivity
import os

private let logger = Logger(subsystem: "repflow", category: "watch-inbox")

/// 手机往手表发 ack、retry_pending 的出口；测试里换成只记录发出内容的实现
protocol WatchMessageSender: AnyObject {
    var isActivated: Bool { get }
    func transfer(_ userInfo: [String: Any])
    /// 系统队列里还有没送达的同类消息
    func hasOutstanding(type: String) -> Bool
}

extension RecordingTransfer: WatchMessageSender {
    var isActivated: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    func transfer(_ userInfo: [String: Any]) {
        WCSession.default.transferUserInfo(userInfo)
    }

    func hasOutstanding(type: String) -> Bool {
        WCSession.default.outstandingUserInfoTransfers.contains {
            $0.userInfo["type"] as? String == type
        }
    }
}

/// 手表消息契约 v1 第 3.2、3.3 节的手机侧：校验、归属、去重，本地写入成功后才回 ack。
/// 只写本地，上传交给 UploadQueue。
@MainActor
final class WatchInbox: ObservableObject {
    /// 最近一条没能接收的消息给用户的说明；之后成功处理一条就清掉
    @Published private(set) var problem: String?

    private let context: ModelContext
    private let sender: any WatchMessageSender
    private let currentUserID: () -> UUID?
    /// 本地写入成功后调用，参数是当前登录账号，用来触发上传
    private let onStored: (UUID) -> Void

    init(
        context: ModelContext, sender: any WatchMessageSender,
        currentUserID: @escaping () -> UUID?, onStored: @escaping (UUID) -> Void
    ) {
        self.context = context
        self.sender = sender
        self.currentUserID = currentUserID
        self.onStored = onStored
    }

    func receive(_ userInfo: [String: Any]) {
        let type = userInfo["type"] as? String ?? "?"
        guard let userID = currentUserID() else {
            // 未登录不写库、不 ack：副本由手表保留，登录后发 retry_pending 让它补发
            logger.info("watch message ignored while logged out: type=\(type)")
            return
        }
        do {
            let ack: [String: String]
            switch try WatchMessage(userInfo) {
            case .setSaved(let message):
                try receive(message, loggedIn: userID)
                ack = [
                    "ack_type": "set_saved", "workout_id": message.workoutID.contractString,
                    "set_id": message.setID.contractString,
                ]
            case .workoutEnded(let message):
                try receive(message)
                ack = ["ack_type": "workout_ended", "workout_id": message.workoutID.contractString]
            case .notForPhone:
                return
            }
            send("ack", ack)
            problem = nil
            onStored(userID)
        } catch let error as WatchMessageError {
            logger.error("watch message rejected: type=\(type), error=\(error.description)")
            problem = error.hint
        } catch {
            logger.error("save watch message failed: type=\(type), error=\(error)")
            problem = "保存手表记录失败，稍后会重试；记录仍保留在手表上"
        }
    }

    /// 登录成功，或 session 激活时已登录：请手表检查发件箱。系统队列里已有一条就不再排
    func requestRetry() {
        guard currentUserID() != nil, sender.isActivated,
            !sender.hasOutstanding(type: "retry_pending")
        else { return }
        send("retry_pending", [:])
    }

    private func receive(_ message: SetSaved, loggedIn userID: UUID) throws {
        let setID = message.setID
        let workoutID = message.workoutID
        if let record = try first(
            FetchDescriptor<SetIDRecord>(predicate: #Predicate { $0.setID == setID }))
        {
            // 重复组只认 ID：不比内容、不覆盖手机上的编辑、不恢复删除
            guard record.workoutID == workoutID else {
                throw WatchMessageError.conflict(
                    "set \(setID) 已属于训练 \(record.workoutID)，消息里是 \(workoutID)")
            }
            return
        }
        // 归属按 workout_id 跨账号查：已知训练始终归原账号，只有新训练才绑定当前账号
        if let marker = try first(
            FetchDescriptor<DeletedWorkout>(predicate: #Predicate { $0.workoutID == workoutID }))
        {
            try WorkoutStore(context: context, userID: marker.userID)
                .recordDeletedWatchSet(setID, workoutID: workoutID)
            return
        }
        let existing = try first(
            FetchDescriptor<Workout>(predicate: #Predicate { $0.workoutID == workoutID }))
        if let existing, existing.endHandoffReceived {
            throw WatchMessageError.conflict("训练 \(workoutID) 已结束交接，不再接收新组 \(setID)")
        }
        let set = WorkoutSet(
            setID: setID, position: 0, exerciseID: message.exerciseID,
            finalRepCount: message.finalRepCount, estimatedRepCount: message.estimatedRepCount,
            recordSource: .automatic)
        set.setStartedAt = message.setStartedAt
        set.setEndedAt = message.setEndedAt
        set.watchSetIndex = message.setIndex
        try WorkoutStore(context: context, userID: existing?.userID ?? userID).receiveWatchSet(
            set, workoutID: workoutID, startedAt: message.startedAt,
            timeZone: message.timeZone, into: existing)
    }

    private func receive(_ message: WorkoutEnded) throws {
        let workoutID = message.workoutID
        let marker = try first(
            FetchDescriptor<DeletedWorkout>(predicate: #Predicate { $0.workoutID == workoutID }))
        let workout = try first(
            FetchDescriptor<Workout>(predicate: #Predicate { $0.workoutID == workoutID }))
        guard marker != nil || workout != nil else {
            throw WatchMessageError.conflict("结束消息指向本机没有的训练 \(workoutID)")
        }
        // 重复结束直接 ack，不覆盖手机之后的编辑或删除
        if marker?.endHandoffReceived == true || workout?.endHandoffReceived == true { return }
        // 手表收齐组 ack 才发结束，缺组说明协议出错或本机数据丢了；不建空训练、不等
        let received = Set(
            try context.fetch(
                FetchDescriptor<SetIDRecord>(predicate: #Predicate { $0.workoutID == workoutID })
            ).map(\.setID))
        let missing = message.savedSetIDs.filter { !received.contains($0) }
        guard missing.isEmpty else {
            throw WatchMessageError.conflict("训练 \(workoutID) 的结束清单缺组 \(missing)")
        }
        if let marker {
            try WorkoutStore(context: context, userID: marker.userID).recordDeletedWatchEnd(marker)
        } else if let workout {
            try WorkoutStore(context: context, userID: workout.userID)
                .receiveWatchEnd(workout, endedAt: message.endedAt)
        }
    }

    private func send(_ type: String, _ payload: [String: String]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            sender.transfer(["type": type, "version": WatchMessage.version, "payload": data])
        } catch {
            logger.error("encode watch message failed: type=\(type), error=\(error)")
        }
    }

    private func first<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws
        -> Model?
    {
        try context.fetch(descriptor).first
    }
}

enum WatchMessageError: Error, CustomStringConvertible {
    /// 未知 type 或 version
    case unsupported(String)
    /// 已知消息里的字段缺失或不合法
    case invalid(String)
    /// 动作键不在共享字典里；契约不允许猜名称
    case unknownExercise(String)
    /// 跨训练复用 ID、结束指向未知训练或缺组等协议错误
    case conflict(String)

    var description: String {
        switch self {
        case .unsupported(let detail), .invalid(let detail), .conflict(let detail): detail
        case .unknownExercise(let id): "unknown exercise_id \(id)"
        }
    }

    var hint: String {
        switch self {
        case .unsupported: "手表发来了本机不认识的消息版本，请把两端更新到同一版本；记录仍保留在手表上"
        case .invalid: "手表发来的一条训练记录格式不对，没有接收；记录仍保留在手表上"
        case .unknownExercise: "手表记录里有本机不认识的动作，请更新 App；记录仍保留在手表上"
        case .conflict: "手表的一条训练记录和本机数据对不上，没有接收；记录仍保留在手表上"
        }
    }
}

/// 解码后的手表消息。字段约束见契约第 2.2 节
enum WatchMessage {
    case setSaved(SetSaved)
    case workoutEnded(WorkoutEnded)
    /// ack、retry_pending 是手机发给手表的，收到也不处理、不回 ack，避免 ack 循环
    case notForPhone

    static let version = 1
    private static let maxPayloadBytes = 64 * 1024

    init(_ userInfo: [String: Any]) throws {
        let type = userInfo["type"] as? String
        guard let type, let version = userInfo["version"] as? NSNumber,
            version.isInteger, version.intValue == Self.version
        else {
            throw WatchMessageError.unsupported(
                "type=\(type ?? "nil"), version=\(String(describing: userInfo["version"]))")
        }
        if type == "ack" || type == "retry_pending" {
            self = .notForPhone
            return
        }
        guard type == "set_saved" || type == "workout_ended" else {
            throw WatchMessageError.unsupported("type=\(type), version=\(version)")
        }
        guard let data = userInfo["payload"] as? Data else {
            throw WatchMessageError.invalid("\(type) payload 不是 Data")
        }
        // 超限不截断，原样留在手表上报错
        guard data.count <= Self.maxPayloadBytes else {
            throw WatchMessageError.invalid("\(type) payload \(data.count) 字节，超过 64 KiB")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WatchMessageError.invalid("\(type) payload 不是 JSON 对象")
        }
        let fields = PayloadFields(raw: object)
        self =
            type == "set_saved"
            ? .setSaved(try SetSaved(fields))
            : .workoutEnded(
                try WorkoutEnded(fields))
    }
}

struct SetSaved {
    let workoutID: UUID
    let setID: UUID
    let startedAt: Date
    let timeZone: String
    let setStartedAt: Date
    let setEndedAt: Date
    let setIndex: Int
    let exerciseID: String
    let finalRepCount: Int
    let estimatedRepCount: Int

    fileprivate init(_ fields: PayloadFields) throws {
        workoutID = try fields.uuid("workout_id")
        setID = try fields.uuid("set_id")
        startedAt = try fields.date("started_at")
        timeZone = try fields.timeZone("time_zone")
        setStartedAt = try fields.date("set_started_at")
        setEndedAt = try fields.date("set_ended_at")
        setIndex = try fields.int("set_index", in: 1...Int.max)
        exerciseID = try fields.string("exercise_id")
        finalRepCount = try fields.int("final_rep_count", in: 1...9999)
        estimatedRepCount = try fields.int("estimated_rep_count", in: 0...Int(Int32.max))
        guard try fields.string("record_source") == "automatic" else {
            throw WatchMessageError.invalid("record_source 不是 automatic")
        }
        // v1 手表不填重量，必须显式为 null
        guard fields.raw["weight_grams"] is NSNull else {
            throw WatchMessageError.invalid("weight_grams 不是 null")
        }
        guard exerciseID.wholeMatch(of: /[a-z][a-z0-9_]{0,63}/) != nil else {
            throw WatchMessageError.invalid("exercise_id 格式不对：\(exerciseID)")
        }
        guard ExerciseCatalog.exercise(id: exerciseID) != nil else {
            throw WatchMessageError.unknownExercise(exerciseID)
        }
        guard startedAt <= setStartedAt, setStartedAt <= setEndedAt else {
            throw WatchMessageError.invalid("set \(setID) 的时间先后不对")
        }
    }
}

struct WorkoutEnded {
    let workoutID: UUID
    let startedAt: Date
    let timeZone: String
    let endedAt: Date
    let savedSetIDs: [UUID]

    fileprivate init(_ fields: PayloadFields) throws {
        workoutID = try fields.uuid("workout_id")
        startedAt = try fields.date("started_at")
        timeZone = try fields.timeZone("time_zone")
        endedAt = try fields.date("ended_at")
        guard let raw = fields.raw["saved_set_ids"] as? [Any], (1...1000).contains(raw.count)
        else { throw WatchMessageError.invalid("saved_set_ids 不是 1–1000 个元素的数组") }
        savedSetIDs = try raw.map { item in
            guard let text = item as? String else {
                throw WatchMessageError.invalid("saved_set_ids 含非字符串")
            }
            return try PayloadFields.uuid(text, field: "saved_set_ids")
        }
        guard Set(savedSetIDs).count == savedSetIDs.count else {
            throw WatchMessageError.invalid("saved_set_ids 有重复")
        }
        guard startedAt <= endedAt else {
            throw WatchMessageError.invalid("训练 \(workoutID) 结束早于开始")
        }
    }
}

/// payload 的类型化读取。用 JSONSerialization 而不是 Codable：要区分 1 与 true、10 与 10.0
private struct PayloadFields {
    let raw: [String: Any]

    func string(_ key: String) throws -> String {
        guard let text = raw[key] as? String else {
            throw WatchMessageError.invalid("\(key) 缺失或不是字符串")
        }
        return text
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard let number = raw[key] as? NSNumber, number.isInteger,
            range.contains(number.intValue)
        else { throw WatchMessageError.invalid("\(key) 不是 \(range) 内的整数") }
        return number.intValue
    }

    func uuid(_ key: String) throws -> UUID {
        try Self.uuid(string(key), field: key)
    }

    /// 契约要求小写标准形式的 UUIDv4；UUID(uuidString:) 本身大小写和版本都放行
    static func uuid(_ text: String, field: String) throws -> UUID {
        guard
            text.wholeMatch(
                of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil,
            let id = UUID(uuidString: text)
        else { throw WatchMessageError.invalid("\(field) 不是小写 UUIDv4：\(text)") }
        return id
    }

    /// 固定毫秒和 Z 的 UTC 时间
    func date(_ key: String) throws -> Date {
        let text = try string(key)
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil,
            let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        else { throw WatchMessageError.invalid("\(key) 不是带毫秒的 UTC 时间：\(text)") }
        return date
    }

    /// `TimeZone(identifier:)` 还会接受 GMT+0800、PST 这类固定偏移和缩写，后端的 ZoneInfo 不认，
    /// 回了 ack 就再也传不上去。手表发的是 `TimeZone.current.identifier`，总在系统 IANA 列表里；
    /// UTC、Etc/UTC 是列表外的合法别名。
    private static let ianaTimeZones = Set(TimeZone.knownTimeZoneIdentifiers).union([
        "UTC", "Etc/UTC",
    ])

    func timeZone(_ key: String) throws -> String {
        let name = try string(key)
        guard Self.ianaTimeZones.contains(name) else {
            throw WatchMessageError.invalid("\(key) 不是 IANA 时区：\(name)")
        }
        return name
    }
}

extension NSNumber {
    /// 排除布尔值和小数：从属性列表或 JSON 来的 true、10.0 都能桥接成 Int
    fileprivate var isInteger: Bool {
        CFGetTypeID(self) != CFBooleanGetTypeID() && !CFNumberIsFloatType(self as CFNumber)
    }
}

extension UUID {
    /// 契约里的小写形式
    fileprivate var contractString: String { uuidString.lowercased() }
}
