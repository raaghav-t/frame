@preconcurrency import AVFoundation
import CoreLocation
import EventKit
import Foundation
@preconcurrency import HomeKit
@preconcurrency import HealthKit
@preconcurrency import Intents
import MapKit
@preconcurrency import MusicKit
@preconcurrency import Photos
import UIKit
import WeatherKit

@MainActor
protocol WeatherProviding: AnyObject {
    var locationPermission: PermissionState { get }
    var accessWasRequested: Bool { get }
    var manualLocationName: String? { get }
    func requestLocationAccess() async -> PermissionState
    func setManualLocation(_ name: String?)
    func loadWeather() async throws -> WeatherSummary
    func loadAttribution() async throws -> WeatherAttributionInfo
}

@MainActor
protocol FocusStatusProviding: AnyObject {
    func currentState() -> FocusStatusState
    func requestAccess() async -> FocusStatusState
}

@MainActor
final class SystemFocusStatusProvider: FocusStatusProviding {
    // Constructing the Focus-status connection can wake the DND service. Keep
    // it lazy so merely launching Frame never contacts it.
    private lazy var center = INFocusStatusCenter.default

    func currentState() -> FocusStatusState {
        switch center.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            guard let isFocused = center.focusStatus.isFocused else { return .unavailable }
            return isFocused ? .active : .inactive
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }

    func requestAccess() async -> FocusStatusState {
        if center.authorizationStatus == .notDetermined {
            _ = await center.requestAuthorization()
        }
        return currentState()
    }
}

@MainActor
protocol CalendarProviding: AnyObject {
    var permissionState: PermissionState { get }
    var availableCalendars: [CalendarDescriptor] { get }
    var selectedCalendarIdentifiers: Set<String> { get }
    var hasStoredCalendarSelection: Bool { get }
    var onStoreChanged: (() -> Void)? { get set }
    func requestAccess() async -> PermissionState
    func upcomingEvents() async throws -> [AgendaItem]
    func setSelectedCalendarIdentifiers(_ identifiers: Set<String>)
}

@MainActor
protocol RouteProviding: AnyObject {
    func route(
        for event: AgendaItem,
        transportMode: RouteTransportMode,
        allowingLocationPrompt: Bool
    ) async throws -> MapRouteSummary
}

struct HomeKitDiscoveryResult: Sendable {
    let hasHomes: Bool
    let cameras: [HomeKitCameraDescriptor]
    let controls: [HomeControl]
}

@MainActor
protocol HomeCameraProviding: AnyObject {
    var onStreamStateChanged: ((UUID, Error?) -> Void)? { get set }
    var onControlsChanged: (([HomeControl]) -> Void)? { get set }
    func discover() async throws -> HomeKitDiscoveryResult
    func refreshControls() async -> [HomeControl]
    func startStream(for id: UUID) async throws -> HMCameraSource
    func stopStream(for id: UUID)
    func snapshot(for id: UUID) async throws -> HMCameraSource?
    func setLight(id: String, isOn: Bool) async throws -> HomeControl
    func setThermostat(id: String, targetTemperature: Double) async throws -> HomeControl
    func setSpeaker(id: String, isOn: Bool) async throws -> HomeControl
    func setSpeakerVolume(id: String, volume: Double) async throws -> HomeControl
}

@MainActor
protocol SleepProviding: AnyObject {
    var accessWasRequested: Bool { get }
    func requestAccess() async -> PermissionState
    func loadLastNight() async throws -> SleepSummary?
}

@MainActor
protocol MirrorProviding: AnyObject {
    var status: MirrorPermissionState { get }
    var session: AVCaptureSession? { get }
    var previewRenderer: MirrorPreviewRenderer { get }
    var isRecording: Bool { get }
    var recordingStartedAt: Date? { get }
    var onStatusChange: (() -> Void)? { get set }
    var onSessionChange: (() -> Void)? { get set }
    var onFacePresenceChange: ((Bool) -> Void)? { get set }
    var onRecordingChange: (() -> Void)? { get set }
    var onCaptureResult: ((MirrorCaptureResult) -> Void)? { get set }
    func start()
    func stop()
    func retry()
    func previewDidAttach(to session: AVCaptureSession)
    func previewDidBecomeReady(to session: AVCaptureSession)
    @discardableResult func capturePhoto() -> Bool
    @discardableResult func startRecording() -> Bool
    func stopRecording()
    func setAttentionMonitoring(_ enabled: Bool)
    func resetAttentionBaseline()
}

@MainActor
protocol MusicProviding: AnyObject {
    var selectedPlaylistID: String? { get }
    var selectedPlaylistName: String { get }
    func requestAccess() async -> PermissionState
    func loadTracks() async throws -> [MusicTrack]
    func loadPlaylists() async throws -> [MusicPlaylistDescriptor]
    func selectPlaylist(id: String?) async throws -> [MusicTrack]
    func play() async throws -> MusicTrack?
    func pause()
    func skipToNext() async throws -> MusicTrack?
    func skipToPrevious() async throws -> MusicTrack?
    func rewind()
    func seek(to time: TimeInterval)
    func currentTrack() -> MusicTrack?
    func playbackProgress() -> MusicPlaybackProgress
}

@MainActor
protocol UpdatesProviding: AnyObject {
    func makeUpdates(weather: WeatherSummary?, agenda: [AgendaItem], feedStatuses: [String: FeedStatus], includeSunriseSunset: Bool) async -> [UpdateItem]
}

@MainActor
final class LiveUpdatesProvider: UpdatesProviding {
    func makeUpdates(weather: WeatherSummary?, agenda: [AgendaItem], feedStatuses: [String: FeedStatus], includeSunriseSunset: Bool) async -> [UpdateItem] {
        var updates: [UpdateItem] = []
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        for next in agenda {
            let location = next.location.map { " · \($0)" } ?? ""
            updates.append(UpdateItem(
                id: "agenda-\(next.id)",
                title: next.isPrivate ? "Private event" : next.title,
                detail: eventDetail(for: next, timeFormatter: timeFormatter, dayFormatter: dayFormatter) + location,
                kind: .calendar,
                accent: "#FF3B30",
                date: next.date
            ))
        }

        if let weather {
            let calendar = Calendar.current
            for day in weather.forecast where day.date > Date() && !calendar.isDateInToday(day.date) {
                updates.append(UpdateItem(
                    id: "weather-\(day.date.timeIntervalSince1970)",
                    title: day.condition,
                    detail: "High of \(day.high)° · Low of \(day.low)°",
                    kind: .weather,
                    accent: "#A6D9D7",
                    date: day.date
                ))
            }

            if includeSunriseSunset, weather.sunrise != nil || weather.sunset != nil {
                let sunriseText = weather.sunrise.map { "Sunrise \(timeFormatter.string(from: $0))" } ?? "Sunrise unavailable"
                let sunsetText = weather.sunset.map { "Sunset \(timeFormatter.string(from: $0))" } ?? "Sunset unavailable"
                updates.append(UpdateItem(
                    id: "sunrise-sunset",
                    title: sunriseText,
                    detail: sunsetText,
                    kind: .sunriseSunset,
                    accent: "#F4C66A",
                    // Solar times describe the current weather context. Keep them in
                    // today's section even after sunrise has already happened or
                    // when WeatherKit's forecast date crosses a UTC boundary.
                    date: nil
                ))
            }
        }

        if feedStatuses.values.contains(where: { $0 == .offline }) {
            updates.append(UpdateItem(
                id: "camera-offline",
                title: "A camera needs attention",
                detail: "Check your HomeKit connection",
                kind: .home,
                accent: "#F07C73",
                date: nil
            ))
        }

        return updates
    }

    private func eventDetail(for event: AgendaItem, timeFormatter: DateFormatter, dayFormatter: DateFormatter) -> String {
        let calendar = Calendar.current
        if event.isAllDay {
            if calendar.isDateInToday(event.date) { return "All day today" }
            if calendar.isDateInTomorrow(event.date) { return "All day tomorrow" }
            return "All day · \(dayFormatter.string(from: event.date))"
        }

        let time = timeFormatter.string(from: event.date)
        if calendar.isDateInToday(event.date) { return "Today at \(time)" }
        if calendar.isDateInTomorrow(event.date) { return "Tomorrow at \(time)" }
        return "\(dayFormatter.string(from: event.date)) at \(time)"
    }
}

@MainActor
final class MapKitRouteProvider: RouteProviding {
    // CLLocationManager can synchronously establish its service connection.
    // Updates can use an already-authorized location in the background, while
    // the Map feed remains the explicit path that may request access.
    private lazy var locationProvider = LocationProvider()

    private struct GeocodedDestination {
        let coordinate: CLLocationCoordinate2D
        let postalCode: String?
        let country: String?
        let isoCountryCode: String?
    }

    func route(
        for event: AgendaItem,
        transportMode: RouteTransportMode,
        allowingLocationPrompt: Bool
    ) async throws -> MapRouteSummary {
        guard let address = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw ProviderError.unavailable("This event does not include a location.")
        }

        let currentLocation = try await locationProvider.requestLocation(
            allowingAuthorizationPrompt: allowingLocationPrompt
        )
        let destination: GeocodedDestination
        if let coordinate = event.locationCoordinate {
            destination = GeocodedDestination(
                coordinate: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                postalCode: nil,
                country: nil,
                isoCountryCode: nil
            )
        } else {
            destination = try await geocode(address)
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = Self.mapKitTransportType(for: transportMode)
        if event.isAllDay {
            request.departureDate = Date()
        } else {
            // Ask MapKit for the travel estimate that gets the person to the
            // event at its scheduled start, rather than estimating a trip that
            // departs at the moment the dashboard happens to refresh.
            request.arrivalDate = event.date
        }
        request.requestsAlternateRoutes = false

        if transportMode == .transit {
            let eta: MKDirections.ETAResponse
            do {
                eta = try await calculateETA(request)
            } catch {
                throw ProviderError.unavailable(
                    "Transit ETA is unavailable for this destination. Try Apple Maps for full transit directions."
                )
            }

            let sourcePoint = MapRoutePoint(
                latitude: currentLocation.coordinate.latitude,
                longitude: currentLocation.coordinate.longitude
            )
            let destinationPoint = MapRoutePoint(
                latitude: destination.coordinate.latitude,
                longitude: destination.coordinate.longitude
            )
            let fallbackDistance = CLLocation(
                latitude: currentLocation.coordinate.latitude,
                longitude: currentLocation.coordinate.longitude
            ).distance(from: CLLocation(
                latitude: destination.coordinate.latitude,
                longitude: destination.coordinate.longitude
            ))
            let distanceMeters = eta.distance > 0 ? eta.distance : fallbackDistance

            return MapRouteSummary(
                destinationName: displayAddress(address, destination: destination),
                travelTimeMinutes: max(1, Int((eta.expectedTravelTime / 60).rounded())),
                trafficLabel: "TRANSIT ESTIMATE",
                distanceMiles: distanceMeters / 1_609.344,
                // MapKit exposes transit as ETA-only, so there is no transit
                // polyline to draw. RouteMapView renders this connector as a
                // dashed approximation rather than implying it is the route.
                points: [sourcePoint, destinationPoint],
                transportMode: transportMode
            )
        }

        let response = try await calculate(request)
        guard let route = response.routes.first else {
            throw ProviderError.unavailable("Apple Maps could not find a \(transportMode.title.lowercased()) route.")
        }

        let pointCount = route.polyline.pointCount
        guard pointCount > 1 else {
            throw ProviderError.unavailable("Apple Maps returned an empty route.")
        }
        let routePoints = (0..<pointCount).map { index -> MapRoutePoint in
            let coordinate = route.polyline.points()[index].coordinate
            return MapRoutePoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        let trafficLabel: String
        switch transportMode {
        case .driving:
            trafficLabel = "DRIVING ESTIMATE"
        case .transit:
            trafficLabel = "TRANSIT ESTIMATE"
        case .walking:
            trafficLabel = "WALKING ESTIMATE"
        case .cycling:
            trafficLabel = "CYCLING ESTIMATE"
        }
        return MapRouteSummary(
            destinationName: displayAddress(address, destination: destination),
            travelTimeMinutes: max(1, Int((route.expectedTravelTime / 60).rounded())),
            trafficLabel: trafficLabel,
            distanceMiles: route.distance / 1_609.344,
            points: routePoints,
            transportMode: transportMode
        )
    }

    private static func mapKitTransportType(for mode: RouteTransportMode) -> MKDirectionsTransportType {
        switch mode {
        case .driving: return .automobile
        case .transit: return .transit
        case .walking: return .walking
        case .cycling: return .cycling
        }
    }

    private func geocode(_ address: String) async throws -> GeocodedDestination {
        let geocoder = CLGeocoder()
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.geocodeAddressString(address) { placemarks, error in
                if let error {
                    continuation.resume(throwing: normalizedLocationError(error))
                } else if let placemark = placemarks?.first,
                          let coordinate = placemark.location?.coordinate {
                    continuation.resume(returning: GeocodedDestination(
                        coordinate: coordinate,
                        postalCode: placemark.postalCode,
                        country: placemark.country,
                        isoCountryCode: placemark.isoCountryCode
                    ))
                } else {
                    continuation.resume(throwing: ProviderError.unavailable("Apple Maps could not find \(address)."))
                }
            }
        }
    }

    private func displayAddress(_ address: String, destination: GeocodedDestination) -> String {
        var countryNames = Set([
            "us",
            "usa",
            "u.s.",
            "u.s.a.",
            "united states",
            "united states of america"
        ])
        countryNames.formUnion([
            destination.country,
            destination.isoCountryCode
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if destination.isoCountryCode?.caseInsensitiveCompare("US") == .orderedSame {
            countryNames.formUnion(["usa", "u.s.a.", "united states of america"])
        }

        let parts = address
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { rawPart -> String? in
                var part = String(rawPart)
                if let postalCode = destination.postalCode, !postalCode.isEmpty {
                    part = part.replacingOccurrences(of: postalCode, with: "", options: .caseInsensitive)
                }
                part = Self.usPostalCodeRegex.stringByReplacingMatches(
                    in: part,
                    options: [],
                    range: NSRange(part.startIndex..., in: part),
                    withTemplate: ""
                )
                part = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = part.lowercased()
                guard !part.isEmpty, !countryNames.contains(normalized) else { return nil }
                return part
            }

        return parts.isEmpty ? address : parts.joined(separator: ", ")
    }

    private static let usPostalCodeRegex: NSRegularExpression = {
        // Calendar locations commonly contain a ZIP in either "93101" or
        // "93101-1234" form, even when the event also provides coordinates.
        try! NSRegularExpression(pattern: #"\b\d{5}(?:-\d{4})?\b"#)
    }()

    private func calculate(_ request: MKDirections.Request) async throws -> MKDirections.Response {
        try await withCheckedThrowingContinuation { continuation in
            MKDirections(request: request).calculate { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ProviderError.unavailable("Apple Maps did not return a route."))
                }
            }
        }
    }

    private func calculateETA(_ request: MKDirections.Request) async throws -> MKDirections.ETAResponse {
        try await withCheckedThrowingContinuation { continuation in
            MKDirections(request: request).calculateETA { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ProviderError.unavailable("Apple Maps did not return a transit ETA."))
                }
            }
        }
    }
}

@MainActor
final class HealthKitSleepProvider: SleepProviding {
    // Keep the HealthKit connection out of the cached dashboard's first frame.
    private lazy var store = HKHealthStore()
    private(set) var accessWasRequested = UserDefaults.standard.bool(
        forKey: HealthKitSleepProvider.accessWasRequestedKey
    )
    private static let accessWasRequestedKey = "frame.sleepAccessWasRequested"

    private var sleepType: HKCategoryType? {
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    func requestAccess() async -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable(), let sleepType else { return .unavailable }
        accessWasRequested = true
        UserDefaults.standard.set(true, forKey: Self.accessWasRequestedKey)
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: [sleepType])
            return .allowed
        } catch {
            return .denied
        }
    }

    func loadLastNight() async throws -> SleepSummary? {
        guard HKHealthStore.isHealthDataAvailable(), let sleepType else {
            throw ProviderError.unavailable("Health data is not available on this iPad.")
        }

        let calendar = Calendar.current
        let now = Date()
        let previousDay = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) ?? now.addingTimeInterval(-18 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let samples = try await query(sleepType: sleepType, predicate: predicate)

        guard !samples.isEmpty else { return nil }
        let startDate = samples.map(\.startDate).min()
        let endDate = samples.map(\.endDate).max()
        let inBedIntervals = samples
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .inBed }
            .map { ($0.startDate, $0.endDate) }
        let asleepIntervals = samples
            .filter { value in
                switch HKCategoryValueSleepAnalysis(rawValue: value.value) {
                case .asleepDeep, .asleepREM, .asleepCore, .asleepUnspecified: return true
                default: return false
                }
            }
            .map { ($0.startDate, $0.endDate) }
        let deepIntervals = samples
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .asleepDeep }
            .map { ($0.startDate, $0.endDate) }
        let remIntervals = samples
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .asleepREM }
            .map { ($0.startDate, $0.endDate) }
        let awakeSamples = samples.filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) == .awake }
        let awakenings = Set(awakeSamples.map { Int($0.startDate.timeIntervalSince1970 / 60) }).count
        let sleepMinutes = IntervalMath.mergedMinutes(asleepIntervals)
        let inBedMinutes = IntervalMath.mergedMinutes(inBedIntervals)
        let deepMinutes = IntervalMath.mergedMinutes(deepIntervals)
        let remMinutes = IntervalMath.mergedMinutes(remIntervals)

        guard sleepMinutes > 0 || inBedMinutes > 0 else { return nil }
        return SleepSummary(
            sleepStart: startDate,
            sleepEnd: endDate,
            totalSleepMinutes: sleepMinutes,
            inBedMinutes: inBedMinutes,
            deepSleepMinutes: deepMinutes,
            remSleepMinutes: remMinutes,
            awakenings: awakenings
        )
    }

    private func query(sleepType: HKCategoryType, predicate: NSPredicate) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }
}

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var lastLocation: CLLocation?
    private(set) var permissionState: PermissionState = .unknown

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocation(allowingAuthorizationPrompt: Bool = true) async throws -> CLLocation {
        permissionState = map(manager.authorizationStatus)
        if permissionState == .denied || permissionState == .restricted {
            throw ProviderError.permissionDenied(locationAccessMessage)
        }
        if permissionState == .unavailable {
            throw ProviderError.unavailable("Location Services are not available on this iPad.")
        }
        if !allowingAuthorizationPrompt, permissionState != .allowed {
            throw ProviderError.unavailable("Location access is not available for travel estimates.")
        }

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[requestID] = continuation
                if Task.isCancelled {
                    waiters.removeValue(forKey: requestID)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                timeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.timeout(requestID)
                }

                if waiters.count == 1 {
                    switch permissionState {
                    case .unknown, .requesting:
                        guard allowingAuthorizationPrompt else {
                            finishAll(with: .failure(ProviderError.unavailable("Location access is not available for travel estimates.")))
                            return
                        }
                        // The authorization callback supplies the current
                        // state and starts the request when access is allowed.
                        manager.requestWhenInUseAuthorization()
                    case .allowed:
                        manager.requestLocation()
                    case .denied, .restricted, .unavailable:
                        finishAll(with: .failure(ProviderError.permissionDenied(locationAccessMessage)))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        permissionState = map(manager.authorizationStatus)
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            if !waiters.isEmpty { manager.requestLocation() }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finishAll(with: .failure(ProviderError.permissionDenied(locationAccessMessage)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        finishAll(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishAll(with: .failure(normalizedLocationError(error)))
    }

    private func timeout(_ requestID: UUID) {
        guard waiters[requestID] != nil else { return }
        let continuation = waiters.removeValue(forKey: requestID)
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation?.resume(throwing: ProviderError.unavailable("Location was not available. Check Location Services and try again."))
    }

    private func cancel(_ requestID: UUID) {
        guard let continuation = waiters.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: CancellationError())
    }

    private func finishAll(with result: Result<CLLocation, Error>) {
        let currentWaiters = waiters.values
        waiters.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        for continuation in currentWaiters {
            continuation.resume(with: result)
        }
    }

    private func map(_ status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .unknown
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .unavailable
        }
    }
}

private let locationAccessMessage = "Location access is off. Allow it to load local weather and routes."

private func normalizedLocationError(_ error: Error) -> Error {
    guard let error = error as? CLError, error.code == .denied else { return error }
    return ProviderError.permissionDenied(locationAccessMessage)
}

@MainActor
final class WeatherKitProvider: WeatherProviding {
    // Creating CLLocationManager can wake locationd. Defer that until the
    // staged weather refresh starts after the cached dashboard is on screen.
    private lazy var locationProvider = LocationProvider()
    private(set) var locationPermission: PermissionState = .unknown
    private(set) var accessWasRequested: Bool
    private(set) var manualLocationName: String?

    private static let manualLocationKey = "frame.weather.manualLocation"
    private static let weatherCacheKey = "frame.weather.cache.v2"
    private static let accessWasRequestedKey = "frame.weather.accessWasRequested"

    init() {
        let defaults = UserDefaults.standard
        manualLocationName = defaults.string(forKey: Self.manualLocationKey)
        accessWasRequested = defaults.bool(forKey: Self.accessWasRequestedKey)
        if !accessWasRequested,
           manualLocationName == nil,
           defaults.data(forKey: Self.weatherCacheKey) != nil {
            // Migrate a pre-marker local-weather cache. Rechecking an access
            // decision already made by the user is safe and avoids a prompt.
            accessWasRequested = true
            defaults.set(true, forKey: Self.accessWasRequestedKey)
        }
    }

    func setManualLocation(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        manualLocationName = trimmed.isEmpty ? nil : trimmed
        if let manualLocationName {
            UserDefaults.standard.set(manualLocationName, forKey: Self.manualLocationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.manualLocationKey)
        }
    }

    func requestLocationAccess() async -> PermissionState {
        if manualLocationName != nil {
            locationPermission = .allowed
            return locationPermission
        }
        accessWasRequested = true
        UserDefaults.standard.set(true, forKey: Self.accessWasRequestedKey)
        if locationProvider.permissionState == .unknown {
            _ = try? await locationProvider.requestLocation()
        }
        locationPermission = locationProvider.permissionState
        return locationPermission
    }

    func loadWeather() async throws -> WeatherSummary {
        let location: CLLocation
        let locationName: String
        if let manualLocationName {
            location = try await geocode(manualLocationName)
            locationName = manualLocationName
        } else {
            do {
                if let lastLocation = locationProvider.lastLocation {
                    location = lastLocation
                } else {
                    location = try await locationProvider.requestLocation()
                }
                locationName = "Current location"
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProviderError.unavailable("Location was not available. Allow Location Services to load local weather.")
            }
        }
        locationPermission = locationProvider.permissionState

        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let forecasts = Array(weather.dailyForecast.forecast)
            let calendar = Calendar.current
            let day = forecasts.first(where: { calendar.isDate($0.date, inSameDayAs: current.date) }) ?? forecasts.first
            let calculatedSolarTimes = SolarTimes.forDate(current.date, coordinate: location.coordinate)
            let unit: UnitTemperature = Locale.current.measurementSystem == .metric ? .celsius : .fahrenheit
            let rounded: (Measurement<UnitTemperature>) -> Int = { measurement in
                Int(measurement.converted(to: unit).value.rounded())
            }
            let futureForecast = forecasts
                .filter { $0.date > current.date && !calendar.isDate($0.date, inSameDayAs: current.date) }
                .map { forecast in
                    WeatherForecastDay(
                        date: forecast.date,
                        high: rounded(forecast.highTemperature),
                        low: rounded(forecast.lowTemperature),
                        condition: forecast.condition.description.capitalized,
                        symbolName: forecast.symbolName
                    )
                }

            let summary = WeatherSummary(
                temperature: rounded(current.temperature),
                high: rounded(day?.highTemperature ?? current.temperature),
                low: rounded(day?.lowTemperature ?? current.temperature),
                condition: current.condition.description.capitalized,
                symbolName: current.symbolName,
                locationName: locationName,
                observedAt: current.date,
                isStale: false,
                sunrise: day?.sun.sunrise ?? calculatedSolarTimes.sunrise,
                sunset: day?.sun.sunset ?? calculatedSolarTimes.sunset,
                forecast: futureForecast
            )
            if let data = try? JSONEncoder().encode(summary) {
                UserDefaults.standard.set(data, forKey: Self.weatherCacheKey)
            }
            return summary
        } catch {
            guard let data = UserDefaults.standard.data(forKey: Self.weatherCacheKey),
                  let cached = try? JSONDecoder().decode(WeatherSummary.self, from: data) else {
                let details = String(describing: error)
                if details.localizedCaseInsensitiveContains("WDSJWT")
                    || details.localizedCaseInsensitiveContains("authservice")
                    || details.localizedCaseInsensitiveContains("not authorized") {
                    throw ProviderError.unavailable(
                        "WeatherKit is not authorized for this build. Enable WeatherKit for com.raaghavt.frame, refresh the signing profile, then reinstall Frame."
                    )
                }
                throw ProviderError.failed("Weather could not be loaded right now. Check the connection and try again.")
            }
            let currentDay = Calendar.current
            let calculatedSolarTimes = SolarTimes.forDate(Date(), coordinate: location.coordinate)
            let cachedSunrise = cached.sunrise.flatMap { currentDay.isDate($0, inSameDayAs: Date()) ? $0 : nil }
            let cachedSunset = cached.sunset.flatMap { currentDay.isDate($0, inSameDayAs: Date()) ? $0 : nil }
            return WeatherSummary(
                temperature: cached.temperature,
                high: cached.high,
                low: cached.low,
                condition: cached.condition,
                symbolName: cached.symbolName,
                locationName: cached.locationName,
                observedAt: cached.observedAt,
                isStale: true,
                sunrise: cachedSunrise ?? calculatedSolarTimes.sunrise,
                sunset: cachedSunset ?? calculatedSolarTimes.sunset,
                forecast: cached.forecast
            )
        }
    }

    func loadAttribution() async throws -> WeatherAttributionInfo {
        let attribution = try await WeatherService.shared.attribution
        return WeatherAttributionInfo(
            markURL: attribution.combinedMarkLightURL,
            legalURL: attribution.legalPageURL,
            serviceName: attribution.serviceName
        )
    }

    private func geocode(_ name: String) async throws -> CLLocation {
        let geocoder = CLGeocoder()
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.geocodeAddressString(name) { placemarks, error in
                if error != nil {
                    continuation.resume(throwing: ProviderError.unavailable("Could not find \(name). Check the spelling and try again."))
                } else if let location = placemarks?.first?.location {
                    continuation.resume(returning: location)
                } else {
                    continuation.resume(throwing: ProviderError.unavailable("Could not find \(name). Check the spelling and try again."))
                }
            }
        }
    }
}

private enum SolarTimes {
    struct Pair {
        let sunrise: Date?
        let sunset: Date?
    }

    static func forDate(_ date: Date, coordinate: CLLocationCoordinate2D) -> Pair {
        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let longitudeHour = coordinate.longitude / 15

        return Pair(
            sunrise: calculate(isSunrise: true, dayOfYear: dayOfYear, longitudeHour: longitudeHour, coordinate: coordinate, date: date),
            sunset: calculate(isSunrise: false, dayOfYear: dayOfYear, longitudeHour: longitudeHour, coordinate: coordinate, date: date)
        )
    }

    private static func calculate(
        isSunrise: Bool,
        dayOfYear: Double,
        longitudeHour: Double,
        coordinate: CLLocationCoordinate2D,
        date: Date
    ) -> Date? {
        let approximateTime = dayOfYear + (((isSunrise ? 6.0 : 18.0) - longitudeHour) / 24.0)
        let meanAnomaly = (0.9856 * approximateTime) - 3.289
        let meanAnomalyRadians = degreesToRadians(meanAnomaly)
        let trueLongitude = normalizedDegrees(
            meanAnomaly
                + (1.916 * sin(meanAnomalyRadians))
                + (0.020 * sin(2 * meanAnomalyRadians))
                + 282.634
        )
        let trueLongitudeRadians = degreesToRadians(trueLongitude)

        var rightAscension = radiansToDegrees(atan(0.91764 * tan(trueLongitudeRadians)))
        rightAscension = normalizedDegrees(rightAscension)
        rightAscension += (floor(trueLongitude / 90) * 90) - (floor(rightAscension / 90) * 90)
        rightAscension /= 15

        let declinationSin = 0.39782 * sin(trueLongitudeRadians)
        let declinationCos = cos(asin(declinationSin))
        let latitudeRadians = degreesToRadians(coordinate.latitude)
        let cosineHourAngle = (cos(degreesToRadians(90.833)) - (declinationSin * sin(latitudeRadians)))
            / (declinationCos * cos(latitudeRadians))

        guard (-1...1).contains(cosineHourAngle) else {
            return nil
        }

        var hourAngle = radiansToDegrees(acos(cosineHourAngle))
        if isSunrise {
            hourAngle = 360 - hourAngle
        }
        hourAngle /= 15

        let localMeanTime = hourAngle + rightAscension - (0.06571 * approximateTime) - 6.622
        let universalTime = normalizedHours(localMeanTime - longitudeHour)
        return utcDate(for: universalTime, localDate: date)
    }

    private static func utcDate(for universalTime: Double, localDate: Date) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: localDate)
        let hour = Int(universalTime)
        let minute = Int((universalTime - Double(hour)) * 60)
        let second = Int((((universalTime - Double(hour)) * 60) - Double(minute)) * 60)
        components.hour = hour
        components.minute = minute
        components.second = second

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard var result = utcCalendar.date(from: components) else { return nil }

        // Universal time can fall on the adjacent UTC day while still belonging
        // to the requested local day (for example, a California sunset).
        let localCalendar = Calendar.current
        let localDayStart = localCalendar.startOfDay(for: localDate)
        let nextLocalDayStart = localCalendar.date(byAdding: .day, value: 1, to: localDayStart) ?? localDayStart
        while result < localDayStart {
            result = utcCalendar.date(byAdding: .day, value: 1, to: result) ?? result
        }
        while result >= nextLocalDayStart {
            result = utcCalendar.date(byAdding: .day, value: -1, to: result) ?? result
        }
        return result
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 360)
        return result >= 0 ? result : result + 360
    }

    private static func normalizedHours(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 24)
        return result >= 0 ? result : result + 24
    }

    private static func degreesToRadians(_ value: Double) -> Double {
        value * .pi / 180
    }

    private static func radiansToDegrees(_ value: Double) -> Double {
        value * 180 / .pi
    }
}

@MainActor
final class MusicKitProvider: MusicProviding {
    // ApplicationMusicPlayer establishes an XPC connection on first access.
    // Frame opens on the Mirror surface, so defer that work until music is
    // actually requested rather than making app launch wait for it.
    private lazy var player = ApplicationMusicPlayer.shared
    private var songs: [Song] = []
    private var playlistTracks: [Track] = []
    private var activePlaylist: Playlist?
    private var index = 0
    private var queueNeedsReset = true
    private var permissionState: PermissionState = .unknown
    private static let selectedPlaylistKey = "frame.music.selectedPlaylist"

    private(set) var selectedPlaylistID: String?
    private(set) var selectedPlaylistName: String = "Favorites Mix"

    init() {
        selectedPlaylistID = UserDefaults.standard.string(forKey: Self.selectedPlaylistKey)
    }

    func requestAccess() async -> PermissionState {
        let status = await MusicAuthorization.request()
        permissionState = Self.map(status)
        return permissionState
    }

    func loadTracks() async throws -> [MusicTrack] {
        if permissionState != .allowed {
            let access = await requestAccess()
            guard access == .allowed else {
                throw ProviderError.permissionDenied("Apple Music access is off. Allow it to play music in Frame.")
            }
        }

        songs.removeAll()
        playlistTracks.removeAll()
        activePlaylist = nil
        index = 0
        queueNeedsReset = true

        if let selectedPlaylistID {
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()
            guard let playlist = response.items.first(where: { $0.id.rawValue == selectedPlaylistID }) else {
                throw ProviderError.unavailable("That playlist is no longer available in your music library.")
            }
            let detailedPlaylist = try await playlistWithTracks(playlist, preferredSource: .library)
            activePlaylist = detailedPlaylist
            selectedPlaylistName = detailedPlaylist.name
            playlistTracks = Array(detailedPlaylist.tracks ?? [])
            guard !playlistTracks.isEmpty else {
                throw ProviderError.unavailable("That playlist has no playable tracks.")
            }
            return playlistTracks.map(Self.map)
        }

        if let favoritesMix = try? await loadFavoritesMix() {
            do {
                let detailedPlaylist: Playlist
                do {
                    detailedPlaylist = try await playlistWithTracks(favoritesMix, preferredSource: .library)
                } catch {
                    detailedPlaylist = try await playlistWithTracks(favoritesMix, preferredSource: .catalog)
                }
                let tracks = Array(detailedPlaylist.tracks ?? [])
                if !tracks.isEmpty {
                    activePlaylist = detailedPlaylist
                    selectedPlaylistName = detailedPlaylist.name
                    playlistTracks = tracks
                    return tracks.map(Self.map)
                }
            } catch {
                // Personal recommendations can contain a playlist shell without
                // a loaded relationship. Fall through to a catalog search instead
                // of presenting a play button that cannot start a queue.
            }
        }

        var request = MusicCatalogSearchRequest(term: "ambient focus", types: [Song.self])
        request.limit = 5
        let response = try await request.response()
        songs = Array(response.songs)

        guard !songs.isEmpty else {
            throw ProviderError.unavailable("No Apple Music tracks were found for this Frame.")
        }

        return songs.map(Self.map)
    }

    func loadPlaylists() async throws -> [MusicPlaylistDescriptor] {
        if permissionState != .allowed {
            let access = await requestAccess()
            guard access == .allowed else {
                throw ProviderError.permissionDenied("Apple Music access is off. Allow it to choose a playlist in Frame.")
            }
        }

        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()
        return response.items
            .map { MusicPlaylistDescriptor(id: $0.id.rawValue, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func selectPlaylist(id: String?) async throws -> [MusicTrack] {
        selectedPlaylistID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedPlaylistKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedPlaylistKey)
            selectedPlaylistName = "Favorites Mix"
        }
        return try await loadTracks()
    }

    func play() async throws -> MusicTrack? {
        if songs.isEmpty, playlistTracks.isEmpty, activePlaylist == nil { _ = try await loadTracks() }
        guard !playlistTracks.isEmpty || !songs.isEmpty else {
            throw ProviderError.unavailable("The selected playlist has no playable tracks.")
        }

        let subscription: MusicSubscription
        do {
            subscription = try await MusicSubscription.current
        } catch {
            throw ProviderError.unavailable("Apple Music subscription status is unavailable.")
        }
        guard subscription.canPlayCatalogContent else {
            throw ProviderError.unavailable("An Apple Music subscription is required for full-length playback.")
        }

        if queueNeedsReset || !player.isPreparedToPlay {
            if !playlistTracks.isEmpty {
                guard playlistTracks.indices.contains(index) else { return nil }
                player.queue = ApplicationMusicPlayer.Queue(for: playlistTracks, startingAt: playlistTracks[index])
            } else {
                guard songs.indices.contains(index) else { return nil }
                player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: songs[index])
            }
            queueNeedsReset = false
        }
        try await player.prepareToPlay()
        try await player.play()
        return currentTrack()
    }

    func pause() {
        player.pause()
    }

    func skipToNext() async throws -> MusicTrack? {
        if songs.isEmpty, playlistTracks.isEmpty, activePlaylist == nil { _ = try await loadTracks() }

        let count = max(songs.count, playlistTracks.count)
        guard count > 0 else {
            throw ProviderError.unavailable("The selected playlist has no playable tracks.")
        }

        let previousTrackID = currentTrack()?.id
        if index < count - 1 {
            index += 1
            try await player.skipToNextEntry()
        } else {
            index = 0
            queueNeedsReset = true
            if !playlistTracks.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: playlistTracks, startingAt: playlistTracks[index])
            } else if !songs.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: songs[index])
            }
            queueNeedsReset = false
            try await player.prepareToPlay()
            try await player.play()
        }
        return await currentTrack(afterChangingFrom: previousTrackID)
    }

    func skipToPrevious() async throws -> MusicTrack? {
        if songs.isEmpty, playlistTracks.isEmpty, activePlaylist == nil { _ = try await loadTracks() }

        let count = max(songs.count, playlistTracks.count)
        guard count > 0 else {
            throw ProviderError.unavailable("The selected playlist has no playable tracks.")
        }

        let previousTrackID = currentTrack()?.id
        if index > 0 {
            index -= 1
            try await player.skipToPreviousEntry()
        } else {
            index = count - 1
            queueNeedsReset = true
            if !playlistTracks.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: playlistTracks, startingAt: playlistTracks[index])
            } else if !songs.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: songs[index])
            }
            queueNeedsReset = false
            try await player.prepareToPlay()
            try await player.play()
        }
        return await currentTrack(afterChangingFrom: previousTrackID)
    }

    func rewind() {
        let current = player.playbackTime
        guard current.isFinite else { return }
        player.playbackTime = max(0, current - 15)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        player.playbackTime = max(0, time)
    }

    func playbackProgress() -> MusicPlaybackProgress {
        let time = player.playbackTime.isFinite ? max(0, player.playbackTime) : 0
        let duration: TimeInterval?
        if playlistTracks.indices.contains(index) {
            duration = playlistTracks[index].duration
        } else if songs.indices.contains(index) {
            duration = songs[index].duration
        } else {
            duration = nil
        }
        return MusicPlaybackProgress(time: time, duration: max(0, duration ?? 0))
    }

    private static func map(_ song: Song) -> MusicTrack {
        MusicTrack(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "Apple Music",
            artworkURL: song.artwork?.url(width: 640, height: 640),
            duration: song.duration
        )
    }

    private static func map(_ track: Track) -> MusicTrack {
        MusicTrack(
            id: track.id.rawValue,
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle ?? "Playlist",
            artworkURL: track.artwork?.url(width: 640, height: 640),
            duration: track.duration
        )
    }

    func currentTrack() -> MusicTrack? {
        guard let entry = player.queue.currentEntry else {
            return indexedTrack()
        }

        let itemID = entry.item?.id.rawValue
        if let itemID,
           let playlistIndex = playlistTracks.firstIndex(where: { $0.id.rawValue == itemID }) {
            index = playlistIndex
            return Self.map(playlistTracks[playlistIndex])
        }
        if let itemID,
           let songIndex = songs.firstIndex(where: { $0.id.rawValue == itemID }) {
            index = songIndex
            return Self.map(songs[songIndex])
        }

        let duration = max(0, (entry.endTime ?? 0) - (entry.startTime ?? 0))
        return MusicTrack(
            id: itemID ?? entry.id,
            title: entry.title,
            artist: entry.subtitle ?? "",
            album: selectedPlaylistName,
            artworkURL: entry.artwork?.url(width: 640, height: 640),
            duration: duration
        )
    }

    private func indexedTrack() -> MusicTrack? {
        if playlistTracks.indices.contains(index) { return Self.map(playlistTracks[index]) }
        if songs.indices.contains(index) { return Self.map(songs[index]) }
        return nil
    }

    private func currentTrack(afterChangingFrom previousTrackID: String?) async -> MusicTrack? {
        for _ in 0..<8 {
            let track = currentTrack()
            if track?.id != previousTrackID { return track }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return currentTrack() ?? indexedTrack()
    }

    private func loadFavoritesMix() async throws -> Playlist? {
        var request = MusicPersonalRecommendationsRequest()
        request.limit = 8
        let response = try await request.response()
        let playlists = response.recommendations.flatMap { Array($0.playlists) }
        return playlists.first(where: { $0.name.localizedCaseInsensitiveContains("favorite") })
            ?? playlists.first(where: { $0.name.localizedCaseInsensitiveContains("mix") })
            ?? playlists.first
    }

    private func playlistWithTracks(_ playlist: Playlist, preferredSource: MusicPropertySource) async throws -> Playlist {
        if let tracks = playlist.tracks, !tracks.isEmpty {
            return playlist
        }
        return try await playlist.with([.tracks], preferredSource: preferredSource)
    }

    private static func map(_ status: MusicAuthorization.Status) -> PermissionState {
        switch status {
        case .notDetermined: return .unknown
        case .authorized: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }
}

@MainActor
final class EventKitCalendarProvider: NSObject, CalendarProviding {
    private lazy var store: EKEventStore = {
        let store = EKEventStore()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCalendarOptions()
                self.onStoreChanged?()
            }
        }
        return store
    }()
    private(set) var permissionState: PermissionState
    private(set) var availableCalendars: [CalendarDescriptor] = []
    private(set) var selectedCalendarIdentifiers: Set<String>
    private(set) var hasStoredCalendarSelection: Bool
    private var changeObserver: NSObjectProtocol?
    var onStoreChanged: (() -> Void)?

    private static let selectedCalendarsKey = "frame.selectedCalendarIdentifiers"

    override init() {
        permissionState = Self.map(EKEventStore.authorizationStatus(for: .event))
        if let stored = UserDefaults.standard.array(forKey: Self.selectedCalendarsKey) as? [String] {
            selectedCalendarIdentifiers = Set(stored)
            hasStoredCalendarSelection = true
        } else {
            selectedCalendarIdentifiers = []
            hasStoredCalendarSelection = false
        }
        super.init()
        // EKEventStore construction and calendar enumeration can synchronously
        // contact the EventKit daemon. Both remain deferred until refresh.
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func requestAccess() async -> PermissionState {
        let currentStatus = EKEventStore.authorizationStatus(for: .event)
        switch currentStatus {
        case .authorized, .fullAccess:
            permissionState = .allowed
            await refreshCalendarOptions()
            return permissionState
        case .denied:
            permissionState = .denied
            return permissionState
        case .restricted:
            permissionState = .restricted
            return permissionState
        case .writeOnly, .notDetermined:
            break
        @unknown default:
            permissionState = .unavailable
            return permissionState
        }

        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
        permissionState = granted ? .allowed : .denied
        if permissionState == .allowed { await refreshCalendarOptions() }
        return permissionState
    }

    func setSelectedCalendarIdentifiers(_ identifiers: Set<String>) {
        selectedCalendarIdentifiers = identifiers
        hasStoredCalendarSelection = true
        UserDefaults.standard.set(Array(identifiers), forKey: Self.selectedCalendarsKey)
        onStoreChanged?()
    }

    func upcomingEvents() async throws -> [AgendaItem] {
        guard isAuthorized else {
            throw ProviderError.permissionDenied("Calendar access is off. Enable it to add events to Updates.")
        }

        let identifiers = selectedCalendarIdentifiers
        let filtersCalendars = hasStoredCalendarSelection
        return await Task.detached(priority: .utility) {
            // EventKit's fetch API is synchronous and may contact its daemon.
            // Own a short-lived store entirely on this worker so a large or
            // temporarily slow calendar cannot stall SwiftUI's main actor.
            let store = EKEventStore()
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start)
                ?? start.addingTimeInterval(604_800)
            let selectedCalendars: [EKCalendar]? = filtersCalendars
                ? store.calendars(for: .event).filter { identifiers.contains($0.calendarIdentifier) }
                : nil
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            var seenOccurrences = Set<String>()
            var agenda: [AgendaItem] = []

            for event in events {
                let baseIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
                let occurrenceIdentifier = "\(baseIdentifier):\(Int(event.startDate.timeIntervalSinceReferenceDate.rounded()))"
                guard seenOccurrences.insert(occurrenceIdentifier).inserted else { continue }
                let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                agenda.append(AgendaItem(
                    id: occurrenceIdentifier,
                    title: event.title ?? "Untitled event",
                    date: event.startDate,
                    calendarName: event.calendar.title,
                    isPrivate: false,
                    location: location.isEmpty ? nil : location,
                    locationCoordinate: event.structuredLocation?.geoLocation.map {
                        MapRoutePoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                    },
                    endDate: event.endDate,
                    calendarIdentifier: event.calendar.calendarIdentifier,
                    isAllDay: event.isAllDay
                ))

                if agenda.count == 12 { break }
            }
            return agenda
        }.value
    }

    private func refreshCalendarOptions() async {
        availableCalendars = await Task.detached(priority: .utility) {
            let store = EKEventStore()
            return store.calendars(for: .event)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { CalendarDescriptor(id: $0.calendarIdentifier, title: $0.title, sourceName: $0.source.title) }
        }.value
    }

    private var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .fullAccess: return .allowed
        case .writeOnly: return .unknown
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        @unknown default: return .unavailable
        }
    }
}

private nonisolated final class HomeCharacteristicReadBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    nonisolated init(count: Int) {
        remaining = count
    }

    nonisolated func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    nonisolated func completeOne() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        remaining -= 1
        guard remaining <= 0 else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    nonisolated func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
final class HomeKitCameraProvider: NSObject, HomeCameraProviding, HMHomeManagerDelegate, @preconcurrency HMAccessoryDelegate, HMCameraStreamControlDelegate, HMCameraSnapshotControlDelegate {
    private lazy var homeManager: HMHomeManager = {
        let manager = HMHomeManager()
        manager.delegate = self
        return manager
    }()
    private var profiles: [UUID: HMCameraProfile] = [:]
    private var controlServices: [String: HMService] = [:]
    private var controlDescriptors: [String: HomeControl] = [:]
    private var discoveryWaiters: [UUID: CheckedContinuation<HomeKitDiscoveryResult, Error>] = [:]
    private var discoveryTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var hasReceivedInitialHomeUpdate = false
    private var streamWaiters: [UUID: [UUID: CheckedContinuation<HMCameraSource, Error>]] = [:]
    private var snapshotWaiters: [UUID: [UUID: CheckedContinuation<HMCameraSource?, Error>]] = [:]
    private var streamTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var snapshotTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    var onStreamStateChanged: ((UUID, Error?) -> Void)?
    var onControlsChanged: (([HomeControl]) -> Void)?

    override init() {
        super.init()
    }

    func discover() async throws -> HomeKitDiscoveryResult {
        let manager = homeManager
        if manager.authorizationStatus.contains(.restricted) {
            throw ProviderError.permissionDenied("Home access is restricted on this iPad.")
        }

        // Authorization can become available before HMHomeManager has
        // delivered its first homes update. Treating that transient empty
        // array as discovery success made Home appear forgotten after launch.
        if manager.authorizationStatus.contains(.authorized),
           hasReceivedInitialHomeUpdate || !manager.homes.isEmpty {
            hasReceivedInitialHomeUpdate = true
            let result = makeDiscoveryResult()
            return HomeKitDiscoveryResult(
                hasHomes: result.hasHomes,
                cameras: result.cameras,
                controls: await refreshControls()
            )
        }

        if manager.authorizationStatus.contains(.determined),
           !manager.authorizationStatus.contains(.authorized) {
            throw ProviderError.permissionDenied("Home access is off. Enable it in Settings to add cameras.")
        }

        let requestID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                discoveryWaiters[requestID] = continuation
                if Task.isCancelled {
                    cancelDiscoveryWaiter(requestID)
                    return
                }
                discoveryTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.timeoutDiscoveryWaiter(requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelDiscoveryWaiter(requestID)
            }
        }
        return HomeKitDiscoveryResult(
            hasHomes: result.hasHomes,
            cameras: result.cameras,
            controls: await refreshControls()
        )
    }

    func refreshControls() async -> [HomeControl] {
        // HMCharacteristic.value is a cache. Re-read every readable value so
        // changes made by another controller or at the accessory reconcile
        // even when an event notification was missed while Frame was asleep.
        let readableCharacteristics = controlServices.values.flatMap { service in
            service.characteristics.filter {
                $0.properties.contains(HMCharacteristicPropertyReadable)
            }
        }
        await refreshValues(for: readableCharacteristics)
        guard !Task.isCancelled else { return sortedControlDescriptors() }

        for (id, service) in controlServices {
            _ = try? refreshedControl(for: service, id: id)
        }
        return sortedControlDescriptors()
    }

    private func refreshValues(for characteristics: [HMCharacteristic]) async {
        guard !characteristics.isEmpty else { return }
        let batch = HomeCharacteristicReadBatch(count: characteristics.count)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                batch.install(continuation)
                for characteristic in characteristics {
                    characteristic.readValue { _ in batch.completeOne() }
                }
                Task {
                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        return
                    }
                    batch.finish()
                }
            }
        } onCancel: {
            batch.finish()
        }
    }

    func startStream(for id: UUID) async throws -> HMCameraSource {
#if targetEnvironment(simulator)
        // HomeKit's camera transport is not implemented reliably by the iOS
        // Simulator and otherwise produces FigCaptureSourceRemote XPC asserts.
        throw ProviderError.unavailable("Home camera streaming requires a physical iPad.")
#else
        guard let profile = profiles[id], let control = profile.streamControl else {
            throw ProviderError.unavailable("This camera does not provide a live stream.")
        }

        if let source = control.cameraStream {
            return source
        }

        control.delegate = self
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = streamWaiters[id]?.isEmpty ?? true
                streamWaiters[id, default: [:]][requestID] = continuation
                if Task.isCancelled {
                    cancelStreamWaiter(for: id, requestID: requestID)
                    return
                }
                streamTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.timeoutStreamWaiter(for: id, requestID: requestID)
                }
                if shouldStart {
                    control.startStream()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStreamWaiter(for: id, requestID: requestID)
            }
        }
#endif
    }

    func stopStream(for id: UUID) {
        profiles[id]?.streamControl?.stopStream()
        if let waiters = streamWaiters.removeValue(forKey: id) {
            waiters.forEach { requestID, continuation in
                streamTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                continuation.resume(throwing: ProviderError.failed("The stream was stopped."))
            }
        }
    }

    func snapshot(for id: UUID) async throws -> HMCameraSource? {
#if targetEnvironment(simulator)
        // Avoid asking the Simulator's unavailable media pipeline for a HomeKit
        // snapshot. Physical devices continue through the normal HomeKit path.
        throw ProviderError.unavailable("Home camera snapshots require a physical iPad.")
#else
        guard let profile = profiles[id], let control = profile.snapshotControl else { return nil }
        control.delegate = self
        if let snapshot = control.mostRecentSnapshot { return snapshot }

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                snapshotWaiters[id, default: [:]][requestID] = continuation
                if Task.isCancelled {
                    cancelSnapshotWaiter(for: id, requestID: requestID)
                    return
                }
                snapshotTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.timeoutSnapshotWaiter(for: id, requestID: requestID)
                }
                control.takeSnapshot()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSnapshotWaiter(for: id, requestID: requestID)
            }
        }
#endif
    }

    func setLight(id: String, isOn: Bool) async throws -> HomeControl {
        guard let service = controlServices[id], let characteristic = characteristic(ofType: HMCharacteristicTypePowerState, in: service) else {
            throw ProviderError.unavailable("That light is no longer available.")
        }
        try await write(NSNumber(value: isOn), to: characteristic)
        return try refreshedControl(for: service, id: id)
    }

    func setThermostat(id: String, targetTemperature: Double) async throws -> HomeControl {
        guard let service = controlServices[id], let characteristic = characteristic(ofType: HMCharacteristicTypeTargetTemperature, in: service) else {
            throw ProviderError.unavailable("That thermostat is no longer available.")
        }
        let normalized = normalizedThermostatTarget(targetTemperature, for: characteristic)
        try await write(NSNumber(value: normalized.writeValue), to: characteristic)

        var updated = try refreshedControl(for: service, id: id)
        // Some accessories publish the characteristic change asynchronously.
        // Return the accepted value immediately so the UI does not jump back.
        updated.targetTemperature = normalized.celsiusValue
        controlDescriptors[id] = updated
        return updated
    }

    func setSpeaker(id: String, isOn: Bool) async throws -> HomeControl {
        guard let service = controlServices[id] else {
            throw ProviderError.unavailable("That speaker is no longer available.")
        }

        if let power = characteristic(ofType: HMCharacteristicTypePowerState, in: service) {
            try await write(NSNumber(value: isOn), to: power)
        } else if let mute = characteristic(ofType: HMCharacteristicTypeMute, in: service) {
            try await write(NSNumber(value: !isOn), to: mute)
        } else {
            throw ProviderError.unavailable("This speaker does not expose a power control.")
        }

        return try refreshedControl(for: service, id: id)
    }

    func setSpeakerVolume(id: String, volume: Double) async throws -> HomeControl {
        guard let service = controlServices[id], let characteristic = characteristic(ofType: HMCharacteristicTypeVolume, in: service) else {
            throw ProviderError.unavailable("This speaker does not expose volume control.")
        }

        try await write(NSNumber(value: min(max(volume, 0), 100)), to: characteristic)
        return try refreshedControl(for: service, id: id)
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        hasReceivedInitialHomeUpdate = true
        resolveDiscoveryWaiters()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        if status.contains(.authorized) {
            if hasReceivedInitialHomeUpdate || !manager.homes.isEmpty {
                hasReceivedInitialHomeUpdate = true
                resolveDiscoveryWaiters()
            }
        }
        else if status.contains(.determined) || status.contains(.restricted) {
            let error = ProviderError.permissionDenied("Home access is off. Enable it in Settings to add cameras.")
            discoveryWaiters.values.forEach { $0.resume(throwing: error) }
            discoveryWaiters.removeAll()
            discoveryTimeoutTasks.values.forEach { $0.cancel() }
            discoveryTimeoutTasks.removeAll()
        }
    }

    func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        guard let (id, waiters) = streamWaiters.first(where: { profiles[$0.key]?.streamControl === cameraStreamControl }),
              let source = cameraStreamControl.cameraStream else { return }
        waiters.forEach { requestID, continuation in
            streamTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            continuation.resume(returning: source)
        }
        streamWaiters[id] = nil
    }

    func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: Error?) {
        guard let id = profiles.first(where: { $0.value.streamControl === cameraStreamControl })?.key else { return }
        let streamError = error.map { ProviderError.failed($0.localizedDescription) } ?? ProviderError.failed("The camera stream stopped.")
        if let waiters = streamWaiters.removeValue(forKey: id) {
            waiters.forEach { requestID, continuation in
                streamTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                continuation.resume(throwing: streamError)
            }
        }
        onStreamStateChanged?(id, error)
    }

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        guard let updated = makeControl(for: service, accessory: accessory) else { return }
        controlDescriptors[updated.id] = updated
        onControlsChanged?(sortedControlDescriptors())
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let changed = accessory.services.compactMap { makeControl(for: $0, accessory: accessory) }
        guard !changed.isEmpty else { return }
        onControlsChanged?(sortedControlDescriptors())
    }

    private func cancelStreamWaiter(for id: UUID, requestID: UUID) {
        guard var waiters = streamWaiters[id], let continuation = waiters.removeValue(forKey: requestID) else { return }
        streamTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: CancellationError())
        streamWaiters[id] = waiters.isEmpty ? nil : waiters
    }

    private func timeoutStreamWaiter(for id: UUID, requestID: UUID) {
        guard var waiters = streamWaiters[id], let continuation = waiters.removeValue(forKey: requestID) else { return }
        streamTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        streamWaiters[id] = waiters.isEmpty ? nil : waiters
        continuation.resume(throwing: ProviderError.unavailable("The camera stream did not start in time."))
    }

    private func cancelDiscoveryWaiter(_ requestID: UUID) {
        guard let continuation = discoveryWaiters.removeValue(forKey: requestID) else { return }
        discoveryTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: CancellationError())
    }

    private func timeoutDiscoveryWaiter(_ requestID: UUID) {
        guard let continuation = discoveryWaiters.removeValue(forKey: requestID) else { return }
        discoveryTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: ProviderError.unavailable("Home did not respond. Open the Home app once, then try again."))
    }

    private func cancelSnapshotWaiter(for id: UUID, requestID: UUID) {
        guard var waiters = snapshotWaiters[id], let continuation = waiters.removeValue(forKey: requestID) else { return }
        snapshotTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: CancellationError())
        snapshotWaiters[id] = waiters.isEmpty ? nil : waiters
    }

    private func timeoutSnapshotWaiter(for id: UUID, requestID: UUID) {
        guard var waiters = snapshotWaiters[id], let continuation = waiters.removeValue(forKey: requestID) else { return }
        snapshotTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        snapshotWaiters[id] = waiters.isEmpty ? nil : waiters
        continuation.resume(throwing: ProviderError.unavailable("The camera snapshot did not arrive in time."))
    }

    private func registerCharacteristicDelegates(for service: HMService) {
        serviceAccessory(for: service)?.delegate = self
        for characteristic in service.characteristics
        where characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
                && !characteristic.isNotificationEnabled {
            characteristic.enableNotification(true) { _ in }
        }
    }

    private func sortedControlDescriptors() -> [HomeControl] {
        controlDescriptors.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
        guard let id = profiles.first(where: { $0.value.snapshotControl === cameraSnapshotControl })?.key,
              let waiters = snapshotWaiters.removeValue(forKey: id) else { return }
        waiters.keys.forEach { snapshotTimeoutTasks.removeValue(forKey: $0)?.cancel() }
        if let error {
            waiters.values.forEach { $0.resume(throwing: ProviderError.failed(error.localizedDescription)) }
        } else {
            waiters.values.forEach { $0.resume(returning: snapshot) }
        }
    }

    func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        guard let id = profiles.first(where: { $0.value.snapshotControl === cameraSnapshotControl })?.key,
              let waiters = snapshotWaiters.removeValue(forKey: id) else { return }
        waiters.keys.forEach { snapshotTimeoutTasks.removeValue(forKey: $0)?.cancel() }
        waiters.values.forEach { $0.resume(returning: cameraSnapshotControl.mostRecentSnapshot) }
    }

    private func resolveDiscoveryWaiters() {
        guard homeManager.authorizationStatus.contains(.authorized),
              hasReceivedInitialHomeUpdate else { return }
        let result = makeDiscoveryResult()
        discoveryWaiters.values.forEach { $0.resume(returning: result) }
        discoveryWaiters.removeAll()
        discoveryTimeoutTasks.values.forEach { $0.cancel() }
        discoveryTimeoutTasks.removeAll()
    }

    private func makeDiscoveryResult() -> HomeKitDiscoveryResult {
        profiles.removeAll()
        controlServices.removeAll()
        controlDescriptors.removeAll()
        let homes = homeManager.homes
        for home in homes {
            for accessory in home.accessories {
                for profile in accessory.cameraProfiles ?? [] {
                    profiles[profile.uniqueIdentifier] = profile
                }
            }
        }

        let cameras = profiles.values.compactMap { profile -> HomeKitCameraDescriptor? in
            guard let accessory = profile.accessory else { return nil }
            let homeName = homes.first(where: { $0.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) })?.name ?? "Home"
            return HomeKitCameraDescriptor(
                id: profile.uniqueIdentifier,
                name: accessory.name,
                roomName: accessory.room?.name ?? "Unassigned",
                homeName: homeName,
                supportsStream: profile.streamControl != nil,
                supportsSnapshot: profile.snapshotControl != nil
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let controls = homes.flatMap { home in
            home.accessories.flatMap { accessory in
                accessory.services.compactMap { service in
                    makeControl(for: service, accessory: accessory)
                }
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return HomeKitDiscoveryResult(hasHomes: !homes.isEmpty, cameras: cameras, controls: controls)
    }

    private func makeControl(for service: HMService, accessory: HMAccessory?) -> HomeControl? {
        let kind: HomeControl.Kind
        switch service.serviceType {
        case HMServiceTypeLightbulb, HMServiceTypeSwitch:
            guard characteristic(ofType: HMCharacteristicTypePowerState, in: service) != nil else { return nil }
            kind = .light
        case HMServiceTypeThermostat:
            guard characteristic(ofType: HMCharacteristicTypeTargetTemperature, in: service) != nil else { return nil }
            kind = .thermostat
        case HMServiceTypeSpeaker:
            guard characteristic(ofType: HMCharacteristicTypePowerState, in: service) != nil
                    || characteristic(ofType: HMCharacteristicTypeVolume, in: service) != nil
                    || characteristic(ofType: HMCharacteristicTypeMute, in: service) != nil else { return nil }
            kind = .speaker
        default:
            return nil
        }

        let id = service.uniqueIdentifier.uuidString
        controlServices[id] = service
        registerCharacteristicDelegates(for: service)
        let power = characteristic(ofType: HMCharacteristicTypePowerState, in: service)?.value as? NSNumber
        let currentTemperature = temperatureValue(characteristic(ofType: HMCharacteristicTypeCurrentTemperature, in: service)?.value)
        let targetTemperature = temperatureValue(characteristic(ofType: HMCharacteristicTypeTargetTemperature, in: service)?.value)
        let volume = characteristic(ofType: HMCharacteristicTypeVolume, in: service)?.value as? NSNumber
        let mute = characteristic(ofType: HMCharacteristicTypeMute, in: service)?.value as? NSNumber
        let hue = characteristic(ofType: HMCharacteristicTypeHue, in: service)?.value as? NSNumber
        let saturation = characteristic(ofType: HMCharacteristicTypeSaturation, in: service)?.value as? NSNumber
        let brightness = characteristic(ofType: HMCharacteristicTypeBrightness, in: service)?.value as? NSNumber
        let isOn: Bool
        switch kind {
        case .light:
            isOn = power?.boolValue ?? false
        case .thermostat:
            isOn = true
        case .speaker:
            if let power {
                isOn = power.boolValue
            } else if let mute {
                isOn = !mute.boolValue
            } else {
                isOn = (volume?.doubleValue ?? 0) > 0
            }
        }
        let control = HomeControl(
            id: id,
            name: service.name,
            roomName: accessory?.room?.name ?? "Unassigned",
            kind: kind,
            isOn: isOn,
            currentTemperature: currentTemperature,
            targetTemperature: targetTemperature,
            volume: kind == .speaker ? volume?.doubleValue : nil,
            isMuted: kind == .speaker ? mute?.boolValue : nil,
            lightColor: kind == .light ? lightColor(hue: hue, saturation: saturation, brightness: brightness) : nil
        )
        controlDescriptors[id] = control
        return control
    }

    private func serviceAccessory(for service: HMService) -> HMAccessory? {
        homeManager.homes
            .flatMap { $0.accessories }
            .first(where: { accessory in accessory.services.contains(where: { $0.uniqueIdentifier == service.uniqueIdentifier }) })
    }

    private func refreshedControl(for service: HMService, id: String) throws -> HomeControl {
        if let control = makeControl(for: service, accessory: serviceAccessory(for: service)) ?? controlDescriptors[id] {
            return control
        }
        throw ProviderError.unavailable("That Home control is no longer available.")
    }

    private func characteristic(ofType type: String, in service: HMService) -> HMCharacteristic? {
        service.characteristics.first(where: { $0.characteristicType == type })
    }

    private func lightColor(hue: NSNumber?, saturation: NSNumber?, brightness: NSNumber?) -> HomeControl.LightColor? {
        guard let hue, let saturation else { return nil }
        return HomeControl.LightColor(
            hue: min(max(hue.doubleValue / 360, 0), 1),
            saturation: min(max(saturation.doubleValue / 100, 0), 1),
            brightness: min(max((brightness?.doubleValue ?? 100) / 100, 0.2), 1)
        )
    }

    private func temperatureValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private func normalizedThermostatTarget(
        _ celsiusValue: Double,
        for characteristic: HMCharacteristic
    ) -> (writeValue: Double, celsiusValue: Double) {
        let metadata = characteristic.metadata
        let usesFahrenheit = metadata?.units == HMCharacteristicMetadataUnitsFahrenheit
        let proposedValue = usesFahrenheit
            ? Measurement(value: celsiusValue, unit: UnitTemperature.celsius)
                .converted(to: .fahrenheit)
                .value
            : celsiusValue
        let defaultMinimum = usesFahrenheit ? 41.0 : 5.0
        let defaultMaximum = usesFahrenheit ? 86.0 : 30.0
        let minimum = metadata?.minimumValue?.doubleValue ?? defaultMinimum
        let maximum = metadata?.maximumValue?.doubleValue ?? defaultMaximum
        let step = max(metadata?.stepValue?.doubleValue ?? (usesFahrenheit ? 1.0 : 0.5), 0.001)
        let boundedValue = min(max(proposedValue, minimum), maximum)
        let steppedValue = minimum + ((boundedValue - minimum) / step).rounded() * step
        let writeValue = min(max(steppedValue, minimum), maximum)
        let acceptedCelsius = usesFahrenheit
            ? Measurement(value: writeValue, unit: UnitTemperature.fahrenheit)
                .converted(to: .celsius)
                .value
            : writeValue
        return (writeValue, acceptedCelsius)
    }

    private func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: ProviderError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private nonisolated final class LowFrequencyFaceMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.raaghavt.frame.mirror.face", qos: .utility)
    var onPresenceChange: (@Sendable (Bool) -> Void)?

    private let samplingInterval: TimeInterval = 1
    private let presenceHeartbeatInterval: TimeInterval = 5
    private var lastSampleTime: TimeInterval = 0
    private var lastPresenceHeartbeatTime: TimeInterval = 0
    private var consecutivePresentSamples = 0
    private var consecutiveAbsentSamples = 0
    private var isPresenceConfirmed = false

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSampleTime >= samplingInterval else { return }
        lastSampleTime = now

        let faceIsPresent = metadataObjects
            .compactMap { $0 as? AVMetadataFaceObject }
            .contains { face in
                let bounds = face.bounds
                let area = bounds.width * bounds.height
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                return area >= 0.015
                    && (0.04 ... 0.96).contains(center.x)
                    && (0.04 ... 0.96).contains(center.y)
            }
        if faceIsPresent {
            consecutivePresentSamples += 1
            consecutiveAbsentSamples = 0

            if consecutivePresentSamples >= 2 {
                let presenceChanged = !isPresenceConfirmed
                isPresenceConfirmed = true
                if presenceChanged || now - lastPresenceHeartbeatTime >= presenceHeartbeatInterval {
                    lastPresenceHeartbeatTime = now
                    onPresenceChange?(true)
                }
            }
        } else {
            consecutiveAbsentSamples += 1
            consecutivePresentSamples = 0

            if consecutiveAbsentSamples >= 3, isPresenceConfirmed {
                isPresenceConfirmed = false
                onPresenceChange?(false)
            }
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            lastSampleTime = 0
            lastPresenceHeartbeatTime = 0
            consecutivePresentSamples = 0
            consecutiveAbsentSamples = 0
            isPresenceConfirmed = false
        }
    }
}

// Render the same sample buffers used for liveness without attaching an
// AVCaptureVideoPreviewLayer to the capture session. The preview layer's
// session detach/reattach path was both crashing and intermittently ceasing to
// display even while the data output continued receiving frames.
nonisolated final class MirrorPreviewRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var videoRenderer: AVSampleBufferVideoRenderer?

    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        let changed = displayLayer !== layer
        displayLayer = layer
        videoRenderer = layer.sampleBufferRenderer
        lock.unlock()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.clear.cgColor
#if DEBUG
        print("[FrameMirror] display attach layer=\(ObjectIdentifier(layer)) changed=\(changed)")
#endif
        if changed {
            layer.sampleBufferRenderer.flush(
                removingDisplayedImage: true,
                completionHandler: nil
            )
        }
    }

    @MainActor
    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        let renderer = displayLayer === layer ? videoRenderer : nil
        if displayLayer === layer {
            displayLayer = nil
            videoRenderer = nil
        }
        lock.unlock()
#if DEBUG
        print("[FrameMirror] display detach layer=\(ObjectIdentifier(layer))")
#endif
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func reset() {
        lock.lock()
        let renderer = videoRenderer
        lock.unlock()
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let renderer = videoRenderer
        lock.unlock()
        guard let renderer else { return }
        if renderer.status == .failed {
#if DEBUG
            print("[FrameMirror] display renderer failed error=\(String(describing: renderer.error))")
#endif
            renderer.flush()
        }
        // Capture timestamps are useful for recording but not for a zero-latency
        // mirror. Displaying immediately replaces any queued image, preventing a
        // renderer timeline/backpressure stall from leaving the camera active
        // while the visible layer goes empty.
        Self.markForImmediateDisplay(sampleBuffer)
        renderer.enqueue(sampleBuffer)
    }

    private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

// AVCaptureSession.isRunning can remain true even when the camera pipeline has
// stopped delivering frames. A tiny video-output delegate gives Mirror a real
// liveness signal without retaining or processing any image buffers.
nonisolated final class MirrorFrameLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var monitoringStartedAt: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var monitoringGeneration: Int?
    private var hasPublishedFirstFrame = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func begin(generation: Int) {
        lock.lock()
        monitoringStartedAt = now()
        lastFrameTime = nil
        monitoringGeneration = generation
        hasPublishedFirstFrame = false
        lock.unlock()
    }

    func noteFrame() -> Int? {
        lock.lock()
        lastFrameTime = now()
        let generation: Int?
        if !hasPublishedFirstFrame, let monitoringGeneration {
            hasPublishedFirstFrame = true
            generation = monitoringGeneration
        } else {
            generation = nil
        }
        lock.unlock()
        return generation
    }

    func stop() {
        lock.lock()
        monitoringStartedAt = nil
        lastFrameTime = nil
        monitoringGeneration = nil
        hasPublishedFirstFrame = false
        lock.unlock()
    }

    func frameAge() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let monitoringStartedAt else { return nil }
        return now() - (lastFrameTime ?? monitoringStartedAt)
    }
}

private nonisolated final class MirrorFrameHeartbeatDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.raaghavt.frame.mirror.heartbeat", qos: .utility)
    var onFirstFrame: (@Sendable (Int) -> Void)?
    private let liveness = MirrorFrameLiveness()
    private let renderer: MirrorPreviewRenderer

    init(renderer: MirrorPreviewRenderer) {
        self.renderer = renderer
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        renderer.enqueue(sampleBuffer)
        if let generation = liveness.noteFrame() {
            onFirstFrame?(generation)
        }
    }

    nonisolated func beginMonitoring(generation: Int) {
        renderer.reset()
        liveness.begin(generation: generation)
    }

    nonisolated func stopMonitoring() {
        liveness.stop()
        renderer.reset()
    }

    nonisolated func frameAge() -> TimeInterval? {
        liveness.frameAge()
    }
}

private nonisolated final class MirrorPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Int64, Data?) -> Void
    private var capturedData: Data?
    private var processingFailed = false

    init(completion: @escaping (Int64, Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        processingFailed = error != nil
        capturedData = error == nil ? photo.fileDataRepresentation() : nil
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        completion(
            resolvedSettings.uniqueID,
            error == nil && !processingFailed ? capturedData : nil
        )
    }
}

private nonisolated final class MirrorPhotoCaptureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var delegates: [Int64: MirrorPhotoCaptureDelegate] = [:]

    nonisolated func register(_ delegate: MirrorPhotoCaptureDelegate, for uniqueID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard delegates.isEmpty else { return false }
        delegates[uniqueID] = delegate
        return true
    }

    nonisolated func finish(_ uniqueID: Int64) {
        lock.lock()
        delegates[uniqueID] = nil
        lock.unlock()
    }
}

// This state is touched only by sessionQueue. Keeping the desired session
// mode beside the capture commands lets delayed recording callbacks avoid
// stopping a newer camera start.
private nonisolated final class MirrorSessionQueueState: @unchecked Sendable {
    private let lock = NSLock()
    private var startGeneration = 0
    private var storedDesiredRunning = false
    private var storedShouldStopAfterRecordingFinishes = false
    private var expectedStopNotifications = 0

    var desiredRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDesiredRunning
    }

    var shouldStopAfterRecordingFinishes: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedShouldStopAfterRecordingFinishes
        }
        set {
            lock.lock()
            storedShouldStopAfterRecordingFinishes = newValue
            lock.unlock()
        }
    }

    func requestStart(generation: Int) {
        lock.lock()
        startGeneration = generation
        storedDesiredRunning = true
        storedShouldStopAfterRecordingFinishes = false
        lock.unlock()
    }

    func requestStop(generation: Int) {
        lock.lock()
        startGeneration = generation
        storedDesiredRunning = false
        lock.unlock()
    }

    func shouldRun(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDesiredRunning && startGeneration == generation
    }

    func markExpectedStop() {
        lock.lock()
        expectedStopNotifications += 1
        lock.unlock()
    }

    func consumeExpectedStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expectedStopNotifications > 0 else { return false }
        expectedStopNotifications -= 1
        return true
    }
}

// AVCaptureSession construction can synchronously contact the camera daemon.
// Own the graph outside the main-actor provider and create it only from the
// serial session queue. Stop/background calls use existing() so they never
// build an unused capture graph merely to tear it down.
private nonisolated final class MirrorCaptureGraph: @unchecked Sendable {
    let session = AVCaptureSession()
    let faceMetadataOutput = AVCaptureMetadataOutput()
    let frameHeartbeatOutput = AVCaptureVideoDataOutput()
    let photoOutput = AVCapturePhotoOutput()
    let movieOutput = AVCaptureMovieFileOutput()

    var existingPhotoOutput: AVCapturePhotoOutput? { photoOutput }
    var existingMovieOutput: AVCaptureMovieFileOutput? { movieOutput }
}

private nonisolated final class MirrorCaptureGraphStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGraph: MirrorCaptureGraph?

    func existing() -> MirrorCaptureGraph? {
        lock.lock()
        defer { lock.unlock() }
        return storedGraph
    }

    func getOrCreate() -> MirrorCaptureGraph {
        lock.lock()
        defer { lock.unlock() }
        if let storedGraph { return storedGraph }
        let graph = MirrorCaptureGraph()
        storedGraph = graph
        return graph
    }

    func replaceWithNewGraph() -> (old: MirrorCaptureGraph?, new: MirrorCaptureGraph) {
        // AVCaptureSession construction can synchronously talk to media-serverd.
        // Callers must invoke this from the provider's serial session queue.
        let newGraph = MirrorCaptureGraph()
        lock.lock()
        let oldGraph = storedGraph
        storedGraph = newGraph
        lock.unlock()
        return (oldGraph, newGraph)
    }
}

@MainActor
final class AVFoundationMirrorProvider: NSObject, MirrorProviding, AVCaptureFileOutputRecordingDelegate {
    // Reading this property is part of SwiftUI view construction, so it must
    // never create AVCaptureSession on the main actor. The graph is prepared on
    // sessionQueue and then published for the preview to attach before startup.
    var session: AVCaptureSession? { captureGraphStore.existing()?.session }
    let previewRenderer = MirrorPreviewRenderer()
    private(set) var status: MirrorPermissionState = .stopped
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    var onStatusChange: (() -> Void)?
    var onSessionChange: (() -> Void)?
    var onFacePresenceChange: ((Bool) -> Void)?
    var onRecordingChange: (() -> Void)?
    var onCaptureResult: ((MirrorCaptureResult) -> Void)?
    private let sessionQueue = DispatchQueue(label: "com.raaghavt.frame.mirror")
    private let captureGraphStore = MirrorCaptureGraphStore()
    private let faceMetadataDelegate = LowFrequencyFaceMetadataDelegate()
    private lazy var frameHeartbeatDelegate = MirrorFrameHeartbeatDelegate(
        renderer: previewRenderer
    )
    private let photoCaptureRegistry = MirrorPhotoCaptureRegistry()
    private let sessionQueueState = MirrorSessionQueueState()
    private var lastPublishedFacePresence = false
    private var mirrorRequested = false
    private var attentionMonitoringRequested = false
    private var attentionStartInFlight = false
    private var startRequestID = 0
    private var recordingStartPending = false
    private var recordingStartGeneration = 0
    private var recordingOutputURL: URL?
    private var photoCapturePending = false
    private var startWatchdogTask: Task<Void, Never>?
    private var frameWatchdogTask: Task<Void, Never>?
    private var frameRestartGuardTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryStabilityTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var frameRestartInFlight = false
    private var rebuildCaptureGraphOnNextStart = false
    private var firstFrameRequestID: Int?
    private var sessionObservers: [NSObjectProtocol] = []
    private weak var observedSession: AVCaptureSession?

    private func mirrorDebug(_ message: String) {
#if DEBUG
        print("[FrameMirror] \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(message)")
#endif
    }

    override init() {
        super.init()
        faceMetadataDelegate.onPresenceChange = { [weak self] isPresent in
            Task { @MainActor [weak self] in
                self?.publishFacePresence(isPresent)
            }
        }
        frameHeartbeatDelegate.onFirstFrame = { [weak self] generation in
            Task { @MainActor [weak self] in
                self?.handleFirstMirrorFrame(for: generation)
            }
        }
    }

    deinit {
        startWatchdogTask?.cancel()
        frameWatchdogTask?.cancel()
        frameRestartGuardTask?.cancel()
        recoveryTask?.cancel()
        recoveryStabilityTask?.cancel()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func installSessionObserversIfNeeded(for session: AVCaptureSession) {
        if observedSession === session, !sessionObservers.isEmpty { return }
        removeSessionObservers()
        observedSession = session
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let errorCode = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
                Task { @MainActor [weak self] in
                    self?.handleSessionRuntimeError(code: errorCode)
                }
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionInterruption()
                }
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartCaptureAfterSystemEvent()
                }
            },
            center.addObserver(
                forName: AVCaptureSession.didStopRunningNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverFromUnexpectedSessionStop()
                }
            }
        ]
    }

    private func removeSessionObservers() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
        observedSession = nil
    }

    private func handleSessionRuntimeError(code: Int?) {
        recordingStartGeneration &+= 1
        recordingStartPending = false
        publishRecording(startedAt: nil)

        if mirrorRequested {
            let mediaServicesWereReset = code == AVError.Code.mediaServicesWereReset.rawValue
            scheduleCaptureRecovery(
                forceSessionRestart: true,
                rebuildCaptureGraph: mediaServicesWereReset
            )
        } else {
            attentionStartInFlight = false
            publishFacePresence(false)
        }
    }

    private func handleSessionInterruption() {
        recordingStartGeneration &+= 1
        recordingStartPending = false
        publishRecording(startedAt: nil)
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        if mirrorRequested {
            updateStatus(.requesting)
        }
    }

    private func restartCaptureAfterSystemEvent() {
        guard mirrorRequested || attentionMonitoringRequested else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        startRequestID &+= 1
        let requestID = startRequestID
        let publishesMirrorStatus = mirrorRequested
        attentionStartInFlight = !publishesMirrorStatus
        configureAndStart(
            requestID: requestID,
            publishesMirrorStatus: publishesMirrorStatus,
            attentionOnly: !mirrorRequested
        )
    }

    private func recoverFromUnexpectedSessionStop() {
        if sessionQueueState.consumeExpectedStop() {
            mirrorDebug("didStopRunning expected")
            return
        }
        mirrorDebug("didStopRunning unexpected requested=\(mirrorRequested) restartInFlight=\(frameRestartInFlight)")
        guard mirrorRequested, !frameRestartInFlight else { return }
        scheduleCaptureRecovery()
    }

    private func scheduleCaptureRecovery(
        forceSessionRestart: Bool = false,
        rebuildCaptureGraph: Bool = false
    ) {
        guard mirrorRequested, recoveryTask == nil else { return }
        guard recoveryAttempt < 2 else {
            // A transient camera-service failure must not require a user tap.
            // After two quick restarts, pause briefly and replace the entire
            // graph. Keep doing this only while the visible Mirror is requested.
            updateStatus(.requesting)
            recoveryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self,
                      mirrorRequested,
                      UIApplication.shared.applicationState == .active,
                      !Task.isCancelled else { return }
                recoveryTask = nil
                recoveryAttempt = 0
                startRequestID &+= 1
                prepareMirrorSessionForPreview(
                    requestID: startRequestID,
                    replacingCaptureGraph: true
                )
            }
            return
        }
        recoveryAttempt += 1
        frameRestartInFlight = forceSessionRestart
        let shouldRebuildGraph = rebuildCaptureGraph
            || (forceSessionRestart && recoveryAttempt >= 2)
        updateStatus(.requesting)
        let delay = Duration.milliseconds(450 * recoveryAttempt)
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, mirrorRequested, !Task.isCancelled else { return }
            recoveryTask = nil
            startRequestID &+= 1
            let requestID = startRequestID
            if shouldRebuildGraph {
                prepareMirrorSessionForPreview(
                    requestID: requestID,
                    replacingCaptureGraph: true
                )
            } else if forceSessionRestart {
                restartRunningCaptureSession(requestID: requestID)
            } else {
                configureAndStart(
                    requestID: requestID,
                    publishesMirrorStatus: true,
                    attentionOnly: false
                )
            }
        }
    }

    private func restartRunningCaptureSession(requestID: Int) {
        let queueState = sessionQueueState
        let graphStore = captureGraphStore
        sessionQueue.async { [weak self] in
            guard queueState.desiredRunning,
                  let graph = graphStore.existing() else { return }
            if graph.session.isRunning {
                queueState.markExpectedStop()
                graph.session.stopRunning()
            }
            guard queueState.desiredRunning else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      mirrorRequested,
                      startRequestID == requestID else { return }
                configureAndStart(
                    requestID: requestID,
                    publishesMirrorStatus: true,
                    attentionOnly: false
                )
            }
        }
    }

    private func startFrameWatchdog() {
        frameWatchdogTask?.cancel()
        frameWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }

            while let self,
                  mirrorRequested,
                  status == .live,
                  !Task.isCancelled {
                if UIApplication.shared.applicationState == .active,
                   !isRecording,
                   !recordingStartPending,
                   !photoCapturePending,
                   let frameAge = frameHeartbeatDelegate.frameAge(),
                   frameAge >= 4 {
                    scheduleCaptureRecovery(forceSessionRestart: true)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func startWatchdog(for requestID: Int) {
        startWatchdogTask?.cancel()
        startWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard let self,
                  mirrorRequested,
                  startRequestID == requestID,
                  status == .requesting else { return }
            // A running session is not proof that its capture graph is delivering
            // frames. Keep the startup cover visible and perform a bounded restart
            // if the first heartbeat never arrives.
            scheduleCaptureRecovery(forceSessionRestart: true)
        }
    }

    private func handleFirstMirrorFrame(for requestID: Int) {
        guard mirrorRequested,
              startRequestID == requestID,
              status == .requesting else { return }
        firstFrameRequestID = requestID
        publishMirrorLiveIfReady()
    }

    private func publishMirrorLiveIfReady() {
        guard mirrorRequested,
              status == .requesting,
              firstFrameRequestID == startRequestID else { return }
        updateStatus(.live)
    }

    private func prepareMirrorSessionForPreview(
        requestID: Int,
        replacingCaptureGraph: Bool = false
    ) {
        guard mirrorRequested, startRequestID == requestID else { return }
        if replacingCaptureGraph {
            // The old session's intentional stop emits didStopRunning. Do not
            // treat that notification as another failure while its replacement
            // is being prepared.
            frameRestartInFlight = true
        }
        firstFrameRequestID = nil
        updateStatus(.requesting)

        let graphStore = captureGraphStore
        let heartbeatDelegate = frameHeartbeatDelegate
        let metadataDelegate = faceMetadataDelegate
        let queueState = sessionQueueState
        let shouldMonitorAttention = attentionMonitoringRequested
        queueState.requestStart(generation: requestID)
        sessionQueue.async { [weak self] in
            guard queueState.shouldRun(generation: requestID) else { return }
            let graph: MirrorCaptureGraph
            if replacingCaptureGraph {
                heartbeatDelegate.stopMonitoring()
                graph = graphStore.getOrCreate()
                if graph.existingMovieOutput?.isRecording == true {
                    graph.existingMovieOutput?.stopRecording()
                }
                if graph.session.isRunning {
                    queueState.markExpectedStop()
                    graph.session.stopRunning()
                }
                Self.removeUserCaptureOutputs(from: graph)
            } else {
                graph = graphStore.getOrCreate()
            }
            guard queueState.shouldRun(generation: requestID) else { return }

            do {
                try Self.prepareMirrorCaptureGraph(
                    graph,
                    heartbeatDelegate: heartbeatDelegate,
                    metadataDelegate: metadataDelegate,
                    monitorAttention: shouldMonitorAttention
                )
            } catch {
                self?.publishMirrorStartFailure(for: requestID)
                return
            }
            guard queueState.shouldRun(generation: requestID) else { return }
            heartbeatDelegate.beginMonitoring(generation: requestID)
#if DEBUG
            print("[FrameMirror] \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) startRunning begin generation=\(requestID)")
#endif
            if !graph.session.isRunning { graph.session.startRunning() }
#if DEBUG
            print("[FrameMirror] \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) startRunning end running=\(graph.session.isRunning) generation=\(requestID)")
#endif
            guard queueState.shouldRun(generation: requestID) else {
                if graph.session.isRunning {
                    queueState.markExpectedStop()
                    graph.session.stopRunning()
                }
                return
            }
            if graph.session.isRunning {
                self?.publishSessionStarted(for: requestID, session: graph.session)
            } else {
                self?.publishMirrorStartFailure(for: requestID)
            }
        }
    }

    func previewDidAttach(to session: AVCaptureSession) {}

    func previewDidBecomeReady(to session: AVCaptureSession) {
        // Rendering is driven by AVSampleBufferDisplayLayer rather than an
        // AVCaptureVideoPreviewLayer connection readiness callback.
    }

    func start() {
#if targetEnvironment(simulator)
        // The iPad simulator does not provide a dependable local camera
        // pipeline. Avoid starting AVCaptureSession here; the system can emit
        // FigCaptureSourceRemote assertions even though the app is otherwise
        // healthy. Mirror remains available on a physical iPad.
        updateStatus(.unavailable)
#else
        mirrorDebug("start status=\(String(describing: status))")
        mirrorRequested = true
        attentionStartInFlight = false
        guard status != .live, status != .requesting else { return }
        startRequestID &+= 1
        let requestID = startRequestID
        let shouldReplaceCaptureGraph = rebuildCaptureGraphOnNextStart
        rebuildCaptureGraphOnNextStart = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            prepareMirrorSessionForPreview(
                requestID: requestID,
                replacingCaptureGraph: shouldReplaceCaptureGraph
            )
        case .notDetermined:
            updateStatus(.requesting)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.startRequestID == requestID else { return }
                    if granted {
                        self.prepareMirrorSessionForPreview(
                            requestID: requestID,
                            replacingCaptureGraph: shouldReplaceCaptureGraph
                        )
                    }
                    else { self.updateStatus(.denied) }
                }
            }
        case .denied: updateStatus(.denied)
        case .restricted: updateStatus(.unavailable)
        @unknown default: updateStatus(.unavailable)
        }
#endif
    }

    func stop() {
        mirrorDebug("stop status=\(String(describing: status))")
        let stoppedAfterFailedStart = status == .unavailable || status == .requesting
        recordingStartGeneration &+= 1
        recordingStartPending = false
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        firstFrameRequestID = nil
        frameWatchdogTask?.cancel()
        frameWatchdogTask = nil
        frameRestartGuardTask?.cancel()
        frameRestartGuardTask = nil
        frameRestartInFlight = false
        frameHeartbeatDelegate.stopMonitoring()
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryStabilityTask?.cancel()
        recoveryStabilityTask = nil
        recoveryAttempt = 0
        if stoppedAfterFailedStart {
            rebuildCaptureGraphOnNextStart = true
        }
        mirrorRequested = false
        startRequestID &+= 1
        sessionQueueState.requestStop(generation: startRequestID)
        updateStatus(.stopped)
        let graphStore = captureGraphStore
        sessionQueue.async {
            guard let graph = graphStore.existing() else { return }
            if graph.existingMovieOutput?.isRecording == true {
                graph.existingMovieOutput?.stopRecording()
            }
        }
        guard !attentionMonitoringRequested else {
            reconfigureForAttentionOnly()
            return
        }
        stopCaptureSession()
    }

    func retry() {
#if targetEnvironment(simulator)
        updateStatus(.unavailable)
#else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            start()
            return
        }
        startWatchdogTask?.cancel()
        frameWatchdogTask?.cancel()
        recoveryTask?.cancel()
        recoveryStabilityTask?.cancel()
        firstFrameRequestID = nil
        recoveryAttempt = 0
        rebuildCaptureGraphOnNextStart = false
        mirrorRequested = true
        attentionStartInFlight = false
        startRequestID &+= 1
        prepareMirrorSessionForPreview(
            requestID: startRequestID,
            replacingCaptureGraph: true
        )
#endif
    }

    func capturePhoto() -> Bool {
        guard status == .live,
              !isRecording,
              !recordingStartPending,
              !photoCapturePending else { return false }
        photoCapturePending = true
        let rotationAngle = currentCaptureRotationAngle()
        let registry = photoCaptureRegistry
        let graphStore = captureGraphStore

        sessionQueue.async { [weak self] in
            guard let graph = graphStore.existing() else { return }
            guard graph.session.isRunning else {
                self?.finishPhotoCapture(nil)
                return
            }
            let photoOutput = graph.photoOutput
            if !graph.session.outputs.contains(where: { $0 === photoOutput }) {
                graph.session.beginConfiguration()
                if graph.session.canAddOutput(photoOutput) {
                    graph.session.addOutput(photoOutput)
                    photoOutput.maxPhotoQualityPrioritization = .balanced
                }
                graph.session.commitConfiguration()
            }
            guard graph.session.outputs.contains(where: { $0 === photoOutput }) else {
                self?.finishPhotoCapture(nil)
                return
            }
            let settings = AVCapturePhotoSettings()
            let delegate = MirrorPhotoCaptureDelegate { uniqueID, data in
                registry.finish(uniqueID)
                self?.finishPhotoCapture(data)
            }
            guard registry.register(delegate, for: settings.uniqueID) else {
                self?.finishPhotoCapture(nil)
                return
            }
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            // Keep validation, connection mutation, and capture issuance on the
            // same serial executor as session start/stop/configuration.
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
        return true
    }

    func startRecording() -> Bool {
        guard status == .live,
              !isRecording,
              !recordingStartPending,
              recordingOutputURL == nil else { return false }
        recordingStartGeneration &+= 1
        let generation = recordingStartGeneration
        recordingStartPending = true
        let rotationAngle = currentCaptureRotationAngle()
        let graphStore = captureGraphStore
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-mirror-\(UUID().uuidString).mov")
        recordingOutputURL = outputURL
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let graph = graphStore.existing(), graph.session.isRunning else {
                self.publishRecordingStartFailure(for: generation, outputURL: outputURL)
                return
            }
            let movieOutput = graph.movieOutput
            if !graph.session.outputs.contains(where: { $0 === movieOutput }) {
                graph.session.beginConfiguration()
                if graph.session.canAddOutput(movieOutput) {
                    graph.session.addOutput(movieOutput)
                }
                graph.session.commitConfiguration()
            }
            guard graph.session.outputs.contains(where: { $0 === movieOutput }),
                  !movieOutput.isRecording else {
                self.publishRecordingStartFailure(for: generation, outputURL: outputURL)
                return
            }
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }
        return true
    }

    func stopRecording() {
        recordingStartGeneration &+= 1
        recordingStartPending = false
        let graphStore = captureGraphStore
        sessionQueue.async {
            guard let graph = graphStore.existing() else { return }
            if graph.existingMovieOutput?.isRecording == true {
                graph.existingMovieOutput?.stopRecording()
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor [weak self] in
            guard let self, recordingOutputURL == fileURL else { return }
            guard recordingStartPending else {
                stopStaleRecordingOutput(output)
                return
            }
            recordingStartPending = false
            publishRecording(startedAt: Date())
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let recordingSucceeded: Bool
        if let error {
            recordingSucceeded = (error as NSError)
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        } else {
            recordingSucceeded = true
        }

        Task { @MainActor [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            guard recordingOutputURL == outputFileURL else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            recordingOutputURL = nil
            recordingStartPending = false
            publishRecording(startedAt: nil)
            finishDeferredSessionStopAfterRecording()

            guard recordingSucceeded else {
                try? FileManager.default.removeItem(at: outputFileURL)
                onCaptureResult?(.failed("The video recording could not be completed."))
                return
            }
            Self.saveVideo(at: outputFileURL) { [weak self] saved in
                if !saved {
                    try? FileManager.default.removeItem(at: outputFileURL)
                }
                self?.publishCaptureResult(
                    saved ? .videoSaved : .failed("The video could not be saved to Photos.")
                )
            }
        }
    }

    private func finishDeferredSessionStopAfterRecording() {
        let queueState = sessionQueueState
        let graphStore = captureGraphStore
        sessionQueue.async {
            guard queueState.shouldStopAfterRecordingFinishes else { return }
            queueState.shouldStopAfterRecordingFinishes = false
            guard let graph = graphStore.existing() else { return }
            if !queueState.desiredRunning, graph.session.isRunning {
                queueState.markExpectedStop()
                graph.session.stopRunning()
            }
            if !queueState.desiredRunning {
                Self.removeUserCaptureOutputs(from: graph)
            }
        }
    }

    private func stopStaleRecordingOutput(_ output: AVCaptureFileOutput) {
        sessionQueue.async {
            if output.isRecording { output.stopRecording() }
        }
    }

    private nonisolated func publishRecordingStartFailure(
        for generation: Int,
        outputURL: URL
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  recordingOutputURL == outputURL else { return }
            let shouldReportFailure = recordingStartGeneration == generation
            recordingStartPending = false
            recordingOutputURL = nil
            publishRecording(startedAt: nil)
            if shouldReportFailure {
                onCaptureResult?(.failed("Video recording could not start."))
            }
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    func setAttentionMonitoring(_ enabled: Bool) {
#if targetEnvironment(simulator)
        attentionMonitoringRequested = false
#else
        if attentionMonitoringRequested == enabled {
            if enabled,
               !mirrorRequested,
               !attentionStartInFlight,
               captureGraphStore.existing()?.session.isRunning != true,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                startRequestID &+= 1
                attentionStartInFlight = true
                configureAndStart(
                    requestID: startRequestID,
                    publishesMirrorStatus: false,
                    attentionOnly: !mirrorRequested
                )
            }
            return
        }

        attentionMonitoringRequested = enabled
        if enabled {
            // Attention monitoring never prompts on its own. Camera access is
            // requested only through the visible Mirror interaction.
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            if mirrorRequested { return }
            startRequestID &+= 1
            attentionStartInFlight = true
            configureAndStart(
                requestID: startRequestID,
                publishesMirrorStatus: false,
                attentionOnly: !mirrorRequested
            )
        } else {
            attentionStartInFlight = false
            faceMetadataDelegate.reset()
            publishFacePresence(false)
            guard !mirrorRequested else { return }
            startRequestID &+= 1
            stopCaptureSession()
        }
#endif
    }

    func resetAttentionBaseline() {
        faceMetadataDelegate.reset()
        publishFacePresence(false)
    }

    private func stopCaptureSession() {
        faceMetadataDelegate.reset()
        publishFacePresence(false)
        let queueState = sessionQueueState
        let graphStore = captureGraphStore
        queueState.requestStop(generation: startRequestID)
        sessionQueue.async {
            guard let graph = graphStore.existing() else { return }
            if graph.existingMovieOutput?.isRecording == true {
                queueState.shouldStopAfterRecordingFinishes = true
                graph.existingMovieOutput?.stopRecording()
                return
            }
            if graph.session.isRunning {
                queueState.markExpectedStop()
                graph.session.stopRunning()
            }
            Self.removeUserCaptureOutputs(from: graph)
        }
    }

    private nonisolated static func removeUserCaptureOutputs(from graph: MirrorCaptureGraph) {
        let outputs: [AVCaptureOutput] = [graph.photoOutput, graph.movieOutput]
        guard outputs.contains(where: { graph.session.outputs.contains($0) }) else { return }
        graph.session.beginConfiguration()
        outputs.forEach { candidate in
            if graph.session.outputs.contains(candidate) {
                graph.session.removeOutput(candidate)
            }
        }
        graph.session.commitConfiguration()
    }

    private nonisolated static func prepareMirrorCaptureGraph(
        _ graph: MirrorCaptureGraph,
        heartbeatDelegate: MirrorFrameHeartbeatDelegate,
        metadataDelegate: LowFrequencyFaceMetadataDelegate,
        monitorAttention: Bool
    ) throws {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            throw ProviderError.unavailable("The front camera is unavailable.")
        }

        let session = graph.session
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.position == .front }) {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw ProviderError.unavailable("The front camera could not be connected.")
            }
            session.addInput(input)
        }

        let heartbeatOutput = graph.frameHeartbeatOutput
        heartbeatOutput.alwaysDiscardsLateVideoFrames = true
        heartbeatOutput.setSampleBufferDelegate(
            heartbeatDelegate,
            queue: heartbeatDelegate.queue
        )
        if !session.outputs.contains(where: { $0 === heartbeatOutput }) {
            guard session.canAddOutput(heartbeatOutput) else {
                throw ProviderError.unavailable("Camera frame monitoring could not be connected.")
            }
            session.addOutput(heartbeatOutput)
        }
        if let connection = heartbeatOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        let metadataOutput = graph.faceMetadataOutput
        metadataOutput.setMetadataObjectsDelegate(
            metadataDelegate,
            queue: metadataDelegate.queue
        )
        if monitorAttention,
           !session.outputs.contains(where: { $0 === metadataOutput }),
           session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
        }
        configureFrameRate(for: device, attentionOnly: false)
    }

    private func configureAndStart(
        requestID: Int,
        publishesMirrorStatus: Bool,
        attentionOnly: Bool
    ) {
        if publishesMirrorStatus {
            updateStatus(.requesting)
        }
        let queueState = sessionQueueState
        let graphStore = captureGraphStore
        let metadataDelegate = faceMetadataDelegate
        let heartbeatDelegate = frameHeartbeatDelegate
        let shouldMonitorAttention = attentionMonitoringRequested
        queueState.requestStart(generation: requestID)

        // AVCaptureSession.startRunning() is synchronous and may take a noticeable
        // amount of time while the camera daemon wakes up. Keep configuration,
        // start, and stop on the same serial queue so the main actor never waits
        // for the camera service and no configuration races with the preview.
        sessionQueue.async { [weak self] in
            guard queueState.shouldRun(generation: requestID) else { return }
            let graph = graphStore.getOrCreate()
            let session = graph.session
            let faceMetadataOutput = graph.faceMetadataOutput
            let frameHeartbeatOutput = graph.frameHeartbeatOutput
            faceMetadataOutput.setMetadataObjectsDelegate(metadataDelegate, queue: metadataDelegate.queue)
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                if publishesMirrorStatus {
                    self?.publishMirrorStartFailure(for: requestID)
                } else {
                    self?.publishAttentionCaptureResult(false, for: requestID)
                }
                return
            }

            do {
                try {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }

                    let preferredPreset: AVCaptureSession.Preset = attentionOnly ? .vga640x480 : .hd1280x720
                    if session.canSetSessionPreset(preferredPreset) {
                        session.sessionPreset = preferredPreset
                    }

                    if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.position == .front }) {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else {
                            throw ProviderError.unavailable("The front camera could not be connected.")
                        }
                        session.addInput(input)
                    }

                    if publishesMirrorStatus {
                        frameHeartbeatOutput.alwaysDiscardsLateVideoFrames = true
                        frameHeartbeatOutput.setSampleBufferDelegate(
                            heartbeatDelegate,
                            queue: heartbeatDelegate.queue
                        )
                        if !session.outputs.contains(where: { $0 === frameHeartbeatOutput }),
                           session.canAddOutput(frameHeartbeatOutput) {
                            session.addOutput(frameHeartbeatOutput)
                        }
                        guard session.outputs.contains(where: { $0 === frameHeartbeatOutput }) else {
                            throw ProviderError.unavailable("Camera frame monitoring could not be connected.")
                        }
                        if session.outputs.contains(where: { $0 === frameHeartbeatOutput }) {
                            if let connection = frameHeartbeatOutput.connection(with: .video) {
                                if connection.isVideoRotationAngleSupported(0) {
                                    connection.videoRotationAngle = 0
                                }
                                if connection.isVideoMirroringSupported {
                                    connection.automaticallyAdjustsVideoMirroring = false
                                    connection.isVideoMirrored = true
                                }
                            }
                            heartbeatDelegate.beginMonitoring(generation: requestID)
                        } else {
                            heartbeatDelegate.stopMonitoring()
                        }
                    }

                    if shouldMonitorAttention,
                       !session.outputs.contains(where: { $0 === faceMetadataOutput }),
                       session.canAddOutput(faceMetadataOutput) {
                        session.addOutput(faceMetadataOutput)
                        if faceMetadataOutput.availableMetadataObjectTypes.contains(.face) {
                            faceMetadataOutput.metadataObjectTypes = [.face]
                        }
                    }

                    Self.configureFrameRate(for: device, attentionOnly: attentionOnly)
                }()

                guard queueState.shouldRun(generation: requestID) else { return }
                if !session.isRunning { session.startRunning() }
                guard queueState.shouldRun(generation: requestID) else {
                    if session.isRunning {
                        queueState.markExpectedStop()
                        session.stopRunning()
                    }
                    return
                }
                if publishesMirrorStatus {
                    if session.isRunning {
                        self?.publishSessionStarted(for: requestID, session: session)
                    } else {
                        self?.publishMirrorStartFailure(for: requestID)
                    }
                } else {
                    self?.publishAttentionCaptureResult(session.isRunning, for: requestID, session: session)
                }
            } catch {
                if publishesMirrorStatus {
                    self?.publishMirrorStartFailure(for: requestID)
                } else {
                    self?.publishAttentionCaptureResult(false, for: requestID)
                }
            }
        }
    }

    private func reconfigureForAttentionOnly() {
        let queueState = sessionQueueState
        let graphStore = captureGraphStore
        let requestID = startRequestID
        queueState.requestStart(generation: requestID)
        sessionQueue.async {
            guard queueState.shouldRun(generation: requestID) else { return }
            guard let graph = graphStore.existing() else { return }
            let session = graph.session
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first(where: { $0.position == .front }) else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
            Self.configureFrameRate(for: device, attentionOnly: true)
        }
    }

    private nonisolated static func configureFrameRate(
        for device: AVCaptureDevice,
        attentionOnly: Bool
    ) {
        let preferredRate = attentionOnly ? 2.0 : 30.0
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate <= preferredRate && preferredRate <= $0.maxFrameRate
        }) ?? device.activeFormat.videoSupportedFrameRateRanges.first else { return }
        let supportedRate = min(max(preferredRate, range.minFrameRate), range.maxFrameRate)
        let duration = CMTime(seconds: 1 / supportedRate, preferredTimescale: 600)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            // Frame-rate throttling is an optimization. Mirror and face metadata
            // remain functional if a particular camera format rejects it.
        }
    }

    private func updateStatus(_ status: MirrorPermissionState) {
        mirrorDebug("status \(String(describing: self.status)) -> \(String(describing: status))")
        if status != .requesting {
            startWatchdogTask?.cancel()
            startWatchdogTask = nil
        }
        if status == .live {
            recoveryTask?.cancel()
            recoveryTask = nil
            startFrameWatchdog()
            if frameRestartInFlight {
                frameRestartGuardTask?.cancel()
                frameRestartGuardTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    guard let self, self.status == .live else { return }
                    frameRestartInFlight = false
                    frameRestartGuardTask = nil
                }
            }
            recoveryStabilityTask?.cancel()
            recoveryStabilityTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self, mirrorRequested, self.status == .live else { return }
                recoveryAttempt = 0
                recoveryStabilityTask = nil
            }
        } else {
            frameWatchdogTask?.cancel()
            frameWatchdogTask = nil
            recoveryStabilityTask?.cancel()
            recoveryStabilityTask = nil
            if status != .requesting {
                recoveryTask?.cancel()
                recoveryTask = nil
                frameRestartGuardTask?.cancel()
                frameRestartGuardTask = nil
                frameRestartInFlight = false
            }
        }
        self.status = status
        onStatusChange?()
    }

    private func publishRecording(startedAt: Date?) {
        recordingStartedAt = startedAt
        isRecording = startedAt != nil
        onRecordingChange?()
    }

    private func currentCaptureRotationAngle() -> CGFloat {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .landscapeRight

        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return 0
        }
    }

    private nonisolated func publishCaptureResult(_ result: MirrorCaptureResult) {
        Task { @MainActor [weak self] in
            self?.onCaptureResult?(result)
        }
    }

    private nonisolated func finishPhotoCapture(_ data: Data?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            photoCapturePending = false
            guard let data else {
                onCaptureResult?(.failed("The photo could not be captured."))
                return
            }
            Self.savePhotoData(data) { [weak self] saved in
                self?.publishCaptureResult(
                    saved ? .photoSaved : .failed("The photo could not be saved to Photos.")
                )
            }
        }
    }

    private nonisolated static func savePhotoData(
        _ data: Data,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        requestPhotoLibraryAccess { authorized in
            guard authorized else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { saved, _ in
                completion(saved)
            }
        }
    }

    private nonisolated static func saveVideo(
        at url: URL,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        requestPhotoLibraryAccess { authorized in
            guard authorized else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { saved, _ in
                if saved {
                    try? FileManager.default.removeItem(at: url)
                }
                completion(saved)
            }
        }
    }

    private nonisolated static func requestPhotoLibraryAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            completion(true)
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        } else {
            completion(false)
        }
    }

    private func publishFacePresence(_ isPresent: Bool) {
        guard lastPublishedFacePresence != isPresent else {
            if isPresent { onFacePresenceChange?(true) }
            return
        }
        lastPublishedFacePresence = isPresent
        onFacePresenceChange?(isPresent)
    }

    private nonisolated func publish(
        _ status: MirrorPermissionState,
        for requestID: Int,
        session: AVCaptureSession? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.startRequestID == requestID else { return }
            if let session { self.installSessionObserversIfNeeded(for: session) }
            self.updateStatus(status)
        }
    }

    private nonisolated func publishSessionStarted(
        for requestID: Int,
        session: AVCaptureSession
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.startRequestID == requestID else { return }
            self.installSessionObserversIfNeeded(for: session)
            self.startWatchdog(for: requestID)
        }
    }

    private nonisolated func publishMirrorStartFailure(for requestID: Int) {
        Task { @MainActor [weak self] in
            guard let self,
                  mirrorRequested,
                  startRequestID == requestID else { return }
            scheduleCaptureRecovery(forceSessionRestart: true)
        }
    }

    private nonisolated func publishAttentionCaptureResult(
        _ succeeded: Bool,
        for requestID: Int,
        session: AVCaptureSession? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.startRequestID == requestID else { return }
            if let session { self.installSessionObserversIfNeeded(for: session) }
            self.attentionStartInFlight = false
            if !succeeded { self.publishFacePresence(false) }
        }
    }
}
