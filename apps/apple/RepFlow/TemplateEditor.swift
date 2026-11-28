import SwiftData
import SwiftUI

struct TemplateEditor: View {
    let userID: UUID
    var original: TrainingTemplate?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rows: [TemplateRow]
    @State private var error: String?

    init(userID: UUID, original: TrainingTemplate? = nil, starting: [TemplateTarget] = []) {
        self.userID = userID
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _rows = State(initialValue: (original?.orderedTargets ?? starting).map(TemplateRow.init))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("模板名称", text: $name)
                Section("动作顺序与目标") {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading) {
                            Picker("动作", selection: $row.exerciseID) {
                                if ExerciseCatalog.exercise(id: row.exerciseID) == nil {
                                    Text(row.exerciseID).tag(row.exerciseID)
                                }
                                ForEach(ExerciseCatalog.all) { Text($0.displayName).tag($0.id) }
                            }
                            Stepper("\(row.sets) 组", value: $row.sets, in: 1...max(100, row.sets))
                            HStack {
                                TextField("每组次数", text: $row.reps).keyboardType(.numberPad)
                                Text("次")
                                TextField("可选重量", text: $row.weight).keyboardType(.decimalPad)
                                Text("kg")
                            }
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    Button("添加动作") {
                        guard let first = ExerciseCatalog.all.first else { return }
                        rows.append(
                            TemplateRow(
                                .init(exerciseID: first.id, sets: 1, reps: 8, weightGrams: nil)))
                    }
                }
                if let error { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle(original == nil ? "新建模板" : "编辑模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(
                            rows.isEmpty
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets: [TemplateTarget]
        do throws(SetInput.ValidationError) {
            var parsed: [TemplateTarget] = []
            for row in rows { parsed.append(try row.target()) }
            targets = parsed
        } catch {
            self.error = error.message
            return
        }
        if let original {
            guard original.userID == userID else {
                error = "模板所属账号已变化"
                return
            }
            original.name = trimmed
            let previous = original.targets
            original.targets = targets.enumerated().map {
                TrainingTarget(position: $0.offset, target: $0.element)
            }
            for target in previous { context.delete(target) }
        } else {
            context.insert(TrainingTemplate(userID: userID, name: trimmed, targets: targets))
        }
        do {
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            self.error = "模板保存失败：\(error.localizedDescription)"
        }
    }
}

private struct TemplateRow: Identifiable {
    let id = UUID()
    var exerciseID: String
    var sets: Int
    var reps: String
    var weight: String
    init(_ target: TemplateTarget) {
        exerciseID = target.exerciseID
        sets = target.sets
        reps = String(target.reps)
        weight = SetInput.weightText(grams: target.weightGrams)
    }
    func target() throws(SetInput.ValidationError) -> TemplateTarget {
        try TemplateTarget(
            exerciseID: exerciseID, sets: sets, reps: SetInput.reps(from: reps),
            weightGrams: SetInput.weightGrams(from: weight))
    }
}
