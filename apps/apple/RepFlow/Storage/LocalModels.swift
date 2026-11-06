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
