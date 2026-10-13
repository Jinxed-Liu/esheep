import Foundation

public enum MotionEasing: Codable, Equatable, Sendable {
    case linear
    case easeInOut
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
    case spring(MotionSpring)
}

public struct MotionKeyframe: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var time: TimeInterval
    public var value: Double
    public var easing: MotionEasing

    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        value: Double,
        easing: MotionEasing = .linear
    ) {
        self.id = id
        self.time = max(time, 0)
        self.value = value
        self.easing = easing
    }
}

public struct MotionTrack: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var keyPath: String
    public var keyframes: [MotionKeyframe]

    public init(
        id: UUID = UUID(),
        keyPath: String,
        keyframes: [MotionKeyframe]
    ) {
        self.id = id
        self.keyPath = keyPath
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }
}

public enum MotionTrigger: Codable, Equatable, Sendable {
    case automatic
    case tap
    case gesture(String)
    case marker(String)
    case external(String)
}

public enum MotionLoopMode: String, Codable, Sendable {
    case playOnce
    case loop
    case autoReverse
}

public struct MotionSequence: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var duration: TimeInterval
    public var loopMode: MotionLoopMode
    public var trigger: MotionTrigger
    public var tracks: [MotionTrack]

    public init(
        id: UUID = UUID(),
        name: String,
        duration: TimeInterval,
        loopMode: MotionLoopMode = .playOnce,
        trigger: MotionTrigger = .automatic,
        tracks: [MotionTrack] = []
    ) {
        self.id = id
        self.name = name
        self.duration = max(duration, 0)
        self.loopMode = loopMode
        self.trigger = trigger
        self.tracks = tracks
    }
}

public enum MotionSequenceSampler {
    public static func value(
        in track: MotionTrack,
        at time: TimeInterval
    ) -> Double? {
        guard let first = track.keyframes.first else { return nil }
        guard time > first.time else { return first.value }
        guard let last = track.keyframes.last, time < last.time else {
            return track.keyframes.last?.value
        }

        guard let upperIndex = track.keyframes.firstIndex(where: { $0.time >= time }),
              upperIndex > 0 else {
            return first.value
        }

        let lower = track.keyframes[upperIndex - 1]
        let upper = track.keyframes[upperIndex]
        let span = max(upper.time - lower.time, .leastNonzeroMagnitude)
        let rawProgress = min(max((time - lower.time) / span, 0), 1)
        let easedProgress = eased(rawProgress, using: upper.easing)
        return lower.value + (upper.value - lower.value) * easedProgress
    }

    private static func eased(
        _ progress: Double,
        using easing: MotionEasing
    ) -> Double {
        switch easing {
        case .linear:
            return progress
        case .easeInOut:
            return progress * progress * (3 - 2 * progress)
        case .cubicBezier(_, let y1, _, let y2):
            let inverse = 1 - progress
            return 3 * inverse * inverse * progress * y1
                + 3 * inverse * progress * progress * y2
                + progress * progress * progress
        case .spring(let spring):
            let decay = exp(-spring.dampingRatio * 8 * progress)
            return 1 - decay * cos(progress * Double.pi * 2 / spring.response)
        }
    }
}
