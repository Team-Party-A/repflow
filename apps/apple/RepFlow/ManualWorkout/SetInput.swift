import Foundation

/// 手动录入一组时的输入校验，规则与原型 `readSetForm` 和契约 WorkoutSet 一致。
enum SetInput {
    static let maxReps = 9999
    static let maxWeightGrams = 1_000_000

    enum ValidationError: Error, Equatable {
        case invalidReps
        case invalidWeight
        case negativeWeight
        case weightTooLarge

        var message: String {
            switch self {
            case .invalidReps: "请输入有效的整数次数"
            case .invalidWeight: "请输入有效的重量"
            case .negativeWeight: "重量不能小于 0"
            case .weightTooLarge: "重量不能超过 1000 kg"
            }
        }
    }

    /// 1–9999 的整数；0、负数、小数都不接受
    static func reps(from text: String) throws(ValidationError) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy(\.isASCII), let value = Int(trimmed), (1...maxReps).contains(value)
        else { throw .invalidReps }
        return value
    }

    /// 空串返回 nil（未填写），与明确填的 0 区分。kg 按十进制换算成整数克再四舍五入，
    /// 避免 Double 在 x.xxx5 这类边界上舍错；超上限报错，不截断。
    static func weightGrams(from text: String) throws(ValidationError) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Decimal(string:) 会接受 "1.2.3" 这类只解析前缀的输入，先按格式整串匹配
        guard let match = trimmed.wholeMatch(of: /(-?)([0-9]+(?:\.[0-9]+)?)/),
            let kg = Decimal(string: String(match.2), locale: Locale(identifier: "en_US_POSIX"))
        else { throw .invalidWeight }
        if !match.1.isEmpty && kg > 0 { throw .negativeWeight }

        var grams = kg * 1000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &grams, 0, .plain)
        guard rounded <= Decimal(maxWeightGrams) else { throw .weightTooLarge }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// 克 → 界面显示的 kg 文本，去掉多余的 0。固定用点号作小数点：这段文本会预填回表单，
    /// 而 `weightGrams(from:)` 只认点号，跟随地区会在逗号小数点的设置下解析失败
    static func weightText(grams: Int?) -> String {
        guard let grams else { return "" }
        return (Decimal(grams) / 1000).formatted(
            .number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
