import ESMotionCore
import Foundation

public enum MotionParticlePreset:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable {
    case rain
    case snow
    case confetti
    case ambient
}

public struct MotionParticlePalette: Codable, Equatable, Hashable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float = 1
    ) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public static let rain = MotionParticlePalette(
        red: 0.52,
        green: 0.76,
        blue: 1,
        alpha: 0.72
    )
    public static let snow = MotionParticlePalette(
        red: 0.95,
        green: 0.98,
        blue: 1,
        alpha: 0.88
    )
    public static let ambient = MotionParticlePalette(
        red: 0.56,
        green: 0.86,
        blue: 0.76,
        alpha: 0.45
    )
}

public struct MotionParticleScene: MotionSceneDescriptor, Codable, Sendable {
    public var id: String
    public var preset: MotionParticlePreset
    public var particleCount: Int
    public var intensity: Double
    public var palette: MotionParticlePalette
    public var budget: MotionBudget

    public init(
        id: String,
        preset: MotionParticlePreset,
        particleCount: Int = 320,
        intensity: Double = 1,
        palette: MotionParticlePalette? = nil,
        budget: MotionBudget = .ambientScene
    ) {
        self.id = id
        self.preset = preset
        self.particleCount = min(max(particleCount, 1), 2_048)
        self.intensity = min(max(intensity, 0.05), 2)
        self.palette = palette ?? Self.defaultPalette(for: preset)
        self.budget = budget
    }

    private static func defaultPalette(
        for preset: MotionParticlePreset
    ) -> MotionParticlePalette {
        switch preset {
        case .rain:
            return .rain
        case .snow:
            return .snow
        case .confetti:
            return MotionParticlePalette(
                red: 1,
                green: 0.52,
                blue: 0.28,
                alpha: 0.9
            )
        case .ambient:
            return .ambient
        }
    }
}
