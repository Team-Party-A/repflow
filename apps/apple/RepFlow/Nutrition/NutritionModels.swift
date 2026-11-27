import Foundation

struct Nutrients: Codable, Equatable {
    var carbs: Double?
    var protein: Double?
    var fat: Double?
    var energy: Double?

    enum CodingKeys: String, CodingKey {
        case carbs = "carbs_g"
        case protein = "protein_g"
        case fat = "fat_g"
        case energy = "energy_kcal"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(carbs, forKey: .carbs)
        try values.encode(protein, forKey: .protein)
        try values.encode(fat, forKey: .fat)
        try values.encode(energy, forKey: .energy)
    }

    func serving(grams: Double?) -> Nutrients {
        func scale(_ value: Double?) -> Double? {
            guard let grams, let value else { return nil }
            return grams * value / 100
        }
        return Nutrients(
            carbs: scale(carbs), protein: scale(protein), fat: scale(fat), energy: scale(energy))
    }

    static func sum(_ rows: [Nutrients]) -> Nutrients {
        func amount(_ key: KeyPath<Nutrients, Double?>) -> Double? {
            var sum = 0.0
            for row in rows {
                guard let value = row[keyPath: key] else { return nil }
                sum += value
            }
            return sum
        }
        return Nutrients(
            carbs: amount(\.carbs), protein: amount(\.protein), fat: amount(\.fat),
            energy: amount(\.energy))
    }

    static func display(_ value: Double?, unit: String) -> String {
        guard let value else { return "待补" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit
    }
}

struct FoodReference: Codable, Equatable {
    let id: UUID
    let version: Int
}

struct FoodSnapshot: Decodable {
    let reference: FoodReference?
    let name: String
    let preparation: String
    let source: String
    let sourceReference: String?
    let per100g: Nutrients

    enum CodingKeys: String, CodingKey {
        case reference, name, preparation, source
        case sourceReference = "source_reference"
        case per100g = "per_100g"
    }

    var sourceLabel: String {
        switch source {
        case "verified": return "官方已核实"
        case "private": return "我的食物"
        case "ai_estimate": return "AI 估算"
        default: return "待匹配"
        }
    }
}

struct CatalogFood: Decodable, Identifiable {
    let id: UUID
    let version: Int
    let name: String
    let preparation: String
    let source: String
    let sourceReference: String?
    let per100g: Nutrients

    enum CodingKeys: String, CodingKey {
        case id, version, name, preparation, source
        case sourceReference = "source_reference"
        case per100g = "per_100g"
    }

    var snapshot: FoodSnapshot {
        FoodSnapshot(
            reference: FoodReference(id: id, version: version), name: name,
            preparation: preparation, source: source, sourceReference: sourceReference,
            per100g: per100g)
    }
}

struct FoodPage: Decodable {
    let items: [CatalogFood]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct PrivateFoodInput: Encodable, Equatable {
    let name: String
    let preparation: String
    let per100g: Nutrients
    enum CodingKeys: String, CodingKey {
        case name, preparation
        case per100g = "per_100g"
    }
}

struct MealItem: Decodable {
    let food: FoodSnapshot
    let grams: Double?
}

struct RecordedMeal: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let eatenAt: Date
    let items: [MealItem]
    let totals: Nutrients
    enum CodingKeys: String, CodingKey {
        case id, revision
        case eatenAt = "eaten_at"
        case items, totals
    }
}

struct NutritionDay: Decodable {
    let meals: [RecordedMeal]
    let totals: Nutrients
}

struct AnalysisJob: Decodable {
    struct Item: Decodable {
        let food: FoodSnapshot
        let grams: Double?
        let needsReview: Bool
        enum CodingKeys: String, CodingKey {
            case food, grams
            case needsReview = "needs_review"
        }
    }
    let id: UUID
    let status: String
    let items: [Item]
    let failureCode: String?
    enum CodingKeys: String, CodingKey {
        case id, items, status
        case failureCode = "failure_code"
    }
}

struct DraftItem: Identifiable {
    let id = UUID()
    var food: FoodSnapshot
    var weight: String
    var needsReview: Bool

    init(food: FoodSnapshot, grams: Double?, needsReview: Bool = false) {
        self.food = food
        self.weight =
            grams.map {
                $0.formatted(
                    .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(
                        .fractionLength(0...10)))
            } ?? ""
        self.needsReview = needsReview
    }

    var grams: Double? {
        Double(weight.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
    var valid: Bool {
        weight.isEmpty || grams.map { $0.isFinite && $0 > 0 && $0 <= 1_000_000 } == true
    }
}

struct MealDraft: Identifiable {
    let id: UUID
    var revision: Int
    var eatenAt: Date
    var items: [DraftItem]

    init(date: Date = .now, original: RecordedMeal? = nil) {
        id = original?.id ?? UUID()
        revision = (original?.revision ?? 0) + 1
        eatenAt = original?.eatenAt ?? date
        items = original?.items.map { DraftItem(food: $0.food, grams: $0.grams) } ?? []
    }

    var totals: Nutrients { .sum(items.map { $0.food.per100g.serving(grams: $0.grams) }) }
    var valid: Bool { !items.isEmpty && items.count <= 256 && items.allSatisfy(\.valid) }
}

struct MealWrite: Encodable {
    struct Item: Encodable {
        let item: DraftItem
        enum CodingKeys: String, CodingKey {
            case grams, food
            case unmatchedName = "unmatched_name"
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(item.grams, forKey: .grams)
            if let ref = item.food.reference {
                try values.encode(ref, forKey: .food)
            } else {
                try values.encode(item.food.name, forKey: .unmatchedName)
            }
        }
    }
    let revision: Int
    let eatenAt: Date
    let items: [Item]
    enum CodingKeys: String, CodingKey {
        case revision
        case eatenAt = "eaten_at"
        case items
    }
    init(_ draft: MealDraft) {
        revision = draft.revision
        eatenAt = draft.eatenAt
        items = draft.items.map { Item(item: $0) }
    }
}
