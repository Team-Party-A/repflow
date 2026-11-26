import Charts
import SwiftData
import SwiftUI

/// 单个动作的历史（REQ-IOS-010）：有重量时画每次训练的最大重量折线，下面按时间倒序列出历次的所有组。
/// 看的是全部历史，不受趋势页本周／本月的限制。
struct ExerciseTrendView: View {
    let exerciseID: String

    @Query private var workouts: [Workout]

    init(userID: UUID, exerciseID: String) {
        self.exerciseID = exerciseID
        _workouts = Query(filter: WorkoutStore.owned(by: userID), sort: WorkoutStore.newestFirst())
    }

    var body: some View {
        let sessions = TrainingStats.sessions(of: exerciseID, in: workouts)
        let series = TrainingStats.maxWeightSeries(of: exerciseID, in: workouts)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(ExerciseName.of(exerciseID))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Palette.text)
                if !series.isEmpty {
                    MaxWeightChart(points: series)
                }
                if sessions.isEmpty {
                    EmptyHint(text: "还没有练过这个动作")
                }
                ForEach(sessions, id: \.workout.workoutID) { session in
                    SessionCard(session: session)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .pageBackground()
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MaxWeightChart: View {
    let points: [MaxWeightPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("每次最大重量").font(.headline).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if let best = points.map(\.weightGrams).max() {
                    Text("最高 \(SetInput.weightText(grams: best)) kg")
                        .font(.footnote).foregroundStyle(Palette.text2)
                }
            }
            Chart(points, id: \.startedAt) { point in
                LineMark(
                    x: .value("日期", point.startedAt),
                    y: .value("重量", Double(point.weightGrams) / 1000)
                )
                .foregroundStyle(Palette.text)
                PointMark(
                    x: .value("日期", point.startedAt),
                    y: .value("重量", Double(point.weightGrams) / 1000)
                )
                .foregroundStyle(Palette.text)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(HistoryFormat.monthDay(date)) }
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
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 160)
        }
        .padding(16)
        .card()
    }
}

private struct SessionCard: View {
    let session: ExerciseSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "\(HistoryFormat.dayHeader(session.workout.startedAt)) \(HistoryFormat.time(session.workout.startedAt))"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.text2)
            ForEach(Array(session.sets.enumerated()), id: \.element.setID) { index, set in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.text2)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.raised))
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(set.finalRepCount)").font(.title3.weight(.bold)).monospacedDigit()
                        Text("次").font(.subheadline).foregroundStyle(Palette.text2)
                    }
                    .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    Text(set.weightGrams.map { "\(SetInput.weightText(grams: $0)) kg" } ?? "重量未填写")
                        .foregroundStyle(set.weightGrams == nil ? Palette.text2 : Palette.text)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
