import ESMotion
import XCTest
@testable import eSheepNext

final class MotionEngineTests: XCTestCase {
    private let budget = MotionBudget(
        workload: .foregroundScene,
        frameRateRange: .foreground,
        lowPowerFrameRateRange: .ambient,
        baseRenderScale: 0.80
    )

    func testNominalRuntimePreservesRequestedQuality() {
        let runtime = MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: inputs()
        )

        XCTAssertFalse(runtime.isPaused)
        XCTAssertEqual(runtime.frameRateRange.preferred, 60)
        XCTAssertEqual(runtime.renderScale, 0.80, accuracy: 0.0001)
        XCTAssertEqual(runtime.quality, .full)
    }

    func testPowerSavingReducesCadenceAndInternalResolution() {
        let runtime = MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: inputs(prefersPowerSaving: true)
        )

        XCTAssertFalse(runtime.isPaused)
        XCTAssertEqual(runtime.frameRateRange.preferred, 30)
        XCTAssertEqual(runtime.renderScale, 0.672, accuracy: 0.0001)
        XCTAssertEqual(runtime.quality, .efficient)
    }

    func testSeriousThermalPressureProtectsInteractionBudget() {
        let runtime = MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: inputs(thermalPressure: .serious)
        )

        XCTAssertFalse(runtime.isPaused)
        XCTAssertEqual(runtime.frameRateRange.preferred, 24)
        XCTAssertEqual(runtime.renderScale, 0.576, accuracy: 0.0001)
        XCTAssertEqual(runtime.quality, .efficient)
    }

    func testCriticalThermalPressureAndReducedMotionPauseTimeline() {
        let critical = MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: inputs(thermalPressure: .critical)
        )
        let reducedMotion = MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: inputs(prefersReducedMotion: true)
        )

        XCTAssertTrue(critical.isPaused)
        XCTAssertEqual(critical.frameRateRange.preferred, 1)
        XCTAssertEqual(critical.quality, .minimal)
        XCTAssertTrue(reducedMotion.isPaused)
    }

    func testClockWrapsBeforeConvertingToFloat() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_012.375)
        let expected = Float(
            date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1_800)
        )

        XCTAssertEqual(
            Float(MotionClock.wrappedTime(for: date, wrap: 1_800)),
            expected
        )
    }

    func testWeatherSceneSelectsCadenceByMotionDemand() {
        let storm = WeatherMotionScene(kind: .storm, baseRenderScale: 0.5)
        let fog = WeatherMotionScene(kind: .fog, baseRenderScale: 0.5)

        XCTAssertEqual(
            storm.budget.frameRateRange.preferred,
            60
        )
        XCTAssertEqual(
            fog.budget.frameRateRange.preferred,
            30
        )
    }

    private func inputs(
        prefersReducedMotion: Bool = false,
        prefersPowerSaving: Bool = false,
        thermalPressure: MotionThermalPressure = .nominal
    ) -> MotionRuntimeInputs {
        MotionRuntimeInputs(
            isSceneActive: true,
            prefersReducedMotion: prefersReducedMotion,
            prefersPowerSaving: prefersPowerSaving,
            thermalPressure: thermalPressure
        )
    }
}
