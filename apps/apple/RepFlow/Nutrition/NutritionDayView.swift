import SwiftUI

struct NutrientSummary: View {
    let values: Nutrients

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 15) { labels }
            Grid(alignment: .leading) { labels }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var labels: some View {
        label("碳水", values.carbs, "g")
        label("蛋白质", values.protein, "g")
        label("脂肪", values.fat, "g")
        label("能量", values.energy, "kcal")
    }

    private func label(_ title: String, _ amount: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Nutrients.display(amount, unit: unit)).font(.footnote.weight(.medium))
                .monospacedDigit()
        }
    }
}

struct NutritionDayView: View {
    let userID: UUID
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDate = Date.now
    @State private var day: NutritionDay?
    @State private var message: String?
    @State private var draft: MealDraft?
    @State private var deletion: RecordedMeal?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Calendar.current.isDateInToday(selectedDate) ? "今日摄入" : "当日摄入").font(.headline)
                Spacer()
                DatePicker("查看日期", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden().accessibilityLabel("查看饮食记录日期")
            }
            if let day {
                NutrientSummary(values: day.totals)
                if day.meals.isEmpty {
                    Text("这天还没有记录餐次").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(day.meals) { meal in
                    Divider()
                    HStack {
                        Button {
                            draft = MealDraft(original: meal)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meal.items.map { $0.food.name }.joined(separator: "、"))
                                    .lineLimit(2)
                                Text(
                                    meal.eatenAt.formatted(date: .omitted, time: .shortened) + " · "
                                        + Nutrients.display(meal.totals.energy, unit: "kcal")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            deletion = meal
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("删除这餐")
                    }
                }
            } else if message == nil {
                ProgressView().accessibilityLabel("读取饮食记录")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("重新读取") { generation = UUID() }
            }
            Button {
                let time = Calendar.current.dateComponents([.hour, .minute], from: .now)
                let date =
                    Calendar.current.date(
                        bySettingHour: time.hour ?? 12, minute: time.minute ?? 0,
                        second: 0, of: selectedDate) ?? selectedDate
                draft = MealDraft(date: date)
            } label: {
                Label("记一餐", systemImage: "fork.knife").font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
        .task(id: generation) {
            day = nil
            message = nil
            let date = selectedDate
            do {
                let result = try await accounts.nutrition(for: userID).day(date)
                if !Task.isCancelled { day = result }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
        .onChange(of: selectedDate) { _, _ in generation = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { generation = UUID() } }
        .sheet(item: $draft, onDismiss: { generation = UUID() }) { initial in
            MealEditor(userID: userID, initial: initial) { date in
                selectedDate = date
                draft = nil
            }
        }
        .confirmationDialog(
            "删除这条餐次记录？",
            isPresented: Binding(
                get: { deletion != nil },
                set: {
                    if !$0 { deletion = nil }
                }), presenting: deletion
        ) { meal in
            Button("删除这餐", role: .destructive) {
                Task {
                    do {
                        try await accounts.nutrition(for: userID).delete(meal)
                        generation = UUID()
                    } catch { message = error.localizedDescription }
                }
            }
        }
    }
}
