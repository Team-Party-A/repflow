/// 一个可记录的动作。`id` 就是契约里的 `exercise_id`，会写进手表↔手机消息和后端 API，
/// 发布后不能改名或换给别的动作。
struct Exercise: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// 只有 true 的动作在手表上自动计次；其余在手表上手动加减，手机上都能手动记录
    let isAutoCounted: Bool
    let load: ExerciseLoad
}

/// `weight_grams` 记的是哪部分重量。同一个数字对哑铃和杠铃含义不同，界面要据此标注。
enum ExerciseLoad: Sendable {
    /// 单只哑铃的重量（两手各一只时不翻倍）
    case perDumbbell
    /// 杠铃含杠总重
    case barbellTotal
    /// 自重之外的额外负重，徒手记 0
    case addedToBodyweight
}

enum ExerciseCatalog {
    static let all: [Exercise] = [
        Exercise(
            id: "dumbbell_curl", displayName: "哑铃弯举", isAutoCounted: true, load: .perDumbbell),
        Exercise(
            id: "dumbbell_shoulder_press", displayName: "哑铃肩推", isAutoCounted: true,
            load: .perDumbbell),
        // 腕部信号可能偏弱，迭代 2 看采集数据再决定是否自动计次
        Exercise(
            id: "dumbbell_squat", displayName: "持哑铃深蹲", isAutoCounted: false,
            load: .perDumbbell),
        Exercise(id: "bench_press", displayName: "卧推", isAutoCounted: false, load: .barbellTotal),
        Exercise(id: "deadlift", displayName: "硬拉", isAutoCounted: false, load: .barbellTotal),
        Exercise(
            id: "pull_up", displayName: "引体向上", isAutoCounted: false, load: .addedToBodyweight),
        Exercise(
            id: "push_up", displayName: "俯卧撑", isAutoCounted: false, load: .addedToBodyweight),
    ]

    /// 契约规定未知 `exercise_id` 不能猜名称：查不到返回 nil，由调用方保留记录并提示更新
    static func exercise(id: String) -> Exercise? {
        all.first { $0.id == id }
    }
}
