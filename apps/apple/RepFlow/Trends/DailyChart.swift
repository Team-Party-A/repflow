import Charts
import SwiftUI

/// 每日柱状图：按天一根柱子，可切换指标，虚线是本期平均值，点柱子看当天数值。
/// 配色同 UI 原型的统计卡：墨色卡里其他天是灰柱，选中的那天（没选时是今天）用 Volt。
struct DailyChart: View {
    let summary: PeriodSummary
    let period: StatsPeriod

    @State private var metric: DailyMetric = .duration
    @State private var selectedDay: Date?

    var body: some View {
        let average = summary.average(of: metric)
        let trainedDays = summary.days.filter { $0.totals.workoutCount > 0 }
        let selected = selectedDay.flatMap { day in trainedDays.first { $0.day == day } }
        let highlightedDay = selected?.day ?? Calendar.stats.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: 12) {
            SegmentedPicker(selection: $metric, options: DailyMetric.allCases, title: \.title)
            readout(selected: selected, average: average)
            Chart {
                // 没训练的天不画柱子，靠固定的 X 轴范围留空
                ForEach(trainedDays, id: \.day) { day in
                    BarMark(
                        x: .value("日期", day.day, unit: .day),
                        y: .value(metric.title, metric.display(day.totals.value(of: metric)))
                    )
                    .foregroundStyle(
                        day.day == highlightedDay ? Palette.volt : Palette.text2.opacity(0.35)
                    )
                    .cornerRadius(3)
                }
                RuleMark(y: .value("平均", metric.display(average)))
                    .foregroundStyle(Palette.text2)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXScale(domain: summary.interval.start...summary.interval.end)
            .chartXAxis {
                AxisMarks(values: xAxisDays) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(axisLabel(date)) }
                    }
                    .foregroundStyle(Palette.text2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Palette.raised)
                    AxisValueLabel().foregroundStyle(Palette.text2)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            selectDay(at: location, proxy: proxy, geometry: geometry)
                        }
                }
            }
            .frame(height: 180)
        }
        .padding(16)
        .inkCard()
        .onChange(of: period) { selectedDay = nil }
    }

    /// 选中某天时显示当天数值，否则显示本期平均
    private func readout(selected: DayStats?, average: Double) -> some View {
        let value = selected.map { metric.display($0.totals.value(of: metric)) }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(metric.text(value ?? metric.display(average)))
                .font(.title2.weight(.bold)).monospacedDigit()
                .foregroundStyle(Palette.text)
            Text(metric.unit).font(.subheadline).foregroundStyle(Palette.text2)
            Spacer(minLength: 8)
            Text(selected.map { HistoryFormat.dayHeader($0.day) } ?? "有训练的天平均")
                .font(.footnote)
                .foregroundStyle(Palette.text2)
        }
    }

    private func selectDay(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame,
            let date: Date = proxy.value(atX: location.x - geometry[plotFrame].origin.x)
        else { return }
        let day = Calendar.stats.startOfDay(for: date)
        let isTrained = summary.days.contains { $0.day == day && $0.totals.workoutCount > 0 }
        // 再点一次同一天，或点在空白天上，都取消选中
        selectedDay = isTrained && selectedDay != day ? day : nil
    }

    /// 周视图每天一个刻度；月视图太挤，只标 1、8、15、22、29 日
    private var xAxisDays: [Date] {
        let days = summary.days.map(\.day)
        guard period == .month else { return days }
        return days.filter {
            [1, 8, 15, 22, 29].contains(Calendar.stats.component(.day, from: $0))
        }
    }

    private func axisLabel(_ date: Date) -> String {
        let calendar = Calendar.stats
        if period == .month { return "\(calendar.component(.day, from: date))" }
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }
}

extension DailyMetric {
    var title: String {
        switch self {
        case .duration: "时长"
        case .volume: "总重量"
        case .sets: "组数"
        case .reps: "次数"
        }
    }

    var unit: String {
        switch self {
        case .duration: "分钟"
        case .volume: "kg"
        case .sets: "组"
        case .reps: "次"
        }
    }

    /// 统计值（秒、克）换成图上的单位（分钟、千克）
    func display(_ value: Double) -> Double {
        switch self {
        case .duration: value / 60
        case .volume: value / 1000
        case .sets, .reps: value
        }
    }

    func text(_ displayed: Double) -> String {
        displayed.formatted(.number.precision(.fractionLength(0...1)))
    }
}
