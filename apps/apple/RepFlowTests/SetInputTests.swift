import XCTest

@testable import RepFlow

final class SetInputTests: XCTestCase {
    func testRepsMustBePositiveInteger() throws {
        XCTAssertEqual(try SetInput.reps(from: " 12 "), 12)
        XCTAssertEqual(try SetInput.reps(from: "9999"), 9999)
        for text in ["", "0", "-1", "2.5", "abc", "10000", "１２"] {
            XCTAssertThrowsError(try SetInput.reps(from: text), "reps=\(text)") {
                XCTAssertEqual($0 as? SetInput.ValidationError, .invalidReps)
            }
        }
    }

    func testEmptyWeightIsNilAndZeroIsKept() throws {
        XCTAssertNil(try SetInput.weightGrams(from: ""))
        XCTAssertNil(try SetInput.weightGrams(from: "  "))
        XCTAssertEqual(try SetInput.weightGrams(from: "0"), 0)
    }

    func testWeightConvertsKilogramsToRoundedGrams() throws {
        XCTAssertEqual(try SetInput.weightGrams(from: "12.5"), 12_500)
        XCTAssertEqual(try SetInput.weightGrams(from: "0.0005"), 1)
        XCTAssertEqual(try SetInput.weightGrams(from: "1.0004"), 1_000)
        XCTAssertEqual(try SetInput.weightGrams(from: "1000"), 1_000_000)
    }

    func testInvalidWeightIsRejectedNotTruncated() {
        let cases: [(String, SetInput.ValidationError)] = [
            ("-1", .negativeWeight), ("abc", .invalidWeight), ("1.2.3", .invalidWeight),
            ("1000.001", .weightTooLarge),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try SetInput.weightGrams(from: text), "weight=\(text)") {
                XCTAssertEqual($0 as? SetInput.ValidationError, expected)
            }
        }
    }

    func testWeightTextRoundTrips() {
        XCTAssertEqual(SetInput.weightText(grams: nil), "")
        XCTAssertEqual(SetInput.weightText(grams: 0), "0")
        XCTAssertEqual(SetInput.weightText(grams: 12_500), "12.5")
    }
}
