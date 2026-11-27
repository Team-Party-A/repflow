import SwiftData
import SwiftUI

/// 趋势页：本周／本月的数据卡片、每日柱状图和动作列表。口径全部来自 `TrainingStats`。
struct TrendsView: View {
    let userID: UUID

    @Query private var workouts: [Workout]
    @State private var period: StatsPeriod = .week

    init(userID: UUID) {
        self.userID = userID
        _workouts = Query(filter: WorkoutStore.owned(by: userID), sort: WorkoutStore.newestFirst())
    }

    var body: some View {
        let summary = TrainingStats.summary(of: workouts, period: period)
        let inPeriod = TrainingStats.workouts(workouts, in: summary.interval)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SegmentedPicker(
                        selection: $period, options: StatsPeriod.allCases, title: \.title)
                    StatCards(totals: summary.totals)
                    section("每日") {
                        if inPeriod.isEmpty {
                            EmptyHint(text: "\(period.title)还没有训练，去「今天」开始一次")
                        } else {
                            DailyChart(summary: summary, period: period)
                        }
                    }
                    section("肌群") {
                        if inPeriod.isEmpty {
                            EmptyHint(text: "练过之后，这里会按肌群对比次数、组数和重量")
                        } else {
                            MuscleRadarChart(workouts: inPeriod)
                        }
                    }
                    section("训练部位") {
                        if inPeriod.isEmpty {
                            EmptyHint(text: "练过之后，这里会在人体图上标出练到的部位")
                        } else {
                            BodyMuscleMap(workouts: inPeriod)
                        }
                    }
                    section("动作") {
                        if inPeriod.isEmpty {
                            EmptyHint(text: "练过的动作会按组数列在这里")
                        } else {
                            ExerciseList(summaries: TrainingStats.exerciseSummaries(of: inPeriod))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .pageBackground()
            .navigationTitle("趋势")
            .navigationDestination(for: String.self) { exerciseID in
                ExerciseTrendView(userID: userID, exerciseID: exerciseID)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.text)
                .padding(.top, 6)
            content()
        }
    }
}

// MARK: 数据卡片

private struct StatCards: View {
    let totals: StatsTotals

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                card("\(totals.workoutCount)", "次", "训练次数")
                card(
                    TrendsFormat.durationValue(totals.durationSeconds),
                    TrendsFormat.durationUnit(totals.durationSeconds), "训练时长")
            }
            GridRow {
                card("\(totals.totalReps)", "次", "动作总次数")
                card(TrendsFormat.kilograms(totals.volumeGrams), "kg", "总重量")
            }
        }
    }

    private func card(_ value: String, _ unit: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.dataNumber).monospacedDigit().foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(unit).font(.subheadline).foregroundStyle(Palette.text2)
            }
            Text(caption).font(.footnote).foregroundStyle(Palette.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }
}

// MARK: 动作列表

private struct ExerciseList: View {
    let summaries: [ExerciseSummary]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(summaries, id: \.exerciseID) { item in
                NavigationLink(value: item.exerciseID) {
                    HStack(spacing: 10) {
                        Text(ExerciseName.of(item.exerciseID))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text("\(item.setCount) 组 · \(item.totalReps) 次")
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(Palette.text2)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.text2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .card()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: 通用小件

struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.text2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(.horizontal, 16)
            .card()
    }
}

/// UI 规范第 4 节的分段控件：`raised` 底，选中段 `text` 底 + 反色字
struct SegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    init(selection: Binding<Option>, options: [Option], title: @escaping (Option) -> String) {
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(isSelected ? Palette.ground : Palette.text)
                        .background(Capsule().fill(isSelected ? Palette.text : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.raised))
    }
}

/// 趋势页的数字文案。时长、重量的换算只在展示时做，统计里一律秒和克
enum TrendsFormat {
    /// 不足 1 小时显示分钟，否则显示小时（一位小数）
    static func durationValue(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes)" }
        return (Double(minutes) / 60).formatted(.number.precision(.fractionLength(0...1)))
    }

    static func durationUnit(_ seconds: TimeInterval) -> String {
        Int((seconds / 60).rounded()) >= 60 ? "小时" : "分钟"
    }

    /// 整数千克，带千分位；不足 1 kg 时保留一位小数
    static func kilograms(_ grams: Int) -> String {
        let kg = Double(grams) / 1000
        if grams > 0 && kg < 1 {
            return kg.formatted(.number.precision(.fractionLength(1)))
        }
        return Int(kg.rounded()).formatted(.number.grouping(.automatic))
    }
}
