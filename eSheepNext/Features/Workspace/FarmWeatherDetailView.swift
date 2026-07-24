import Charts
import ESMotion
import SwiftUI

struct FarmWeatherDetailView: View {
    let farm: FarmRecord
    let initialWeather: FarmWeatherSnapshot?

    @State private var detail: FarmWeatherDetailSnapshot?
    @State private var loadError: String?
    @State private var selectedChartMetric: WeatherChartMetric = .temperature

    init(
        farm: FarmRecord,
        initialWeather: FarmWeatherSnapshot?,
        initialDetail: FarmWeatherDetailSnapshot? = nil
    ) {
        self.farm = farm
        self.initialWeather = initialWeather
        _detail = State(initialValue: initialDetail)
    }

    var body: some View {
        MotionActivationGate(
            plan: MotionActivationPlan(
                contentDelay: .zero,
                motionDelay: .milliseconds(250)
            )
        ) { activation in
            weatherContent(activation: activation)
        }
    }

    private func weatherContent(activation: MotionActivationPhase) -> some View {
        ZStack {
            MetalWeatherBackground(
                kind: currentWeather?.visualKind ?? .clear,
                intensity: currentWeather?.visualIntensity.rawValue ?? 0,
                cloudCover: currentWeather?.visualCloudCover ?? 0,
                wind: currentWeather?.visualWind ?? 0,
                isDaylight: currentWeather?.isDaylight ?? true,
                isPaused: !activation.playsContinuousMotion,
                renderScale: 0.50
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.16), .clear, .black.opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                GlassEffectContainer(spacing: 12) {
                    LazyVStack(spacing: 18) {
                        topBar
                        currentSummary

                        if let detail {
                            if !detail.alerts.isEmpty {
                                alertsSection(detail.alerts)
                            }
                            hourlySection(detail.hourly)
                            chartsSection(detail.hourly)
                            dailySection(title: "未来 7 天", subtitle: "天气预报", days: detail.forecast)
                            windSection(detail.current)
                            celestialSection(detail.current)
                            conditionsSection(detail.current)
                            dailySection(title: "过去 7 天", subtitle: "历史实况", days: detail.history)
                            attribution(for: detail.current.source)
                        } else if let loadError {
                            errorCard(loadError)
                        } else {
                            loadingCard
                        }
                    }
                }
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, 8)
                .safeAreaPadding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .background(AppTheme.pageBackground)
        .task(id: farm.locationUpdatedAt) {
            await loadDetail()
        }
    }

    private var currentWeather: FarmWeatherSnapshot? {
        detail?.current ?? initialWeather
    }

    private var topBar: some View {
        VStack(spacing: 2) {
            Text(farm.name)
                .font(.headline)
                .lineLimit(1)
            Text(farm.locationSnapshot?.displayName ?? "牧场天气")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var currentSummary: some View {
        if let weather = currentWeather {
            VStack(spacing: 5) {
                Text(weather.temperatureText)
                    .font(.system(size: 76, weight: .ultraLight, design: .rounded))
                    .tracking(-4)
                    .contentTransition(.numericText())
                Text(weather.visualDescription)
                    .font(.title3.weight(.medium))
                Text("体感 \(weather.apparentTemperatureText)  ·  最高/最低 \(weather.highLowText)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.80))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        }
    }

    private func hourlySection(_ hours: [FarmHourlyWeather]) -> some View {
        WeatherGlassSection(title: "未来 24 小时", symbol: "clock") {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(hours) { hour in
                        VStack(spacing: 8) {
                            Text(hour.date, format: .dateTime.hour())
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                            Image(systemName: hour.symbolName)
                                .symbolRenderingMode(.multicolor)
                                .font(.title3)
                                .frame(height: 28)
                            Text(hour.temperatureText)
                                .font(.subheadline.weight(.semibold))
                            if hour.precipitationChanceText != "0%" {
                                Text(hour.precipitationChanceText)
                                    .font(.caption2)
                                    .foregroundStyle(.cyan.opacity(0.90))
                            } else {
                                Text(" ").font(.caption2)
                            }
                        }
                        .frame(width: 52)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func alertsSection(_ alerts: [FarmWeatherAlert]) -> some View {
        WeatherGlassSection(title: "天气预警", symbol: "exclamationmark.triangle.fill") {
            VStack(spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.14))
                    }
                    Link(destination: alert.detailsURL) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: alert.severity.symbolName)
                                .font(.title3)
                                .foregroundStyle(alert.severity.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(alert.severity.title)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(alert.severity.tint)
                                    if let region = alert.region, !region.isEmpty {
                                        Text(region)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.58))
                                            .lineLimit(1)
                                    }
                                }
                                Text(alert.summary)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                Text("发布：\(alert.source)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.54))
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.46))
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chartsSection(_ hours: [FarmHourlyWeather]) -> some View {
        WeatherGlassSection(
            title: "24 小时趋势",
            symbol: "chart.xyaxis.line",
            headerAccessory: { chartMetricSelector }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                chartTitle(
                    selectedChartMetric.title,
                    value: selectedChartMetric.summary(in: hours),
                    symbol: selectedChartMetric.symbolName
                )

                selectedChart(hours)
                    .frame(height: 145)
                    .id(selectedChartMetric)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .animation(.easeInOut(duration: 0.20), value: selectedChartMetric)
        }
    }

    private var chartMetricSelector: some View {
        Picker("24 小时趋势指标", selection: $selectedChartMetric) {
            ForEach(WeatherChartMetric.allCases) { metric in
                Text(metric.title)
                    .tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 174)
        .labelsHidden()
    }

    @ViewBuilder
    private func selectedChart(_ hours: [FarmHourlyWeather]) -> some View {
        switch selectedChartMetric {
        case .temperature:
            Chart(hours) { hour in
                AreaMark(
                    x: .value("时间", hour.date),
                    y: .value("温度", hour.temperatureValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow.opacity(0.34), .yellow.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("时间", hour.date),
                    y: .value("温度", hour.temperatureValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.yellow)
                .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .chartXAxis { weatherTimeAxis }
            .chartYAxis(.hidden)

        case .precipitation:
            Chart(hours) { hour in
                BarMark(
                    x: .value("时间", hour.date),
                    y: .value("降水概率", hour.precipitationChanceValue * 100)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .blue.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(3)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { weatherTimeAxis }
            .chartYAxis(.hidden)

        case .wind:
            Chart(hours) { hour in
                AreaMark(
                    x: .value("时间", hour.date),
                    y: .value("风速", hour.windSpeedValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.mint.opacity(0.30), .mint.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("时间", hour.date),
                    y: .value("风速", hour.windSpeedValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.mint)
                .lineStyle(.init(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            }
            .chartXAxis { weatherTimeAxis }
            .chartYAxis(.hidden)
        }
    }

    private var weatherTimeAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
            AxisGridLine()
                .foregroundStyle(.white.opacity(0.10))
            AxisTick()
                .foregroundStyle(.white.opacity(0.22))
            AxisValueLabel(format: .dateTime.hour())
                .foregroundStyle(.white.opacity(0.54))
        }
    }

    private func chartTitle(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.60))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.66))
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func dailySection(title: String, subtitle: String, days: [FarmDailyWeather]) -> some View {
        WeatherGlassSection(title: title, symbol: title.contains("过去") ? "clock.arrow.circlepath" : "calendar") {
            VStack(spacing: 0) {
                HStack {
                    Text(subtitle)
                    Spacer()
                    Text("降水 · 低温 / 高温")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
                .padding(.bottom, 8)

                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.12))
                    }
                    HStack(spacing: 10) {
                        Text(day.date, format: .dateTime.weekday(.abbreviated).month().day())
                            .font(.subheadline.weight(.medium))
                            .frame(width: 84, alignment: .leading)
                        Image(systemName: day.symbolName)
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 28)
                        Text(day.precipitationChanceText)
                            .font(.caption)
                            .foregroundStyle(.cyan.opacity(0.90))
                            .frame(width: 38, alignment: .trailing)
                        Spacer(minLength: 4)
                        Text(day.lowTemperatureText)
                            .foregroundStyle(.white.opacity(0.62))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.cyan, .yellow, .orange],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 52, height: 4)
                        Text(day.highTemperatureText)
                    }
                    .font(.subheadline)
                    .frame(minHeight: 54)
                }
            }
        }
    }

    private func conditionsSection(_ weather: FarmWeatherSnapshot) -> some View {
        WeatherGlassSection(title: "当前状况", symbol: "gauge.with.dots.needle.bottom.50percent") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ConditionMetric(title: "湿度", value: weather.humidityText, symbol: "humidity.fill")
                ConditionMetric(title: "气压", value: weather.pressureText, symbol: "barometer")
                ConditionMetric(title: "能见度", value: weather.visibilityText, symbol: "eye.fill")
                ConditionMetric(title: "紫外线", value: weather.uvIndexText, symbol: "sun.max.fill")
            }
        }
    }

    private func windSection(_ weather: FarmWeatherSnapshot) -> some View {
        WeatherGlassSection(title: "风", symbol: "wind") {
            HStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(index.isMultiple(of: 2) ? 0.50 : 0.24))
                            .frame(width: 2, height: index.isMultiple(of: 2) ? 7 : 4)
                            .offset(y: -42)
                            .rotationEffect(.degrees(Double(index) * 45))
                    }
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.mint)
                        .rotationEffect(.degrees(weather.windDirectionDegrees))
                        .shadow(color: .mint.opacity(0.38), radius: 8)
                }
                .frame(width: 94, height: 94)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weather.windDirectionText)
                            .font(.title2.weight(.semibold))
                        Text("当前风向")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.54))
                    }
                    HStack(spacing: 22) {
                        windValue(title: "持续风速", value: weather.windSpeedText)
                        windValue(title: "阵风", value: weather.windGustText)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func windValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.54))
        }
    }

    private func celestialSection(_ weather: FarmWeatherSnapshot) -> some View {
        WeatherGlassSection(title: "日月", symbol: "sun.and.horizon.fill") {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "sun.max.fill")
                        .font(.title)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 38)
                    celestialTimes(
                        title: "日升日落",
                        primaryLabel: "日出",
                        primaryValue: weather.sunriseText,
                        secondaryLabel: "日落",
                        secondaryValue: weather.sunsetText
                    )
                }

                Divider().overlay(.white.opacity(0.14))

                HStack(spacing: 14) {
                    Image(systemName: weather.moonPhaseSymbol)
                        .font(.title)
                        .foregroundStyle(.indigo.opacity(0.92), .white)
                        .frame(width: 38)
                    celestialTimes(
                        title: weather.moonPhaseText,
                        primaryLabel: "月出",
                        primaryValue: weather.moonriseText,
                        secondaryLabel: "月落",
                        secondaryValue: weather.moonsetText
                    )
                }
            }
        }
    }

    private func celestialTimes(
        title: String,
        primaryLabel: String,
        primaryValue: String,
        secondaryLabel: String,
        secondaryValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 18) {
                Text("\(primaryLabel) \(primaryValue)")
                Text("\(secondaryLabel) \(secondaryValue)")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.66))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attribution(for source: FarmWeatherDataSource) -> some View {
        let destination = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
        return Link(destination: destination) {
            HStack(spacing: 5) {
                Image(systemName: "apple.logo")
                Text("Apple Weather · 数据来源与法律归属")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var loadingCard: some View {
        WeatherGlassSection(title: "正在载入", symbol: "arrow.triangle.2.circlepath") {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func errorCard(_ message: String) -> some View {
        WeatherGlassSection(title: "天气暂时不可用", symbol: "exclamationmark.triangle") {
            VStack(spacing: 12) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                Button("重新载入") {
                    Task { await loadDetail() }
                }
                .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadDetail() async {
        guard let location = farm.locationSnapshot else {
            loadError = "请先设置牧场固定位置。"
            return
        }
        loadError = nil
        do {
            detail = try await FarmWeatherRepository.shared.detailedWeather(for: farm.id, location: location)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private enum WeatherChartMetric: String, CaseIterable, Identifiable {
    case temperature
    case precipitation
    case wind

    var id: Self { self }

    var title: String {
        switch self {
        case .temperature: "温度"
        case .precipitation: "降水"
        case .wind: "风速"
        }
    }

    var symbolName: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .precipitation: "drop.fill"
        case .wind: "wind"
        }
    }

    var tint: Color {
        switch self {
        case .temperature: .yellow
        case .precipitation: .cyan
        case .wind: .mint
        }
    }

    func summary(in hours: [FarmHourlyWeather]) -> String {
        guard !hours.isEmpty else { return "—" }
        switch self {
        case .temperature:
            let values = hours.map(\.temperatureValue)
            guard let minimum = values.min(), let maximum = values.max() else { return "—" }
            return "\(Int(minimum.rounded()))° – \(Int(maximum.rounded()))°"
        case .precipitation:
            return hours.map(\.precipitationChanceValue).max()?.formatted(
                .percent.precision(.fractionLength(0))
            ) ?? "—"
        case .wind:
            guard let maximum = hours.map(\.windSpeedValue).max() else { return "—" }
            return "最高 \(Int(maximum.rounded())) km/h"
        }
    }
}

private struct WeatherGlassSection<Content: View, HeaderAccessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let headerAccessory: HeaderAccessory
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) where HeaderAccessory == EmptyView {
        self.title = title
        self.symbol = symbol
        self.headerAccessory = EmptyView()
        self.content = content()
    }

    init(
        title: String,
        symbol: String,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))

                Spacer(minLength: 0)

                headerAccessory
            }
            content
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .black.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .glassEffect(.clear, in: .rect(cornerRadius: 22))
    }
}

private struct ConditionMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

private extension FarmWeatherAlert.Severity {
    var title: String {
        switch self {
        case .minor: "一般预警"
        case .moderate: "较重预警"
        case .severe: "严重预警"
        case .extreme: "极端预警"
        case .unknown: "天气预警"
        }
    }

    var symbolName: String {
        switch self {
        case .minor: "exclamationmark.circle.fill"
        case .moderate: "exclamationmark.triangle.fill"
        case .severe, .extreme: "exclamationmark.octagon.fill"
        case .unknown: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .minor: .yellow
        case .moderate: .orange
        case .severe: .red
        case .extreme: .purple
        case .unknown: .orange
        }
    }
}
