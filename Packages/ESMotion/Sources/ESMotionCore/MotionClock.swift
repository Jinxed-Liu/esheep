import Foundation

public enum MotionClock {
    public static func wrappedTime(
        for date: Date,
        wrap: TimeInterval
    ) -> TimeInterval {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: max(wrap, 1))
    }
}

public struct MotionFrame: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let targetTimestamp: TimeInterval
    public let deltaTime: TimeInterval
    public let wrappedTime: TimeInterval
    public let renderScale: Double
    public let quality: MotionQualityTier

    public init(
        timestamp: TimeInterval,
        targetTimestamp: TimeInterval,
        deltaTime: TimeInterval,
        wrappedTime: TimeInterval,
        renderScale: Double,
        quality: MotionQualityTier
    ) {
        self.timestamp = timestamp
        self.targetTimestamp = targetTimestamp
        self.deltaTime = max(deltaTime, 0)
        self.wrappedTime = wrappedTime
        self.renderScale = min(max(renderScale, 0.35), 1)
        self.quality = quality
    }
}

public protocol MotionSceneDescriptor: Hashable, Sendable {
    var id: String { get }
    var budget: MotionBudget { get }
}
