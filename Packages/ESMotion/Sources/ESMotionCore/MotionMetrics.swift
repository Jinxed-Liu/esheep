import Foundation

public struct MotionMetricSample: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let frameInterval: TimeInterval
    public let callbackCount: Int
    public let quality: MotionQualityTier

    public init(
        timestamp: TimeInterval,
        frameInterval: TimeInterval,
        callbackCount: Int,
        quality: MotionQualityTier
    ) {
        self.timestamp = timestamp
        self.frameInterval = max(frameInterval, 0)
        self.callbackCount = max(callbackCount, 0)
        self.quality = quality
    }
}

public actor MotionMetricsStore {
    private let capacity: Int
    private var samples: [MotionMetricSample] = []

    public init(capacity: Int = 240) {
        self.capacity = max(capacity, 1)
    }

    public func append(_ sample: MotionMetricSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func append(contentsOf newSamples: [MotionMetricSample]) {
        samples.append(contentsOf: newSamples)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func snapshot() -> [MotionMetricSample] {
        samples
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
