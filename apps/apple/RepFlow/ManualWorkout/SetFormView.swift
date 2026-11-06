import SwiftUI

/// 草稿中的一组，点「完成训练」时才变成 `WorkoutSet` 落盘
struct DraftSet: Identifiable, Equatable {
    var id = UUID()
    var exerciseID: String
    var reps: Int
    var weightGrams: Int?
}

/// 删除一组前要不要确认，以及弹窗文案。草稿阶段的删除不需要，已保存的组需要
struct DeleteConfirmation {
    let title: String
    let message: String
    let action: String
}

/// 添加或修改一组：动作、次数、重量（可不填）。对应原型的 setForm。
struct SetFormView: View {
    let title: String
    /// 只在修正已有组时传，显示红字「删除这一组」
    let onDelete: (() -> Void)?
    let deleteConfirmation: DeleteConfirmation?
    let onSave: (DraftSet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exerciseID: String
    @State private var repsText: String
    @State private var weightText: String
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false
    private let draftID: UUID?

    /// `blankReps` 为 true 时只沿用动作和重量，次数留空让用户填
    init(
        title: String, initial: DraftSet?, blankReps: Bool, onDelete: (() -> Void)? = nil,
        deleteConfirmation: DeleteConfirmation? = nil,
        onSave: @escaping (DraftSet) -> Void
    ) {
        self.title = title
        self.onDelete = onDelete
        self.deleteConfirmation = deleteConfirmation
        self.onSave = onSave
        draftID = initial?.id
        _exerciseID = State(initialValue: initial?.exerciseID ?? ExerciseCatalog.all[0].id)
        _repsText = State(initialValue: blankReps ? "" : initial.map { String($0.reps) } ?? "")
        _weightText = State(initialValue: SetInput.weightText(grams: initial?.weightGrams))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("动作")
                    Menu {
                        Picker("动作", selection: $exerciseID) {
                            ForEach(ExerciseCatalog.all) { Text($0.displayName).tag($0.id) }
                        }
                    } label: {
                        HStack {
                            Text(exerciseName).foregroundStyle(Palette.text)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(Palette.text2)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .card(radius: 14)
                    }
                    .accessibilityLabel("动作，\(exerciseName)")

                    fieldLabel("次数")
                    HStack(spacing: 12) {
                        stepButton(systemImage: "minus", label: "减少 1 次") { step(-1) }
                        TextField("0", text: $repsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.countNumber)
                            .monospacedDigit()
                            .foregroundStyle(Palette.text)
                            .frame(height: 72)
                            .card(radius: 16)
                            .accessibilityLabel("次数")
                        stepButton(systemImage: "plus", label: "增加 1 次") { step(1) }
                    }

                    fieldLabel("重量（可不填）")
                    HStack {
                        TextField("未填写", text: $weightText)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(Palette.text)
                        Text("kg").foregroundStyle(Palette.text2)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .card(radius: 14)
                    Text(loadHint).font(.footnote).foregroundStyle(Palette.text2)

                    if let errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(Palette.red)
                            .padding(.top, 4)
                    }

                    Button(action: save) {
                        Label("保存", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 16)

                    if let onDelete {
                        Button(role: .destructive) {
                            if deleteConfirmation == nil {
                                onDelete()
                                dismiss()
                            } else {
                                isConfirmingDelete = true
                            }
                        } label: {
                            Label("删除这一组", systemImage: "trash")
                                .font(.body)
                                .foregroundStyle(Palette.red)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .pageBackground()
            .confirmationDialog(
                deleteConfirmation?.title ?? "", isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button(deleteConfirmation?.action ?? "删除", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
            } message: {
                Text(deleteConfirmation?.message ?? "")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var exerciseName: String {
        ExerciseCatalog.exercise(id: exerciseID)?.displayName ?? exerciseID
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.text2)
            .padding(.top, 12)
    }

    private func stepButton(
        systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Palette.raised))
        }
        .accessibilityLabel(label)
    }

    /// 同一个数字对哑铃和杠铃含义不同，按动作提示重量口径
    private var loadHint: String {
        switch ExerciseCatalog.exercise(id: exerciseID)?.load {
        case .perDumbbell: "填单只哑铃的重量"
        case .barbellTotal: "填杠铃含杠总重"
        case .addedToBodyweight: "填自重之外的额外负重，徒手填 0"
        case nil: ""
        }
    }

    private func step(_ delta: Int) {
        let current = Int(repsText.trimmingCharacters(in: .whitespaces)) ?? 0
        repsText = String(min(max(0, current + delta), SetInput.maxReps))
    }

    private func save() {
        do throws(SetInput.ValidationError) {
            let reps = try SetInput.reps(from: repsText)
            let weightGrams = try SetInput.weightGrams(from: weightText)
            onSave(
                DraftSet(
                    id: draftID ?? UUID(), exerciseID: exerciseID, reps: reps,
                    weightGrams: weightGrams))
            dismiss()
        } catch {
            errorMessage = error.message
        }
    }
}
