import Foundation

public struct MotionSpring: Codable, Equatable, Sendable {
    public let response: TimeInterval
    public let dampingRatio: Double

    public init(response: TimeInterval, dampingRatio: Double) {
        self.response = max(response, 0.05)
        self.dampingRatio = max(dampingRatio, 0.01)
    }

    public static let transition = MotionSpring(
        response: 0.42,
        dampingRatio: 0.86
    )
    public static let press = MotionSpring(
        response: 0.18,
        dampingRatio: 0.82
    )
}

public struct MotionSpringState: Equatable, Sendable {
    public var value: Double
    public var velocity: Double
    public var target: Double

    public init(value: Double, velocity: Double = 0, target: Double) {
        self.value = value
        self.velocity = velocity
        self.target = target
    }

    public var isSettled: Bool {
        abs(target - value) < 0.0005 && abs(velocity) < 0.0005
    }

    public mutating func retarget(to newTarget: Double) {
        target = newTarget
    }

    public mutating func step(
        deltaTime: TimeInterval,
        spring: MotionSpring
    ) {
        guard deltaTime > 0 else { return }

        let angularFrequency = (2 * Double.pi) / spring.response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * spring.dampingRatio * angularFrequency
        let cappedDelta = min(deltaTime, 1 / 30)
        let acceleration = stiffness * (target - value) - damping * velocity

        velocity += acceleration * cappedDelta
        value += velocity * cappedDelta

        if isSettled {
            value = target
            velocity = 0
        }
    }
}

public struct MotionInteractiveProgress: Equatable, Sendable {
    public private(set) var progress: Double
    public private(set) var velocity: Double
    public private(set) var target: Double

    public init(
        progress: Double = 0,
        velocity: Double = 0,
        target: Double = 0
    ) {
        self.progress = progress.clampedUnit
        self.velocity = velocity
        self.target = target.clampedUnit
    }

    public mutating func update(progress: Double, velocity: Double) {
        self.progress = progress.clampedUnit
        self.velocity = velocity
    }

    @discardableResult
    public mutating func finish(
        projectedProgress: Double,
        velocity: Double,
        progressThreshold: Double = 0.35,
        velocityThreshold: Double = 900
    ) -> Bool {
        let shouldComplete = projectedProgress >= progressThreshold
            || velocity >= velocityThreshold
        target = shouldComplete ? 1 : 0
        self.velocity = velocity
        return shouldComplete
    }

    public mutating func cancel() {
        target = 0
    }

    public mutating func retarget(to progress: Double) {
        target = progress.clampedUnit
    }

    public mutating func synchronize(with springState: MotionSpringState) {
        progress = springState.value.clampedUnit
        velocity = springState.velocity
        target = springState.target.clampedUnit
    }
}

extension Double {
    fileprivate var clampedUnit: Double {
        min(max(self, 0), 1)
    }
}
