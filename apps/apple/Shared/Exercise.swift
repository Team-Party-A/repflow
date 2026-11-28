import SwiftUI

/// 一个可记录的动作。`id` 就是契约里的 `exercise_id`，会写进手表↔手机消息和后端 API，
/// 发布后不能改名或换给别的动作。
struct Exercise: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// 只有 true 的动作在手表上自动计次；其余在手表上手动加减，手机上都能手动记录
    let isAutoCounted: Bool
    let load: ExerciseLoad
    /// 统计时计全量；1–2 个
    let primaryMuscles: [MuscleGroup]
    /// 统计时计一半；0–3 个
    let secondaryMuscles: [MuscleGroup]
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
    // 前 7 个是 v0.1 已发布的动作，id 和显示名不能改；新动作参考 Motra 动作库里健身房常用的
    // 自由重量和自重动作。绳索和固定器械的配重不符合三种重量口径，暂不收录。
    static let all: [Exercise] = [
        Exercise(
            id: "dumbbell_curl", displayName: "哑铃弯举", isAutoCounted: true, load: .perDumbbell,
            primaryMuscles: [.arms], secondaryMuscles: []),
        Exercise(
            id: "dumbbell_shoulder_press", displayName: "哑铃肩推", isAutoCounted: true,
            load: .perDumbbell, primaryMuscles: [.shoulders], secondaryMuscles: [.arms]),
        // 腕部信号可能偏弱，迭代 2 看采集数据再决定是否自动计次
        Exercise(
            id: "dumbbell_squat", displayName: "持哑铃深蹲", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.legs], secondaryMuscles: [.core]),
        Exercise(
            id: "bench_press", displayName: "卧推", isAutoCounted: false, load: .barbellTotal,
            primaryMuscles: [.chest], secondaryMuscles: [.shoulders, .arms]),
        Exercise(
            id: "deadlift", displayName: "硬拉", isAutoCounted: false, load: .barbellTotal,
            primaryMuscles: [.back, .legs], secondaryMuscles: [.core, .arms]),
        Exercise(
            id: "pull_up", displayName: "引体向上", isAutoCounted: false, load: .addedToBodyweight,
            primaryMuscles: [.back], secondaryMuscles: [.arms, .shoulders]),
        Exercise(
            id: "push_up", displayName: "俯卧撑", isAutoCounted: false, load: .addedToBodyweight,
            primaryMuscles: [.chest], secondaryMuscles: [.shoulders, .arms, .core]),

        Exercise(
            id: "dumbbell_bench_press", displayName: "哑铃卧推", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.chest], secondaryMuscles: [.shoulders, .arms]),
        Exercise(
            id: "dumbbell_fly", displayName: "哑铃飞鸟", isAutoCounted: false, load: .perDumbbell,
            primaryMuscles: [.chest], secondaryMuscles: [.shoulders]),
        Exercise(
            id: "barbell_row", displayName: "杠铃俯身划船", isAutoCounted: false,
            load: .barbellTotal, primaryMuscles: [.back], secondaryMuscles: [.arms, .shoulders]),
        Exercise(
            id: "dumbbell_row", displayName: "哑铃单臂划船", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.back], secondaryMuscles: [.arms]),
        Exercise(
            id: "barbell_overhead_press", displayName: "杠铃推举", isAutoCounted: false,
            load: .barbellTotal, primaryMuscles: [.shoulders], secondaryMuscles: [.arms, .core]),
        Exercise(
            id: "dumbbell_lateral_raise", displayName: "哑铃侧平举", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.shoulders], secondaryMuscles: []),
        Exercise(
            id: "barbell_curl", displayName: "杠铃弯举", isAutoCounted: false, load: .barbellTotal,
            primaryMuscles: [.arms], secondaryMuscles: []),
        Exercise(
            id: "dumbbell_hammer_curl", displayName: "哑铃锤式弯举", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.arms], secondaryMuscles: []),
        // 双手握一只哑铃，按单只哑铃记重
        Exercise(
            id: "dumbbell_overhead_triceps_extension", displayName: "哑铃颈后臂屈伸",
            isAutoCounted: false, load: .perDumbbell, primaryMuscles: [.arms],
            secondaryMuscles: [.shoulders]),
        Exercise(
            id: "dips", displayName: "双杠臂屈伸", isAutoCounted: false, load: .addedToBodyweight,
            primaryMuscles: [.arms, .chest], secondaryMuscles: [.shoulders]),
        Exercise(
            id: "barbell_squat", displayName: "杠铃深蹲", isAutoCounted: false,
            load: .barbellTotal, primaryMuscles: [.legs], secondaryMuscles: [.core, .back]),
        Exercise(
            id: "romanian_deadlift", displayName: "罗马尼亚硬拉", isAutoCounted: false,
            load: .barbellTotal, primaryMuscles: [.legs], secondaryMuscles: [.back, .core]),
        Exercise(
            id: "dumbbell_lunge", displayName: "哑铃箭步蹲", isAutoCounted: false,
            load: .perDumbbell, primaryMuscles: [.legs], secondaryMuscles: [.core]),
        Exercise(
            id: "hanging_leg_raise", displayName: "悬垂举腿", isAutoCounted: false,
            load: .addedToBodyweight, primaryMuscles: [.core], secondaryMuscles: [.arms]),
        Exercise(
            id: "ab_rollout", displayName: "腹轮滚出", isAutoCounted: false,
            load: .addedToBodyweight, primaryMuscles: [.core], secondaryMuscles: [.shoulders]),
    ]

    /// 契约规定未知 `exercise_id` 不能猜名称：查不到返回 nil，由调用方保留记录并提示更新
    static func exercise(id: String) -> Exercise? {
        all.first { $0.id == id }
    }

    struct PickerSection: Identifiable {
        let title: String
        let exercises: [Exercise]
        var id: String { title }
    }

    /// 动作选择列表：自动计次的动作单独放最前，其余按第一个主肌群分组
    static let pickerSections: [PickerSection] = {
        let auto = PickerSection(title: "自动计次", exercises: all.filter(\.isAutoCounted))
        let manual = all.filter { !$0.isAutoCounted }
        let groups = MuscleGroup.allCases.map { group in
            PickerSection(
                title: group.displayName,
                exercises: manual.filter { $0.primaryMuscles.first == group })
        }
        return ([auto] + groups).filter { !$0.exercises.isEmpty }
    }()
}

/// 按分组列出的动作选项，手表开组和手机手动记录共用。不用 `Picker`：iOS 把 `Picker` 放进
/// `Menu` 后会丢掉分组标题，所以每个动作是一个按钮，外层 `Menu` 或 `List` 负责呈现。
struct ExerciseChoices: View {
    @Binding var selection: String
    /// 手表上列表是推进来的一页，选完要退回；iOS 的 `Menu` 选完自己会收起，不能再 dismiss，
    /// 否则会把整个表单关掉
    var dismissOnPick = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ForEach(ExerciseCatalog.pickerSections) { section in
            Section(section.title) {
                ForEach(section.exercises) { exercise in
                    Button {
                        selection = exercise.id
                        if dismissOnPick { dismiss() }
                    } label: {
                        if let icon = icon(for: exercise) {
                            Label(exercise.displayName, systemImage: icon)
                        } else {
                            Text(exercise.displayName)
                        }
                    }
                    .accessibilityAddTraits(exercise.id == selection ? .isSelected : [])
                }
            }
        }
    }

    /// 自动计次的动作带手表图标；当前选中的显示对勾（自动计次分组的标题已经说明了它）
    private func icon(for exercise: Exercise) -> String? {
        if exercise.id == selection { return "checkmark" }
        return exercise.isAutoCounted ? "applewatch" : nil
    }
}
