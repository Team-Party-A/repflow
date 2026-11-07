import Foundation

/// 单条训练在界面上的同步状态。来自训练本身，不看上传队列里有没有任务：
/// 已同步 = 当前 revision 被后端确认；其余看队列是否把它标成失败或被拒收。
enum SyncStatus {
    case pending
    case failed
    case synced
}

extension Workout {
    var syncStatus: SyncStatus {
        if isSynced { return .synced }
        return uploadState == .failed ? .failed : .pending
    }

    /// 按首次出现的顺序去重，详情页按动作分组、列表行拼动作名都用它
    var exerciseIDs: [String] {
        var seen = Set<String>()
        return orderedSets.map(\.exerciseID).filter { seen.insert($0).inserted }
    }

    var totalReps: Int {
        sets.reduce(0) { $0 + $1.finalRepCount }
    }
}

/// 同步失败横幅的说明。UI 规范 7.2：网络类失败提供重试；被后端拒收的按错误码说明原因，
/// 输入错误引导去修改。拒收后仍保留「重试」：后端修好或更新动作字典后，同一份快照可能被接受。
enum FailureHint {
    static func detail(state: UploadTaskState?, errorCode: String?) -> String {
        guard state == .rejected else { return "网络或服务器暂时不可用，可以点重试" }
        switch errorCode {
        case "VALIDATION_ERROR":
            return "内容不符合要求，后端没有接受。请修改有问题的组后重新保存"
        case "REVISION_CONFLICT":
            return "后端已有这次训练的其他版本，本机修改没有覆盖它"
        case "SET_ID_CONFLICT":
            return "有组和你的另一次训练重复，后端没有接受"
        case "WORKOUT_DELETED":
            return "这次训练已在后端删除，不能再恢复上传"
        default:
            return "后端没有接受这次训练，可以修改后重新保存"
        }
    }
}

enum ExerciseName {
    /// 清单里没有的动作键保留原样显示，不猜名称
    static func of(_ exerciseID: String) -> String {
        ExerciseCatalog.exercise(id: exerciseID)?.displayName ?? exerciseID
    }
}

/// 日期与时间文案，规则见 UI 规范 3.3。按设备当前时区显示。
enum HistoryFormat {
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func monthDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// 「今天」「昨天」，更早的返回 nil
    private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String? {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
        return days == 0 ? "今天" : days == 1 ? "昨天" : nil
    }

    /// 列表里按天分组的标题：今天、昨天、10月16日 周五
    static func dayHeader(_ date: Date, now: Date = Date(), calendar: Calendar = .current)
        -> String
    {
        if let relative = relativeDay(date, now: now, calendar: calendar) { return relative }
        let weekday = calendar.component(.weekday, from: date)
        return "\(monthDay(date, calendar: calendar)) 周\(weekdays[weekday - 1])"
    }

    /// 详情页副标题：有结束时间给完整时间段，否则只有开始时间
    static func timeSpan(of workout: Workout, calendar: Calendar = .current) -> String {
        let start = time(workout.startedAt, calendar: calendar)
        if let endedAt = workout.endedAt {
            let minutes = Int((endedAt.timeIntervalSince(workout.startedAt) / 60).rounded())
            if minutes > 0 {
                return "\(start) – \(time(endedAt, calendar: calendar)) · \(minutes) 分钟"
            }
        }
        return workout.origin == .phone ? "\(start) · 手动记录" : start
    }
}
