import ESMotion
import SwiftUI

struct WeatherMotionScene: MotionSceneDescriptor, Hashable {
    let kind: FarmWeatherSnapshot.VisualKind
    let baseRenderScale: CGFloat

    var id: String {
        "weather.\(kind.rawValue)"
    }

    var budget: MotionBudget {
        MotionBudget(
            workload: .foregroundScene,
            frameRateRange: MotionFrameRateRange(
                minimum: min(preferredFramesPerSecond, 30),
                maximum: preferredFramesPerSecond,
                preferred: preferredFramesPerSecond
            ),
            lowPowerFrameRateRange: .ambient,
            baseRenderScale: Double(baseRenderScale)
        )
    }

    private var preferredFramesPerSecond: Int {
        switch kind {
        case .rain, .snow, .storm, .wind, .dust, .freezingRain, .sleet, .hail,
             .blowingSnow, .sunRain, .sunSnow, .tropicalStorm, .blizzard:
            60
        case .clear, .partlyCloudy, .cloudy, .fog, .haze, .heat, .frigid, .smoke:
            30
        }
    }
}

struct MetalWeatherBackground: View {
    let kind: FarmWeatherSnapshot.VisualKind
    let intensity: Float
    let cloudCover: Float
    let wind: Float
    let isDaylight: Bool
    let isPaused: Bool
    let renderScale: CGFloat

    private var renderedKind: FarmWeatherSnapshot.VisualKind {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ESHEEP_WEATHER_DEBUG_KIND"]?.lowercased() {
        case "clear":
            return .clear
        case "partlycloudy", "partly-cloudy":
            return .partlyCloudy
        case "cloudy":
            return .cloudy
        case "rain":
            return .rain
        case "snow":
            return .snow
        case "storm":
            return .storm
        case "fog":
            return .fog
        case "haze":
            return .haze
        case "wind":
            return .wind
        case "dust":
            return .dust
        case "freezingrain", "freezing-rain":
            return .freezingRain
        case "sleet":
            return .sleet
        case "hail":
            return .hail
        case "blowingsnow", "blowing-snow":
            return .blowingSnow
        case "sunrain", "sun-rain":
            return .sunRain
        case "sunsnow", "sun-snow":
            return .sunSnow
        case "tropicalstorm", "tropical-storm":
            return .tropicalStorm
        case "heat":
            return .heat
        case "frigid":
            return .frigid
        case "smoke":
            return .smoke
        case "blizzard":
            return .blizzard
        default:
            break
        }
        #endif
        return kind
    }

    private var renderedDaylight: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ESHEEP_WEATHER_DEBUG_DAYLIGHT"] {
            return value != "0" && value.lowercased() != "false"
        }
        #endif
        return isDaylight
    }

    private var renderedIntensity: Float {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ESHEEP_WEATHER_DEBUG_INTENSITY"]?.lowercased() {
            switch value {
            case "none":
                return 0
            case "light":
                return 0.25
            case "moderate", "medium":
                return 0.50
            case "heavy":
                return 0.75
            case "extreme", "violent":
                return 1
            default:
                if let numericValue = Float(value) {
                    return min(max(numericValue, 0), 1)
                }
            }
        }
        #endif
        return min(max(intensity, 0), 1)
    }

    private var renderedCloudCover: Float {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ESHEEP_WEATHER_DEBUG_CLOUD"],
           let numericValue = Float(value) {
            return min(max(numericValue, 0), 1)
        }
        #endif
        return min(max(cloudCover, 0), 1)
    }

    private var renderedWind: Float {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ESHEEP_WEATHER_DEBUG_WIND"],
           let numericValue = Float(value) {
            return min(max(numericValue, 0), 1)
        }
        #endif
        return min(max(wind, 0), 1)
    }

    var body: some View {
        let scene = WeatherMotionScene(
            kind: renderedKind,
            baseRenderScale: renderScale
        )
        let kindValue = renderedKind.rawValue
        let daylightValue: Float = renderedDaylight ? 1 : 0
        let intensityValue = renderedIntensity
        let cloudCoverValue = renderedCloudCover
        let windValue = renderedWind

        ZStack {
            weatherFallback

            MotionTimelineView(
                scene: scene,
                isSuspended: isPaused
            ) { frame in
                MotionRenderSurface(renderScale: frame.renderScale) { renderSize in
                    Rectangle()
                        .fill(.white)
                        .colorEffect(
                            ShaderLibrary.farmWeatherBackground(
                                .float2(renderSize),
                                .float(Float(frame.wrappedTime)),
                                .float(kindValue),
                                .float(daylightValue),
                                .float(intensityValue),
                                .float(cloudCoverValue),
                                .float(windValue)
                            )
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var weatherFallback: some View {
        LinearGradient(
            colors: renderedDaylight
                ? [
                    Color(red: 0.19, green: 0.35, blue: 0.50),
                    Color(red: 0.08, green: 0.19, blue: 0.28),
                ]
                : [
                    Color(red: 0.035, green: 0.075, blue: 0.14),
                    Color(red: 0.015, green: 0.03, blue: 0.065),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
