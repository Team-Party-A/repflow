import XCTest

@testable import RepFlow

final class RecordingFilesTests: XCTestCase {
    private func data(id: String, version: String = "1.0", extra: String = "") throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "recording_id": id, "format_version": version, "data_kind": "synthetic",
                "extra": extra,
            ], options: [.sortedKeys])
    }

    func testPersistsAcrossInstancesAndDuplicateDeliveryDoesNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let storage = RecordingFiles(directory: directory)
        XCTAssertTrue(try storage.list().isEmpty)
        let identifier = UUID().uuidString.lowercased()
        let original = try data(id: identifier)
        let file = try storage.save(original)
        XCTAssertEqual(try storage.save(original), file)
        XCTAssertThrowsError(try storage.save(data(id: identifier, extra: "changed")))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try RecordingFiles(directory: directory).list(), [file])
        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true)
    }

    func testRejectsUnsupportedVersionPathTraversalAndInvalidJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let storage = RecordingFiles(directory: directory)
        XCTAssertThrowsError(try storage.save(data(id: UUID().uuidString, version: "2.0")))
        XCTAssertThrowsError(try storage.save(data(id: "../../outside")))
        XCTAssertThrowsError(try storage.save(Data("invalid json".utf8)))
        XCTAssertTrue(try storage.list().isEmpty)
    }

    func testWriteFailureIsReportedAndSameBytesCanBeRetried() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("Recordings")
        try Data().write(to: directory)
        let storage = RecordingFiles(directory: directory)
        let original = try data(id: UUID().uuidString)
        XCTAssertThrowsError(try storage.save(original))
        try FileManager.default.removeItem(at: directory)
        let file = try storage.save(original)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
