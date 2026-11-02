import SwiftUI

/// UI 规范 v0.2（Chalk & Volt）的色板。取值在 Asset Catalog 里按 token 名分浅色／深色维护，
/// 代码只引用 token，不写十六进制。
enum Palette {
    static let ground = Color("ground")
    static let surface = Color("surface")
    static let raised = Color("raised")
    static let text = Color("text")
    static let text2 = Color("text2")
    static let volt = Color("volt")
    static let amber = Color("amber")
    static let red = Color("red")
}

extension Font {
    /// 数据数字：统计卡、组记录里的次数
    static let dataNumber = Font.system(size: 34, weight: .bold).width(.compressed)
    /// 次数输入的大数字，不跟随动态字体
    static let countNumber = Font.system(size: 64, weight: .heavy).width(.compressed)
}

/// 每屏唯一的主操作。Volt 和浅色底对比度只有 1.04:1，浅色模式改用墨色底 + Volt 字。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isLight = colorScheme == .light
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isLight ? Palette.volt : Palette.ground)
            .background(Capsule().fill(isLight ? Palette.text : Palette.volt))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}

/// 次按钮：`raised` 底 + `text` 字
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(Palette.text)
            .background(Capsule().fill(Palette.raised))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func pageBackground() -> some View {
        background(Palette.ground.ignoresSafeArea())
    }

    func card(radius: CGFloat = 18) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Palette.surface))
    }
}
