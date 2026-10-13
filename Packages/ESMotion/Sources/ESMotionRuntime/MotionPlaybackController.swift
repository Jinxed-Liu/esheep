// Modified for eSheep: deinitialization without the iOS 18.4 runtime. See README.md.
import ESMotionCore
import Foundation
import Observation

public enum MotionPlaybackStatus: Equatable, Sendable {
    case idle
    case playing
    case paused
    case completed
    case cancelled
}

@MainActor
@Observable
public final class MotionPlaybackController {
    public private(set) var status = MotionPlaybackStatus.idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var progress: Double = 0
    public private(set) var sampledValues: [String: Double] = [:]

    @ObservationIgnored private weak var engine: MotionEngine?
    @ObservationIgnored private var callbackID: UUID?
    @ObservationIgnored private var sequence: MotionSequence?
    @ObservationIgnored private var direction: Double = 1

    public init(engine: MotionEngine) {
        self.engine = engine
    }

    deinit {
        if let callbackID {
            Task { @MainActor [weak engine] in
                engine?.displayCoordinator.unregister(callbackID)
            }
        }
    }

    public func play(
        _ sequence: MotionSequence,
        from progress: Double = 0
    ) {
        self.sequence = sequence
        currentTime = min(max(progress, 0), 1) * sequence.duration
        direction = 1
        status = .playing
        registerIfNeeded()
        sample()
    }

    public func pause() {
        guard status == .playing else { return }
        status = .paused
    }

    public func resume() {
        guard sequence != nil else { return }
        status = .playing
        registerIfNeeded()
    }

    public func cancel() {
        status = .cancelled
        unregister()
    }

    public func reverse() {
        direction *= -1
        if status != .playing {
            status = .playing
            registerIfNeeded()
        }
    }

    public func seek(to progress: Double) {
        guard let sequence else { return }
        currentTime = min(max(progress, 0), 1) * sequence.duration
        sample()
    }

    private func registerIfNeeded() {
        guard callbackID == nil, let engine else { return }
        callbackID = engine.displayCoordinator.register(
            budget: .foregroundScene
        ) { [weak self] frame in
            self?.tick(deltaTime: frame.deltaTime)
        }
    }

    private func unregister() {
        guard let callbackID, let engine else { return }
        engine.displayCoordinator.unregister(callbackID)
        self.callbackID = nil
    }

    private func tick(deltaTime: TimeInterval) {
        guard status == .playing, let sequence else { return }
        guard sequence.duration > 0 else {
            status = .completed
            unregister()
            return
        }

        currentTime += deltaTime * direction

        switch sequence.loopMode {
        case .playOnce:
            if currentTime >= sequence.duration {
                currentTime = sequence.duration
                status = .completed
                unregister()
            } else if currentTime <= 0, direction < 0 {
                currentTime = 0
                status = .completed
                unregister()
            }
        case .loop:
            currentTime = currentTime
                .truncatingRemainder(dividingBy: sequence.duration)
            if currentTime < 0 {
                currentTime += sequence.duration
            }
        case .autoReverse:
            if currentTime >= sequence.duration {
                currentTime = sequence.duration
                direction = -1
            } else if currentTime <= 0 {
                currentTime = 0
                direction = 1
            }
        }

        sample()
    }

    private func sample() {
        guard let sequence else { return }
        progress = sequence.duration == 0
            ? 1
            : min(max(currentTime / sequence.duration, 0), 1)
        sampledValues = Dictionary(
            uniqueKeysWithValues: sequence.tracks.compactMap { track in
                MotionSequenceSampler.value(
                    in: track,
                    at: currentTime
                ).map { (track.keyPath, $0) }
            }
        )
    }
}
