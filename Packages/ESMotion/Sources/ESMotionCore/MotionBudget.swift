import Foundation

public enum MotionQualityTier: Int, Codable, CaseIterable, Hashable, Sendable {
    case full
    case balanced
    case efficient
    case minimal

    public mutating func degrade(to tier: MotionQualityTier) {
        if tier.rawValue > rawValue {
            self = tier
        }
    }
}

public enum MotionThermalPressure: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }
}

public struct MotionFrameRateRange: Codable, Hashable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public let preferred: Int

    public init(minimum: Int, maximum: Int, preferred: Int) {
        let normalizedMinimum = max(minimum, 1)
        let normalizedMaximum = max(maximum, normalizedMinimum)
        self.minimum = normalizedMinimum
        self.maximum = normalizedMaximum
        self.preferred = min(max(preferred, normalizedMinimum), normalizedMaximum)
    }

    public static let interactive = MotionFrameRateRange(
        minimum: 80,
        maximum: 120,
        preferred: 120
    )
    public static let foreground = MotionFrameRateRange(
        minimum: 30,
        maximum: 60,
        preferred: 60
    )
    public static let ambient = MotionFrameRateRange(
        minimum: 15,
        maximum: 30,
        preferred: 30
    )
    public static let lowPowerAmbient = MotionFrameRateRange(
        minimum: 10,
        maximum: 20,
        preferred: 15
    )
}

public enum MotionWorkload: String, Codable, Hashable, Sendable {
    case interaction
    case foregroundScene
    case ambientScene
}

public struct MotionBudget: Codable, Hashable, Sendable {
    public let workload: MotionWorkload
    public let frameRateRange: MotionFrameRateRange
    public let lowPowerFrameRateRange: MotionFrameRateRange
    public let baseRenderScale: Double
    public let timeWrap: TimeInterval

    public init(
        workload: MotionWorkload,
        frameRateRange: MotionFrameRateRange,
        lowPowerFrameRateRange: MotionFrameRateRange,
        baseRenderScale: Double = 1,
        timeWrap: TimeInterval = 1_800
    ) {
        self.workload = workload
        self.frameRateRange = frameRateRange
        self.lowPowerFrameRateRange = lowPowerFrameRateRange
        self.baseRenderScale = baseRenderScale.clamped(to: 0.35 ... 1)
        self.timeWrap = max(timeWrap, 1)
    }

    public static let interaction = MotionBudget(
        workload: .interaction,
        frameRateRange: .interactive,
        lowPowerFrameRateRange: .foreground
    )

    public static let foregroundScene = MotionBudget(
        workload: .foregroundScene,
        frameRateRange: .foreground,
        lowPowerFrameRateRange: .ambient,
        baseRenderScale: 0.75
    )

    public static let ambientScene = MotionBudget(
        workload: .ambientScene,
        frameRateRange: .ambient,
        lowPowerFrameRateRange: .lowPowerAmbient,
        baseRenderScale: 0.6
    )
}

public struct MotionRuntimeInputs: Equatable, Sendable {
    public let isExternallySuspended: Bool
    public let isSceneActive: Bool
    public let prefersReducedMotion: Bool
    public let prefersPowerSaving: Bool
    public let thermalPressure: MotionThermalPressure

    public init(
        isExternallySuspended: Bool = false,
        isSceneActive: Bool = true,
        prefersReducedMotion: Bool = false,
        prefersPowerSaving: Bool = false,
        thermalPressure: MotionThermalPressure = .nominal
    ) {
        self.isExternallySuspended = isExternallySuspended
        self.isSceneActive = isSceneActive
        self.prefersReducedMotion = prefersReducedMotion
        self.prefersPowerSaving = prefersPowerSaving
        self.thermalPressure = thermalPressure
    }
}

public struct MotionRuntimeDecision: Equatable, Sendable {
    public let isPaused: Bool
    public let frameRateRange: MotionFrameRateRange
    public let renderScale: Double
    public let quality: MotionQualityTier

    public init(
        isPaused: Bool,
        frameRateRange: MotionFrameRateRange,
        renderScale: Double,
        quality: MotionQualityTier
    ) {
        self.isPaused = isPaused
        self.frameRateRange = frameRateRange
        self.renderScale = renderScale.clamped(to: 0.35 ... 1)
        self.quality = quality
    }
}

public enum MotionRuntimePolicy {
    public static func resolve(
        budget: MotionBudget,
        inputs: MotionRuntimeInputs
    ) -> MotionRuntimeDecision {
        var frameRateRange = inputs.prefersPowerSaving
            ? budget.lowPowerFrameRateRange
            : budget.frameRateRange
        var renderScale = budget.baseRenderScale
        var quality = MotionQualityTier.full

        if inputs.prefersPowerSaving {
            renderScale *= 0.84
            quality.degrade(to: .efficient)
        }

        switch inputs.thermalPressure {
        case .nominal:
            break
        case .fair:
            frameRateRange = frameRateRange.capped(at: 45)
            renderScale *= 0.90
            quality.degrade(to: .balanced)
        case .serious:
            frameRateRange = frameRateRange.capped(at: 24)
            renderScale *= 0.72
            quality.degrade(to: .efficient)
        case .critical:
            frameRateRange = MotionFrameRateRange(
                minimum: 1,
                maximum: 1,
                preferred: 1
            )
            renderScale *= 0.55
            quality.degrade(to: .minimal)
        }

        let isPaused = inputs.isExternallySuspended
            || !inputs.isSceneActive
            || inputs.prefersReducedMotion
            || inputs.thermalPressure == .critical

        return MotionRuntimeDecision(
            isPaused: isPaused,
            frameRateRange: frameRateRange,
            renderScale: renderScale,
            quality: quality
        )
    }
}

extension MotionFrameRateRange {
    fileprivate func capped(at cap: Int) -> MotionFrameRateRange {
        let maximum = min(max(self.maximum, 1), max(cap, 1))
        return MotionFrameRateRange(
            minimum: min(minimum, maximum),
            maximum: maximum,
            preferred: min(preferred, maximum)
        )
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
