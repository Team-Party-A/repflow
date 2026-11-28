/// 统计和动作分组用的六个粗粒度肌群。只在两端本地使用，不进契约；
/// case 顺序就是界面上分组和雷达图轴的顺序。
enum MuscleGroup: String, CaseIterable, Identifiable, Sendable {
    case chest
    case back
    case shoulders
    case arms
    case legs
    case core

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chest: "胸"
        case .back: "背"
        case .shoulders: "肩"
        case .arms: "手臂"
        case .legs: "腿"
        case .core: "核心"
        }
    }
}
