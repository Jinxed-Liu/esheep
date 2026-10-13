import ESMotionCore
import Foundation

public struct MotionDocumentVersion: Codable, Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = max(major, 0)
        self.minor = max(minor, 0)
    }

    public static let current = MotionDocumentVersion(major: 0, minor: 1)

    public static func < (
        lhs: MotionDocumentVersion,
        rhs: MotionDocumentVersion
    ) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public struct MotionCanvas: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var frameRate: Double
    public var backgroundColor: String

    public init(
        width: Double = 390,
        height: Double = 844,
        frameRate: Double = 60,
        backgroundColor: String = "#00000000"
    ) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.frameRate = max(frameRate, 1)
        self.backgroundColor = backgroundColor
    }
}

public enum MotionAssetKind: String, Codable, CaseIterable, Sendable {
    case lottie
    case image
    case symbol
    case text
    case metalScene
    case composition
}

public struct MotionAssetDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: MotionAssetKind
    public var relativePath: String?
    public var metadata: [String: String]
    public var sha256: String?

    public init(
        id: String,
        kind: MotionAssetKind,
        relativePath: String? = nil,
        metadata: [String: String] = [:],
        sha256: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.metadata = metadata
        self.sha256 = sha256
    }
}

public struct MotionPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MotionTransform: Codable, Equatable, Sendable {
    public var position: MotionPoint
    public var anchor: MotionPoint
    public var scale: MotionPoint
    public var rotation: Double
    public var opacity: Double

    public init(
        position: MotionPoint = MotionPoint(x: 0, y: 0),
        anchor: MotionPoint = MotionPoint(x: 0.5, y: 0.5),
        scale: MotionPoint = MotionPoint(x: 1, y: 1),
        rotation: Double = 0,
        opacity: Double = 1
    ) {
        self.position = position
        self.anchor = anchor
        self.scale = scale
        self.rotation = rotation
        self.opacity = min(max(opacity, 0), 1)
    }
}

public enum MotionLayerKind: String, Codable, CaseIterable, Sendable {
    case shape
    case text
    case image
    case lottie
    case precomposition
    case particle
}

public struct MotionLayer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: MotionLayerKind
    public var assetID: String?
    public var transform: MotionTransform
    public var isHidden: Bool
    public var children: [MotionLayer]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: MotionLayerKind,
        assetID: String? = nil,
        transform: MotionTransform = MotionTransform(),
        isHidden: Bool = false,
        children: [MotionLayer] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.assetID = assetID
        self.transform = transform
        self.isHidden = isHidden
        self.children = children
    }
}

public struct MotionState: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var sequenceIDs: [UUID]

    public init(id: String, name: String, sequenceIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.sequenceIDs = sequenceIDs
    }
}

public struct MotionAccessibilityFallback: Codable, Equatable, Sendable {
    public var staticStateID: String?
    public var sequenceID: UUID?
    public var disablesParallax: Bool
    public var disablesHaptics: Bool

    public init(
        staticStateID: String? = nil,
        sequenceID: UUID? = nil,
        disablesParallax: Bool = true,
        disablesHaptics: Bool = false
    ) {
        self.staticStateID = staticStateID
        self.sequenceID = sequenceID
        self.disablesParallax = disablesParallax
        self.disablesHaptics = disablesHaptics
    }
}

public struct MotionDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var version: MotionDocumentVersion
    public var name: String
    public var canvas: MotionCanvas
    public var assets: [MotionAssetDescriptor]
    public var layers: [MotionLayer]
    public var states: [MotionState]
    public var sequences: [MotionSequence]
    public var reducedMotion: MotionAccessibilityFallback

    public init(
        id: UUID = UUID(),
        version: MotionDocumentVersion = .current,
        name: String,
        canvas: MotionCanvas = MotionCanvas(),
        assets: [MotionAssetDescriptor] = [],
        layers: [MotionLayer] = [],
        states: [MotionState] = [],
        sequences: [MotionSequence] = [],
        reducedMotion: MotionAccessibilityFallback = MotionAccessibilityFallback()
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.canvas = canvas
        self.assets = assets
        self.layers = layers
        self.states = states
        self.sequences = sequences
        self.reducedMotion = reducedMotion
    }
}
