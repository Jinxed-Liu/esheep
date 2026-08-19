import CoreLocation
import MapKit
import OSLog
import SwiftData
import SwiftUI
import WeatherKit

enum FarmWeatherDataSource: Sendable, Equatable {
    case appleWeather
}

struct FarmWeatherAlert: Identifiable, Sendable, Equatable {
    enum Severity: Sendable, Equatable {
        case minor
        case moderate
        case severe
        case extreme
        case unknown
    }

    let id: String
    let summary: String
    let region: String?
    let source: String
    let severity: Severity
    let detailsURL: URL
}

struct FarmWeatherSnapshot: Sendable, Equatable {
    enum VisualKind: Float, Sendable {
        case clear = 0
        case partlyCloudy = 1
        case cloudy = 2
        case rain = 3
        case snow = 4
        case storm = 5
        case fog = 6
        case haze = 7
        case wind = 8
        case dust = 9
        case freezingRain = 10
        case sleet = 11
        case hail = 12
        case blowingSnow = 13
        case sunRain = 14
        case sunSnow = 15
        case tropicalStorm = 16
        case heat = 17
        case frigid = 18
        case smoke = 19
        case blizzard = 20

        init(condition: WeatherCondition) {
            switch condition {
            case .clear:
                self = .clear
            case .mostlyClear, .partlyCloudy:
                self = .partlyCloudy
            case .cloudy, .mostlyCloudy:
                self = .cloudy
            case .drizzle, .rain, .heavyRain:
                self = .rain
            case .flurries, .snow, .heavySnow:
                self = .snow
            case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms:
                self = .storm
            case .foggy:
                self = .fog
            case .haze:
                self = .haze
            case .breezy, .windy:
                self = .wind
            case .blowingDust:
                self = .dust
            case .freezingDrizzle, .freezingRain:
                self = .freezingRain
            case .sleet, .wintryMix:
                self = .sleet
            case .hail:
                self = .hail
            case .blowingSnow:
                self = .blowingSnow
            case .sunShowers:
                self = .sunRain
            case .sunFlurries:
                self = .sunSnow
            case .hurricane, .tropicalStorm:
                self = .tropicalStorm
            case .hot:
                self = .heat
            case .frigid:
                self = .frigid
            case .smoky:
                self = .smoke
            case .blizzard:
                self = .blizzard
            @unknown default:
                self = .cloudy
            }
        }
    }

    enum VisualIntensity: Float, Sendable {
        case none = 0
        case light = 0.25
        case moderate = 0.50
        case heavy = 0.75
        case extreme = 1.0

        init(condition: WeatherCondition, precipitationMillimetersPerHour: Double) {
            let measuredLevel: Self? = if precipitationMillimetersPerHour > 0.05 {
                if precipitationMillimetersPerHour < 2.5 {
                    .light
                } else if precipitationMillimetersPerHour < 7.6 {
                    .moderate
                } else if precipitationMillimetersPerHour < 50 {
                    .heavy
                } else {
                    .extreme
                }
            } else {
                nil
            }

            switch condition {
            case .drizzle, .freezingDrizzle, .flurries:
                self = measuredLevel ?? .light
            case .rain, .snow, .sleet, .wintryMix, .freezingRain:
                self = measuredLevel ?? .moderate
            case .heavyRain, .heavySnow:
                let measured = measuredLevel ?? .heavy
                self = measured.rawValue >= Self.heavy.rawValue ? measured : .heavy
            case .isolatedThunderstorms:
                self = measuredLevel ?? .light
            case .scatteredThunderstorms, .thunderstorms:
                self = measuredLevel ?? .heavy
            case .strongStorms, .blizzard, .hurricane, .tropicalStorm:
                self = .extreme
            case .blowingSnow, .hail, .windy, .blowingDust:
                self = .heavy
            case .breezy, .sunFlurries, .sunShowers:
                self = measuredLevel ?? .light
            case .clear, .cloudy, .foggy, .frigid, .haze, .hot, .mostlyClear,
                 .mostlyCloudy, .partlyCloudy, .smoky:
                self = .none
            @unknown default:
                self = .moderate
            }
        }
    }

    let source: FarmWeatherDataSource
    let symbolName: String
    let temperatureText: String
    let humidityText: String
    let windSpeedText: String
    let windDirectionText: String
    let windDirectionDegrees: Double
    let windGustText: String
    let highLowText: String
    let apparentTemperatureText: String
    let pressureText: String
    let visibilityText: String
    let uvIndexText: String
    let sunriseText: String
    let sunsetText: String
    let moonPhaseText: String
    let moonPhaseSymbol: String
    let moonriseText: String
    let moonsetText: String
    let visualKind: VisualKind
    let visualIntensity: VisualIntensity
    let visualCloudCover: Float
    let visualWind: Float
    let isDaylight: Bool
    let observedAt: Date

    var visualDescription: String {
        visualKind.displayName(intensity: visualIntensity)
    }
}

struct FarmHourlyWeather: Identifiable, Sendable, Equatable {
    let date: Date
    let symbolName: String
    let temperatureText: String
    let precipitationChanceText: String
    let temperatureValue: Double
    let precipitationChanceValue: Double
    let windSpeedText: String
    let windSpeedValue: Double

    var id: Date { date }
}

struct FarmDailyWeather: Identifiable, Sendable, Equatable {
    let date: Date
    let symbolName: String
    let highTemperatureText: String
    let lowTemperatureText: String
    let precipitationChanceText: String
    let windSpeedText: String

    var id: Date { date }
}

struct FarmWeatherDetailSnapshot: Sendable, Equatable {
    let current: FarmWeatherSnapshot
    let hourly: [FarmHourlyWeather]
    let history: [FarmDailyWeather]
    let forecast: [FarmDailyWeather]
    let alerts: [FarmWeatherAlert]
}

actor FarmWeatherRepository {
    static let shared = FarmWeatherRepository()

    private enum RepositoryError: LocalizedError {
        case weatherKitFailed(String)

        var errorDescription: String? {
            switch self {
            case .weatherKitFailed(let reason):
                "WeatherKit：\(reason)"
            }
        }
    }

    private struct CacheEntry {
        let snapshot: FarmWeatherSnapshot
        let locationUpdatedAt: Date
    }

    private var cache: [UUID: CacheEntry] = [:]

    private struct DetailCacheEntry {
        let snapshot: FarmWeatherDetailSnapshot
        let locationUpdatedAt: Date
        let fetchedAt: Date
    }

    private struct DetailRequest {
        let id: UUID
        let locationUpdatedAt: Date
        let task: Task<FarmWeatherDetailSnapshot, Error>
    }

    private var detailCache: [UUID: DetailCacheEntry] = [:]
    private var detailRequests: [UUID: DetailRequest] = [:]

    func currentWeather(for farmID: UUID, location: FarmLocationSnapshot) async throws -> FarmWeatherSnapshot {
        if let cached = cache[farmID],
           cached.locationUpdatedAt == location.updatedAt,
           cached.snapshot.observedAt.addingTimeInterval(15 * 60) > .now {
            return cached.snapshot
        }

        do {
            let snapshot = try await appleCurrentWeather(for: location)
            cache[farmID] = CacheEntry(snapshot: snapshot, locationUpdatedAt: location.updatedAt)
            return snapshot
        } catch {
            let weatherKitFailure = Self.diagnosticDescription(for: error)
            Self.logger.error("WeatherKit current request failed: \(weatherKitFailure, privacy: .public)")
            #if DEBUG
            print("[WeatherKit][current] \(weatherKitFailure)")
            #endif
            throw RepositoryError.weatherKitFailed(weatherKitFailure)
        }
    }

    private func appleCurrentWeather(for location: FarmLocationSnapshot) async throws -> FarmWeatherSnapshot {
        let weather = try await WeatherService.shared.weather(for: CLLocation(
            latitude: location.latitude,
            longitude: location.longitude
        ))
        return Self.currentSnapshot(from: weather, location: location)
    }

    private static func currentSnapshot(
        from weather: WeatherKit.Weather,
        location: FarmLocationSnapshot
    ) -> FarmWeatherSnapshot {
        let current = weather.currentWeather
        let today = weather.dailyForecast.forecast.first
        let precipitationMillimetersPerHour = current.precipitationIntensity
            .converted(to: Self.millimetersPerHour)
            .value
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = TimeZone(identifier: location.timeZoneIdentifier) ?? .current
        return FarmWeatherSnapshot(
            source: .appleWeather,
            symbolName: current.symbolName,
            temperatureText: Self.temperatureText(current.temperature),
            humidityText: current.humidity.formatted(.percent.precision(.fractionLength(0))),
            windSpeedText: current.wind.speed.formatted(.measurement(width: .abbreviated)),
            windDirectionText: current.wind.compassDirection.description,
            windDirectionDegrees: current.wind.direction.converted(to: .degrees).value,
            windGustText: current.wind.gust?.formatted(.measurement(width: .abbreviated)) ?? "—",
            highLowText: today.map {
                "\(Self.temperatureText($0.highTemperature)) / \(Self.temperatureText($0.lowTemperature))"
            } ?? "—",
            apparentTemperatureText: Self.temperatureText(current.apparentTemperature),
            pressureText: current.pressure.formatted(.measurement(width: .abbreviated)),
            visibilityText: current.visibility.formatted(.measurement(width: .abbreviated)),
            uvIndexText: "\(current.uvIndex.value)",
            sunriseText: today?.sun.sunrise?.formatted(timeStyle) ?? "—",
            sunsetText: today?.sun.sunset?.formatted(timeStyle) ?? "—",
            moonPhaseText: today.map { Self.moonPhaseText($0.moon.phase) } ?? "—",
            moonPhaseSymbol: today?.moon.phase.symbolName ?? "moon.stars.fill",
            moonriseText: today?.moon.moonrise?.formatted(timeStyle) ?? "—",
            moonsetText: today?.moon.moonset?.formatted(timeStyle) ?? "—",
            visualKind: .init(condition: current.condition),
            visualIntensity: .init(
                condition: current.condition,
                precipitationMillimetersPerHour: precipitationMillimetersPerHour
            ),
            visualCloudCover: Float(min(max(current.cloudCover, 0), 1)),
            visualWind: Self.normalizedVisualWind(current.wind),
            isDaylight: current.isDaylight,
            observedAt: .now
        )
    }

    func detailedWeather(for farmID: UUID, location: FarmLocationSnapshot) async throws -> FarmWeatherDetailSnapshot {
        if let cached = detailCache[farmID],
           cached.locationUpdatedAt == location.updatedAt,
           cached.fetchedAt.addingTimeInterval(15 * 60) > .now {
            return cached.snapshot
        }

        if let request = detailRequests[farmID],
           request.locationUpdatedAt == location.updatedAt {
            return try await request.task.value
        }

        let requestID = UUID()
        let task = Task<FarmWeatherDetailSnapshot, Error> {
            do {
                return try await Self.fetchDetailedWeather(for: location)
            } catch {
                let weatherKitFailure = Self.diagnosticDescription(for: error)
                Self.logger.error("WeatherKit detail request failed: \(weatherKitFailure, privacy: .public)")
                #if DEBUG
                print("[WeatherKit][detail] \(weatherKitFailure)")
                #endif
                throw RepositoryError.weatherKitFailed(weatherKitFailure)
            }
        }
        detailRequests[farmID] = DetailRequest(
            id: requestID,
            locationUpdatedAt: location.updatedAt,
            task: task
        )

        do {
            let snapshot = try await task.value
            if detailRequests[farmID]?.id == requestID {
                detailRequests.removeValue(forKey: farmID)
            }
            detailCache[farmID] = DetailCacheEntry(
                snapshot: snapshot,
                locationUpdatedAt: location.updatedAt,
                fetchedAt: .now
            )
            cache[farmID] = CacheEntry(snapshot: snapshot.current, locationUpdatedAt: location.updatedAt)
            return snapshot
        } catch {
            if detailRequests[farmID]?.id == requestID {
                detailRequests.removeValue(forKey: farmID)
            }
            throw error
        }
    }

    private static func fetchDetailedWeather(
        for location: FarmLocationSnapshot
    ) async throws -> FarmWeatherDetailSnapshot {
        let coordinate = CLLocation(latitude: location.latitude, longitude: location.longitude)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: location.timeZoneIdentifier) ?? .current
        let today = calendar.startOfDay(for: .now)
        let historyStart = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        async let aggregateWeather = WeatherService.shared.weather(for: coordinate)
        async let historicalForecast = WeatherService.shared.weather(
            for: coordinate,
            including: .daily(startDate: historyStart, endDate: today)
        )

        let (aggregate, history) = try await (aggregateWeather, historicalForecast)
        return FarmWeatherDetailSnapshot(
            current: Self.currentSnapshot(from: aggregate, location: location),
            hourly: aggregate.hourlyForecast.forecast.prefix(24).map {
                FarmHourlyWeather(
                    date: $0.date,
                    symbolName: $0.symbolName,
                    temperatureText: Self.temperatureText($0.temperature),
                    precipitationChanceText: $0.precipitationChance.formatted(.percent.precision(.fractionLength(0))),
                    temperatureValue: $0.temperature.converted(to: .celsius).value,
                    precipitationChanceValue: $0.precipitationChance,
                    windSpeedText: $0.wind.speed.formatted(.measurement(width: .abbreviated)),
                    windSpeedValue: $0.wind.speed.converted(to: .kilometersPerHour).value
                )
            },
            history: history.forecast.suffix(7).map(Self.dailySnapshot),
            forecast: aggregate.dailyForecast.forecast.prefix(7).map(Self.dailySnapshot),
            alerts: (aggregate.weatherAlerts ?? []).map(Self.alertSnapshot)
        )
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "eSheepNext",
        category: "WeatherRepository"
    )

    private static let millimetersPerHour = UnitSpeed(
        symbol: "mm/h",
        converter: UnitConverterLinear(coefficient: 1.0 / 3_600_000.0)
    )

    private static func normalizedVisualWind(_ wind: Wind) -> Float {
        let speed = wind.speed.converted(to: .kilometersPerHour).value
        let gust = wind.gust?.converted(to: .kilometersPerHour).value ?? speed
        return Float(min(max(max(speed, gust) / 100.0, 0), 1))
    }

    private static func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        var result = "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " <- \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)"
        }
        return result
    }

    private static func temperatureText(_ temperature: Measurement<UnitTemperature>) -> String {
        temperature.formatted(
            .measurement(
                width: .abbreviated,
                usage: .weather,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
        )
    }

    private static func dailySnapshot(_ day: DayWeather) -> FarmDailyWeather {
        FarmDailyWeather(
            date: day.date,
            symbolName: day.symbolName,
            highTemperatureText: temperatureText(day.highTemperature),
            lowTemperatureText: temperatureText(day.lowTemperature),
            precipitationChanceText: day.precipitationChance.formatted(.percent.precision(.fractionLength(0))),
            windSpeedText: day.wind.speed.formatted(.measurement(width: .abbreviated))
        )
    }

    private static func alertSnapshot(_ alert: WeatherAlert) -> FarmWeatherAlert {
        FarmWeatherAlert(
            id: alert.detailsURL.absoluteString,
            summary: alert.summary,
            region: alert.region,
            source: alert.source,
            severity: alertSeverity(alert.severity),
            detailsURL: alert.detailsURL
        )
    }

    private static func alertSeverity(_ severity: WeatherSeverity) -> FarmWeatherAlert.Severity {
        switch severity {
        case .minor: .minor
        case .moderate: .moderate
        case .severe: .severe
        case .extreme: .extreme
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private static func moonPhaseText(_ phase: MoonPhase) -> String {
        switch phase {
        case .new: "新月"
        case .waxingCrescent: "蛾眉月"
        case .firstQuarter: "上弦月"
        case .waxingGibbous: "盈凸月"
        case .full: "满月"
        case .waningGibbous: "亏凸月"
        case .lastQuarter: "下弦月"
        case .waningCrescent: "残月"
        @unknown default: "月相"
        }
    }
}

struct FarmWeatherPanel: View {
    let farm: FarmRecord
    @State private var state: State = .idle

    private enum State: Equatable {
        case idle
        case loading
        case loaded(FarmWeatherSnapshot)
        case unavailable
    }

    var body: some View {
        Group {
            if let location = farm.locationSnapshot {
                switch state {
                case .loaded(let weather):
                    HStack(spacing: 6) {
                        Image(systemName: weather.symbolName)
                        Text("天气：\(weather.temperatureText) · 湿度 \(weather.humidityText)")
                        Spacer(minLength: 0)
                        Text(location.displayName)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                case .loading, .idle:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取牧场天气")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                case .unavailable:
                    Text("天气暂时不可用；不会覆盖已保存的牧场位置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("天气：尚未设置牧场固定位置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: farm.locationUpdatedAt) {
            await loadWeather()
        }
    }

    private func loadWeather() async {
        guard let location = farm.locationSnapshot else {
            state = .idle
            return
        }
        state = .loading
        do {
            state = .loaded(try await FarmWeatherRepository.shared.currentWeather(for: farm.id, location: location))
        } catch {
            state = .unavailable
        }
    }
}

struct FarmLocationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var displayName: String
    @State private var addressSnapshot: String
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var timeZoneIdentifier: String
    @State private var source: FarmLocationSource
    @State private var horizontalAccuracyMeters: Double?
    @State private var searchText = ""
    @State private var searchResults: [FarmMapSearchResult] = []
    @State private var isSearching = false
    @State private var isLocating = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let location = farm.locationSnapshot
        _displayName = State(initialValue: location?.displayName ?? farm.name)
        _addressSnapshot = State(initialValue: farm.addressSnapshot ?? "")
        _latitudeText = State(initialValue: farm.latitude.map { String(format: "%.6f", $0) } ?? "")
        _longitudeText = State(initialValue: farm.longitude.map { String(format: "%.6f", $0) } ?? "")
        _timeZoneIdentifier = State(initialValue: farm.timeZoneIdentifier)
        _source = State(initialValue: location?.source ?? .manualCoordinate)
        _horizontalAccuracyMeters = State(initialValue: farm.horizontalAccuracyMeters)
    }

    var body: some View {
        Form {
            Section("搜索地点") {
                HStack {
                    TextField("牧场地址、村镇或地标", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit(search)
                    Button(action: search) {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(isSearching || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if isSearching { ProgressView("正在搜索地点") }
                ForEach(searchResults) { result in
                    Button { apply(result) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.name).foregroundStyle(.primary)
                            Text(result.address).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("固定位置") {
                TextField("地点名称", text: $displayName)
                TextField("地址快照（可选）", text: $addressSnapshot, axis: .vertical)
                    .lineLimit(2...3)
                TextField("纬度", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("经度", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("IANA 时区", text: $timeZoneIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(isLocating ? LocalizedStringKey("正在获取当前位置") : LocalizedStringKey("使用当前位置")) {
                    useCurrentLocation()
                }
                .disabled(isLocating)
                Text("只在点击“使用当前位置”时申请使用期间定位权限。搜索和手动坐标不依赖定位授权。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let coordinate = mapCoordinate {
                Section("位置预览") {
                    MapReader { proxy in
                        Map(initialPosition: .region(mapRegion(for: coordinate))) {
                            Marker(displayName.isEmpty ? farm.name : displayName, coordinate: coordinate)
                        }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard let selectedCoordinate = proxy.convert(point, from: .local) else { return }
                            applyManualMapCoordinate(selectedCoordinate)
                        }
                    }
                    .frame(height: 230)
                    .clipShape(.rect(cornerRadius: 12))
                    Text("轻点地图可重设标记。坐标参考系为 WGS 84；保存前请核对牧场实际位置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("牧场位置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .alert("无法保存牧场位置", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private var mapCoordinate: CLLocationCoordinate2D? {
        guard let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func mapRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000)
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                let response = try await MKLocalSearch(request: request).start()
                searchResults = response.mapItems.map { item in
                    FarmMapSearchResult(
                        name: item.name ?? "未命名地点",
                        address: item.address?.fullAddress ?? "",
                        latitude: item.location.coordinate.latitude,
                        longitude: item.location.coordinate.longitude
                    )
                }
            } catch {
                errorMessage = "地图搜索暂时不可用。请重试，或手动填写坐标。"
            }
        }
    }

    private func apply(_ result: FarmMapSearchResult) {
        displayName = result.name
        addressSnapshot = result.address
        latitudeText = String(format: "%.6f", result.latitude)
        longitudeText = String(format: "%.6f", result.longitude)
        source = .mapSearch
        horizontalAccuracyMeters = nil
        searchResults = []
    }

    private func applyManualMapCoordinate(_ coordinate: CLLocationCoordinate2D) {
        latitudeText = String(format: "%.6f", coordinate.latitude)
        longitudeText = String(format: "%.6f", coordinate.longitude)
        source = .manualCoordinate
        horizontalAccuracyMeters = nil
    }

    private func useCurrentLocation() {
        isLocating = true
        Task {
            defer { isLocating = false }
            do {
                let location = try await CurrentFarmLocationProvider().requestCoordinate()
                latitudeText = String(format: "%.6f", location.coordinate.latitude)
                longitudeText = String(format: "%.6f", location.coordinate.longitude)
                timeZoneIdentifier = TimeZone.current.identifier
                source = .currentLocation
                horizontalAccuracyMeters = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let coordinate = mapCoordinate else {
            errorMessage = FarmCommandError.invalidFarmCoordinate.localizedDescription
            return
        }
        do {
            try commandService.execute(
                .updateFarmLocation(
                    displayName: displayName,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    addressSnapshot: addressSnapshot,
                    timeZoneIdentifier: timeZoneIdentifier,
                    source: source,
                    horizontalAccuracyMeters: horizontalAccuracyMeters
                ),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FarmMapSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
}

@MainActor
private final class CurrentFarmLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func requestCoordinate() async throws -> CLLocation {
        manager.delegate = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(CurrentFarmLocationError.permissionDenied))
            @unknown default:
                finish(.failure(CurrentFarmLocationError.permissionDenied))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(CurrentFarmLocationError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(CurrentFarmLocationError.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(CurrentFarmLocationError.locationUnavailable))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(CurrentFarmLocationError.locationUnavailable))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private enum CurrentFarmLocationError: LocalizedError {
    case permissionDenied
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "未获得当前位置权限。您仍可通过搜索地点或手动填写坐标保存牧场位置。"
        case .locationUnavailable: "暂时无法获取当前位置。请稍后重试，或通过搜索地点和手动坐标继续设置。"
        }
    }
}
