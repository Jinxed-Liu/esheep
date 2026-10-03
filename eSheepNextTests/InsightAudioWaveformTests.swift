import XCTest
@testable import eSheepNext

final class InsightAudioWaveformTests: XCTestCase {
    func testKnownTimelinePreservesLevelOrderAndLatestRecordingTime() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var timeline = InsightAudioWaveformTimeline()
        let levels: [Float] = [0, 0.2, 0.8, 0.3, 0]
        for (index, level) in levels.enumerated() {
            timeline.append(level: level, at: origin.addingTimeInterval(Double(index + 1) * 0.1))
        }

        XCTAssertEqual(timeline.samples, levels)
        XCTAssertEqual(timeline.sampleCount, 5)
        XCTAssertEqual(timeline.lastSampleAt, origin.addingTimeInterval(0.5))
        XCTAssertEqual(InsightAudioWaveformTimeline.sampleInterval, 0.1, accuracy: 0.000_001)
    }

    func testSilenceRemainsDistinctFromAnAudibleLevel() {
        let silence = InsightAudioWaveformTimeline.normalizedLevel(forDecibels: -60)
        let quiet = InsightAudioWaveformTimeline.normalizedLevel(forDecibels: -40)
        let speech = InsightAudioWaveformTimeline.normalizedLevel(forDecibels: -20)
        let loud = InsightAudioWaveformTimeline.normalizedLevel(forDecibels: -5)

        XCTAssertEqual(silence, 0)
        XCTAssertGreaterThan(quiet, silence)
        XCTAssertGreaterThan(speech, quiet)
        XCTAssertEqual(loud, 1)
        var timeline = InsightAudioWaveformTimeline()
        timeline.append(decibels: -60, at: Date(timeIntervalSince1970: 0.1))
        timeline.append(decibels: -20, at: Date(timeIntervalSince1970: 0.2))
        XCTAssertEqual(timeline.samples, [silence, speech])
    }

    func testInvalidMeterValuesCannotCreateNonFiniteWaveformGeometry() {
        var timeline = InsightAudioWaveformTimeline()
        for (index, level) in [Float.nan, .infinity, -.infinity, -1, 2].enumerated() {
            timeline.append(level: level, at: Date(timeIntervalSince1970: Double(index)))
        }

        XCTAssertTrue(timeline.samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertEqual(Array(timeline.samples.suffix(2)), [0, 1])
        XCTAssertEqual(timeline.sampleCount, 5)
    }

    func testCrossingTheRecentWindowKeepsOnlyLatestLevelsAndAbsoluteSampleCount() {
        var timeline = InsightAudioWaveformTimeline()
        let input = (0..<260).map { Float($0 % 10) / 10 }
        for (index, level) in input.enumerated() {
            timeline.append(level: level, at: Date(timeIntervalSince1970: Double(index + 1) * 0.1))
        }

        XCTAssertEqual(timeline.samples, Array(input.suffix(256)))
        XCTAssertEqual(timeline.samples.count, InsightAudioWaveformTimeline.maximumLiveSamples)
        XCTAssertEqual(timeline.sampleCount, 260, "Trimming old bars must not restart the recording's time position.")
        XCTAssertEqual(timeline.lastSampleAt, Date(timeIntervalSince1970: 26))
    }

    func testAnHourOfRecordingHasBoundedMemoryWithoutRemappingTheRecentPeak() {
        var timeline = InsightAudioWaveformTimeline()
        let sampleCount = 36_000
        let peakIndex = sampleCount - 20
        for index in 0..<sampleCount {
            timeline.append(level: index == peakIndex ? 1 : 0,
                            at: Date(timeIntervalSince1970: Double(index + 1) * 0.1))
        }
        XCTAssertEqual(timeline.samples.count, 256)
        XCTAssertEqual(timeline.sampleCount, sampleCount)
        XCTAssertEqual(timeline.lastSampleAt, Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(timeline.samples.firstIndex(of: 1), 236)

        for index in sampleCount..<(sampleCount + 10) {
            timeline.append(level: 0, at: Date(timeIntervalSince1970: Double(index + 1) * 0.1))
        }
        XCTAssertEqual(timeline.samples.count, 256)
        XCTAssertEqual(timeline.sampleCount, sampleCount + 10)
        XCTAssertEqual(timeline.samples.firstIndex(of: 1), 226,
                       "One elapsed second must move a retained peak left by ten bars, without stretching the history.")
    }

    func testResetClearsLiveTimeAndLevelsButDoesNotChangeAnAlreadyCapturedSnapshot() {
        var timeline = InsightAudioWaveformTimeline()
        timeline.append(level: 0.8, at: Date(timeIntervalSince1970: 0.1))
        timeline.append(level: 0, at: Date(timeIntervalSince1970: 0.2))
        let capturedLevels = timeline.samples
        let capturedCount = timeline.sampleCount
        timeline.reset()

        XCTAssertTrue(timeline.samples.isEmpty)
        XCTAssertEqual(timeline.sampleCount, 0)
        XCTAssertNil(timeline.lastSampleAt)
        XCTAssertEqual(capturedLevels, [0.8, 0])
        XCTAssertEqual(capturedCount, 2)
        timeline.append(level: 0.3, at: Date(timeIntervalSince1970: 100.1))
        XCTAssertEqual(timeline.samples, [0.3])
        XCTAssertEqual(timeline.sampleCount, 1)
        XCTAssertEqual(timeline.lastSampleAt, Date(timeIntervalSince1970: 100.1))
    }
}
