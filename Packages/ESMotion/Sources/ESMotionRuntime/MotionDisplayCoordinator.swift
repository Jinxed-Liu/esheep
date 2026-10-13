// Modified for eSheep: deinitialization without the iOS 18.4 runtime. See README.md.
import ESMotionCore
import Foundation
import QuartzCore

#if os(iOS)
@MainActor
private final class MotionDisplayLinkTarget: NSObject {
    private let callback: @MainActor (CADisplayLink) -> Void

    init(callback: @escaping @MainActor (CADisplayLink) -> Void) {
        self.callback = callback
        super.init()
    }

    @objc
    func tick(_ displayLink: CADisplayLink) {
        callback(displayLink)
    }
}
#endif

@MainActor
private final class MotionDisplayDriver {
    #if os(iOS)
    var displayLink: CADisplayLink?
    #else
    var timer: Timer?
    #endif

    func invalidate() {
        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #else
        timer?.invalidate()
        timer = nil
        #endif
    }
}

@MainActor
public final class MotionDisplayCoordinator {
    public typealias Callback = @MainActor (MotionFrame) -> Void

    private struct Registration {
        var budget: MotionBudget
        var isSuspended: Bool
        var callback: Callback
    }

    public private(set) var activeBudget: MotionBudget?
    public private(set) var decision = MotionRuntimeDecision(
        isPaused: true,
        frameRateRange: .ambient,
        renderScale: 1,
        quality: .full
    )

    private let metricsStore: MotionMetricsStore
    private var registrations: [UUID: Registration] = [:]
    private var activeCallbacks: [Callback] = []
    private var pendingMetricSamples: [MotionMetricSample] = []
    private var runtimeInputs = MotionRuntimeInputs()
    private var previousTimestamp: TimeInterval?
    private var timeWrap: TimeInterval = 1_800

    private let driver = MotionDisplayDriver()

    public init(metricsStore: MotionMetricsStore = MotionMetricsStore()) {
        self.metricsStore = metricsStore
        pendingMetricSamples.reserveCapacity(30)
    }

    deinit {
        // A MainActor reference is Sendable; its platform objects stay on MainActor.
        Task { @MainActor [driver] in
            driver.invalidate()
        }
    }

    @discardableResult
    public func register(
        budget: MotionBudget,
        isSuspended: Bool = false,
        callback: @escaping Callback
    ) -> UUID {
        let id = UUID()
        registrations[id] = Registration(
            budget: budget,
            isSuspended: isSuspended,
            callback: callback
        )
        resolveActivePolicy()
        ensureDriver()
        return id
    }

    public func unregister(_ id: UUID) {
        registrations[id] = nil
        resolveActivePolicy()
        if registrations.isEmpty {
            activeBudget = nil
            stopDriver()
        }
    }

    public func updateRegistration(
        _ id: UUID,
        budget: MotionBudget? = nil,
        isSuspended: Bool? = nil
    ) {
        guard var registration = registrations[id] else { return }
        if let budget {
            registration.budget = budget
        }
        if let isSuspended {
            registration.isSuspended = isSuspended
        }
        registrations[id] = registration
        resolveActivePolicy()
    }

    public func updateRuntimeInputs(_ inputs: MotionRuntimeInputs) {
        runtimeInputs = inputs
        resolveActivePolicy()
    }

    public func apply(
        _ decision: MotionRuntimeDecision,
        timeWrap: TimeInterval
    ) {
        self.decision = decision
        self.timeWrap = max(timeWrap, 1)
        updateDriverPolicy()
    }

    public func removeAllCallbacks() {
        registrations.removeAll(keepingCapacity: true)
        activeBudget = nil
        stopDriver()
    }

    private func resolveActivePolicy() {
        let activeRegistrations = registrations.values.filter {
            !$0.isSuspended
        }
        activeCallbacks = activeRegistrations.map(\.callback)
        activeBudget = activeRegistrations
            .map(\.budget)
            .reduce(nil) { current, incoming in
                highestPriorityBudget(
                    current: current,
                    incoming: incoming
                )
            }

        guard let activeBudget else {
            decision = MotionRuntimeDecision(
                isPaused: true,
                frameRateRange: .ambient,
                renderScale: 1,
                quality: .minimal
            )
            updateDriverPolicy()
            return
        }

        timeWrap = activeBudget.timeWrap
        decision = MotionRuntimePolicy.resolve(
            budget: activeBudget,
            inputs: runtimeInputs
        )
        updateDriverPolicy()
    }

    private func highestPriorityBudget(
        current: MotionBudget?,
        incoming: MotionBudget
    ) -> MotionBudget {
        guard let current else { return incoming }
        return priority(of: incoming.workload) < priority(of: current.workload)
            ? incoming
            : current
    }

    private func priority(of workload: MotionWorkload) -> Int {
        switch workload {
        case .interaction:
            0
        case .foregroundScene:
            1
        case .ambientScene:
            2
        }
    }

    private func ensureDriver() {
        #if os(iOS)
        guard driver.displayLink == nil else { return }
        // CADisplayLink retains its target; the proxy avoids retaining this owner.
        let target = MotionDisplayLinkTarget { [weak self] displayLink in
            self?.displayLinkDidFire(displayLink)
        }
        let link = CADisplayLink(
            target: target,
            selector: #selector(MotionDisplayLinkTarget.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        driver.displayLink = link
        #else
        guard driver.timer == nil else { return }
        driver.timer = Timer.scheduledTimer(
            withTimeInterval: 1 / 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerDidFire()
            }
        }
        #endif
        updateDriverPolicy()
    }

    private func stopDriver() {
        driver.invalidate()
        previousTimestamp = nil
        flushMetrics()
    }

    private func updateDriverPolicy() {
        #if os(iOS)
        guard let displayLink = driver.displayLink else { return }
        let range = decision.frameRateRange
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(range.minimum),
            maximum: Float(range.maximum),
            preferred: Float(range.preferred)
        )
        displayLink.isPaused = decision.isPaused
            || registrations.values.allSatisfy(\.isSuspended)
        #else
        if decision.isPaused {
            driver.timer?.fireDate = .distantFuture
        } else {
            driver.timer?.fireDate = .now
        }
        #endif
    }

    #if os(iOS)
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        emitFrame(
            timestamp: displayLink.timestamp,
            targetTimestamp: displayLink.targetTimestamp
        )
    }
    #else
    private func timerDidFire() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let interval = 1 / Double(decision.frameRateRange.preferred)
        emitFrame(
            timestamp: timestamp,
            targetTimestamp: timestamp + interval
        )
    }
    #endif

    private func emitFrame(
        timestamp: TimeInterval,
        targetTimestamp: TimeInterval
    ) {
        guard !decision.isPaused, !activeCallbacks.isEmpty else {
            return
        }
        let delta = previousTimestamp.map { timestamp - $0 } ?? 0
        previousTimestamp = timestamp

        let frame = MotionFrame(
            timestamp: timestamp,
            targetTimestamp: targetTimestamp,
            deltaTime: delta,
            wrappedTime: timestamp.truncatingRemainder(dividingBy: timeWrap),
            renderScale: decision.renderScale,
            quality: decision.quality
        )
        for callback in activeCallbacks {
            callback(frame)
        }

        let sample = MotionMetricSample(
            timestamp: timestamp,
            frameInterval: delta,
            callbackCount: activeCallbacks.count,
            quality: decision.quality
        )
        pendingMetricSamples.append(sample)
        if pendingMetricSamples.count >= 30 {
            flushMetrics()
        }
    }

    private func flushMetrics() {
        guard !pendingMetricSamples.isEmpty else { return }
        let samples = pendingMetricSamples
        pendingMetricSamples.removeAll(keepingCapacity: true)
        Task {
            await metricsStore.append(contentsOf: samples)
        }
    }
}
