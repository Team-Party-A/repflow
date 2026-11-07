import SwiftData
import SwiftUI
import os

private let logger = Logger(subsystem: "repflow", category: "history")

/// 训练详情：摘要、按动作分组的组记录，以及修改、添加、删除。
/// 数据按 ID 查询而不是直接持有 Workout：删除后模型实例失效，继续读它的属性会崩溃。
struct WorkoutDetailView: View {
    let userID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var uploads: UploadQueue
    @Query private var matches: [Workout]
    /// 一条训练最多一个待发任务，失败原因从这里取
    @Query private var tasks: [UploadTask]
    @State private var sheet: SetSheet?
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private enum SetSheet: Identifiable {
        case add
        case edit(setID: UUID)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let setID): setID.uuidString
            }
        }
    }

    init(userID: UUID, workoutID: UUID) {
        self.userID = userID
        _matches = Query(
            filter: #Predicate<Workout> { $0.workoutID == workoutID && $0.userID == userID })
        _tasks = Query(
            filter: #Predicate<UploadTask> { $0.workoutID == workoutID && $0.userID == userID })
    }

    var body: some View {
        Group {
            if let workout = matches.first {
                content(of: workout)
            }
        }
        .pageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func content(of workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(HistoryFormat.monthDay(workout.startedAt)) 训练")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Palette.text)
                    Text(HistoryFormat.timeSpan(of: workout))
                        .foregroundStyle(Palette.text2)
                }
                statusBanner(workout.syncStatus)
                summary(of: workout)
                ForEach(workout.exerciseIDs, id: \.self) { exerciseID in
                    group(exerciseID, of: workout)
                }
                Button {
                    sheet = .add
                } label: {
                    Label("添加一组", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("删除训练", systemImage: "trash")
                        .foregroundStyle(Palette.red)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .sheet(item: $sheet) { kind in
            setForm(kind, workout: workout)
        }
        .alert("删除这次训练？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除训练", role: .destructive) {
                if perform({ try $0.delete(workout) }) { dismiss() }
            }
        } message: {
            Text("它将从历史和统计中移除，删除结果会同步到后端。")
        }
    }

    // MARK: 同步状态

    @ViewBuilder
    private func statusBanner(_ status: SyncStatus) -> some View {
        let style = status.style
        let (title, detail) =
            switch status {
            case .pending: ("已保存到手机 · 待同步", "联网后自动上传，可以继续查看和修改")
            case .failed:
                (
                    "同步失败 · 本地记录已保留",
                    FailureHint.detail(
                        state: tasks.first?.state, errorCode: tasks.first?.lastErrorCode)
                )
            case .synced: ("已同步", "后端已保存这次训练的当前版本")
            }
        HStack(spacing: 10) {
            Image(systemName: style.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote)
            }
            Spacer(minLength: 0)
            if status == .failed {
                Button {
                    Task { await uploads.retry(userID: userID) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Palette.surface))
                }
            }
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(style.fill))
    }

    // MARK: 摘要与组

    private func summary(of workout: Workout) -> some View {
        HStack {
            tile("\(workout.exerciseIDs.count)", "个动作")
            tile("\(workout.sets.count)", "组")
            tile("\(workout.totalReps)", "动作总次数")
        }
        .padding(.vertical, 14)
        .card()
    }

    private func tile(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.dataNumber).monospacedDigit().foregroundStyle(Palette.text)
            Text(caption).font(.footnote).foregroundStyle(Palette.text2)
        }
        .frame(maxWidth: .infinity)
    }

    private func group(_ exerciseID: String, of workout: Workout) -> some View {
        let sets = workout.orderedSets.filter { $0.exerciseID == exerciseID }
        return VStack(alignment: .leading, spacing: 8) {
            Text(ExerciseName.of(exerciseID))
                .font(.headline)
                .foregroundStyle(Palette.text)
                .padding(.top, 6)
            ForEach(Array(sets.enumerated()), id: \.element.setID) { index, set in
                SetRecordRow(number: index + 1, set: set) { sheet = .edit(setID: set.setID) }
            }
        }
    }

    // MARK: 编辑

    @ViewBuilder
    private func setForm(_ kind: SetSheet, workout: Workout) -> some View {
        switch kind {
        case .add:
            // 和手动记录一致：新的一组沿用最后一组的动作和重量
            let last = workout.orderedSets.last.map {
                DraftSet(exerciseID: $0.exerciseID, reps: 0, weightGrams: $0.weightGrams)
            }
            SetFormView(title: "添加一组", initial: last, blankReps: true) { draft in
                perform { try $0.addSet(draft, to: workout) }
            }
        case .edit(let setID):
            if let set = workout.sets.first(where: { $0.setID == setID }) {
                let number =
                    (workout.orderedSets.filter { $0.exerciseID == set.exerciseID }
                        .firstIndex { $0.setID == setID } ?? 0) + 1
                let isLast = workout.sets.count == 1
                SetFormView(
                    title: "修正第 \(number) 组",
                    initial: DraftSet(
                        id: set.setID, exerciseID: set.exerciseID, reps: set.finalRepCount,
                        weightGrams: set.weightGrams),
                    blankReps: false,
                    onDelete: {
                        // 删最后一组等于删整次训练，详情页随之退出
                        if perform({ try $0.deleteSet(set, of: workout) }), isLast { dismiss() }
                    },
                    deleteConfirmation: isLast
                        ? .init(
                            title: "删除最后一组？",
                            message: "这次训练只剩这一组，删除后整次训练会从历史和统计中移除，删除结果会同步到后端。",
                            action: "删除训练")
                        : .init(
                            title: "删除这一组？", message: "本次训练的总组数和动作总次数会随之更新，其他组不变。",
                            action: "删除"),
                    onSave: { draft in
                        perform { try $0.updateSet(set, in: workout, to: draft) }
                    })
            }
        }
    }

    /// 写入成功后马上触发上传；失败时给提示，改动已由 store 回滚
    @discardableResult
    private func perform(_ change: (WorkoutStore) throws -> Void) -> Bool {
        do {
            try change(WorkoutStore(context: modelContext, userID: userID))
            uploads.sync(userID: userID)
            return true
        } catch {
            logger.error("edit workout failed: user=\(userID), error=\(error)")
            errorMessage = "修改没有保存，请重试。（\(error.localizedDescription)）"
            return false
        }
    }
}

/// 组记录行：序号圆点、34 pt 次数、重量、来源与组时间、修正按钮（UI 规范第 4 节）
private struct SetRecordRow: View {
    let number: Int
    let set: WorkoutSet
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.raised))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(set.finalRepCount)").font(.dataNumber).monospacedDigit()
                Text("次").font(.subheadline).foregroundStyle(Palette.text2)
            }
            .foregroundStyle(Palette.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.weightGrams.map { "\(SetInput.weightText(grams: $0)) kg" } ?? "重量未填写")
                    .foregroundStyle(set.weightGrams == nil ? Palette.text2 : Palette.text)
                Text(source).font(.footnote).foregroundStyle(Palette.text2)
                if let span = timeSpan {
                    Text(span).font(.footnote).foregroundStyle(Palette.text2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("修正\(ExerciseName.of(set.exerciseID))第 \(number) 组")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .card()
    }

    private var source: String {
        switch set.recordSource {
        case .manual: "手动"
        case .automatic:
            set.estimatedRepCount.map { $0 != set.finalRepCount } == true
                ? "自动计次（已修正）· 估计 \(set.estimatedRepCount ?? 0) 次" : "自动计次"
        }
    }

    /// 组时间只存手机，手动记录的组没有
    private var timeSpan: String? {
        guard let start = set.setStartedAt else { return nil }
        guard let end = set.setEndedAt else { return HistoryFormat.time(start) }
        return "\(HistoryFormat.time(start)) – \(HistoryFormat.time(end))"
    }
}
