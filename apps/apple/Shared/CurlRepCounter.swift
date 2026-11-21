struct CurlRepCounter {
    struct Sample {
        let timestamp: Double
        let userAccelerationG: SIMD3<Double>
        let rotationRateRadS: SIMD3<Double>
        let gravityG: SIMD3<Double>
    }

    private enum Phase {
        case waitingForQuiet
        case ready
        case moving
    }

    private static let windowSeconds = 0.20
    private static let maximumGap = 0.20
    private static let minimumInterval = 0.90
    private static let quietRate = 0.20
    private static let minimumPeakRate = 1.50
    private static let minimumLift = 0.45
    private static let returnFraction = 0.85
    private static let assistedReturnFraction = 0.70
    private static let minimumGravityCosine = 0.90

    private(set) var count = 0
    private(set) var gapCount = 0
    private var isFinished = false
    private var phase = Phase.waitingForQuiet
    private var previousSample: Sample?
    private var lastCountTime: Double?
    private var window: [(timestamp: Double, rate: Double)] = []
    private var rateSum = 0.0
    private var startGravity: SIMD3<Double> = .zero
    private var angle = 0.0
    private var highestAngle = 0.0
    private var reachedPeak = false

    mutating func append(_ sample: Sample) {
        guard !isFinished, sample.timestamp.isFinite, sample.timestamp >= 0,
            Self.isFinite(sample.userAccelerationG), Self.isFinite(sample.rotationRateRadS),
            Self.isFinite(sample.gravityG)
        else { return }

        let previous = previousSample
        let interval = previous.map { sample.timestamp - $0.timestamp } ?? 0
        guard previous == nil || interval > 0 else { return }
        previousSample = sample
        if interval > Self.maximumGap {
            gapCount += 1
            phase = .waitingForQuiet
            window.removeAll(keepingCapacity: true)
            rateSum = 0
        }

        let rate = -sample.rotationRateRadS.y
        window.append((sample.timestamp, rate))
        rateSum += rate
        while let first = window.first, first.timestamp < sample.timestamp - Self.windowSeconds {
            rateSum -= window.removeFirst().rate
        }
        let smoothRate = rateSum / Double(window.count)
        switch phase {
        case .waitingForQuiet:
            if abs(smoothRate) <= Self.quietRate { phase = .ready }
            return
        case .ready:
            guard smoothRate > Self.quietRate, let previous else { return }
            startGravity = previous.gravityG
            angle = 0
            highestAngle = 0
            reachedPeak = false
            phase = .moving
        case .moving:
            break
        }

        angle += smoothRate * interval
        highestAngle = max(highestAngle, angle)
        reachedPeak = reachedPeak || smoothRate >= Self.minimumPeakRate
        guard reachedPeak, highestAngle >= Self.minimumLift else {
            if angle <= 0 { phase = .ready }
            return
        }
        guard smoothRate < 0 else { return }

        // At the top the gyro is quiet too. Count only after a measured return.
        let returned = highestAngle - angle
        let gravityConfirmsReturn =
            returned >= Self.assistedReturnFraction * highestAngle
            && Self.hasReturnedToStart(sample.gravityG, startGravity)
        guard returned >= Self.returnFraction * highestAngle || gravityConfirmsReturn else {
            return
        }
        phase = .ready
        if lastCountTime.map({ sample.timestamp - $0 >= Self.minimumInterval }) ?? true {
            count += 1
            lastCountTime = sample.timestamp
        }
    }

    mutating func finish() -> Int {
        isFinished = true
        return count
    }

    mutating func reset() {
        self = Self()
    }

    private static func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private static func hasReturnedToStart(
        _ gravity: SIMD3<Double>, _ start: SIMD3<Double>
    ) -> Bool {
        let product = gravity * start
        let gravitySquared = gravity * gravity
        let startSquared = start * start
        let lengthProduct =
            (gravitySquared.x + gravitySquared.y + gravitySquared.z).squareRoot()
            * (startSquared.x + startSquared.y + startSquared.z).squareRoot()
        guard lengthProduct > 0, lengthProduct.isFinite else { return false }
        let cosine = (product.x + product.y + product.z) / lengthProduct
        return cosine >= minimumGravityCosine
    }
}
