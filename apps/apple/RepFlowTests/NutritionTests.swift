import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import RepFlow

final class NutritionTests: XCTestCase {
    private let rice = FoodSnapshot(
        reference: FoodReference(id: UUID(), version: 1), name: "米饭", preparation: "熟",
        source: "verified", sourceReference: "包装标签",
        per100g: Nutrients(carbs: 28, protein: 2, fat: 0, energy: 120))

    func testPortionChangesImmediatelyAndUnknownPropagatesPerField() throws {
        var draft = MealDraft()
        draft.items = [DraftItem(food: rice, grams: 200)]
        XCTAssertEqual(draft.totals.carbs, 56)
        draft.items[0].weight = "120"
        XCTAssertEqual(draft.totals.energy, 144)
        XCTAssertEqual(draft.totals.carbs, 33.6)
        let incomplete = FoodSnapshot(
            reference: nil, name: "酱汁", preparation: "未注明", source: "unmatched",
            sourceReference: nil, per100g: Nutrients(carbs: nil, protein: 0, fat: nil, energy: nil))
        draft.items.append(DraftItem(food: incomplete, grams: 10))
        XCTAssertNil(draft.totals.carbs)
        XCTAssertEqual(draft.totals.protein, 2.4)
        draft.items[0].weight = "-3"
        XCTAssertFalse(draft.valid)
    }

    func testUnknownsAreNullAndOnlyOneFoodIdentityIsSent() throws {
        let unmatched = FoodSnapshot(
            reference: nil, name: "混合菜", preparation: "熟", source: "unmatched",
            sourceReference: nil, per100g: Nutrients())
        var draft = MealDraft()
        draft.items = [DraftItem(food: rice, grams: 120), DraftItem(food: unmatched, grams: nil)]
        let wire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(MealWrite(draft)))
                as? [String: Any])
        let items = try XCTUnwrap(wire["items"] as? [[String: Any]])
        XCTAssertEqual(Set(items[0].keys), ["food", "grams"])
        XCTAssertEqual(Set(items[1].keys), ["unmatched_name", "grams"])
        XCTAssertTrue(items[1]["grams"] is NSNull)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Nutrients())) as? [String: Any])
        XCTAssertEqual(values.count, 4)
        XCTAssertTrue(values.values.allSatisfy { $0 is NSNull })
    }

    func testEncodedPhotoDiscardsGPSAndDownsamples() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 24))
        let input = try XCTUnwrap(
            renderer.image { context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2400, height: 24))
            }.cgImage)
        let sourceBytes = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                sourceBytes, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 34.5, kCGImagePropertyGPSLatitudeRef: "N",
        ]
        CGImageDestinationAddImage(
            dest, input, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let jpeg = try MealPhoto.encode(sourceBytes as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let result = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(result[kCGImagePropertyGPSDictionary])
        XCTAssertLessThanOrEqual(try XCTUnwrap(result[kCGImagePropertyPixelWidth] as? Int), 1600)
        XCTAssertLessThanOrEqual(jpeg.count, 4 * 1024 * 1024)
    }

    @MainActor
    func testDraftUploadUsesPrivateJPEGAndSavingUsesStableMealID() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.handler = nil
        }
        let client = NutritionAPI(
            client: APIClient(baseURL: URL(string: "https://test.invalid")!, session: session),
            token: { "unit-only" }, expired: { _ in XCTFail("unexpected expiration") })
        let mealID = UUID()
        let wireFood =
            #"{"reference":null,"source":"unmatched","name":"菜","preparation":"熟","source_reference":null,"per_100g":{"carbs_g":null,"protein_g":null,"fat_g":null,"energy_kcal":null}}"#
        let job =
            "{\"id\":\"\(mealID)\",\"status\":\"ready\",\"failure_code\":null,\"items\":[{\"food\":\(wireFood),\"grams\":null,\"needs_review\":true}]}"
        let key = UUID()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/nutrition/analyses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-only")
            return (202, Data(job.utf8))
        }
        let items = try await client.analyse(Data([0xff, 0xd8]), key: key)
        XCTAssertEqual(items.first?.food.name, "菜")
        var draft = MealDraft()
        draft.items = items.map { DraftItem(food: $0.food, grams: $0.grams) }
        let stable = draft.id
        let result =
            "{\"id\":\"\(stable)\",\"revision\":1,\"eaten_at\":\"2026-11-21T03:04:05.250Z\",\"items\":[],\"totals\":{\"carbs_g\":null,\"protein_g\":null,\"fat_g\":null,\"energy_kcal\":null}}"
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.lastPathComponent, stable.uuidString)
            return (200, Data(result.utf8))
        }
        for _ in 0..<2 {
            let saved = try await client.save(draft)
            XCTAssertEqual(saved.id, stable)
        }
    }
}
