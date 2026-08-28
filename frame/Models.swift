import Combine
import Foundation
import ImageIO
import UIKit

enum FrameBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case tahoe
    case santaBarbara
    case redwood
    case sanFrancisco
    case losAngeles
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tahoe: return "Tahoe"
        case .santaBarbara: return "Santa Barbara"
        case .redwood: return "Redwood"
        case .sanFrancisco: return "San Francisco"
        case .losAngeles: return "Los Angeles"
        case .photo: return "Photo"
        }
    }

    var detail: String {
        switch self {
        case .tahoe: return "Pines and alpine water"
        case .santaBarbara: return "Sand, surf, and sun"
        case .redwood: return "Bark, earth, and fern"
        case .sanFrancisco: return "Orange steel and fog"
        case .losAngeles: return "Pink sky afterglow"
        case .photo: return "Your own image"
        }
    }

    var colors: [String] {
        switch self {
        case .tahoe: return ["#173F35", "#2F7F87", "#9DC9C2", "#D6E3CD"]
        case .santaBarbara: return ["#F3C98B", "#E9916D", "#48A9C5", "#D9F0EA"]
        case .redwood: return ["#542E26", "#A64F3C", "#D18463", "#687A52"]
        case .sanFrancisco: return ["#F04A23", "#AEB8BE", "#E5E3DC", "#536875"]
        case .losAngeles: return ["#F58CB8", "#EFAB9D", "#A986C8", "#FFD19A"]
        case .photo: return []
        }
    }

    static func resolvingStoredValue(_ rawValue: String?) -> FrameBackgroundStyle {
        guard let rawValue else { return .tahoe }
        if let style = FrameBackgroundStyle(rawValue: rawValue) { return style }

        switch rawValue {
        case "sunrise": return .losAngeles
        case "coastal": return .santaBarbara
        case "meadow": return .tahoe
        case "dusk": return .redwood
        case "graphite": return .sanFrancisco
        default: return .tahoe
        }
    }
}

@MainActor
final class FrameBackgroundStore: ObservableObject {
    @Published private(set) var style: FrameBackgroundStyle
    @Published private(set) var photoData: Data?
    @Published private(set) var photoImage: UIImage?
    @Published private(set) var usesLightAccent: Bool
    @Published private(set) var isDynamic: Bool
    @Published private(set) var dynamicSpeed: Double = 1
    @Published private(set) var dynamicCrispness: Double = 0.75
    @Published private(set) var dynamicIntensity: Double = 1
    @Published private(set) var dynamicWaveCount: Double = 8
    @Published private(set) var dynamicVerticalSpread: Double = 1

    private let defaults: UserDefaults
    private let styleKey = "frame.backgroundStyle"
    private let dynamicKey = "frame.backgroundIsDynamic"
    private let dynamicSpeedKey = "frame.backgroundDynamicSpeed"
    private let dynamicCrispnessKey = "frame.backgroundDynamicCrispness"
    private let dynamicIntensityKey = "frame.backgroundDynamicIntensity"
    private let dynamicWaveCountKey = "frame.backgroundDynamicWaveCount"
    private let dynamicVerticalSpreadKey = "frame.backgroundDynamicVerticalSpread"
    private nonisolated static let lightAccentThreshold = 0.58
    private static let photoLightAccentKey = "frame.backgroundPhotoUsesLightAccent"

    private struct LoadedBackgroundPhoto: @unchecked Sendable {
        let data: Data
        let image: UIImage
        let usesLightAccent: Bool
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedStyle = FrameBackgroundStyle.resolvingStoredValue(defaults.string(forKey: styleKey))
        let photoExists = (try? Self.applicationSupportDirectory())
            .map { FileManager.default.fileExists(atPath: Self.photoURL(in: $0).path) } ?? false
        let resolvedStyle = storedStyle == .photo && !photoExists ? .tahoe : storedStyle
        self.photoData = nil
        self.photoImage = nil
        self.style = resolvedStyle
        self.usesLightAccent = resolvedStyle == .photo
            ? (defaults.object(forKey: Self.photoLightAccentKey) as? Bool ?? true)
            : Self.prefersLightAccent(for: resolvedStyle, photoImage: nil)
        self.isDynamic = defaults.object(forKey: dynamicKey) as? Bool ?? true
        self.dynamicSpeed = (defaults.object(forKey: dynamicSpeedKey) == nil ? 1 : defaults.double(forKey: dynamicSpeedKey))
            .clamped(to: 0.4...2)
        self.dynamicCrispness = (defaults.object(forKey: dynamicCrispnessKey) == nil ? 0.75 : defaults.double(forKey: dynamicCrispnessKey))
            .clamped(to: 0.2...1)
        self.dynamicIntensity = (defaults.object(forKey: dynamicIntensityKey) == nil ? 1 : defaults.double(forKey: dynamicIntensityKey))
            .clamped(to: 0.5...1.5)
        self.dynamicWaveCount = (defaults.object(forKey: dynamicWaveCountKey) == nil ? 8 : defaults.double(forKey: dynamicWaveCountKey))
            .clamped(to: 3...12)
            .rounded()
        self.dynamicVerticalSpread = (defaults.object(forKey: dynamicVerticalSpreadKey) == nil ? 1 : defaults.double(forKey: dynamicVerticalSpreadKey))
            .clamped(to: 0.6...1.25)
    }

    func setStyle(_ style: FrameBackgroundStyle) {
        guard style != .photo || photoData != nil else { return }
        self.style = style
        usesLightAccent = Self.prefersLightAccent(for: style, photoImage: photoImage)
        defaults.set(style.rawValue, forKey: styleKey)
    }

    func loadPersistedPhotoIfNeeded() async {
        guard photoData == nil,
              let directory = try? Self.applicationSupportDirectory() else { return }
        let url = Self.photoURL(in: directory)
        let loaded = await Task.detached(priority: .utility) { () -> LoadedBackgroundPhoto? in
            guard let data = try? Data(contentsOf: url),
                  let image = Self.downsampledImage(from: data, maxPixelSize: 2_600) else { return nil }
            return LoadedBackgroundPhoto(
                data: data,
                image: image,
                usesLightAccent: Self.averageLuminance(of: image) < Self.lightAccentThreshold
            )
        }.value

        guard !Task.isCancelled, let loaded else {
            if style == .photo { setStyle(.tahoe) }
            return
        }
        photoData = loaded.data
        photoImage = loaded.image
        defaults.set(loaded.usesLightAccent, forKey: Self.photoLightAccentKey)
        if style == .photo {
            usesLightAccent = loaded.usesLightAccent
        }
    }

    func setDynamic(_ isDynamic: Bool) {
        self.isDynamic = isDynamic
        defaults.set(isDynamic, forKey: dynamicKey)
    }

    func setDynamicSpeed(_ value: Double) {
        dynamicSpeed = value.clamped(to: 0.4...2)
        defaults.set(dynamicSpeed, forKey: dynamicSpeedKey)
    }

    func setDynamicCrispness(_ value: Double) {
        dynamicCrispness = value.clamped(to: 0.2...1)
        defaults.set(dynamicCrispness, forKey: dynamicCrispnessKey)
    }

    func setDynamicIntensity(_ value: Double) {
        dynamicIntensity = value.clamped(to: 0.5...1.5)
        defaults.set(dynamicIntensity, forKey: dynamicIntensityKey)
    }

    func setDynamicWaveCount(_ value: Double) {
        dynamicWaveCount = value.clamped(to: 3...12).rounded()
        defaults.set(dynamicWaveCount, forKey: dynamicWaveCountKey)
    }

    func setDynamicVerticalSpread(_ value: Double) {
        dynamicVerticalSpread = value.clamped(to: 0.6...1.25)
        defaults.set(dynamicVerticalSpread, forKey: dynamicVerticalSpreadKey)
    }

    func resetDynamicTuning() {
        dynamicSpeed = 1
        dynamicCrispness = 0.75
        dynamicIntensity = 1
        dynamicWaveCount = 8
        dynamicVerticalSpread = 1
        defaults.set(dynamicSpeed, forKey: dynamicSpeedKey)
        defaults.set(dynamicCrispness, forKey: dynamicCrispnessKey)
        defaults.set(dynamicIntensity, forKey: dynamicIntensityKey)
        defaults.set(dynamicWaveCount, forKey: dynamicWaveCountKey)
        defaults.set(dynamicVerticalSpread, forKey: dynamicVerticalSpreadKey)
    }

    func setPhotoData(_ data: Data) {
        guard let image = UIImage(data: data),
              let normalizedData = image.jpegData(compressionQuality: 0.82) else { return }
        do {
            let directory = try Self.applicationSupportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try normalizedData.write(to: Self.photoURL(in: directory), options: .atomic)
            photoData = normalizedData
            photoImage = Self.downsampledImage(from: normalizedData, maxPixelSize: 2_600) ?? image
            usesLightAccent = Self.prefersLightAccent(for: .photo, photoImage: photoImage)
            defaults.set(usesLightAccent, forKey: Self.photoLightAccentKey)
            setStyle(.photo)
        } catch {
            // The photo is an enhancement. Keep the last working background if storage fails.
        }
    }

    func clearPhoto() {
        if let directory = try? Self.applicationSupportDirectory() {
            try? FileManager.default.removeItem(at: Self.photoURL(in: directory))
        }
        photoData = nil
        photoImage = nil
        usesLightAccent = Self.prefersLightAccent(for: style, photoImage: nil)
        if style == .photo {
            setStyle(.tahoe)
        }
    }

    private static func prefersLightAccent(for style: FrameBackgroundStyle, photoImage: UIImage?) -> Bool {
        if style == .photo, let image = photoImage {
            return averageLuminance(of: image) < lightAccentThreshold
        }

        let luminances = style.colors.map { hexLuminance($0) }
        let average = luminances.isEmpty ? 0.72 : luminances.reduce(0, +) / Double(luminances.count)
        return average < lightAccentThreshold
    }

    private nonisolated static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private nonisolated static func averageLuminance(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0.72 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.72 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    private static func hexLuminance(_ hex: String) -> Double {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let rgb = UInt64(value, radix: 16) else { return 0.72 }
        let red = Double((rgb >> 16) & 0xFF) / 255
        let green = Double((rgb >> 8) & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory.appendingPathComponent("Frame", isDirectory: true)
    }

    private static func photoURL(in directory: URL) -> URL {
        directory.appendingPathComponent("background.jpg")
    }

}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct WeatherForecastDay: Codable, Equatable, Sendable {
    let date: Date
    let high: Int
    let low: Int
    let condition: String
    let symbolName: String
}

struct WeatherSummary: Codable, Equatable, Sendable {
    let temperature: Int
    let high: Int
    let low: Int
    let condition: String
    let symbolName: String
    let locationName: String
    let observedAt: Date
    let isStale: Bool
    let sunrise: Date?
    let sunset: Date?
    let forecast: [WeatherForecastDay]

    init(
        temperature: Int,
        high: Int,
        low: Int,
        condition: String,
        symbolName: String,
        locationName: String,
        observedAt: Date,
        isStale: Bool,
        sunrise: Date?,
        sunset: Date?,
        forecast: [WeatherForecastDay] = []
    ) {
        self.temperature = temperature
        self.high = high
        self.low = low
        self.condition = condition
        self.symbolName = symbolName
        self.locationName = locationName
        self.observedAt = observedAt
        self.isStale = isStale
        self.sunrise = sunrise
        self.sunset = sunset
        self.forecast = forecast
    }

    private enum CodingKeys: String, CodingKey {
        case temperature, high, low, condition, symbolName, locationName
        case observedAt, isStale, sunrise, sunset, forecast
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try values.decode(Int.self, forKey: .temperature)
        high = try values.decode(Int.self, forKey: .high)
        low = try values.decode(Int.self, forKey: .low)
        condition = try values.decode(String.self, forKey: .condition)
        symbolName = try values.decode(String.self, forKey: .symbolName)
        locationName = try values.decode(String.self, forKey: .locationName)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        isStale = try values.decode(Bool.self, forKey: .isStale)
        sunrise = try values.decodeIfPresent(Date.self, forKey: .sunrise)
        sunset = try values.decodeIfPresent(Date.self, forKey: .sunset)
        forecast = try values.decodeIfPresent([WeatherForecastDay].self, forKey: .forecast) ?? []
    }
}

struct WeatherAttributionInfo: Equatable, Sendable {
    let markURL: URL?
    let legalURL: URL?
    let serviceName: String
}

nonisolated struct AgendaItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let date: Date
    let calendarName: String
    let isPrivate: Bool
    let location: String?
    let locationCoordinate: MapRoutePoint?
    let endDate: Date?
    let calendarIdentifier: String?
    let isAllDay: Bool

    init(
        id: String,
        title: String,
        date: Date,
        calendarName: String,
        isPrivate: Bool,
        location: String?,
        locationCoordinate: MapRoutePoint? = nil,
        endDate: Date? = nil,
        calendarIdentifier: String? = nil,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.calendarName = calendarName
        self.isPrivate = isPrivate
        self.location = location
        self.locationCoordinate = locationCoordinate
        self.endDate = endDate
        self.calendarIdentifier = calendarIdentifier
        self.isAllDay = isAllDay
    }
}

nonisolated struct CalendarDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceName: String
}

nonisolated struct MapRoutePoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

enum RouteTransportMode: String, CaseIterable, Identifiable, Sendable {
    case driving
    case transit
    case walking
    case cycling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .driving: return "Driving"
        case .transit: return "Transit"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        }
    }

    var symbolName: String {
        switch self {
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        }
    }
}

struct MapRouteSummary: Equatable, Sendable {
    let destinationName: String
    let travelTimeMinutes: Int
    let trafficLabel: String
    let distanceMiles: Double
    let points: [MapRoutePoint]
    let transportMode: RouteTransportMode

    var distanceLabel: String {
        String(format: "%.1f mi", distanceMiles)
    }
}

enum RouteState: Equatable {
    case idle
    case loading
    case loaded(MapRouteSummary)
    case unavailable(String)
    case failed(String)

    var summary: MapRouteSummary? {
        if case .loaded(let summary) = self { return summary }
        return nil
    }
}

struct UpdateItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case calendar
        case weather
        case home
        case frame
        case music
        case sleep
        case sunriseSunset
    }

    let id: String
    let title: String
    let detail: String
    let kind: Kind
    let accent: String
    let date: Date?
    let secondaryTitle: String?
    let secondaryDetail: String?
    let systemImage: String?
    let secondarySystemImage: String?

    init(
        id: String,
        title: String,
        detail: String,
        kind: Kind,
        accent: String,
        date: Date?,
        secondaryTitle: String? = nil,
        secondaryDetail: String? = nil,
        systemImage: String? = nil,
        secondarySystemImage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.accent = accent
        self.date = date
        self.secondaryTitle = secondaryTitle
        self.secondaryDetail = secondaryDetail
        self.systemImage = systemImage
        self.secondarySystemImage = secondarySystemImage
    }
}

enum FeedSource: Identifiable, Hashable, Sendable {
    case mirror
    case map
    case homeKit(id: UUID, name: String, room: String)
    case homeControls

    var id: String {
        switch self {
        case .mirror: return "mirror"
        case .map: return "map"
        case .homeKit(let id, _, _): return "homekit-\(id.uuidString)"
        case .homeControls: return "home-controls"
        }
    }

    var displayName: String {
        switch self {
        case .mirror: return "Mirror"
        case .map: return "Map"
        case .homeKit(_, let name, _): return name
        case .homeControls: return "Home Controls"
        }
    }

    var roomName: String {
        switch self {
        case .mirror: return "Local camera"
        case .map: return "Apple Maps"
        case .homeKit(_, _, let room): return room
        case .homeControls: return "Lights · Thermostat"
        }
    }

    var isMirror: Bool {
        if case .mirror = self { return true }
        return false
    }

    var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    var isHomeControls: Bool {
        if case .homeControls = self { return true }
        return false
    }
}

struct MusicTrack: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let duration: TimeInterval?
}

struct MusicPlaylistDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct MusicPlaybackProgress: Equatable, Sendable {
    let time: TimeInterval
    let duration: TimeInterval
}

enum MusicPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case denied(String)
    case unavailable(String)
    case failed(String)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .loading: return "Loading music"
        case .ready: return "Ready to play"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .denied(let message), .unavailable(let message), .failed(let message): return message
        }
    }
}

struct HomeKitCameraDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let name: String
    let roomName: String
    let homeName: String
    let supportsStream: Bool
    let supportsSnapshot: Bool
}

struct HomeControl: Identifiable, Equatable, Codable, Sendable {
    struct LightColor: Equatable, Codable, Sendable {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    enum Kind: String, Codable, Sendable {
        case light
        case thermostat
        case speaker
    }

    let id: String
    let name: String
    let roomName: String
    let kind: Kind
    var isOn: Bool
    var currentTemperature: Double?
    var targetTemperature: Double?
    var volume: Double?
    var isMuted: Bool?
    var lightColor: LightColor? = nil
}

enum TemperatureDisplay {
    static var isMetric: Bool {
        Locale.current.measurementSystem == .metric
    }

    static func displayedValue(fromCelsius value: Double?) -> Int? {
        guard let value else { return nil }
        let converted = isMetric
            ? value
            : Measurement(value: value, unit: UnitTemperature.celsius)
                .converted(to: .fahrenheit)
                .value
        return Int(converted.rounded())
    }

    static func string(fromCelsius value: Double?) -> String {
        guard let displayed = displayedValue(fromCelsius: value) else { return "—" }
        return "\(displayed)°"
    }

    static func celsiusValue(fromDisplayed value: Int) -> Double {
        guard !isMetric else { return Double(value) }
        return Measurement(value: Double(value), unit: UnitTemperature.fahrenheit)
            .converted(to: .celsius)
            .value
    }

    static var unitLabel: String {
        isMetric ? "°C" : "°F"
    }

    static func celsiusDelta(forDisplayedDelta delta: Double) -> Double {
        isMetric
            ? delta
            : Measurement(value: delta, unit: UnitTemperature.fahrenheit)
                .converted(to: .celsius)
                .value
    }
}

enum IntervalMath {
    static func mergedMinutes(_ intervals: [(Date, Date)]) -> Int {
        let sorted = intervals
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }

        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1.timeIntervalSince(current.0)
                current = interval
            }
        }
        total += current.1.timeIntervalSince(current.0)
        return max(0, Int((total / 60).rounded()))
    }
}

enum TravelTimeMath {
    static func leaveByDate(arrivalDate: Date, travelTimeMinutes: Int) -> Date {
        arrivalDate.addingTimeInterval(-Double(max(0, travelTimeMinutes)) * 60)
    }
}

struct SleepSummary: Codable, Equatable, Sendable {
    let sleepStart: Date?
    let sleepEnd: Date?
    let totalSleepMinutes: Int
    let inBedMinutes: Int
    let deepSleepMinutes: Int
    let remSleepMinutes: Int
    let awakenings: Int

    var durationLabel: String {
        let hours = totalSleepMinutes / 60
        let minutes = totalSleepMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var stageDetail: String {
        let deep = "Deep \(deepSleepMinutes / 60)h \(deepSleepMinutes % 60)m"
        let rem = "REM \(remSleepMinutes / 60)h \(remSleepMinutes % 60)m"
        return "\(deep) · \(rem) · \(awakenings) \(awakenings == 1 ? "awakening" : "awakenings")"
    }
}

enum SleepState: Equatable {
    case idle
    case loading
    case loaded(SleepSummary)
    case noData
    case denied(String)
    case unavailable(String)
    case failed(String)

    var summary: SleepSummary? {
        if case .loaded(let summary) = self { return summary }
        return nil
    }
}

enum PermissionState: Equatable, Sendable {
    case unknown
    case requesting
    case allowed
    case denied
    case restricted
    case unavailable
}

enum FocusStatusState: Equatable {
    case notDetermined
    case loading
    case active
    case inactive
    case denied
    case restricted
    case unavailable

    var isAuthorized: Bool {
        switch self {
        case .active, .inactive: return true
        default: return false
        }
    }

    var showsGlyph: Bool {
        isAuthorized
    }

    var systemImage: String {
        switch self {
        case .active: return "moon.fill"
        case .inactive: return "moon"
        default: return "moon"
        }
    }

    var label: String {
        switch self {
        case .notDetermined: return "Not enabled"
        case .loading: return "Checking Focus status"
        case .active: return "Focus is on"
        case .inactive: return "Focus is off"
        case .denied: return "Focus status access denied"
        case .restricted: return "Focus status restricted"
        case .unavailable: return "Focus status unavailable"
        }
    }
}

enum AmbientDisplayMode: Equatable, Sendable {
    case dashboard
    case screensaver
    case sleep
}

struct AmbientModeConfiguration: Equatable, Sendable {
    var screensaverEnabled: Bool
    var screensaverDelay: TimeInterval
    var sleepModeEnabled: Bool
    var sleepStartMinute: Int
    var sleepEndMinute: Int
    var requireFocusDuringSleepWindow: Bool
}

enum AmbientModeResolver {
    static func resolve(
        now: Date,
        lastInteraction: Date,
        focusIsActive: Bool,
        sleepOverrideUntil: Date?,
        configuration: AmbientModeConfiguration,
        calendar: Calendar = .current
    ) -> AmbientDisplayMode {
        let sleepIsTemporarilyOverridden = sleepOverrideUntil.map { now < $0 } ?? false
        let isInSleepWindow = isWithinSleepWindow(
            now,
            startMinute: configuration.sleepStartMinute,
            endMinute: configuration.sleepEndMinute,
            calendar: calendar
        )
        let focusRequirementIsMet = !configuration.requireFocusDuringSleepWindow || focusIsActive

        if configuration.sleepModeEnabled,
           !sleepIsTemporarilyOverridden,
           isInSleepWindow,
           focusRequirementIsMet {
            return .sleep
        }

        if configuration.screensaverEnabled,
           now.timeIntervalSince(lastInteraction) >= max(configuration.screensaverDelay, 10) {
            return .screensaver
        }

        return .dashboard
    }

    static func isWithinSleepWindow(
        _ date: Date,
        startMinute: Int,
        endMinute: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let start = normalizedMinute(startMinute)
        let end = normalizedMinute(endMinute)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if start == end { return true }
        if start < end { return current >= start && current < end }
        return current >= start || current < end
    }

    private static func normalizedMinute(_ minute: Int) -> Int {
        let day = 24 * 60
        return ((minute % day) + day) % day
    }
}

enum WeatherState: Equatable {
    case loading
    case loaded(WeatherSummary)
    case stale(WeatherSummary)
    case denied(String)
    case unavailable(String)
    case failed(String)

    var summary: WeatherSummary? {
        switch self {
        case .loaded(let summary), .stale(let summary): return summary
        default: return nil
        }
    }
}

enum CalendarState: Equatable {
    case idle
    case loading
    case loaded([AgendaItem])
    case empty
    case denied(String)
    case failed(String)

    var items: [AgendaItem] {
        if case .loaded(let items) = self { return items }
        return []
    }
}

enum HomeKitState: Equatable {
    case idle
    case loading
    case loaded([HomeKitCameraDescriptor])
    case noHomes
    case noCameras
    case denied(String)
    case failed(String)

    var cameras: [HomeKitCameraDescriptor] {
        if case .loaded(let cameras) = self { return cameras }
        return []
    }
}

enum FeedStatus: Equatable {
    case permissionNeeded
    case starting
    case live
    case snapshotAvailable
    case offline
    case denied
    case unavailable
    case failed(String)

    var label: String {
        switch self {
        case .permissionNeeded: return "Permission needed"
        case .starting: return "Starting"
        case .live: return "Live"
        case .snapshotAvailable: return "Snapshot"
        case .offline: return "Offline"
        case .denied: return "Access denied"
        case .unavailable: return "Unavailable"
        case .failed(let message): return message
        }
    }
}

enum MirrorPermissionState: Equatable {
    case unknown
    case requesting
    case live
    case denied
    case unavailable
    case stopped
}

enum MirrorCaptureResult: Equatable {
    case photoSaved
    case videoSaved
    case failed(String)
}

struct DashboardState {
    let weather: WeatherState
    let calendar: CalendarState
    let route: RouteState
    let homeKit: HomeKitState
    let homeControls: [HomeControl]
    let sleep: SleepState
    let music: MusicPlaybackState
    let updates: [UpdateItem]
    let feeds: [FeedSource]
    let selectedFeedID: String
    let isOffline: Bool
}

enum ProviderError: LocalizedError, Equatable {
    case permissionDenied(String)
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let message), .unavailable(let message), .failed(let message): return message
        }
    }
}
