import Foundation
import SwiftData

/// 训练由哪一端创建。只说明训练从哪来，不替代组的 `record_source`。
enum WorkoutOrigin: String, Codable {
    case watch
    case phone
}

/// 当前 `revision` 的上传进度。已同步不单独存，由 `confirmedRevision == revision` 判断，
/// 避免旧版本回执把新内容误标成已同步。
enum UploadState: String, Codable {
    case pending
    case failed
}

/// 对应契约 WorkoutSet 的 `record_source`
enum SetRecordSource: String, Codable {
    case automatic
    case manual
}

/// 本地训练，字段映射见 `docs/design/数据库设计.md` 第 5 节。
/// `record_kind` 一期恒为 `actual`，不存列。
@Model
final class Workout {
    @Attribute(.unique) var workoutID: UUID
    /// 只决定本地隔离和用哪个账号的 token 上传，不进请求体
    var userID: UUID
    var revision: Int32
    var startedAt: Date
    var endedAt: Date?
    /// IANA 时区名
    var timeZone: String
    // SwiftData 在 iOS 17 上不能在谓词里比较枚举，枚举都存原始值
    var originRaw: String
    var uploadStateRaw: String
    /// 后端回执确认过的最高版本，只增不减
    var confirmedRevision: Int32?
    /// 手表结束消息已处理过；之后重复的结束消息不能覆盖手机上的编辑
    var endHandoffReceived: Bool
    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.workout)
    var sets: [WorkoutSet]

    init(
        workoutID: UUID = UUID(), userID: UUID, startedAt: Date, timeZone: String,
        origin: WorkoutOrigin
    ) {
        self.workoutID = workoutID
        self.userID = userID
        self.revision = 1
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.originRaw = origin.rawValue
        self.uploadStateRaw = UploadState.pending.rawValue
        self.endHandoffReceived = false
        self.sets = []
    }

    var origin: WorkoutOrigin {
        WorkoutOrigin(rawValue: originRaw) ?? .phone
    }

    var uploadState: UploadState {
        get { UploadState(rawValue: uploadStateRaw) ?? .pending }
        set { uploadStateRaw = newValue.rawValue }
    }

    var isSynced: Bool {
        confirmedRevision == revision
    }

    /// SwiftData 的对多关系不保证顺序，展示和上传都按 position 排
    var orderedSets: [WorkoutSet] {
        sets.sorted { $0.position < $1.position }
    }
}

@Model
final class WorkoutSet {
    @Attribute(.unique) var setID: UUID
    var workout: Workout?
    /// 从 1 开始，决定上传时在 `sets` 数组里的位置，本身不上传
    var position: Int
    var exerciseID: String
    var finalRepCount: Int
    /// automatic 组必填，manual 组为 nil
    var estimatedRepCount: Int?
    var recordSourceRaw: String
    /// nil 表示未填，0 表示明确零负重
    var weightGrams: Int?
    // 以下只存手机
    var setStartedAt: Date?
    var setEndedAt: Date?
    /// 手表首次发来时的序号；position 可被编辑，这个不变
    var watchSetIndex: Int?

    init(
        setID: UUID = UUID(), position: Int, exerciseID: String, finalRepCount: Int,
        estimatedRepCount: Int? = nil, recordSource: SetRecordSource, weightGrams: Int? = nil
    ) {
        self.setID = setID
        self.position = position
        self.exerciseID = exerciseID
        self.finalRepCount = finalRepCount
        self.estimatedRepCount = estimatedRepCount
        self.recordSourceRaw = recordSource.rawValue
        self.weightGrams = weightGrams
    }

    var recordSource: SetRecordSource {
        SetRecordSource(rawValue: recordSourceRaw) ?? .manual
    }
}

enum UploadKind: String, Codable {
    case put
    case delete
}

enum UploadTaskState: String, Codable {
    /// 等下一次触发（保存、回到前台、登录成功、点重试）
    case waiting
    /// 网络错误、超时、5xx 用完本轮重试；下一次触发会自动再试
    case failed
    /// 后端拒收（409、410、422 等）。同一份快照再发结果不会变，只在用户点重试或内容改出新版本时重发
    case rejected
}

/// 待发送的 PUT / DELETE。一条训练只留一个任务：新版本直接覆盖还没发出的旧任务，
/// 后端只接受更大的 revision，旧版本没必要再发。回执确认后删除。
@Model
final class UploadTask {
    @Attribute(.unique) var workoutID: UUID
    /// 只能用这个账号的 token 发送
    var userID: UUID
    var revision: Int32
    var kindRaw: String
    /// PUT 的完整请求体，重试只发这份，保证同一 revision 不会发出两种内容；DELETE 没有请求体
    var requestSnapshot: Data?
    var stateRaw: String
    var attemptCount: Int
    /// 契约错误码，或 NETWORK、HTTP_502 这类没有契约错误体时的说明
    var lastErrorCode: String?
    var createdAt: Date

    init(workoutID: UUID, userID: UUID) {
        self.workoutID = workoutID
        self.userID = userID
        self.revision = 1
        self.kindRaw = UploadKind.put.rawValue
        self.stateRaw = UploadTaskState.waiting.rawValue
        self.attemptCount = 0
        self.createdAt = Date()
    }

    var kind: UploadKind {
        get { UploadKind(rawValue: kindRaw) ?? .put }
        set { kindRaw = newValue.rawValue }
    }

    var state: UploadTaskState {
        get { UploadTaskState(rawValue: stateRaw) ?? .waiting }
        set { stateRaw = newValue.rawValue }
    }
}

/// 删除标记：训练内容删掉后留下的最小记录，用来挡住手表的旧补发和在途请求把训练恢复。
/// 不过期，退出登录也不清。
@Model
final class DeletedWorkout {
    @Attribute(.unique) var workoutID: UUID
    var userID: UUID
    /// 删除时推进后的 revision，也是 DELETE 任务的 revision
    var revision: Int32
    /// 后端确认过的删除版本
    var confirmedRevision: Int32?
    /// 沿用被删训练的结束交接标记，删除后重复的结束消息仍能认出来
    var endHandoffReceived: Bool

    init(workoutID: UUID, userID: UUID, revision: Int32, endHandoffReceived: Bool) {
        self.workoutID = workoutID
        self.userID = userID
        self.revision = revision
        self.endHandoffReceived = endHandoffReceived
    }
}

/// 本机登录过的账号，见 `docs/design/数据库设计.md` 第 5 节。token 不在这里，在 Keychain。
/// 退出不删：退出或 token 失效后，本机仍知道留下的记录属于哪个用户名，重新登录时能预填。
@Model
final class Account {
    @Attribute(.unique) var userID: UUID
    var username: String

    init(userID: UUID, username: String) {
        self.userID = userID
        self.username = username
    }
}
