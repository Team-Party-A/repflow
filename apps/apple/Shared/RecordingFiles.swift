import Foundation

struct RecordingFiles {
    var directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Recordings")

    func list() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.map { $0.resolvingSymlinksInPath() }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    @discardableResult
    func save(_ data: Data) throws -> URL {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["format_version"] as? String == "1.0",
            let kind = object["data_kind"] as? String, ["recorded", "synthetic"].contains(kind),
            let identifier = object["recording_id"] as? String,
            let uuid = UUID(uuidString: identifier)
        else { throw RecordingError(message: "录制文件版本、类型或编号不合法，未保存。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let destination = directory.appendingPathComponent(uuid.uuidString.lowercased() + ".json")
            .resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw RecordingError(message: "相同录制编号的内容不同，未覆盖已有文件。")
            }
        } else {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }
}
