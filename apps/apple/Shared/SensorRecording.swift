import Foundation

struct RecordingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SensorRecording: Encodable {
    struct Metadata: Encodable {
        struct Device: Encodable {
            let model: String
            let osVersion: String
        }
        let participantId: String
        let recordingKind: String
        let activity: String
        let wornWrist: String
        let crownOrientation: String
        let device: Device
        let recorderVersion: String
        let requestedHz: Double
        let timeOrigin = "first_motion_sample"
        let coordinateFrame = "core_motion_device"
        let attitudeReferenceFrame = "xArbitraryZVertical"
        let attitudeRecorded = false
    }

    struct Sample: Encodable {
        let tS: Double
        let userAccelerationG: [Double]
        let rotationRateRadS: [Double]
        let gravityG: [Double]
    }

    struct SetBoundary: Encodable {
        let startS: Double
        let endS: Double

        enum CodingKeys: String, CodingKey { case startS, endS, groundTruthCount }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(startS, forKey: .startS)
            try container.encode(endS, forKey: .endS)
            // 录制按钮只标记组边界，不能把未经独立核验的次数当作真值。
            try container.encodeNil(forKey: .groundTruthCount)
        }
    }

    let recordingId: String
    let dataKind: String
    let durationS: Double
    let metadata: Metadata
    let set: SetBoundary?
    let samples: [Sample]

    enum CodingKeys: String, CodingKey {
        case formatVersion, recordingId, dataKind, durationS, metadata, set, annotations, samples
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("1.0", forKey: .formatVersion)
        try container.encode(recordingId, forKey: .recordingId)
        try container.encode(dataKind, forKey: .dataKind)
        try container.encode(durationS, forKey: .durationS)
        try container.encode(metadata, forKey: .metadata)
        if let set {
            try container.encode(set, forKey: .set)
        } else {
            try container.encodeNil(forKey: .set)
        }
        try container.encode([String](), forKey: .annotations)
        try container.encode(samples, forKey: .samples)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct RecordingDraft {
    let metadata: SensorRecording.Metadata
    private(set) var origin: Double?
    private(set) var samples: [SensorRecording.Sample] = []
    private(set) var startS: Double?
    private(set) var endS: Double?

    mutating func append(
        timestamp: Double, acceleration: [Double], rotation: [Double], gravity: [Double]
    ) throws {
        guard timestamp.isFinite, timestamp >= 0,
            [acceleration, rotation, gravity].allSatisfy({
                $0.count == 3 && $0.allSatisfy(\.isFinite)
            })
        else { throw RecordingError(message: "运动样本含非法时间或三轴数值，录制已中断。") }
        let time = timestamp - (origin ?? timestamp)
        guard samples.last.map({ time > $0.tS }) ?? true else {
            throw RecordingError(message: "运动时间戳重复或倒序，录制已中断。")
        }
        origin = origin ?? timestamp
        samples.append(
            .init(
                tS: time, userAccelerationG: acceleration, rotationRateRadS: rotation,
                gravityG: gravity))
    }

    func relativeTime(at uptime: Double) throws -> Double {
        guard let origin, uptime.isFinite, uptime >= origin else {
            throw RecordingError(message: "尚未收到有效运动样本。")
        }
        return uptime - origin
    }

    mutating func beginSet(at uptime: Double) throws {
        guard metadata.recordingKind == "exercise_set", startS == nil else {
            throw RecordingError(message: "当前录制不能再次开始本组。")
        }
        startS = try relativeTime(at: uptime)
    }

    mutating func endSet(at uptime: Double) throws {
        let time = try relativeTime(at: uptime)
        guard let startS, time > startS, endS == nil else {
            throw RecordingError(message: "请先开始本组，再结束本组。")
        }
        endS = time
    }

    func finish(at uptime: Double, dataKind: String = "recorded") throws -> SensorRecording {
        let duration = try relativeTime(at: uptime)
        guard samples.count >= 2, duration > 0, duration >= samples.last!.tS else {
            throw RecordingError(message: "至少需要两个样本，且结束时间不能早于末样本。")
        }
        var boundary: SensorRecording.SetBoundary?
        if metadata.recordingKind == "exercise_set" {
            guard let startS, let endS, startS < endS, endS <= duration else {
                throw RecordingError(message: "请标记有效组的开始和结束。")
            }
            boundary = .init(startS: startS, endS: endS)
        }
        return SensorRecording(
            recordingId: UUID().uuidString.lowercased(), dataKind: dataKind,
            durationS: duration, metadata: metadata, set: boundary, samples: samples)
    }
}
