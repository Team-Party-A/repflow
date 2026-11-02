import SwiftData
import SwiftUI
import os

private let logger = Logger(subsystem: "repflow", category: "manual-workout")

/// 不依赖手表手动记一次训练：逐组添加，点「完成训练」一次性写入本地数据层。
struct ManualWorkoutView: View {
    let userID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date()
    @State private var sets: [DraftSet] = []
    @State private var editing: DraftSet?
    @State private var isAdding = false
    @State private var isConfirmingDiscard = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if sets.isEmpty {
                        Text("还没有添加组，点下面的「添加一组」开始")
                            .font(.subheadline)
                            .foregroundStyle(Palette.text2)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .card()
                    }
                    ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(number: index + 1, set: set) { editing = set }
                    }
                    Button {
                        isAdding = true
                    } label: {
                        Label("添加一组", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .pageBackground()
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    Label("完成训练", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sets.isEmpty)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.ground)
            }
            .navigationTitle("手动记录训练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if sets.isEmpty { dismiss() } else { isConfirmingDiscard = true }
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                // 和原型一致：新的一组沿用上一组的动作和重量
                let last = sets.last.map {
                    DraftSet(exerciseID: $0.exerciseID, reps: 0, weightGrams: $0.weightGrams)
                }
                SetFormView(title: "添加一组", initial: last, blankReps: true) { sets.append($0) }
            }
            .sheet(item: $editing) { set in
                let number = (sets.firstIndex(of: set) ?? 0) + 1
                SetFormView(
                    title: "修正第 \(number) 组", initial: set, blankReps: false,
                    onDelete: { sets.removeAll { $0.id == set.id } }
                ) { updated in
                    if let index = sets.firstIndex(where: { $0.id == updated.id }) {
                        sets[index] = updated
                    }
                }
            }
            .confirmationDialog(
                "放弃这次记录？", isPresented: $isConfirmingDiscard, titleVisibility: .visible
            ) {
                Button("放弃", role: .destructive) { dismiss() }
            } message: {
                Text("已添加的 \(sets.count) 组不会保存。")
            }
            .alert(
                "保存失败",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button("好") {}
            } message: {
                Text(saveError ?? "")
            }
            .interactiveDismissDisabled(!sets.isEmpty)
        }
    }

    private func save() {
        let workoutSets = sets.map {
            WorkoutSet(
                position: 0, exerciseID: $0.exerciseID, finalRepCount: $0.reps,
                recordSource: .manual, weightGrams: $0.weightGrams)
        }
        do {
            // 原型里手动训练只记开始时间，ended_at 留空表示未知
            try WorkoutStore(context: modelContext, userID: userID).create(
                startedAt: startedAt, timeZone: TimeZone.current.identifier, origin: .phone,
                sets: workoutSets)
            dismiss()
        } catch {
            logger.error("save manual workout failed: sets=\(sets.count), error=\(error)")
            saveError = "训练没有保存，请重试。（\(error.localizedDescription)）"
        }
    }
}

/// 组记录行：序号圆点、动作与重量、34 pt 次数、来源、修正按钮（UI 规范第 4 节）
private struct SetRow: View {
    let number: Int
    let set: DraftSet
    let onEdit: () -> Void

    var body: some View {
        let name = ExerciseCatalog.exercise(id: set.exerciseID)?.displayName ?? set.exerciseID
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(Palette.text)
                Text(set.weightGrams.map { "\(SetInput.weightText(grams: $0)) kg" } ?? "重量未填写")
                    .font(.subheadline)
                    .foregroundStyle(Palette.text2)
                Text("手动").font(.footnote).foregroundStyle(Palette.text2)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(set.reps)").font(.dataNumber).monospacedDigit()
                Text("次").font(.subheadline).foregroundStyle(Palette.text2)
            }
            .foregroundStyle(Palette.text)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("修正\(name)第 \(number) 组")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .card()
    }
}
