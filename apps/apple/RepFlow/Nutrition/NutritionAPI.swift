import Foundation

enum NutritionError: LocalizedError {
    case signIn, invalidPhoto, expired, noFood, unavailable, invalidDraft
    var errorDescription: String? {
        switch self {
        case .signIn: return "请重新登录后记餐"
        case .invalidPhoto: return "无法读取餐照，请重选一张图片"
        case .expired: return "识别超时，可以重试或手动添加食物"
        case .noFood: return "未识别到食物，可重新拍摄或手动添加"
        case .unavailable: return "识别暂不可用，可手动添加食物"
        case .invalidDraft: return "请核对食材和份量后保存"
        }
    }
}

@MainActor
struct NutritionAPI {
    let client: APIClient
    let token: () throws -> String
    let expired: (String) -> Void

    private func call(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [],
        body: Data? = nil, type: String = "application/json", key: UUID? = nil
    ) async throws -> Data {
        let bearer = try token()
        do {
            return try await client.send(
                "nutrition/" + path, method: method, token: bearer, query: query,
                body: body, contentType: type, idempotencyKey: key)
        } catch APIError.server(let status, _, _) where status == 401 {
            expired(bearer)
            throw NutritionError.signIn
        }
    }

    private func read<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let wire = try value.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: wire) { return date }
            format.formatOptions = [.withInternetDateTime]
            guard let date = format.date(from: wire) else { throw APIError.undecodable }
            return date
        }
        return try decoder.decode(T.self, from: data)
    }

    func search(_ text: String, cursor: String? = nil) async throws -> FoodPage {
        var query = [URLQueryItem(name: "q", value: text)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try read(await call("foods", query: query))
    }

    func create(_ food: PrivateFoodInput, key: UUID) async throws -> CatalogFood {
        try read(await call("foods", method: "POST", body: JSONEncoder().encode(food), key: key))
    }

    func submit(_ food: UUID) async throws -> String {
        struct Receipt: Decodable { let status: String }
        let receipt: Receipt = try read(
            await call("foods/\(food.uuidString)/submissions", method: "POST"))
        return receipt.status
    }

    func day(_ date: Date, zone: TimeZone = .current) async throws -> NutritionDay {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return try read(
            await call(
                "meals",
                query: [
                    URLQueryItem(name: "date", value: formatter.string(from: date)),
                    URLQueryItem(name: "timezone", value: zone.identifier),
                ]))
    }

    func save(_ draft: MealDraft) async throws -> RecordedMeal {
        guard draft.valid else { throw NutritionError.invalidDraft }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try read(
            await call(
                "meals/\(draft.id.uuidString)", method: "PUT",
                body: encoder.encode(MealWrite(draft))))
    }

    func delete(_ meal: RecordedMeal) async throws {
        _ = try await call(
            "meals/\(meal.id.uuidString)", method: "DELETE",
            query: [URLQueryItem(name: "revision", value: String(meal.revision + 1))])
    }

    func analyse(_ jpeg: Data, key: UUID) async throws -> [AnalysisJob.Item] {
        var job: AnalysisJob = try read(
            await call("analyses", method: "POST", body: jpeg, type: "image/jpeg", key: key))
        let deadline = ContinuousClock.now.advanced(by: .seconds(105))
        while job.status == "queued" || job.status == "processing" {
            guard ContinuousClock.now < deadline else { throw NutritionError.expired }
            try await Task.sleep(for: .seconds(2))
            job = try read(await call("analyses/\(job.id.uuidString)"))
        }
        if job.status == "ready" { return job.items }
        if job.failureCode == "no_food" { throw NutritionError.noFood }
        if job.status == "expired" { throw NutritionError.expired }
        throw NutritionError.unavailable
    }
}
