import ESMotionCore
import ESMotionRuntime
@preconcurrency import MetalKit
import SwiftUI

@MainActor
public struct MotionMetalParticleView: View {
    private let scene: MotionParticleScene
    private let isSuspended: Bool

    public init(
        scene: MotionParticleScene,
        isSuspended: Bool = false
    ) {
        self.scene = scene
        self.isSuspended = isSuspended
    }

    public var body: some View {
        MotionTimelineView(scene: scene, isSuspended: isSuspended) { frame in
            MotionMetalSurface(scene: scene, frame: frame)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#if os(iOS)
private struct MotionMetalSurface: UIViewRepresentable {
    let scene: MotionParticleScene
    let frame: MotionFrame

    func makeCoordinator() -> MotionParticleRenderer {
        MotionParticleRenderer(scene: scene)
    }

    func makeUIView(context: Context) -> MTKView {
        makeView(renderer: context.coordinator)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(scene: scene, frame: frame)
        view.contentScaleFactor = CGFloat(frame.renderScale)
        view.draw()
    }
}
#elseif os(macOS)
private struct MotionMetalSurface: NSViewRepresentable {
    let scene: MotionParticleScene
    let frame: MotionFrame

    func makeCoordinator() -> MotionParticleRenderer {
        MotionParticleRenderer(scene: scene)
    }

    func makeNSView(context: Context) -> MTKView {
        makeView(renderer: context.coordinator)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(scene: scene, frame: frame)
        view.layer?.contentsScale = CGFloat(frame.renderScale)
        view.draw()
    }
}
#endif

@MainActor
private func makeView(renderer: MotionParticleRenderer) -> MTKView {
    let view = MTKView(frame: .zero, device: renderer.device)
    view.delegate = renderer
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    view.framebufferOnly = true
    #if os(iOS)
    view.isOpaque = false
    #else
    view.wantsLayer = true
    view.layer?.isOpaque = false
    #endif
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.colorPixelFormat = .bgra8Unorm
    return view
}

private struct MotionParticleSeed {
    let x: Float
    let y: Float
    let speed: Float
    let drift: Float
    let size: Float
    let phase: Float
    let hue: Float
}

private struct MotionParticleVertex {
    var position: SIMD2<Float>
    var size: Float
    var color: SIMD4<Float>
}

@MainActor
private final class MotionParticleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer
    private var bufferCapacity: Int
    private var seeds: [MotionParticleSeed]
    private var scene: MotionParticleScene
    private var frame: MotionFrame?

    init(scene: MotionParticleScene) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            preconditionFailure("ESMotionMetal requires a Metal-capable device")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.scene = scene
        self.bufferCapacity = scene.particleCount
        self.seeds = Self.makeSeeds(count: scene.particleCount)

        guard let buffer = device.makeBuffer(
            length: max(scene.particleCount, 1)
                * MemoryLayout<MotionParticleVertex>.stride,
            options: .storageModeShared
        ) else {
            preconditionFailure("Unable to allocate ESMotion particle buffer")
        }
        vertexBuffer = buffer

        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let vertexFunction = library.makeFunction(
                name: "esmotionParticleVertex"
              ),
              let fragmentFunction = library.makeFunction(
                name: "esmotionParticleFragment"
              ) else {
            preconditionFailure("Unable to load ESMotion Metal shaders")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor =
            .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor =
            .oneMinusSourceAlpha

        do {
            pipeline = try device.makeRenderPipelineState(
                descriptor: descriptor
            )
        } catch {
            preconditionFailure(
                "Unable to build ESMotion particle pipeline: \(error)"
            )
        }
        super.init()
    }

    func update(scene: MotionParticleScene, frame: MotionFrame) {
        if scene.particleCount != self.scene.particleCount {
            resize(to: scene.particleCount)
        }
        self.scene = scene
        self.frame = frame
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {}

    func draw(in view: MTKView) {
        guard let frame,
              let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
              ) else {
            return
        }

        writeVertices(time: Float(frame.wrappedTime))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: scene.particleCount
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func resize(to particleCount: Int) {
        bufferCapacity = particleCount
        seeds = Self.makeSeeds(count: particleCount)
        guard let buffer = device.makeBuffer(
            length: max(bufferCapacity, 1)
                * MemoryLayout<MotionParticleVertex>.stride,
            options: .storageModeShared
        ) else {
            return
        }
        vertexBuffer = buffer
    }

    private func writeVertices(time: Float) {
        let pointer = vertexBuffer.contents().bindMemory(
            to: MotionParticleVertex.self,
            capacity: bufferCapacity
        )
        let intensity = Float(scene.intensity)

        for index in 0 ..< scene.particleCount {
            let seed = seeds[index]
            pointer[index] = vertex(
                for: seed,
                time: time,
                intensity: intensity
            )
        }
    }

    private func vertex(
        for seed: MotionParticleSeed,
        time: Float,
        intensity: Float
    ) -> MotionParticleVertex {
        let palette = scene.palette
        var position = SIMD2<Float>(seed.x, seed.y)
        var size = seed.size
        var color = SIMD4<Float>(
            palette.red,
            palette.green,
            palette.blue,
            palette.alpha
        )

        switch scene.preset {
        case .rain:
            let travel = fmod(
                seed.y + time * seed.speed * intensity,
                2.2
            )
            position.y = 1.1 - travel
            position.x += sin(time * 0.7 + seed.phase) * seed.drift
            size *= 0.72 + intensity * 0.24
        case .snow:
            let travel = fmod(
                seed.y + time * seed.speed * intensity * 0.42,
                2.2
            )
            position.y = 1.1 - travel
            position.x += sin(time * 0.9 + seed.phase) * seed.drift * 3
            size *= 1.2
        case .confetti:
            let travel = fmod(
                seed.y + time * seed.speed * intensity,
                2.3
            )
            position.y = 1.15 - travel
            position.x += sin(time * 1.8 + seed.phase) * seed.drift * 4
            color = Self.confettiColor(seed.hue)
        case .ambient:
            position.x += sin(time * 0.25 + seed.phase) * seed.drift * 2
            position.y += cos(time * 0.2 + seed.phase) * seed.drift
            color.w *= 0.7 + 0.3 * sin(time * 0.8 + seed.phase)
        }

        return MotionParticleVertex(
            position: position,
            size: max(size, 1),
            color: color
        )
    }

    private static func makeSeeds(count: Int) -> [MotionParticleSeed] {
        var generator = SplitMix64(seed: 0x45534D4F54494F4E)
        return (0 ..< count).map { _ in
            MotionParticleSeed(
                x: generator.nextFloat(in: -1 ... 1),
                y: generator.nextFloat(in: 0 ... 2.2),
                speed: generator.nextFloat(in: 0.12 ... 0.7),
                drift: generator.nextFloat(in: 0.008 ... 0.06),
                size: generator.nextFloat(in: 2 ... 8),
                phase: generator.nextFloat(in: 0 ... (2 * .pi)),
                hue: generator.nextFloat(in: 0 ... 1)
            )
        }
    }

    private static func confettiColor(_ hue: Float) -> SIMD4<Float> {
        let segment = Int(hue * 5) % 5
        return switch segment {
        case 0:
            SIMD4<Float>(1, 0.32, 0.36, 0.92)
        case 1:
            SIMD4<Float>(1, 0.76, 0.2, 0.92)
        case 2:
            SIMD4<Float>(0.22, 0.82, 0.58, 0.92)
        case 3:
            SIMD4<Float>(0.3, 0.62, 1, 0.92)
        default:
            SIMD4<Float>(0.74, 0.42, 1, 0.92)
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        let unit = Float(next() >> 40) / Float(1 << 24)
        return range.lowerBound
            + (range.upperBound - range.lowerBound) * unit
    }
}
