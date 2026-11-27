import SwiftUI

/// 人体肌群图：正面、背面各一张，按本期组数给六个肌群分四档上色，量越大颜色越浓。
/// 人形是本项目手绘的坐标（见 `BodyFigure`），不用任何外部图片素材。
struct BodyMuscleMap: View {
    let workouts: [Workout]

    var body: some View {
        let levels = Self.levels(
            of: TrainingStats.muscleLoad(of: workouts, metric: .sets))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                figure("正面", regions: BodyFigure.front, lines: BodyFigure.abLines, levels: levels)
                figure("背面", regions: BodyFigure.back, lines: [], levels: levels)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("人体肌群图")
            .accessibilityValue(
                MuscleGroup.allCases.map { "\($0.displayName) \(Self.levelName(levels[$0] ?? 0))" }
                    .joined(separator: "，"))
            legend
            Text("按组数分档，主肌群计全量，次肌群计一半。")
                .font(.footnote)
                .foregroundStyle(Palette.text2)
        }
        .padding(16)
        .card()
    }

    private func figure(
        _ title: String, regions: [BodyFigure.Region], lines: [Path], levels: [MuscleGroup: Int]
    ) -> some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let scale = min(
                    size.width / BodyFigure.size.width, size.height / BodyFigure.size.height)
                let offsetX = (size.width - BodyFigure.size.width * scale) / 2
                let transform = CGAffineTransform(translationX: offsetX, y: 0)
                    .scaledBy(x: scale, y: scale)
                for region in regions {
                    let path = region.path.applying(transform)
                    let level = region.muscle.flatMap { levels[$0] } ?? 0
                    context.fill(path, with: .color(Self.fill(level: level)))
                    // 用卡片底色描边，相邻肌肉之间留出一道缝
                    context.stroke(path, with: .color(Palette.surface), lineWidth: 1.2)
                }
                for line in lines {
                    context.stroke(
                        line.applying(transform), with: .color(Palette.surface), lineWidth: 1)
                }
            }
            .aspectRatio(BodyFigure.size.width / BodyFigure.size.height, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 280)
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.text2)
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            swatch(level: 0)
            Text("未练到").font(.footnote).foregroundStyle(Palette.text2)
            Spacer(minLength: 12)
            Text("少").font(.footnote).foregroundStyle(Palette.text2)
            ForEach(1...4, id: \.self) { swatch(level: $0) }
            Text("多").font(.footnote).foregroundStyle(Palette.text2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图例：灰色为未练到，颜色越浓训练量越大")
    }

    private func swatch(level: Int) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Self.fill(level: level))
            .frame(width: 18, height: 12)
    }

    /// 0 档是没练到，用 `raised`；1–4 档是 `text` 色逐级加浓：
    /// 浅色模式里越来越黑，深色模式里越来越亮，两种模式下都是「量越大越显眼」
    private static func fill(level: Int) -> Color {
        let opacities = [0.3, 0.5, 0.72, 0.95]
        return level == 0 ? Palette.raised : Palette.text.opacity(opacities[level - 1])
    }

    private static func levelName(_ level: Int) -> String {
        ["未练到", "少", "较少", "较多", "多"][level]
    }

    /// 按本期最大的肌群等分四档；没练到的是 0 档
    static func levels(of load: [MuscleGroup: Double]) -> [MuscleGroup: Int] {
        let maxLoad = load.values.max() ?? 0
        return load.mapValues { value in
            guard maxLoad > 0, value > 0 else { return 0 }
            return min(4, Int((value / maxLoad * 4).rounded(.up)))
        }
    }
}

/// 正背面人形的手绘坐标。坐标系 120 × 266，只写画面左半边，右半边按中线镜像。
/// 每块区域给出轮廓点，用 Catmull-Rom 曲线连成圆滑的闭合形状。
enum BodyFigure {
    static let size = CGSize(width: 120, height: 266)

    struct Region {
        /// nil 是头、手、膝、脚这类不归肌群的部位，始终画成未练到的颜色
        let muscle: MuscleGroup?
        let path: Path
    }

    static let front: [Region] =
        mirrored([
            (
                .shoulders,
                [(36, 50), (28, 52), (22, 60), (20, 72), (22, 82), (28, 80), (34, 70), (38, 58)]
            ),
            (
                .chest,
                [
                    (39, 53), (48, 50), (58, 51), (59, 66), (59, 82), (50, 85), (41, 84), (36, 76),
                    (37, 62),
                ]
            ),
            (
                .arms,
                [
                    (22, 85), (29, 83), (33, 92), (31, 108), (28, 120), (21, 123), (16, 113),
                    (16, 97),
                ]
            ),
            (
                .arms,
                [
                    (16, 126), (27, 124), (29, 134), (25, 150), (21, 160), (15, 160), (11, 148),
                    (12, 135),
                ]
            ),
            (.core, [(48, 88), (59, 88), (59, 140), (51, 137), (48, 122), (47, 104)]),
            (
                .core,
                [
                    (39, 87), (45, 89), (45, 106), (47, 124), (49, 138), (42, 134), (38, 118),
                    (37, 100),
                ]
            ),
            (nil, [(39, 138), (50, 141), (59, 146), (59, 152), (48, 152), (38, 147)]),
            (
                .legs,
                [
                    (37, 150), (49, 155), (58, 157), (57, 180), (52, 204), (44, 208), (36, 200),
                    (33, 176), (34, 160),
                ]
            ),
            (.legs, [(38, 220), (46, 219), (51, 223), (50, 240), (46, 253), (40, 253), (36, 239)]),
        ]) + shared

    static let back: [Region] =
        mirrored([
            (.back, [(52, 45), (59, 43), (59, 96), (54, 84), (47, 66), (38, 54), (45, 49)]),
            (
                .shoulders,
                [(36, 53), (28, 53), (22, 60), (20, 72), (22, 82), (28, 80), (33, 70), (37, 61)]
            ),
            (
                .back,
                [
                    (38, 63), (45, 68), (52, 86), (57, 100), (51, 108), (42, 114), (37, 104),
                    (35, 88), (35, 74),
                ]
            ),
            (.back, [(53, 110), (59, 101), (59, 138), (51, 136)]),
            (.core, [(39, 112), (44, 116), (50, 115), (50, 134), (42, 134), (38, 124)]),
            (
                .arms,
                [
                    (22, 85), (29, 83), (33, 92), (31, 108), (28, 120), (21, 123), (16, 113),
                    (16, 97),
                ]
            ),
            (
                .arms,
                [
                    (16, 126), (27, 124), (29, 134), (25, 150), (21, 160), (15, 160), (11, 148),
                    (12, 135),
                ]
            ),
            (.legs, [(40, 137), (51, 138), (59, 142), (59, 166), (50, 170), (40, 166), (36, 152)]),
            (
                .legs,
                [
                    (35, 170), (48, 173), (58, 171), (57, 190), (52, 206), (44, 209), (36, 200),
                    (34, 184),
                ]
            ),
            (.legs, [(37, 220), (46, 217), (52, 222), (52, 236), (46, 249), (40, 249), (35, 236)]),
        ]) + shared

    /// 头、颈、手、膝、脚，正背面相同
    private static let shared: [Region] =
        [
            Region(muscle: nil, path: Path(ellipseIn: CGRect(x: 47, y: 4, width: 26, height: 32))),
            Region(
                muscle: nil,
                path: smoothPath([(52, 33), (68, 33), (68, 45), (60, 47), (52, 45)])),
        ]
        + mirrored([
            (nil, [(14, 162), (21, 162), (22, 172), (18, 180), (12, 178), (11, 168)]),
            (nil, [(38, 209), (52, 208), (53, 216), (46, 219), (38, 217)]),
            (nil, [(39, 255), (48, 255), (51, 262), (37, 262)]),
        ])

    /// 正面腹肌的中线和横向分节线
    static let abLines: [Path] =
        [101, 115, 128].map { y in
            Path { path in
                path.move(to: CGPoint(x: 47, y: y))
                path.addLine(to: CGPoint(x: 73, y: y))
            }
        } + [
            Path { path in
                path.move(to: CGPoint(x: 60, y: 88))
                path.addLine(to: CGPoint(x: 60, y: 140))
            }
        ]

    private static func mirrored(_ halves: [(MuscleGroup?, [(CGFloat, CGFloat)])]) -> [Region] {
        halves.flatMap { muscle, points in
            [
                Region(muscle: muscle, path: smoothPath(points)),
                Region(muscle: muscle, path: smoothPath(points.map { (size.width - $0.0, $0.1) })),
            ]
        }
    }

    /// 闭合的 Catmull-Rom 曲线，转成三次贝塞尔
    private static func smoothPath(_ raw: [(CGFloat, CGFloat)]) -> Path {
        let points = raw.map { CGPoint(x: $0.0, y: $0.1) }
        let count = points.count
        return Path { path in
            path.move(to: points[0])
            for index in 0..<count {
                let previous = points[(index - 1 + count) % count]
                let current = points[index]
                let next = points[(index + 1) % count]
                let afterNext = points[(index + 2) % count]
                let control1 = CGPoint(
                    x: current.x + (next.x - previous.x) / 6,
                    y: current.y + (next.y - previous.y) / 6)
                let control2 = CGPoint(
                    x: next.x - (afterNext.x - current.x) / 6,
                    y: next.y - (afterNext.y - current.y) / 6)
                path.addCurve(to: next, control1: control1, control2: control2)
            }
            path.closeSubpath()
        }
    }
}
