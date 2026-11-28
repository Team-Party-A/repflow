import SwiftUI

/// 人体肌群图：正面、背面各一张。每块肌肉都有描边，没练到的只留描边，练到的按本期组数
/// 分四档填 Volt，量越大越浓。整张卡片放在墨色卡里（`inkCard`），浅色模式下也能用 Volt。
/// 人形和肌肉轮廓是本项目手绘的坐标（见 `BodyFigure`），不用任何外部图片素材。
struct BodyMuscleMap: View {
    let workouts: [Workout]

    var body: some View {
        let levels = Self.levels(of: TrainingStats.muscleLoad(of: workouts, metric: .sets))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                figure("正面", parts: BodyFigure.frontRegions, levels: levels)
                figure("背面", parts: BodyFigure.backRegions, levels: levels)
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
        .inkCard()
    }

    private func figure(
        _ title: String, parts: [BodyFigure.Region], levels: [MuscleGroup: Int]
    ) -> some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let scale = min(
                    size.width / BodyFigure.size.width, size.height / BodyFigure.size.height)
                let offsetX = (size.width - BodyFigure.size.width * scale) / 2
                let transform = CGAffineTransform(translationX: offsetX, y: 0)
                    .scaledBy(x: scale, y: scale)
                context.stroke(
                    BodyFigure.silhouettePath.applying(transform),
                    with: .color(Self.lineColor), lineWidth: 1.2)
                for region in parts {
                    let path = region.path.applying(transform)
                    let level = levels[region.muscle] ?? 0
                    if level > 0 {
                        context.fill(path, with: .color(Self.fill(level: level)))
                    }
                    context.stroke(path, with: .color(Self.lineColor), lineWidth: 1)
                }
            }
            .aspectRatio(BodyFigure.size.width / BodyFigure.size.height, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 300)
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
        .accessibilityLabel("图例：只有轮廓为未练到，颜色越浓训练量越大")
    }

    private func swatch(level: Int) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(level == 0 ? Color.clear : Self.fill(level: level))
            .strokeBorder(Self.lineColor, lineWidth: 1)
            .frame(width: 18, height: 12)
    }

    /// 轮廓线：比 `raised` 亮、比 `text2` 暗，既看得出肌肉分块又不抢 Volt
    private static let lineColor = Palette.text2.opacity(0.6)

    private static func fill(level: Int) -> Color {
        Palette.volt.opacity([0.25, 0.45, 0.7, 1][level - 1])
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

/// 正背面人形的手绘坐标。坐标系 200 × 440，按约 8 头身的比例画；只写画面左半边，
/// 右半边按中线 x = 100 镜像。轮廓点用闭合的 Catmull-Rom 曲线连成圆滑形状。
enum BodyFigure {
    static let size = CGSize(width: 200, height: 440)

    struct Region {
        let muscle: MuscleGroup
        let path: Path
    }

    enum Part {
        case shape(MuscleGroup, [(CGFloat, CGFloat)])
        /// 腹直肌的一节，画成圆角矩形
        case bar(MuscleGroup, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)
    }

    /// 整个人的外轮廓：从头顶中点沿左侧绕到裆部，右半边镜像接回头顶
    static let silhouettePath: Path = {
        let left = silhouette.map { CGPoint(x: $0.0, y: $0.1) }
        let right = left.dropFirst().dropLast().reversed().map { mirror($0) }
        return smoothPath(left + right)
    }()

    static let frontRegions = regions(front)
    static let backRegions = regions(back)

    private static let silhouette: [(CGFloat, CGFloat)] = [
        (100, 5), (86, 9), (80, 20), (79, 34), (82, 48), (88, 58), (89, 66), (86, 72), (74, 76),
        (60, 80), (50, 86), (44, 96), (41, 112), (39, 130), (37, 148), (35, 162), (32, 180),
        (29, 200), (27, 220), (25, 236), (22, 248), (21, 262), (25, 272), (31, 270), (34, 258),
        (35, 246), (36, 238), (40, 220), (44, 200), (48, 180), (52, 162), (55, 145), (58, 124),
        (62, 134), (64, 150), (65, 170), (64, 190), (62, 205), (59, 222), (58, 240), (57, 260),
        (58, 285), (61, 310), (64, 330), (63, 345), (62, 365), (64, 385), (67, 405), (69, 415),
        (64, 428), (68, 436), (86, 436), (88, 428), (86, 416), (88, 395), (90, 370), (89, 345),
        (91, 330), (94, 305), (96, 286), (98, 276), (100, 272),
    ]
    private static let front: [Part] = [
        .shape(.back, [(89, 64), (86, 71), (74, 76), (86, 78), (93, 73)]),
        .shape(
            .shoulders,
            [
                (72, 80), (60, 82), (50, 88), (45, 100), (44, 114), (47, 122), (52, 114), (58, 100),
                (66, 90),
            ]),
        .shape(
            .chest,
            [
                (98, 88), (87, 86), (77, 88), (69, 95), (63, 108), (64, 121), (72, 131), (85, 134),
                (96, 130), (98, 112),
            ]),
        .shape(
            .arms,
            [
                (47, 124), (43, 136), (42, 150), (45, 160), (50, 159), (54, 146), (55, 132),
                (52, 124),
            ]),
        .shape(
            .arms,
            [
                (37, 166), (48, 166), (49, 176), (45, 196), (38, 218), (31, 232), (28, 226),
                (30, 204), (33, 182),
            ]),
        .bar(.core, x: 86...98, y: 139...160),
        .bar(.core, x: 86...98, y: 163...184),
        .bar(.core, x: 87...98, y: 187...208),
        .shape(.core, [(88, 211), (98, 211), (98, 244), (93, 240), (88, 226)]),
        .shape(
            .core,
            [
                (68, 143), (75, 140), (82, 144), (83, 165), (82, 195), (84, 220), (79, 230),
                (72, 216), (68, 196), (67, 168),
            ]),
        .shape(
            .legs,
            [
                (63, 244), (73, 240), (82, 250), (85, 272), (83, 300), (78, 322), (70, 324),
                (64, 308), (61, 284), (60, 262),
            ]),
        .shape(.legs, [(88, 286), (92, 296), (91, 316), (85, 326), (80, 323), (84, 306)]),
        .shape(.legs, [(87, 248), (94, 258), (95, 272), (90, 282), (86, 268)]),
        .shape(
            .legs,
            [
                (65, 340), (72, 338), (78, 350), (78, 378), (74, 402), (70, 404), (66, 385),
                (63, 360),
            ]),
        .shape(.legs, [(82, 345), (88, 348), (89, 370), (86, 392), (82, 388), (81, 366)]),
    ]
    private static let back: [Part] = [
        .shape(
            .back,
            [
                (100, 62), (93, 68), (84, 74), (70, 79), (63, 83), (77, 90), (88, 106), (96, 130),
                (100, 145), (100, 100),
            ]),
        .shape(
            .shoulders,
            [(60, 84), (52, 87), (46, 96), (44, 112), (48, 122), (55, 110), (62, 96), (68, 89)]),
        .shape(.back, [(64, 96), (72, 94), (84, 104), (86, 118), (76, 124), (66, 118), (60, 106)]),
        .shape(
            .back,
            [
                (60, 124), (72, 128), (86, 132), (95, 142), (93, 164), (86, 188), (78, 200),
                (70, 188), (66, 164), (63, 140),
            ]),
        .shape(
            .back, [(97, 150), (99, 152), (99, 228), (91, 230), (88, 214), (92, 192), (96, 170)]),
        .shape(
            .core, [(68, 196), (76, 202), (84, 210), (86, 226), (76, 230), (68, 218), (66, 205)]),
        .shape(
            .arms, [(47, 124), (43, 136), (42, 152), (46, 162), (52, 160), (55, 144), (55, 128)]),
        .shape(
            .arms,
            [
                (37, 166), (48, 166), (49, 176), (45, 196), (38, 218), (31, 232), (28, 226),
                (30, 204), (33, 182),
            ]),
        .shape(
            .legs,
            [
                (99, 236), (86, 232), (70, 234), (61, 246), (60, 262), (65, 276), (78, 282),
                (92, 280), (99, 270),
            ]),
        .shape(
            .legs, [(62, 290), (72, 290), (78, 300), (76, 324), (70, 330), (64, 316), (61, 300)]),
        .shape(
            .legs, [(80, 290), (90, 290), (93, 300), (90, 322), (82, 330), (78, 318), (80, 300)]),
        .shape(
            .legs, [(63, 342), (72, 338), (76, 350), (75, 375), (70, 388), (65, 378), (62, 358)]),
        .shape(
            .legs, [(79, 338), (87, 340), (90, 352), (88, 378), (82, 392), (78, 376), (78, 352)]),
    ]

    private static func regions(_ parts: [Part]) -> [Region] {
        parts.flatMap { part -> [Region] in
            switch part {
            case .shape(let muscle, let raw):
                let points = raw.map { CGPoint(x: $0.0, y: $0.1) }
                return [
                    Region(muscle: muscle, path: smoothPath(points)),
                    Region(muscle: muscle, path: smoothPath(points.map(mirror))),
                ]
            case .bar(let muscle, let x, let y):
                let rect = CGRect(
                    x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound,
                    height: y.upperBound - y.lowerBound)
                let mirrored = CGRect(
                    x: size.width - x.upperBound, y: rect.minY, width: rect.width,
                    height: rect.height)
                return [rect, mirrored].map {
                    Region(muscle: muscle, path: Path(roundedRect: $0, cornerRadius: 3))
                }
            }
        }
    }

    private static func mirror(_ point: CGPoint) -> CGPoint {
        CGPoint(x: size.width - point.x, y: point.y)
    }

    /// 闭合的 Catmull-Rom 曲线，转成三次贝塞尔
    private static func smoothPath(_ points: [CGPoint]) -> Path {
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
