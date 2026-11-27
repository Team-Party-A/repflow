import SwiftUI

struct FoodPicker: View {
    let userID: UUID
    let select: (CatalogFood) -> Void
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [CatalogFood] = []
    @State private var cursor: String?
    @State private var creating = false
    @State private var submission: CatalogFood?
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    creating = true
                } label: {
                    Label("新建私人食物", systemImage: "plus")
                }
                ForEach(items) { food in
                    HStack {
                        Button {
                            select(food)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(food.name).font(.headline)
                                Text(food.preparation + " · " + food.snapshot.sourceLabel)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(
                                    "每 100 克 · "
                                        + Nutrients.display(food.per100g.energy, unit: "kcal")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        if food.source == "private" {
                            Button("投稿") { submission = food }.buttonStyle(.borderless)
                        }
                    }
                }
                if let cursor {
                    Button("更多食物") { Task { await load(after: cursor) } }.disabled(loading)
                }
                if loading { ProgressView() }
                if !loading && items.isEmpty && message == nil { Text("暂无匹配食物，可按包装标签新建。") }
                if let message { Text(message).font(.footnote) }
            }
            .searchable(text: $query, prompt: "按名称或别名搜索")
            .navigationTitle("选择食物")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: query) {
                items = []
                cursor = nil
                message = nil
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                await load(after: nil)
            }
            .sheet(isPresented: $creating) {
                NewFoodView(userID: userID, initialName: query) { food in
                    creating = false
                    select(food)
                }
            }
            .confirmationDialog(
                "向共享食物库投稿？",
                isPresented: Binding(
                    get: { submission != nil },
                    set: {
                        if !$0 { submission = nil }
                    }), presenting: submission
            ) { food in
                Button("提交食物资料") {
                    Task {
                        do {
                            let status = try await accounts.nutrition(for: userID).submit(food.id)
                            let labels = [
                                "pending": "等待审核", "verified": "已核实", "merged": "已合并",
                                "rejected": "已驳回",
                            ]
                            message = food.name + " · " + (labels[status] ?? status)
                        } catch { message = error.localizedDescription }
                    }
                }
            } message: { _ in
                Text("仅提交食物资料。审核通过后其他人可查到这项食物。")
            }
        }
    }

    private func load(after page: String?) async {
        let phrase = query
        loading = true
        defer { if phrase == query && !Task.isCancelled { loading = false } }
        do {
            let result = try await accounts.nutrition(for: userID).search(phrase, cursor: page)
            guard !Task.isCancelled, phrase == query else { return }
            items = page == nil ? result.items : items + result.items
            cursor = result.nextCursor
        } catch {
            if !Task.isCancelled && phrase == query { message = error.localizedDescription }
        }
    }
}

private struct NewFoodView: View {
    let userID: UUID
    let select: (CatalogFood) -> Void
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var preparation = ""
    @State private var carbs = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var energy = ""
    @State private var key = UUID()
    @State private var previous: PrivateFoodInput?
    @State private var saving = false
    @State private var message: String?

    init(userID: UUID, initialName: String, select: @escaping (CatalogFood) -> Void) {
        self.userID = userID
        self.select = select
        _name = State(initialValue: initialName)
    }

    private func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private var input: PrivateFoodInput? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prep = preparation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(label.unicodeScalars.count),
            (1...120).contains(prep.unicodeScalars.count)
        else { return nil }
        for (text, limit) in [(carbs, 100.0), (protein, 100), (fat, 100), (energy, 1_000)]
        where !text.isEmpty {
            guard let value = number(text), (0...limit).contains(value) else { return nil }
        }
        return PrivateFoodInput(
            name: label, preparation: prep,
            per100g: Nutrients(
                carbs: number(carbs), protein: number(protein), fat: number(fat),
                energy: number(energy)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("食物资料") {
                    TextField("食物名称", text: $name)
                    TextField("生熟或做法，例如熟、蒸、包装即食", text: $preparation)
                }
                Section {
                    field("碳水（克）", $carbs)
                    field("蛋白质（克）", $protein)
                    field("脂肪（克）", $fat)
                    field("能量（千卡）", $energy)
                } header: {
                    Text("每 100 克可食部分")
                } footer: {
                    Text("缺少的数值留空，餐次中将显示「待补」。")
                }
                if let message { Text(message) }
            }
            .disabled(saving)
            .navigationTitle("新建私人食物")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并选用") {
                        guard let input else { return }
                        if previous != input {
                            key = UUID()
                            previous = input
                        }
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                select(
                                    try await accounts.nutrition(for: userID).create(
                                        input, key: key))
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(input == nil || saving)
                }
            }
        }
    }

    private func field(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label)
            TextField("待补", text: value).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                .accessibilityLabel(label)
        }
    }
}
