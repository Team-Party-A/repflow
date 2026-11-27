import SwiftUI

/// 肌群雷达图：六个轴，可切换次数、组数、重量。最外圈是本期最大的那个肌群。
/// 和每日柱状图一样放在墨色卡里，数据多边形用 Volt。
struct MuscleRadarChart: View {
    let workouts: [Workout]

    @State private var metric: MuscleMetric = .reps

    /// 从正上方起顺时针：上肢在上半圈，腿和核心在下半圈
    private static let axes: [MuscleGroup] = [.chest, .shoulders, .arms, .core, .legs, .back]

    var body: some View {
        let load = TrainingStats.muscleLoad(of: workouts, metric: metric)
        let values = Self.axes.map { metric.display(load[$0] ?? 0) }
        let maxValue = values.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            SegmentedPicker(selection: $metric, options: MuscleMetric.allCases, title: \.title)
            GeometryReader { geometry in
                let size = geometry.size
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // 上下各留出两行标签的高度，左右的斜向标签宽度够用
                let radius = min(size.width / 2 - 56, size.height / 2 - 40)
                ZStack {
                    grid(center: center, radius: radius)
                    if maxValue > 0 {
                        let ratios = values.map { $0 / maxValue }
                        polygon(ratios: ratios, center: center, radius: radius)
                            .fill(Palette.volt.opacity(0.2))
                        polygon(ratios: ratios, center: center, radius: radius)
                            .stroke(
                                Palette.volt, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    } else {
                        // 只有重量口径会走到这里：本期有训练，但所有组都没填重量
                        Text("本期的组都没有填写重量")
                            .font(.footnote)
                            .foregroundStyle(Palette.text2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Palette.surface))
                            .position(center)
                    }
                    ForEach(Array(Self.axes.enumerated()), id: \.element) { index, muscle in
                        label(muscle, value: values[index])
                            .position(
                                point(index: index, ratio: 1, center: center, radius: radius + 30))
                    }
                }
            }
            .frame(height: 280)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("肌群\(metric.title)")
            .accessibilityValue(
                Self.axes.enumerated().map { index, muscle in
                    "\(muscle.displayName) \(metric.text(values[index])) \(metric.unit)"
                }
                .joined(separator: "，"))
            Text("单位：\(metric.unit)。主肌群计全量，次肌群计一半。")
                .font(.footnote)
                .foregroundStyle(Palette.text2)
        }
        .padding(16)
        .inkCard()
    }

    private func label(_ muscle: MuscleGroup, value: Double) -> some View {
        VStack(spacing: 0) {
            Text(muscle.displayName)
                .font(.footnote)
                .foregroundStyle(Palette.text2)
            Text(metric.text(value))
                .font(.headline).monospacedDigit()
                .foregroundStyle(Palette.text)
        }
        .fixedSize()
    }

    private func grid(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            for ring in 1...4 {
                let ratio = Double(ring) / 4
                let corners = Self.axes.indices.map {
                    point(index: $0, ratio: ratio, center: center, radius: radius)
                }
                path.addLines(corners)
                path.closeSubpath()
            }
            for index in Self.axes.indices {
                path.move(to: center)
                path.addLine(to: point(index: index, ratio: 1, center: center, radius: radius))
            }
        }
        .stroke(Palette.raised, lineWidth: 1)
    }

    private func polygon(ratios: [Double], center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            path.addLines(
                ratios.indices.map {
                    point(index: $0, ratio: ratios[$0], center: center, radius: radius)
                })
            path.closeSubpath()
        }
    }

    private func point(index: Int, ratio: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(Self.axes.count)
        return CGPoint(
            x: center.x + cos(angle) * radius * ratio, y: center.y + sin(angle) * radius * ratio)
    }
}

extension MuscleMetric {
    var title: String {
        switch self {
        case .reps: "次数"
        case .sets: "组数"
        case .volume: "重量"
        }
    }

    var unit: String {
        switch self {
        case .reps: "次"
        case .sets: "组"
        case .volume: "kg"
        }
    }

    /// 重量统计是克，图上用千克
    func display(_ value: Double) -> Double {
        self == .volume ? value / 1000 : value
    }

    /// 次肌群计一半会出现 .5，保留一位小数
    func text(_ displayed: Double) -> String {
        displayed.formatted(.number.precision(.fractionLength(0...1)))
    }
}
