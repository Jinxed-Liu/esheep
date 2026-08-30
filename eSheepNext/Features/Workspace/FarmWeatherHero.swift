import ESMotion
import OSLog
import SwiftUI

struct FarmWeatherHero: View {
    let farm: FarmRecord
    let syncSymbol: String
    let syncText: LocalizedStringKey
    @Binding var isDetailPresented: Bool

    @State private var weather: FarmWeatherSnapshot?
    @State private var prefetchedDetail: FarmWeatherDetailSnapshot?
    @State private var isLoading = false
    @State private var weatherError: String?
    @State private var isWeatherRendererReady = false
    @Namespace private var weatherTransition

    @ViewBuilder
    var body: some View {
        if farm.locationSnapshot != nil {
            Button {
                isDetailPresented = true
            } label: {
                weatherCard
                    .contentShape(.rect(cornerRadius: 28))
                    .motionTransitionSource(
                        id: MotionTransitionID(transitionID),
                        in: weatherTransition,
                        spec: weatherTransitionSpec
                    )
            }
            .buttonStyle(MotionSurfaceButtonStyle())
            .frame(maxWidth: .infinity)
            .navigationDestination(isPresented: $isDetailPresented) {
                FarmWeatherDetailView(
                    farm: farm,
                    initialWeather: weather,
                    initialDetail: prefetchedDetail
                )
                    .motionTransitionDestination(
                        id: MotionTransitionID(transitionID),
                        in: weatherTransition,
                        spec: weatherTransitionSpec
                    )
            }
        } else {
            weatherCard
        }
    }

    private var weatherCard: some View {
        ZStack {
            if isWeatherRendererReady {
                MetalWeatherBackground(
                    kind: weather?.visualKind ?? .clear,
                    intensity: weather?.visualIntensity.rawValue ?? 0,
                    cloudCover: weather?.visualCloudCover ?? 0,
                    wind: weather?.visualWind ?? 0,
                    isDaylight: weather?.isDaylight ?? true,
                    isPaused: isDetailPresented,
                    renderScale: 0.75
                )
            } else {
                launchFallback
            }

            readabilityGradient

            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 4)
                primaryWeather
                Spacer(minLength: 6)
                footer
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .leading)
        .clipShape(.rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.48), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .task(id: farm.locationUpdatedAt) {
            await loadWeather()
        }
        .task(id: farm.locationUpdatedAt) {
            await prefetchDetail()
        }
        .task(id: farm.id) {
            isWeatherRendererReady = false
            do {
                // Let navigation, tab layout, and the first home frame settle
                // before the first Metal shader pipeline is created.
                try await Task.sleep(for: .milliseconds(700))
                isWeatherRendererReady = true
            } catch {
                return
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(farm.locationSnapshot == nil ? [] : .isButton)
        .accessibilityHint(farm.locationSnapshot == nil ? "" : "打开完整天气")
    }

    private var transitionID: String {
        "farm-weather-\(farm.id.uuidString)"
    }

    private var weatherTransitionSpec: MotionTransitionSpec {
        MotionTransitionSpec(
            preset: .card,
            cornerRadius: 28
        )
    }

    private var readabilityGradient: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.24), .clear, .black.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.12)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var launchFallback: some View {
        LinearGradient(
            colors: (weather?.isDaylight ?? true)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                farmNameView
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                    locationNameView
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            }

            Spacer(minLength: 8)

            Label(LocalizedStringKey(farm.role.displayName), systemImage: "person.crop.circle.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
    }

    private var farmNameView: Text {
        Text(verbatim: farm.name)
    }

    private var locationNameView: Text {
        if let displayName = farm.locationSnapshot?.displayName {
            return Text(verbatim: displayName)
        }
        return Text("尚未设置牧场位置")
    }

    @ViewBuilder
    private var primaryWeather: some View {
        if let weather {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: -1) {
                    Text(LocalizedStringKey(weather.temperatureText))
                        .font(.system(size: 50, weight: .ultraLight, design: .rounded))
                        .tracking(-2)
                        .contentTransition(.numericText())
                    Text(LocalizedStringKey(weather.visualDescription))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.86))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("最高 / 最低")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                    Text(LocalizedStringKey(weather.highLowText))
                        .font(.subheadline.weight(.semibold))
                    Text("湿度 \(weather.humidityText) · \(weather.windSpeedText)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.74))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
        } else if isLoading {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("正在读取牧场天气")
                    .font(.subheadline)
            }
            .foregroundStyle(.white.opacity(0.86))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    farm.locationSnapshot == nil ? "设置牧场位置后显示实时天气" : "天气服务暂时不可用",
                    systemImage: farm.locationSnapshot == nil ? "location.slash.fill" : "exclamationmark.triangle.fill"
                )
                .font(.headline)
                #if DEBUG
                if let weatherError {
                    Text(LocalizedStringKey(weatherError))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
                #else
                Text("请稍后重试；牧场业务数据不受影响。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                #endif
            }
            .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: syncSymbol)
                .symbolRenderingMode(.hierarchical)
            Text(syncText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.80))
    }

    private func loadWeather() async {
        guard let location = farm.locationSnapshot else {
            weather = nil
            prefetchedDetail = nil
            weatherError = nil
            isLoading = false
            return
        }
        isLoading = true
        weatherError = nil
        defer { isLoading = false }
        do {
            let snapshot = try await FarmWeatherRepository.shared.currentWeather(for: farm.id, location: location)
            withAnimation(MotionAnimations.ambientChange) {
                weather = snapshot
            }
        } catch {
            weather = nil
            weatherError = error.localizedDescription
            Logger.weather.error("WeatherKit current request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prefetchDetail() async {
        prefetchedDetail = nil
        guard let location = farm.locationSnapshot else { return }
        do {
            try await Task.sleep(for: .seconds(2))
            let snapshot = try await FarmWeatherRepository.shared.detailedWeather(
                for: farm.id,
                location: location
            )
            guard !Task.isCancelled else { return }
            prefetchedDetail = snapshot
        } catch {
            Logger.weather.info("Weather detail prefetch deferred: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension Logger {
    static let weather = Logger(subsystem: Bundle.main.bundleIdentifier ?? "eSheepNext", category: "Weather")
}

extension FarmWeatherSnapshot.VisualKind {
    func displayName(intensity: FarmWeatherSnapshot.VisualIntensity) -> String {
        switch self {
        case .clear: "晴朗"
        case .partlyCloudy: "少云"
        case .cloudy: "多云"
        case .rain, .sunRain:
            switch intensity {
            case .none, .light: "小雨"
            case .moderate: "中雨"
            case .heavy: "大雨"
            case .extreme: "暴雨"
            }
        case .snow, .sunSnow:
            switch intensity {
            case .none, .light: "小雪"
            case .moderate: "中雪"
            case .heavy: "大雪"
            case .extreme: "暴雪"
            }
        case .storm:
            switch intensity {
            case .none, .light: "雷阵雨"
            case .moderate: "雷雨"
            case .heavy: "强雷雨"
            case .extreme: "强雷暴"
            }
        case .fog: "雾"
        case .haze: "霾"
        case .wind: "大风"
        case .dust: "扬沙"
        case .freezingRain: "冻雨"
        case .sleet: "雨夹雪"
        case .hail: "冰雹"
        case .blowingSnow: "风吹雪"
        case .tropicalStorm: "热带风暴"
        case .heat: "高温"
        case .frigid: "严寒"
        case .smoke: "烟霾"
        case .blizzard: "暴风雪"
        }
    }
}
