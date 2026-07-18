import SwiftUI

struct FarmWeatherHero: View {
    let farm: FarmRecord
    let syncSymbol: String
    let syncText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var weather: FarmWeatherSnapshot?
    @State private var isLoading = false

    var body: some View {
        ZStack(alignment: .leading) {
            MetalWeatherBackground(
                kind: weather?.visualKind ?? .clear,
                isDaylight: weather?.isDaylight ?? true,
                isPaused: reduceMotion || scenePhase != .active
            )

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.34)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            content
                .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
        .clipShape(.rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .task(id: farm.locationUpdatedAt) {
            await loadWeather()
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(farm.name)
                        .font(.title2.bold())
                    Text("当前角色：\(farm.role.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer()
                weatherSummary
            }

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                Image(systemName: syncSymbol)
                Text(syncText)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.16), in: .rect(cornerRadius: 14))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
    }

    @ViewBuilder
    private var weatherSummary: some View {
        if let weather {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: weather.symbolName)
                        .symbolRenderingMode(.multicolor)
                    Text(weather.temperatureText)
                        .font(.title.bold())
                        .contentTransition(.numericText())
                }
                Text("湿度 \(weather.humidityText)")
                    .font(.caption)
                if let location = farm.locationSnapshot {
                    Text(location.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
            }
        } else if isLoading {
            ProgressView()
                .tint(.white)
        } else {
            Image(systemName: farm.locationSnapshot == nil ? "location.slash" : "cloud.sun")
                .font(.title2)
        }
    }

    private func loadWeather() async {
        guard let location = farm.locationSnapshot else {
            weather = nil
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        weather = try? await FarmWeatherRepository.shared.currentWeather(for: farm.id, location: location)
    }
}

private struct MetalWeatherBackground: View {
    let kind: FarmWeatherSnapshot.VisualKind
    let isDaylight: Bool
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
            Rectangle()
                .fill(.white)
                .visualEffect { content, proxy in
                    content.colorEffect(
                        ShaderLibrary.farmWeatherBackground(
                            .float2(proxy.size),
                            .float(isPaused ? 0 : timeline.date.timeIntervalSinceReferenceDate),
                            .float(kind.rawValue),
                            .float(isDaylight ? 1 : 0)
                        )
                    )
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
