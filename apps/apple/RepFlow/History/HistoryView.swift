import SwiftData
import SwiftUI

/// 历史：当前账号的全部训练，按开始时间倒序、按天分组。统计卡随后续 Issue 做。
struct HistoryView: View {
    let userID: UUID

    @EnvironmentObject private var uploads: UploadQueue
    @Query private var workouts: [Workout]

    init(userID: UUID) {
        self.userID = userID
        _workouts = Query(filter: WorkoutStore.owned(by: userID), sort: WorkoutStore.newestFirst())
    }

    private struct DayGroup: Identifiable {
        let day: Date
        var workouts: [Workout]
        var id: Date { day }
    }

    /// workouts 已经倒序，同一天的训练是连续的
    private var days: [DayGroup] {
        var groups: [DayGroup] = []
        for workout in workouts {
            let day = Calendar.current.startOfDay(for: workout.startedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].workouts.append(workout)
            } else {
                groups.append(DayGroup(day: day, workouts: [workout]))
            }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SyncBanner(userID: userID)
                    if workouts.isEmpty {
                        emptyState
                    }
                    ForEach(days) { group in
                        Text(HistoryFormat.dayHeader(group.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.text2)
                            .padding(.top, 8)
                        ForEach(group.workouts) { workout in
                            WorkoutRow(workout: workout) {
                                Task { await uploads.retry(userID: userID) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .pageBackground()
            .navigationTitle("历史")
            .navigationDestination(for: UUID.self) { workoutID in
                WorkoutDetailView(userID: userID, workoutID: workoutID)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet").font(.title)
            Text("还没有训练记录").font(.body.weight(.semibold))
            Text("戴上手表开始一组，或者手动记录一次训练").font(.subheadline)
        }
        .foregroundStyle(Palette.text2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct WorkoutRow: View {
    let workout: Workout
    let onRetry: () -> Void

    var body: some View {
        let status = workout.syncStatus
        HStack(spacing: 10) {
            NavigationLink(value: workout.workoutID) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workout.exerciseIDs.map(ExerciseName.of).joined(separator: " · "))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.leading)
                        Text(
                            "\(HistoryFormat.time(workout.startedAt)) · \(workout.exerciseIDs.count) 个动作 · \(workout.sets.count) 组"
                        )
                        .font(.subheadline)
                        .foregroundStyle(Palette.text2)
                        if status == .failed {
                            Text("同步失败 · 本地记录已保留")
                                .font(.footnote)
                                .foregroundStyle(Palette.red)
                        }
                    }
                    Spacer(minLength: 0)
                    if status != .failed { SyncChip(status: status) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if status == .failed {
                Button(action: onRetry) {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Palette.raised))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }
}

/// 状态标签：图标 + 文字 + 色，不只靠颜色区分（UI 规范第 1 节）
struct SyncChip: View {
    let status: SyncStatus

    var body: some View {
        let style = status.style
        Label(style.text, systemImage: style.icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(style.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(style.fill))
    }
}

extension SyncStatus {
    struct Style {
        let text: String
        let icon: String
        let tint: Color
        let fill: Color
    }

    var style: Style {
        switch self {
        case .pending:
            Style(
                text: "待同步", icon: "clock", tint: Palette.amber, fill: Palette.amber.opacity(0.15))
        case .failed:
            Style(
                text: "同步失败", icon: "exclamationmark.triangle", tint: Palette.red,
                fill: Palette.red.opacity(0.13))
        case .synced:
            Style(text: "已同步", icon: "checkmark", tint: Palette.text2, fill: Palette.raised)
        }
    }
}
