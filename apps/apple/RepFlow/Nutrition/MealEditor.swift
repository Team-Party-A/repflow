import CryptoKit
import PhotosUI
import SwiftUI

private struct FoodChoice: Identifiable {
    let id = UUID()
    let replace: UUID?
}

struct MealEditor: View {
    let userID: UUID
    let saved: (Date) -> Void
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealDraft
    @State private var choice: FoodChoice?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var camera = false
    @State private var operation: Task<Void, Never>?
    @State private var lastPhotoHash: SHA256.Digest?
    @State private var photoRequest = UUID()
    @State private var appliedPhotoHashes = Set<Data>()
    @State private var analysing = false
    @State private var saving = false
    @State private var message: String?

    init(userID: UUID, initial: MealDraft, saved: @escaping (Date) -> Void) {
        self.userID = userID
        self.saved = saved
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("用餐时间", selection: $draft.eatenAt)
                    NutrientSummary(values: draft.totals)
                }
                Section("识别餐照") {
                    if analysing {
                        HStack {
                            ProgressView()
                            Text("正在识别餐照")
                            Spacer()
                            Button("取消") { operation?.cancel() }
                        }
                    } else {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                camera = true
                            } label: {
                                Label("拍照", systemImage: "camera")
                            }
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("从相册选择", systemImage: "photo")
                        }
                    }
                    Text("餐照将发送给豆包识别。识别结果可修改，确认保存后才计入当天。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("食物与可食份量") {
                    ForEach($draft.items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.food.name).font(.headline)
                                Spacer()
                                Button("替换") { choice = FoodChoice(replace: item.id) }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    draft.items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless).accessibilityLabel("移除" + item.food.name)
                            }
                            Text(
                                [
                                    item.food.preparation, item.food.sourceLabel,
                                    item.food.sourceReference,
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("待补", text: $item.weight).keyboardType(.decimalPad)
                                    .accessibilityLabel(item.food.name + "的可食重量")
                                Text("克")
                                if item.needsReview {
                                    Text("请核对").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if !item.valid {
                                Text("请输入大于零的克数，或留空待补").font(.caption).foregroundStyle(.red)
                            }
                            NutrientSummary(values: item.food.per100g.serving(grams: item.grams))
                        }
                    }
                    Button {
                        choice = FoodChoice(replace: nil)
                    } label: {
                        Label("添加食物、油或酱汁", systemImage: "plus")
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .disabled(saving)
            .navigationTitle(draft.revision == 1 ? "记一餐" : "修改餐次")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认保存") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let meal = try await accounts.nutrition(for: userID).save(draft)
                                saved(meal.eatenAt)
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(!draft.valid || analysing || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(item: $choice) { selection in
                FoodPicker(userID: userID) { food in
                    if let replace = selection.replace {
                        if let i = draft.items.firstIndex(where: { $0.id == replace }) {
                            draft.items[i].food = food.snapshot
                            draft.items[i].needsReview = false
                        }
                    } else {
                        draft.items.append(DraftItem(food: food.snapshot, grams: nil))
                    }
                    choice = nil
                }
            }
            .sheet(isPresented: $camera) {
                MealCamera { image in
                    camera = false
                    guard let image else { return }
                    begin { try MealPhoto.encode(image) }
                }
            }
            .onChange(of: selectedPhoto) { _, photo in
                guard let photo else { return }
                begin {
                    guard let original = try await photo.loadTransferable(type: Data.self) else {
                        throw NutritionError.invalidPhoto
                    }
                    return try MealPhoto.encode(original)
                }
            }
            .onDisappear { operation?.cancel() }
        }
    }

    private func begin(_ input: @escaping () async throws -> Data) {
        guard !analysing else { return }
        analysing = true
        message = nil
        operation = Task {
            defer {
                analysing = false
                selectedPhoto = nil
                operation = nil
            }
            do {
                let jpeg = try await input()
                try Task.checkCancellation()
                let hash = SHA256.hash(data: jpeg)
                guard !appliedPhotoHashes.contains(Data(hash)) else {
                    message = "这张餐照的识别结果已经加入草稿"
                    return
                }
                if lastPhotoHash != hash {
                    lastPhotoHash = hash
                    photoRequest = UUID()
                }
                let items: [AnalysisJob.Item]
                do {
                    items = try await accounts.nutrition(for: userID).analyse(
                        jpeg, key: photoRequest)
                } catch let failure as NutritionError {
                    // 服务已经返回终态；重新选图时允许发起新一轮识别。
                    lastPhotoHash = nil
                    throw failure
                }
                try Task.checkCancellation()
                appliedPhotoHashes.insert(Data(hash))
                draft.items.append(
                    contentsOf: items.map {
                        DraftItem(food: $0.food, grams: $0.grams, needsReview: $0.needsReview)
                    })
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
}
