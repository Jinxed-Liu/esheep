import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import WeatherKit

struct FarmWeatherSnapshot: Sendable, Equatable {
    enum VisualKind: Float, Sendable {
        case clear = 0
        case cloudy = 1
        case rain = 2
        case snow = 3
        case storm = 4
        case fog = 5

        init(symbolName: String) {
            if symbolName.contains("bolt") {
                self = .storm
            } else if symbolName.contains("snow") || symbolName.contains("sleet") {
                self = .snow
            } else if symbolName.contains("rain") || symbolName.contains("drizzle") {
                self = .rain
            } else if symbolName.contains("fog") || symbolName.contains("haze") {
                self = .fog
            } else if symbolName.contains("cloud") {
                self = .cloudy
            } else {
                self = .clear
            }
        }
    }

    let symbolName: String
    let temperatureText: String
    let humidityText: String
    let visualKind: VisualKind
    let isDaylight: Bool
    let observedAt: Date
}

actor FarmWeatherRepository {
    static let shared = FarmWeatherRepository()

    private struct CacheEntry {
        let snapshot: FarmWeatherSnapshot
        let locationUpdatedAt: Date
    }

    private var cache: [UUID: CacheEntry] = [:]

    func currentWeather(for farmID: UUID, location: FarmLocationSnapshot) async throws -> FarmWeatherSnapshot {
        if let cached = cache[farmID],
           cached.locationUpdatedAt == location.updatedAt,
           cached.snapshot.observedAt.addingTimeInterval(15 * 60) > .now {
            return cached.snapshot
        }

        let weather = try await WeatherService.shared.weather(
            for: CLLocation(latitude: location.latitude, longitude: location.longitude)
        )
        let current = weather.currentWeather
        let snapshot = FarmWeatherSnapshot(
            symbolName: current.symbolName,
            temperatureText: current.temperature.formatted(.measurement(width: .abbreviated)),
            humidityText: current.humidity.formatted(.percent.precision(.fractionLength(0))),
            visualKind: .init(symbolName: current.symbolName),
            isDaylight: current.isDaylight,
            observedAt: .now
        )
        cache[farmID] = CacheEntry(snapshot: snapshot, locationUpdatedAt: location.updatedAt)
        return snapshot
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
                Button(isLocating ? "正在获取当前位置" : "使用当前位置") {
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
            Text(errorMessage ?? "")
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
