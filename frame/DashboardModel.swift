import Combine
@preconcurrency import CoreMotion
import Foundation
import HomeKit
import Network
import UIKit

@MainActor
final class DashboardModel: ObservableObject {
    @Published var weatherState: WeatherState
    @Published var calendarState: CalendarState
    @Published var routeState: RouteState
    @Published private(set) var routeTransportMode: RouteTransportMode
    @Published var homeKitState: HomeKitState = .idle
    @Published var homeControls: [HomeControl]
    @Published var sleepState: SleepState
    @Published var focusStatus: FocusStatusState
    @Published var showSunriseSunsetUpdate: Bool
    @Published var homeControlMessage: String?
    @Published var updates: [UpdateItem]
    @Published private(set) var pastUpdates: [UpdateItem]
    private var clearedUpdateRecords: [ClearedUpdateRecord]
    @Published var feeds: [FeedSource]
    @Published var feedStatuses: [String: FeedStatus]
    @Published var selectedFeedIndex: Int
    @Published var selectedFeedID: String
    @Published var calendarOptions: [CalendarDescriptor]
    @Published var selectedCalendarIdentifiers: Set<String>
    @Published var hasStoredCalendarSelection: Bool
    @Published var showingUpdates = false
    @Published var showingHome = false
    @Published var showingSettings = false
    @Published var displayName: String
    @Published var weatherLocationName: String
    @Published var weatherAttribution: WeatherAttributionInfo?
    @Published var activeHomeKitSource: HMCameraSource?
    @Published private(set) var activeHomeKitSourceFeedID: String?
    @Published var homeKitSnapshots: [String: HMCameraSource] = [:]
    @Published var musicState: MusicPlaybackState = .idle
    @Published var musicTracks: [MusicTrack] = []
    @Published var currentMusicTrack: MusicTrack?
    @Published var musicPlaylists: [MusicPlaylistDescriptor] = []
    @Published var selectedMusicPlaylistID: String?
    @Published var selectedMusicPlaylistName: String
    @Published var musicPlaybackTime: TimeInterval = 0
    @Published var musicPlaybackDuration: TimeInterval = 0
    @Published var mirrorEnabled = true
    @Published private(set) var mirrorRecordingStartedAt: Date?
    @Published private(set) var mirrorSessionRevision = 0
    @Published private(set) var mirrorCaptureResult: MirrorCaptureResult?
    @Published var musicOverlayVisible = false
    @Published var isOffline = false
    @Published private(set) var ambientMode: AmbientDisplayMode
    @Published private(set) var screensaverEnabled: Bool
    @Published private(set) var screensaverDelay: TimeInterval
    @Published private(set) var sleepModeEnabled: Bool
    @Published private(set) var sleepStartMinute: Int
    @Published private(set) var sleepEndMinute: Int
    @Published private(set) var requireFocusDuringSleepWindow: Bool
    @Published private(set) var motionWakeEnabled: Bool
    @Published private(set) var attentionAwarenessEnabled: Bool
    @Published private(set) var showWeatherInSleepMode: Bool
    @Published private(set) var showNextEventInSleepMode: Bool

    var mirrorProvider: any MirrorProviding

    private var weatherProvider: any WeatherProviding
    private var calendarProvider: any CalendarProviding
    private var routeProvider: any RouteProviding
    private var homeCameraProvider: any HomeCameraProviding
    private var sleepProvider: any SleepProviding
    private var focusStatusProvider: any FocusStatusProviding
    private var musicProvider: any MusicProviding
    private let updatesProvider: any UpdatesProviding
    private var activeFeedID: String
    private var hasUserSelectedFeed = false
    private var preferredFeedID: String?
    private var refreshTask: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var musicProgressTask: Task<Void, Never>?
    private var focusStatusTask: Task<Void, Never>?
    private var ambientModeTask: Task<Void, Never>?
    private var homeKitStreamTask: Task<Void, Never>?
    private var homeKitDiscoveryTask: Task<Void, Never>?
    private var homeKitPrefetchTask: Task<Void, Never>?
    private var homeKitSnapshotTasks: [String: Task<Void, Never>] = [:]
    private var activeFeedStartTask: Task<Void, Never>?
    private var backgroundTransitionTask: Task<Void, Never>?
    private var mirrorCaptureResultTask: Task<Void, Never>?
    private var homeControlsRefreshTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var thermostatWriteTasks: [String: Task<Void, Never>] = [:]
    private var thermostatWriteGenerations: [String: Int] = [:]
    private var homeKitStreamGeneration = 0
    private var homeKitDiscoveryGeneration = 0
    private var homeKitSnapshotGeneration = 0
    private var routeGeneration = 0
    private var routeEventID: String?
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.raaghavt.frame.network")
    // Core Motion is opt-in for waking the sleep display. Do not create its
    // service connection during a normal dashboard launch.
    private var motionManager: CMMotionManager?
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.raaghavt.frame.motion"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var consecutiveMotionSamples = 0
    private var lastInteractionDate = Date()
    private var sleepOverrideUntil: Date?
    private var screensaverAttentionDeadline: Date?
    private var isManualScreensaverActive = false
    private var isRunning = false
    private var isAppActive = true
    private var savedSleepBrightness: CGFloat?
    private var hasLiveHomeKitDiscovery = false
    private var lastKnownHomeCameras: [HomeKitCameraDescriptor]

    private static let screensaverEnabledKey = "frame.ambient.screensaverEnabled"
    private static let screensaverDelayKey = "frame.ambient.screensaverDelay"
    private static let sleepModeEnabledKey = "frame.ambient.sleepModeEnabled"
    private static let sleepStartMinuteKey = "frame.ambient.sleepStartMinute"
    private static let sleepEndMinuteKey = "frame.ambient.sleepEndMinute"
    private static let requireFocusKey = "frame.ambient.requireFocus"
    private static let motionWakeKey = "frame.ambient.motionWake"
    private static let attentionAwarenessKey = "frame.ambient.attentionAwareness"
    private static let sleepWeatherKey = "frame.ambient.sleepWeather"
    private static let sleepNextEventKey = "frame.ambient.sleepNextEvent"
    private static let dashboardSnapshotKey = "frame.dashboard.snapshot.v1"
    private static let selectedFeedKey = "frame.selectedFeedID"
    private static let mirrorEnabledKey = "frame.mirrorEnabled"
    private static let dashboardSnapshotMaxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let screensaverAttentionDuration: TimeInterval = 3 * 60

    private struct StoredDashboardSnapshot: Codable {
        let savedAt: Date
        let weather: WeatherSummary?
        let agenda: [AgendaItem]
        let sleep: SleepSummary?
        let updates: [UpdateItem]
        let homeCameras: [HomeKitCameraDescriptor]?
        let homeControls: [HomeControl]?
    }

    init(
        weatherProvider: any WeatherProviding,
        calendarProvider: any CalendarProviding,
        routeProvider: any RouteProviding,
        homeCameraProvider: any HomeCameraProviding,
        sleepProvider: any SleepProviding,
        focusStatusProvider: any FocusStatusProviding,
        musicProvider: any MusicProviding,
        mirrorProvider: any MirrorProviding,
        updatesProvider: any UpdatesProviding
    ) {
        let defaults = UserDefaults.standard
        let initialShowSunriseSunsetUpdate = UserDefaults.standard.object(forKey: "frame.showSunriseSunsetUpdate") as? Bool ?? true
        self.ambientMode = .dashboard
        self.screensaverEnabled = defaults.object(forKey: Self.screensaverEnabledKey) as? Bool ?? true
        self.screensaverDelay = defaults.object(forKey: Self.screensaverDelayKey) as? Double ?? 300
        self.sleepModeEnabled = defaults.object(forKey: Self.sleepModeEnabledKey) as? Bool ?? true
        self.sleepStartMinute = defaults.object(forKey: Self.sleepStartMinuteKey) as? Int ?? 22 * 60
        self.sleepEndMinute = defaults.object(forKey: Self.sleepEndMinuteKey) as? Int ?? 7 * 60
        self.requireFocusDuringSleepWindow = defaults.object(forKey: Self.requireFocusKey) as? Bool ?? false
        self.motionWakeEnabled = defaults.object(forKey: Self.motionWakeKey) as? Bool ?? false
        self.attentionAwarenessEnabled = false
        self.showWeatherInSleepMode = defaults.object(forKey: Self.sleepWeatherKey) as? Bool ?? true
        self.showNextEventInSleepMode = defaults.object(forKey: Self.sleepNextEventKey) as? Bool ?? true
        self.mirrorEnabled = defaults.object(forKey: Self.mirrorEnabledKey) as? Bool ?? true
        self.weatherProvider = weatherProvider
        self.calendarProvider = calendarProvider
        self.routeProvider = routeProvider
        self.homeCameraProvider = homeCameraProvider
        self.sleepProvider = sleepProvider
        self.focusStatusProvider = focusStatusProvider
        self.musicProvider = musicProvider
        self.mirrorProvider = mirrorProvider
        self.updatesProvider = updatesProvider
        self.displayName = UserDefaults.standard.string(forKey: "frame.displayName") ?? "Raaghav"
        self.weatherLocationName = weatherProvider.manualLocationName ?? ""
        let cachedSnapshot = Self.loadDashboardSnapshot()
        let cachedHomeCameras = cachedSnapshot?.homeCameras ?? []
        let cachedHomeControls = cachedSnapshot?.homeControls ?? []
        var initialFeeds: [FeedSource] = [.mirror]
        initialFeeds.append(contentsOf: cachedHomeCameras.map {
            .homeKit(id: $0.id, name: $0.name, room: $0.roomName)
        })
        if !cachedHomeControls.isEmpty {
            initialFeeds.append(.homeControls)
        }
        self.feeds = initialFeeds
        let storedPreferredFeedID = defaults.string(forKey: Self.selectedFeedKey)
        let restoredFeedIndex = storedPreferredFeedID.flatMap { preferredID in
            initialFeeds.firstIndex(where: { $0.id == preferredID })
        } ?? 0
        self.selectedFeedIndex = restoredFeedIndex
        self.selectedFeedID = initialFeeds[restoredFeedIndex].id
        self.preferredFeedID = storedPreferredFeedID
        self.activeFeedID = initialFeeds[restoredFeedIndex].id
        self.feedStatuses = Dictionary(uniqueKeysWithValues: initialFeeds.map { ($0.id, .unavailable) })
        self.calendarOptions = calendarProvider.availableCalendars
        self.selectedCalendarIdentifiers = calendarProvider.selectedCalendarIdentifiers
        self.hasStoredCalendarSelection = calendarProvider.hasStoredCalendarSelection
        self.showSunriseSunsetUpdate = initialShowSunriseSunsetUpdate
        self.homeControls = cachedHomeControls
        self.lastKnownHomeCameras = cachedHomeCameras
        if !cachedHomeCameras.isEmpty {
            self.homeKitState = .loaded(cachedHomeCameras)
        } else if !cachedHomeControls.isEmpty {
            self.homeKitState = .noCameras
        }
        self.sleepState = cachedSnapshot?.sleep.map(SleepState.loaded) ?? .idle
        // Focus Status is deliberately user-initiated from Settings. Reading
        // it here produces repeated DND service requests at startup, even
        // when the person has never enabled the feature for Frame.
        self.focusStatus = .notDetermined
        self.weatherState = cachedSnapshot?.weather.map(WeatherState.stale) ?? .loading
        if let cachedAgenda = cachedSnapshot?.agenda, !cachedAgenda.isEmpty {
            self.calendarState = .loaded(cachedAgenda)
        } else {
            self.calendarState = .loading
        }
        self.routeState = .idle
        self.routeTransportMode = .driving
        self.updates = cachedSnapshot?.updates ?? []
        let clearedUpdateRecords = Self.loadClearedUpdateRecords()
        self.clearedUpdateRecords = clearedUpdateRecords
        self.pastUpdates = clearedUpdateRecords.map(\.item)
        self.weatherAttribution = nil
        self.selectedMusicPlaylistID = musicProvider.selectedPlaylistID
        self.selectedMusicPlaylistName = musicProvider.selectedPlaylistName
        defaults.set(false, forKey: Self.attentionAwarenessKey)
        attachMirrorStatusCallback()
        attachCalendarCallbacks()
        attachHomeKitCallbacks()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isOffline = path.status != .satisfied
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    static func live() -> DashboardModel {
        DashboardModel(
            weatherProvider: WeatherKitProvider(),
            calendarProvider: EventKitCalendarProvider(),
            routeProvider: MapKitRouteProvider(),
            homeCameraProvider: HomeKitCameraProvider(),
            sleepProvider: HealthKitSleepProvider(),
            focusStatusProvider: SystemFocusStatusProvider(),
            musicProvider: MusicKitProvider(),
            mirrorProvider: AVFoundationMirrorProvider(),
            updatesProvider: LiveUpdatesProvider()
        )
    }

    deinit {
        refreshTask?.cancel()
        weatherTask?.cancel()
        calendarTask?.cancel()
        sleepTask?.cancel()
        musicProgressTask?.cancel()
        focusStatusTask?.cancel()
        ambientModeTask?.cancel()
        homeKitStreamTask?.cancel()
        homeKitDiscoveryTask?.cancel()
        homeKitPrefetchTask?.cancel()
        homeKitSnapshotTasks.values.forEach { $0.cancel() }
        activeFeedStartTask?.cancel()
        backgroundTransitionTask?.cancel()
        homeControlsRefreshTask?.cancel()
        routeTask?.cancel()
        thermostatWriteTasks.values.forEach { $0.cancel() }
        motionManager?.stopDeviceMotionUpdates()
        networkMonitor.cancel()
    }

    var selectedFeed: FeedSource {
        feeds.first(where: { $0.id == selectedFeedID }) ?? feeds.first ?? .mirror
    }

    var selectedFeedStatus: FeedStatus {
        feedStatuses[selectedFeed.id] ?? .unavailable
    }

    var mirrorPresentationStatus: MirrorPermissionState {
        if mirrorProvider.status == .stopped,
           mirrorEnabled,
           feedStatuses[FeedSource.mirror.id] == .starting {
            return .requesting
        }
        return mirrorProvider.status
    }

    var homeCameraFeeds: [FeedSource] {
        feeds.filter {
            if case .homeKit = $0 { return true }
            return false
        }
    }

    var state: DashboardState {
        DashboardState(
            weather: weatherState,
            calendar: calendarState,
            route: routeState,
            homeKit: homeKitState,
            homeControls: homeControls,
            sleep: sleepState,
            music: musicState,
            updates: updates,
            feeds: feeds,
            selectedFeedID: selectedFeed.id,
            isOffline: isOffline
        )
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 5..<12: salutation = "Good morning"
        case 12..<18: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        return "\(salutation), \(displayName)."
    }

    var sleepStartDate: Date {
        Self.dateForMinuteOfDay(sleepStartMinute)
    }

    var sleepEndDate: Date {
        Self.dateForMinuteOfDay(sleepEndMinute)
    }

    var nextSleepModeEvent: AgendaItem? {
        calendarState.items
            .filter { $0.date > Date() }
            .sorted { $0.date < $1.date }
            .first
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isAppActive = true
        lastInteractionDate = Date()
        // Present cached state first, then establish Mirror on its own before
        // waking location, calendar, health, and HomeKit daemons. Launching all
        // of those XPC clients together made the visible camera transition look
        // frozen even though the main run loop remained responsive.
        startRefreshLoop(initialDelay: .milliseconds(1_350))
        scheduleHomeKitPrefetch(after: .milliseconds(2_200))
        musicProgressTask?.cancel()
        musicProgressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateMusicProgress()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // Focus Status is opt-in from Settings; do not ping the DND service
        // as a side effect of launching the dashboard.
        let previousMode = ambientMode
        evaluateAmbientMode(updatesAttentionMonitoring: false)
        if ambientMode == .dashboard, previousMode == .dashboard {
            scheduleActiveFeedStart(after: .milliseconds(350))
        }
        if !calendarState.items.isEmpty {
            configureMap(for: calendarState.items)
        }
        updateAttentionMonitoring()
        startAmbientModeMonitoring()
        updateMotionWakeMonitoring()
    }

    private func startRefreshLoop(initialDelay: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: initialDelay)
            } catch {
                return
            }
            guard let self, isRunning, isAppActive, !Task.isCancelled else { return }
            await refreshLiveData()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(600))
                } catch {
                    return
                }
                guard isRunning, isAppActive, !Task.isCancelled else { return }
                await refreshLiveData()
            }
        }
    }

    private func scheduleActiveFeedStart(after delay: Duration) {
        activeFeedStartTask?.cancel()
        if selectedFeed.isMirror,
           mirrorEnabled,
           mirrorProvider.status != .live {
            feedStatuses[FeedSource.mirror.id] = .starting
        }
        activeFeedStartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, isRunning, isAppActive, !Task.isCancelled else { return }
            ensureMirrorCaptureRunning()
            activateSelectedFeed()
        }
    }

    private func scheduleHomeKitPrefetch(after delay: Duration) {
        homeKitPrefetchTask?.cancel()
        homeKitPrefetchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, isRunning, isAppActive, !Task.isCancelled else { return }
            requestHomeKit()
        }
    }

    private func scheduleHomeKitReconciliation() {
        guard hasLiveHomeKitDiscovery else {
            // Cached accessories make the UI immediately useful, but the new
            // provider still needs discovery before it has live HMService and
            // camera profile objects. Do not clear the cache by refreshing an
            // uninitialized provider after a foreground transition.
            scheduleHomeKitPrefetch(after: .milliseconds(250))
            return
        }
        switch homeKitState {
        case .loaded, .noCameras:
            refreshHomeControls()
            prefetchHomeKitSnapshots(for: lastKnownHomeCameras)
        case .idle, .loading, .failed:
            scheduleHomeKitPrefetch(after: .milliseconds(250))
        case .noHomes, .denied:
            // A known empty/denied/failed Home state should not repeatedly wake
            // the Home daemon on every foreground transition. Explicit retry
            // and opening the Home panel still call requestHomeKit().
            break
        }
    }

    func stop() {
        isRunning = false
        isManualScreensaverActive = false
        refreshTask?.cancel()
        weatherTask?.cancel()
        calendarTask?.cancel()
        sleepTask?.cancel()
        refreshTask = nil
        weatherTask = nil
        calendarTask = nil
        sleepTask = nil
        musicProgressTask?.cancel()
        musicProgressTask = nil
        focusStatusTask?.cancel()
        focusStatusTask = nil
        ambientModeTask?.cancel()
        ambientModeTask = nil
        homeKitDiscoveryTask?.cancel()
        homeKitDiscoveryTask = nil
        homeKitPrefetchTask?.cancel()
        homeKitPrefetchTask = nil
        cancelHomeKitSnapshotPrefetch()
        activeFeedStartTask?.cancel()
        activeFeedStartTask = nil
        homeControlsRefreshTask?.cancel()
        homeControlsRefreshTask = nil
        routeTask?.cancel()
        routeTask = nil
        routeEventID = nil
        thermostatWriteTasks.values.forEach { $0.cancel() }
        thermostatWriteTasks.removeAll()
        motionManager?.stopDeviceMotionUpdates()
        consecutiveMotionSamples = 0
        restoreSleepBrightness()
        mirrorProvider.setAttentionMonitoring(false)
        mirrorProvider.stop()
        stopActiveFeed()
    }

    func handleAppBackground(_ isBackgrounded: Bool) {
        if isBackgrounded {
            guard isAppActive else { return }
            backgroundTransitionTask?.cancel()
            backgroundTransitionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                backgroundTransitionTask = nil
                commitAppBackground()
            }
            return
        }
        backgroundTransitionTask?.cancel()
        backgroundTransitionTask = nil
        guard !isAppActive else {
            if isRunning,
               ambientMode == .dashboard,
               mirrorProvider.status != .live {
                scheduleActiveFeedStart(after: .milliseconds(600))
            }
            return
        }
        isAppActive = true
        lastInteractionDate = Date()
        startRefreshLoop(initialDelay: .milliseconds(180))
        scheduleHomeKitReconciliation()
        musicProgressTask?.cancel()
        musicProgressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                updateMusicProgress()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        startAmbientModeMonitoring()
        let previousMode = ambientMode
        evaluateAmbientMode()
        if ambientMode == .dashboard, previousMode == .dashboard {
            scheduleActiveFeedStart(after: .milliseconds(1_200))
        }
        updateMotionWakeMonitoring()
    }

    private func commitAppBackground() {
        guard isAppActive else { return }
        isAppActive = false
        isManualScreensaverActive = false
        restoreSleepBrightness()
        refreshTask?.cancel()
        refreshTask = nil
        weatherTask?.cancel()
        weatherTask = nil
        calendarTask?.cancel()
        calendarTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        homeKitPrefetchTask?.cancel()
        homeKitPrefetchTask = nil
        activeFeedStartTask?.cancel()
        activeFeedStartTask = nil
        homeKitDiscoveryTask?.cancel()
        homeKitDiscoveryTask = nil
        cancelHomeKitSnapshotPrefetch()
        homeControlsRefreshTask?.cancel()
        homeControlsRefreshTask = nil
        routeTask?.cancel()
        routeTask = nil
        routeEventID = nil
        musicProgressTask?.cancel()
        musicProgressTask = nil
        ambientModeTask?.cancel()
        ambientModeTask = nil
        focusStatusTask?.cancel()
        focusStatusTask = nil
        motionManager?.stopDeviceMotionUpdates()
        consecutiveMotionSamples = 0
        mirrorProvider.setAttentionMonitoring(false)
        mirrorProvider.stop()
        stopActiveFeed()
    }

    func handleAppInactive() {
        // Inactive is transient (permission sheets, Control Center, system UI).
        // It is not authorization to stop or cancel the visible Mirror. A
        // sustained background transition is handled separately after a grace
        // period, and iOS owns any hardware interruption in the meantime.
    }

    func requestFocusStatus() {
        focusStatus = .loading
        Task { [weak self] in
            guard let self else { return }
            focusStatus = await focusStatusProvider.requestAccess()
            if focusStatus.isAuthorized {
                startFocusStatusMonitoring()
            }
            evaluateAmbientMode()
        }
    }

    private func startFocusStatusMonitoring() {
        guard focusStatus.isAuthorized else { return }
        focusStatusTask?.cancel()
        focusStatusTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                focusStatus = focusStatusProvider.currentState()
                evaluateAmbientMode()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func registerInteraction() {
        lastInteractionDate = Date()
        if ambientMode == .screensaver {
            isManualScreensaverActive = false
            transitionAmbientMode(to: .dashboard)
        }
    }

    func setRouteTransportMode(_ mode: RouteTransportMode) {
        guard routeTransportMode != mode else { return }
        routeTransportMode = mode
        guard let event = nextLocatedEvent(in: calendarState.items) else { return }
        requestRoute(for: event, force: true, allowingLocationPrompt: true)
    }

    func wakeAmbientDisplay() {
        let now = Date()
        lastInteractionDate = now
        isManualScreensaverActive = false
        if ambientMode == .sleep {
            sleepOverrideUntil = now.addingTimeInterval(30 * 60)
        }
        transitionAmbientMode(to: .dashboard)
    }

    func startScreensaver() {
        lastInteractionDate = Date()
        isManualScreensaverActive = true
        showingSettings = false
        transitionAmbientMode(to: .screensaver)
    }

    func setScreensaverEnabled(_ enabled: Bool) {
        screensaverEnabled = enabled
        if !enabled, ambientMode == .screensaver {
            isManualScreensaverActive = false
        }
        UserDefaults.standard.set(enabled, forKey: Self.screensaverEnabledKey)
        lastInteractionDate = Date()
        evaluateAmbientMode()
    }

    func setScreensaverDelay(_ delay: TimeInterval) {
        screensaverDelay = min(max(delay, 30), 60 * 60)
        UserDefaults.standard.set(screensaverDelay, forKey: Self.screensaverDelayKey)
        lastInteractionDate = Date()
        evaluateAmbientMode()
    }

    func setSleepModeEnabled(_ enabled: Bool) {
        sleepModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.sleepModeEnabledKey)
        lastInteractionDate = Date()
        evaluateAmbientMode()
    }

    func setSleepStartDate(_ date: Date) {
        sleepStartMinute = Self.minuteOfDay(date)
        UserDefaults.standard.set(sleepStartMinute, forKey: Self.sleepStartMinuteKey)
        evaluateAmbientMode()
    }

    func setSleepEndDate(_ date: Date) {
        sleepEndMinute = Self.minuteOfDay(date)
        UserDefaults.standard.set(sleepEndMinute, forKey: Self.sleepEndMinuteKey)
        evaluateAmbientMode()
    }

    func setRequireFocusDuringSleepWindow(_ enabled: Bool) {
        requireFocusDuringSleepWindow = enabled
        UserDefaults.standard.set(enabled, forKey: Self.requireFocusKey)
        evaluateAmbientMode()
    }

    func setMotionWakeEnabled(_ enabled: Bool) {
        motionWakeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.motionWakeKey)
        updateMotionWakeMonitoring()
    }

    func setAttentionAwarenessEnabled(_ enabled: Bool) {
        attentionAwarenessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.attentionAwarenessKey)
        if enabled, ambientMode == .screensaver, screensaverAttentionDeadline == nil {
            screensaverAttentionDeadline = Date().addingTimeInterval(Self.screensaverAttentionDuration)
        }
        updateAttentionMonitoring()
    }

    func setShowWeatherInSleepMode(_ enabled: Bool) {
        showWeatherInSleepMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.sleepWeatherKey)
    }

    func setShowNextEventInSleepMode(_ enabled: Bool) {
        showNextEventInSleepMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.sleepNextEventKey)
    }

    private var ambientModeConfiguration: AmbientModeConfiguration {
        AmbientModeConfiguration(
            screensaverEnabled: screensaverEnabled,
            screensaverDelay: screensaverDelay,
            sleepModeEnabled: sleepModeEnabled,
            sleepStartMinute: sleepStartMinute,
            sleepEndMinute: sleepEndMinute,
            requireFocusDuringSleepWindow: requireFocusDuringSleepWindow
        )
    }

    private func startAmbientModeMonitoring() {
        ambientModeTask?.cancel()
        ambientModeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                evaluateAmbientMode()
            }
        }
    }

    private func evaluateAmbientMode(
        now: Date = Date(),
        updatesAttentionMonitoring: Bool = true
    ) {
        guard isRunning, isAppActive else { return }
        if updatesAttentionMonitoring {
            updateAttentionMonitoring(now: now)
        }
        if isManualScreensaverActive, ambientMode == .screensaver {
            return
        }
        let nextMode = AmbientModeResolver.resolve(
            now: now,
            lastInteraction: lastInteractionDate,
            focusIsActive: focusStatus == .active,
            sleepOverrideUntil: sleepOverrideUntil,
            configuration: ambientModeConfiguration
        )
        transitionAmbientMode(to: nextMode)
    }

    private func transitionAmbientMode(to nextMode: AmbientDisplayMode) {
        guard ambientMode != nextMode else { return }

        if nextMode == .sleep {
            applySleepBrightness()
        } else {
            restoreSleepBrightness()
        }

        ambientMode = nextMode
        screensaverAttentionDeadline = nextMode == .screensaver
            ? Date().addingTimeInterval(Self.screensaverAttentionDuration)
            : nil
        guard isRunning, isAppActive else { return }

        if nextMode == .screensaver {
            mirrorProvider.resetAttentionBaseline()
        }

        if nextMode == .dashboard {
            ensureMirrorCaptureRunning()
            activateSelectedFeed()
        } else {
            activeFeedStartTask?.cancel()
            activeFeedStartTask = nil
            stopActiveFeed()
        }
        updateAttentionMonitoring()
    }

    private func applySleepBrightness() {
        guard savedSleepBrightness == nil else { return }
        savedSleepBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
    }

    private func restoreSleepBrightness() {
        guard let savedSleepBrightness else { return }
        UIScreen.main.brightness = savedSleepBrightness
        self.savedSleepBrightness = nil
    }

    private func updateAttentionMonitoring(now: Date = Date()) {
        guard attentionAwarenessEnabled, isRunning, isAppActive else {
            mirrorProvider.setAttentionMonitoring(false)
            return
        }

        switch ambientMode {
        case .dashboard:
            mirrorProvider.setAttentionMonitoring(true)
        case .screensaver:
            let shouldContinue = screensaverAttentionDeadline.map { now < $0 } ?? false
            mirrorProvider.setAttentionMonitoring(shouldContinue)
        case .sleep:
            mirrorProvider.setAttentionMonitoring(false)
        }
    }

    private func updateMotionWakeMonitoring() {
        guard isRunning, isAppActive, motionWakeEnabled else {
            motionManager?.stopDeviceMotionUpdates()
            consecutiveMotionSamples = 0
            return
        }
        let manager: CMMotionManager
        if let motionManager {
            manager = motionManager
        } else {
            let newManager = CMMotionManager()
            motionManager = newManager
            manager = newManager
        }
        guard manager.isDeviceMotionAvailable else {
            manager.stopDeviceMotionUpdates()
            consecutiveMotionSamples = 0
            return
        }
        guard !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 0.2
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion else { return }
            let acceleration = motion.userAcceleration
            let rotation = motion.rotationRate
            let accelerationMagnitude = sqrt(
                acceleration.x * acceleration.x
                    + acceleration.y * acceleration.y
                    + acceleration.z * acceleration.z
            )
            let rotationMagnitude = sqrt(
                rotation.x * rotation.x
                    + rotation.y * rotation.y
                    + rotation.z * rotation.z
            )
            let isMeaningfulMovement = accelerationMagnitude > 0.12 || rotationMagnitude > 0.8
            Task { @MainActor [weak self] in
                self?.processMotionSample(isMeaningfulMovement)
            }
        }
    }

    private func processMotionSample(_ isMeaningfulMovement: Bool) {
        guard motionWakeEnabled, isAppActive else { return }
        if isMeaningfulMovement {
            consecutiveMotionSamples += 1
        } else {
            consecutiveMotionSamples = 0
        }

        guard consecutiveMotionSamples >= 2 else { return }
        consecutiveMotionSamples = 0
        if ambientMode == .dashboard {
            lastInteractionDate = Date()
        } else {
            wakeAmbientDisplay()
        }
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func dateForMinuteOfDay(_ minute: Int, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minute, to: startOfDay) ?? startOfDay
    }

    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed.isEmpty ? "Raaghav" : trimmed
        UserDefaults.standard.set(displayName, forKey: "frame.displayName")
    }

    func setWeatherLocation(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        weatherLocationName = trimmed
        weatherProvider.setManualLocation(trimmed.isEmpty ? nil : trimmed)
        requestWeather()
    }

    func didChangeFeed(to index: Int) {
        guard feeds.indices.contains(index) else { return }
        didChangeFeed(to: feeds[index].id)
    }

    func didChangeFeed(to feedID: String) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }) else {
            selectedFeedID = selectedFeed.id
            return
        }
        guard selectedFeedID != feedID else {
            selectedFeedIndex = index
            return
        }

        if activeFeedID != feedID {
            if isRunning,
               let oldActiveFeed = feeds.first(where: { $0.id == activeFeedID }) {
                // Privacy and recording finalization are immediate. Only the
                // potentially expensive start of the winning page is debounced.
                stopFeed(oldActiveFeed)
            }
            activeFeedID = feedID
        }

        selectedFeedIndex = index
        selectedFeedID = feedID
        hasUserSelectedFeed = true
        preferredFeedID = feedID
        UserDefaults.standard.set(feedID, forKey: Self.selectedFeedKey)
        // A page-style TabView can publish more than one selection while a
        // swipe is settling. Coalesce those changes so AVFoundation and
        // HomeKit only transition to the page that actually wins.
        scheduleActiveFeedStart(after: .milliseconds(220))
    }

    func selectFeed(_ index: Int) {
        guard feeds.indices.contains(index) else { return }
        didChangeFeed(to: index)
    }

    func selectFeed(id: String) {
        guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        didChangeFeed(to: index)
    }

    func presentHome() {
        showingHome = true
        if hasLiveHomeKitDiscovery,
           homeKitState != .noHomes {
            refreshHomeControls()
            prefetchHomeKitSnapshots(for: lastKnownHomeCameras)
            return
        }
        requestHomeKit()
    }

    func dismissHome() {
        showingHome = false
    }

    func toggleMirror() {
        let mirrorFeed = feeds.first(where: \.isMirror) ?? .mirror
        mirrorEnabled.toggle()
        UserDefaults.standard.set(mirrorEnabled, forKey: Self.mirrorEnabledKey)
        if mirrorEnabled {
            guard isRunning,
                  isAppActive,
                  ambientMode == .dashboard else { return }
            startMirrorCapture(for: mirrorFeed.id)
        } else {
            mirrorProvider.stop()
            feedStatuses[mirrorFeed.id] = .unavailable
        }
    }

    func toggleMusicOverlay() {
        musicOverlayVisible.toggle()
        guard musicOverlayVisible,
              currentMusicTrack == nil,
              !musicState.isLoading else { return }
        switch musicState {
        case .idle, .ready, .paused, .denied, .unavailable, .failed:
            requestMusic()
        case .loading, .playing:
            break
        }
    }

    func setCalendarSelection(_ identifiers: Set<String>) {
        selectedCalendarIdentifiers = identifiers
        hasStoredCalendarSelection = true
        // The provider invokes onStoreChanged after persisting this choice;
        // that callback owns the refresh so we do not launch it twice.
        calendarProvider.setSelectedCalendarIdentifiers(identifiers)
    }

    func requestMusic() {
        musicState = .loading
        Task { [weak self] in
            guard let self else { return }
            let access = await musicProvider.requestAccess()
            guard access == .allowed else {
                musicState = access == .denied ? .denied("Apple Music access is off") : .unavailable("Apple Music is not available on this iPad")
                return
            }
            do {
                musicTracks = try await musicProvider.loadTracks()
                currentMusicTrack = musicTracks.first
                selectedMusicPlaylistID = musicProvider.selectedPlaylistID
                selectedMusicPlaylistName = musicProvider.selectedPlaylistName
                updateMusicProgress()
                musicState = .ready
            } catch let error as ProviderError {
                musicState = .failed(error.localizedDescription)
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func toggleMusicPlayback() {
        if musicState.isPlaying {
            musicProvider.pause()
            musicState = .paused
            updateMusicProgress()
            Task { await refreshUpdates() }
            return
        }

        musicState = .loading
        Task { [weak self] in
            guard let self else { return }
            let access = await musicProvider.requestAccess()
            guard access == .allowed else {
                musicState = access == .denied ? .denied("Apple Music access is off") : .unavailable("Apple Music is not available on this iPad")
                return
            }
            do {
                if musicTracks.isEmpty {
                    musicTracks = try await musicProvider.loadTracks()
                    currentMusicTrack = musicTracks.first
                }
                guard let playedTrack = try await musicProvider.play() else {
                    throw ProviderError.unavailable("The selected playlist has no playable tracks.")
                }
                currentMusicTrack = playedTrack
                musicState = .playing
                updateMusicProgress()
                await refreshUpdates()
            } catch let error as ProviderError {
                musicState = .failed(error.localizedDescription)
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func skipMusic() {
        guard !musicTracks.isEmpty else {
            requestMusic()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                currentMusicTrack = try await musicProvider.skipToNext() ?? currentMusicTrack
                if musicState == .idle || musicState == .ready { musicState = .paused }
                updateMusicProgress()
                await refreshUpdates()
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func skipToPreviousMusic() {
        guard !musicTracks.isEmpty else {
            requestMusic()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                currentMusicTrack = try await musicProvider.skipToPrevious() ?? currentMusicTrack
                if musicState == .idle || musicState == .ready { musicState = .paused }
                updateMusicProgress()
                await refreshUpdates()
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func rewindMusic() {
        musicProvider.rewind()
        updateMusicProgress()
    }

    func seekMusic(to time: TimeInterval) {
        musicProvider.seek(to: time)
        updateMusicProgress()
    }

    func loadMusicPlaylists() {
        Task { [weak self] in
            guard let self else { return }
            let access = await musicProvider.requestAccess()
            guard access == .allowed else {
                musicState = access == .denied ? .denied("Music access is off") : .unavailable("Music is not available on this iPad")
                return
            }
            do {
                musicPlaylists = try await musicProvider.loadPlaylists()
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func selectMusicPlaylist(_ id: String?) {
        musicState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                musicTracks = try await musicProvider.selectPlaylist(id: id)
                selectedMusicPlaylistID = musicProvider.selectedPlaylistID
                selectedMusicPlaylistName = musicProvider.selectedPlaylistName
                currentMusicTrack = musicTracks.first
                musicState = .ready
                updateMusicProgress()
            } catch {
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func requestWeather(allowPermissionPrompt: Bool = true) -> Task<Void, Never> {
        weatherTask?.cancel()
        if weatherState.summary == nil {
            weatherState = .loading
        }
        let cachedWeather = weatherState.summary
        let task = Task { [weak self] in
            guard let self else { return }
            if allowPermissionPrompt {
                _ = await weatherProvider.requestLocationAccess()
            } else if weatherProvider.manualLocationName == nil,
                      !weatherProvider.accessWasRequested {
                if cachedWeather == nil {
                    weatherState = .failed("Connect WeatherKit in Settings")
                }
                return
            } else if weatherProvider.manualLocationName == nil {
                _ = await weatherProvider.requestLocationAccess()
            }
            guard !Task.isCancelled else { return }
            do {
                let summary = try await weatherProvider.loadWeather()
                guard !Task.isCancelled else { return }
                weatherState = summary.isStale ? .stale(summary) : .loaded(summary)
                weatherAttribution = try? await weatherProvider.loadAttribution()
            } catch let error as ProviderError {
                guard !Task.isCancelled else { return }
                weatherState = cachedWeather.map(WeatherState.stale) ?? .failed(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                weatherState = cachedWeather.map(WeatherState.stale) ?? .failed(error.localizedDescription)
            }
            await refreshUpdates()
        }
        weatherTask = task
        return task
    }

    @discardableResult
    func requestCalendar(allowPermissionPrompt: Bool = true) -> Task<Void, Never> {
        calendarTask?.cancel()
        if calendarState.items.isEmpty {
            calendarState = .loading
        }
        let cachedItems = calendarState.items
        let task = Task { [weak self] in
            guard let self else { return }
            let permission: PermissionState
            if allowPermissionPrompt {
                permission = await calendarProvider.requestAccess()
            } else {
                permission = calendarProvider.permissionState
            }
            guard !Task.isCancelled else { return }
            guard permission == .allowed else {
                if cachedItems.isEmpty {
                    calendarState = .denied(
                        permission == .unknown
                            ? "Enable Calendar in Settings"
                            : "Calendar access is off"
                    )
                }
                await refreshUpdates()
                return
            }
            calendarOptions = calendarProvider.availableCalendars
            selectedCalendarIdentifiers = calendarProvider.selectedCalendarIdentifiers
            hasStoredCalendarSelection = calendarProvider.hasStoredCalendarSelection
            do {
                let items = try await calendarProvider.upcomingEvents()
                guard !Task.isCancelled else { return }
                calendarState = items.isEmpty ? .empty : .loaded(items)
                configureMap(for: items)
            } catch {
                guard !Task.isCancelled else { return }
                if cachedItems.isEmpty {
                    calendarState = .failed(error.localizedDescription)
                    configureMap(for: [])
                } else {
                    calendarState = .loaded(cachedItems)
                    configureMap(for: cachedItems)
                }
            }
            await refreshUpdates()
        }
        calendarTask = task
        return task
    }

    @discardableResult
    func requestSleep(allowPermissionPrompt: Bool = true) -> Task<Void, Never> {
        sleepTask?.cancel()
        if sleepState.summary == nil {
            sleepState = .loading
        }
        let cachedSleep = sleepState.summary
        let task = Task { [weak self] in
            guard let self else { return }
            if !allowPermissionPrompt, !sleepProvider.accessWasRequested {
                return
            }
            let permission = await sleepProvider.requestAccess()
            guard !Task.isCancelled else { return }
            guard permission == .allowed else {
                if cachedSleep == nil {
                    sleepState = permission == .unavailable ? .unavailable("Health data is not available on this iPad") : .denied("Health access is off")
                }
                await refreshUpdates()
                return
            }
            do {
                let refreshedSleepState = try await sleepProvider.loadLastNight().map(SleepState.loaded) ?? .noData
                guard !Task.isCancelled else { return }
                sleepState = refreshedSleepState
            } catch let error as ProviderError {
                guard !Task.isCancelled else { return }
                if cachedSleep == nil { sleepState = .failed(error.localizedDescription) }
            } catch {
                guard !Task.isCancelled else { return }
                if cachedSleep == nil { sleepState = .failed(error.localizedDescription) }
            }
            await refreshUpdates()
        }
        sleepTask = task
        return task
    }

    func requestHomeKit() {
        if homeKitDiscoveryTask != nil, case .loading = homeKitState {
            return
        }
        homeKitDiscoveryTask?.cancel()
        cancelHomeKitSnapshotPrefetch()
        homeKitDiscoveryGeneration &+= 1
        let generation = homeKitDiscoveryGeneration
        homeKitState = .loading
        homeKitDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if homeKitDiscoveryGeneration == generation {
                    homeKitDiscoveryTask = nil
                }
            }
            do {
                let result = try await homeCameraProvider.discover()
                guard !Task.isCancelled, homeKitDiscoveryGeneration == generation else { return }
                homeControls = result.controls
                lastKnownHomeCameras = result.cameras
                hasLiveHomeKitDiscovery = true
                let homeFeeds = result.cameras.map { FeedSource.homeKit(id: $0.id, name: $0.name, room: $0.roomName) }
                let mapFeed = feeds.contains(where: { $0.isMap }) ? [FeedSource.map] : []
                replaceFeeds([.mirror] + mapFeed + homeFeeds)
                let existingStatuses = feedStatuses
                feedStatuses = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, existingStatuses[$0.id] ?? .unavailable) })
                if !result.hasHomes {
                    homeKitState = .noHomes
                } else if result.cameras.isEmpty {
                    homeKitState = .noCameras
                } else {
                    homeKitState = .loaded(result.cameras)
                    // Snapshot requests are independent background work. One
                    // slow camera must not hold discovery, controls, or the
                    // rest of the feed list in a loading state for 15 seconds.
                    prefetchHomeKitSnapshots(for: result.cameras)
                }
            } catch let error as ProviderError {
                guard !Task.isCancelled else { return }
                hasLiveHomeKitDiscovery = false
                homeKitState = .denied(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                hasLiveHomeKitDiscovery = false
                homeKitState = .failed(error.localizedDescription)
            }
            await refreshUpdates()
        }
    }

    func refreshHomeControls() {
        guard isRunning else { return }
        guard hasLiveHomeKitDiscovery else {
            scheduleHomeKitPrefetch(after: .milliseconds(350))
            return
        }
        homeControlsRefreshTask?.cancel()
        homeControlsRefreshTask = Task { [weak self] in
            guard let self else { return }
            let controls = await homeCameraProvider.refreshControls()
            guard !Task.isCancelled else { return }
            homeControls = controls
            feedStatuses[FeedSource.homeControls.id] = controls.isEmpty ? .unavailable : .live
        }
    }

    func retrySelectedFeed() {
        if selectedFeed.isMirror {
            mirrorEnabled = true
            UserDefaults.standard.set(true, forKey: Self.mirrorEnabledKey)
            activeFeedStartTask?.cancel()
            activeFeedStartTask = nil
            activeFeedID = selectedFeed.id
            feedStatuses[selectedFeed.id] = .starting
            mirrorProvider.retry()
        } else if case .homeKit = selectedFeed {
            activateSelectedFeed(forceRestart: true)
        } else if selectedFeed.isHomeControls {
            requestHomeKit()
        } else if selectedFeed.isMap {
            if let event = nextLocatedEvent(in: calendarState.items) {
                requestRoute(for: event, force: true)
            }
        }
    }

    func toggleHomeLight(_ id: String) {
        guard let control = homeControls.first(where: { $0.id == id }), control.kind == .light else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await homeCameraProvider.setLight(id: id, isOn: !control.isOn)
                replaceHomeControl(updated)
                homeControlMessage = nil
            } catch {
                homeControlMessage = error.localizedDescription
            }
        }
    }

    func setHomeThermostat(_ id: String, displayedTarget: Int) {
        guard let index = homeControls.firstIndex(where: { $0.id == id }), homeControls[index].kind == .thermostat else { return }
        let control = homeControls[index]
        let target = min(max(TemperatureDisplay.celsiusValue(fromDisplayed: displayedTarget), 5), 30)
        if let currentTarget = control.targetTemperature, abs(target - currentTarget) <= 0.001 { return }

        // Keep the wheel responsive while coalescing a drag into one HomeKit
        // write. The provider normalizes this target to the accessory's own
        // supported range and step before writing it.
        var optimisticControl = control
        optimisticControl.targetTemperature = target
        homeControls[index] = optimisticControl
        homeControlMessage = nil

        let generation = (thermostatWriteGenerations[id] ?? 0) + 1
        thermostatWriteGenerations[id] = generation
        thermostatWriteTasks[id]?.cancel()

        thermostatWriteTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled, let self else { return }

                let updated = try await self.homeCameraProvider.setThermostat(id: id, targetTemperature: target)
                guard self.thermostatWriteGenerations[id] == generation else { return }
                self.replaceHomeControl(updated)
                self.homeControlMessage = nil
            } catch is CancellationError {
                // A newer wheel tick will publish the most recent target.
            } catch {
                guard let self, self.thermostatWriteGenerations[id] == generation else { return }
                self.replaceHomeControl(control)
                self.homeControlMessage = error.localizedDescription
            }
        }
    }

    func toggleHomeSpeaker(_ id: String) {
        guard let control = homeControls.first(where: { $0.id == id }), control.kind == .speaker else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await homeCameraProvider.setSpeaker(id: id, isOn: !control.isOn)
                replaceHomeControl(updated)
                homeControlMessage = nil
            } catch {
                homeControlMessage = error.localizedDescription
            }
        }
    }

    func adjustHomeSpeakerVolume(_ id: String, delta: Double) {
        guard let control = homeControls.first(where: { $0.id == id }), control.kind == .speaker else { return }
        let volume = min(max((control.volume ?? 0) + delta, 0), 100)
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await homeCameraProvider.setSpeakerVolume(id: id, volume: volume)
                replaceHomeControl(updated)
                homeControlMessage = nil
            } catch {
                homeControlMessage = error.localizedDescription
            }
        }
    }

    private func refreshLiveData() async {
        // These sources are independent. Start all three before awaiting any
        // result so a slow location or permission service cannot hold the other
        // cached cards behind it.
        let weatherRefresh = requestWeather(allowPermissionPrompt: false)
        let calendarRefresh = requestCalendar(allowPermissionPrompt: false)
        let sleepRefresh = requestSleep(allowPermissionPrompt: false)
        await weatherRefresh.value
        await calendarRefresh.value
        await sleepRefresh.value
    }

    private func refreshUpdates() async {
        let previousUpdates = updates
        let weather = weatherState.summary
        let agenda = calendarState.items.filter { $0.date > Date() }
        var nextUpdates = await updatesProvider.makeUpdates(weather: weather, agenda: agenda, feedStatuses: feedStatuses, includeSunriseSunset: showSunriseSunsetUpdate)
        if Self.isMorningWindow(Date()), let summary = sleepState.summary {
            nextUpdates.insert(Self.sleepUpdate(for: summary), at: 0)
        }
        if musicState.isPlaying, let track = currentMusicTrack {
            nextUpdates.insert(
                UpdateItem(
                    id: "music-now-playing",
                    title: "Now playing",
                    detail: "\(track.title) · \(track.artist)",
                    kind: .music,
                    accent: "#D7B4F4",
                    date: nil
                ),
                at: 0
            )
        }
        let visibleUpdates = addTravelPlan(to: Self.updatesWithUniqueIDs(nextUpdates))
        archiveUpdates(previousUpdates.filter { previous in
            !visibleUpdates.contains(where: { $0.id == previous.id })
        })
        if !Self.isMorningWindow(Date()), let summary = sleepState.summary {
            archiveUpdates([Self.sleepUpdate(for: summary)])
        }
        updates = visibleUpdates
        persistDashboardSnapshot()
    }

    private func addTravelPlan(to updates: [UpdateItem]) -> [UpdateItem] {
        guard let route = routeState.summary,
              let routeEventID,
              let event = calendarState.items.first(where: { $0.id == routeEventID }),
              event.date > Date(),
              !event.isAllDay,
              let eventIndex = updates.firstIndex(where: { $0.id == "agenda-\(event.id)" }) else {
            return updates
        }

        let leaveBy = TravelTimeMath.leaveByDate(
            arrivalDate: event.date,
            travelTimeMinutes: route.travelTimeMinutes
        )
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let eventUpdate = updates[eventIndex]
        var enriched = updates
        enriched[eventIndex] = UpdateItem(
            id: eventUpdate.id,
            title: "Travel time · \(route.travelTimeMinutes) min",
            detail: "Leave by \(timeFormatter.string(from: leaveBy))",
            kind: eventUpdate.kind,
            accent: eventUpdate.accent,
            date: eventUpdate.date,
            secondaryTitle: eventUpdate.title,
            secondaryDetail: eventUpdate.detail,
            systemImage: "clock.fill",
            secondarySystemImage: "calendar"
        )
        return enriched
    }

    private func persistDashboardSnapshot() {
        let snapshot = StoredDashboardSnapshot(
            savedAt: Date(),
            weather: weatherState.summary,
            agenda: calendarState.items,
            sleep: sleepState.summary,
            updates: updates,
            homeCameras: lastKnownHomeCameras,
            homeControls: homeControls
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.dashboardSnapshotKey)
    }

    private static func loadDashboardSnapshot() -> StoredDashboardSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: dashboardSnapshotKey),
              let snapshot = try? JSONDecoder().decode(StoredDashboardSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) <= dashboardSnapshotMaxAge else {
            return nil
        }

        let upcomingAgenda = snapshot.agenda.filter { event in
            let endDate = event.endDate ?? event.date
            return endDate > Date()
        }
        let currentUpdates = snapshot.updates.filter { update in
            guard update.kind == .calendar, let date = update.date else { return true }
            return date > Date()
        }
        return StoredDashboardSnapshot(
            savedAt: snapshot.savedAt,
            weather: snapshot.weather,
            agenda: upcomingAgenda,
            sleep: snapshot.sleep,
            updates: currentUpdates,
            homeCameras: snapshot.homeCameras,
            homeControls: snapshot.homeControls
        )
    }

    func setShowSunriseSunsetUpdate(_ enabled: Bool) {
        showSunriseSunsetUpdate = enabled
        UserDefaults.standard.set(enabled, forKey: "frame.showSunriseSunsetUpdate")
        Task { await refreshUpdates() }
    }

    private func replaceHomeControl(_ updated: HomeControl) {
        guard let index = homeControls.firstIndex(where: { $0.id == updated.id }) else { return }
        homeControls[index] = updated
    }

    private static func isMorningWindow(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 5 && hour < 12
    }

    private static func sleepUpdate(for summary: SleepSummary) -> UpdateItem {
        UpdateItem(
            id: "sleep-summary",
            title: "Last night · \(summary.durationLabel)",
            detail: summary.stageDetail,
            kind: .sleep,
            accent: "#BCA7F4",
            date: summary.sleepEnd
        )
    }

    private static let pastUpdatesKey = "frame.pastUpdates"
    private static let clearedUpdateLifetime: TimeInterval = 24 * 60 * 60

    private struct ClearedUpdateRecord: Codable {
        let clearedAt: Date
        let item: UpdateItem
    }

    private struct StoredPastUpdates: Codable {
        let day: Date
        let items: [UpdateItem]
    }

    private static func loadClearedUpdateRecords(now: Date = Date()) -> [ClearedUpdateRecord] {
        guard let data = UserDefaults.standard.data(forKey: pastUpdatesKey) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-clearedUpdateLifetime)
        if let records = try? JSONDecoder().decode([ClearedUpdateRecord].self, from: data) {
            return records.filter { $0.clearedAt >= cutoff }
        }

        // Migrate the previous calendar-day format. Its `day` was the most
        // recent archive time, so it is the best available clearance time.
        guard let stored = try? JSONDecoder().decode(StoredPastUpdates.self, from: data),
              stored.day >= cutoff else {
            return []
        }
        return updatesWithUniqueIDs(stored.items).map {
            ClearedUpdateRecord(clearedAt: stored.day, item: $0)
        }
    }

    func presentClearedUpdates() {
        pruneClearedUpdates()
        showingUpdates = true
    }

    private func archiveUpdates(_ candidates: [UpdateItem]) {
        let now = Date()
        pruneClearedUpdates(now: now, persist: false)

        var knownIDs = Set(clearedUpdateRecords.map(\.item.id))
        let newItems = candidates.filter { candidate in
            knownIDs.insert(candidate.id).inserted
        }
        clearedUpdateRecords.append(contentsOf: newItems.map {
            ClearedUpdateRecord(clearedAt: now, item: $0)
        })
        pastUpdates = clearedUpdateRecords.map(\.item)
        if let data = try? JSONEncoder().encode(clearedUpdateRecords) {
            UserDefaults.standard.set(data, forKey: Self.pastUpdatesKey)
        }
    }

    private func pruneClearedUpdates(now: Date = Date(), persist: Bool = true) {
        let cutoff = now.addingTimeInterval(-Self.clearedUpdateLifetime)
        clearedUpdateRecords.removeAll { $0.clearedAt < cutoff }
        pastUpdates = clearedUpdateRecords.map(\.item)
        guard persist, let data = try? JSONEncoder().encode(clearedUpdateRecords) else { return }
        UserDefaults.standard.set(data, forKey: Self.pastUpdatesKey)
    }

    private static func updatesWithUniqueIDs(_ items: [UpdateItem]) -> [UpdateItem] {
        var seenIDs = Set<String>()
        return items.filter { seenIDs.insert($0.id).inserted }
    }

    private func activateSelectedFeed(forceRestart: Bool = false) {
        guard isRunning, isAppActive, ambientMode == .dashboard else { return }
        let nextFeedID = selectedFeed.id
        if activeFeedID != nextFeedID || forceRestart {
            stopActiveFeed()
            activeFeedID = nextFeedID
        }
        startActiveFeed()
    }

    private func startActiveFeed() {
        guard isRunning, isAppActive, ambientMode == .dashboard else { return }
        let feed = selectedFeed
        switch feed {
        case .mirror:
            guard mirrorEnabled else {
                feedStatuses[feed.id] = .unavailable
                return
            }
            startMirrorCapture(for: feed.id)
        case .homeKit(let id, _, _):
            guard hasLiveHomeKitDiscovery else {
                feedStatuses[feed.id] = .starting
                scheduleHomeKitPrefetch(after: .milliseconds(350))
                return
            }
            if activeHomeKitSource != nil, feedStatuses[feed.id] == .live {
                return
            }
            if homeKitStreamTask != nil, feedStatuses[feed.id] == .starting {
                return
            }
            homeKitStreamTask?.cancel()
            homeKitStreamGeneration &+= 1
            let generation = homeKitStreamGeneration
            let feedID = feed.id
            feedStatuses[feed.id] = .starting
            homeKitStreamTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if homeKitStreamGeneration == generation {
                        homeKitStreamTask = nil
                    }
                }
                do {
                let source = try await homeCameraProvider.startStream(for: id)
                    guard !Task.isCancelled,
                          self.activeFeedID == feedID,
                          self.selectedFeedID == feedID,
                          self.homeKitStreamGeneration == generation else {
                        homeCameraProvider.stopStream(for: id)
                        return
                    }
                    activeHomeKitSource = source
                    activeHomeKitSourceFeedID = feedID
                    feedStatuses[feedID] = .live
                } catch let error as ProviderError {
                    guard !Task.isCancelled, self.activeFeedID == feedID else { return }
                    feedStatuses[feedID] = error.localizedDescription.lowercased().contains("permission") ? .denied : .failed(error.localizedDescription)
                } catch {
                    guard !Task.isCancelled, self.activeFeedID == feedID else { return }
                    feedStatuses[feedID] = .failed(error.localizedDescription)
                }
                await refreshUpdates()
            }
        case .map:
            feedStatuses[feed.id] = .starting
            if let event = nextLocatedEvent(in: calendarState.items) {
                requestRoute(for: event, force: routeState.summary == nil, allowingLocationPrompt: true)
            } else {
                routeState = .unavailable("No upcoming calendar event has a location.")
                feedStatuses[feed.id] = .unavailable
            }
        case .homeControls:
            if hasLiveHomeKitDiscovery {
                feedStatuses[feed.id] = homeControls.isEmpty ? .unavailable : .live
            } else {
                feedStatuses[feed.id] = homeControls.isEmpty ? .unavailable : .starting
                scheduleHomeKitPrefetch(after: .milliseconds(350))
            }
        }
    }

    private func startMirrorCapture(for feedID: String) {
        feedStatuses[feedID] = .starting
        mirrorProvider.start()
        switch mirrorProvider.status {
        case .live: feedStatuses[feedID] = .live
        case .denied: feedStatuses[feedID] = .denied
        case .unavailable: feedStatuses[feedID] = .unavailable
        case .requesting, .unknown: feedStatuses[feedID] = .starting
        case .stopped: feedStatuses[feedID] = .unavailable
        }
    }

    private func ensureMirrorCaptureRunning() {
        guard mirrorEnabled,
              mirrorProvider.status != .live,
              mirrorProvider.status != .requesting else { return }
        let mirrorFeed = feeds.first(where: \.isMirror) ?? .mirror
        startMirrorCapture(for: mirrorFeed.id)
    }

    private func attachMirrorStatusCallback() {
        mirrorProvider.onStatusChange = { [weak self] in
            guard let self else { return }
            self.syncMirrorStatus()
        }
        mirrorProvider.onSessionChange = { [weak self] in
            self?.mirrorSessionRevision &+= 1
        }
        mirrorProvider.onFacePresenceChange = { [weak self] isPresent in
            self?.processFacePresence(isPresent)
        }
        mirrorProvider.onRecordingChange = { [weak self] in
            self?.mirrorRecordingStartedAt = self?.mirrorProvider.recordingStartedAt
        }
        mirrorProvider.onCaptureResult = { [weak self] result in
            guard let self else { return }
            mirrorCaptureResultTask?.cancel()
            mirrorCaptureResult = result
            let announcement: String
            switch result {
            case .photoSaved: announcement = "Photo saved"
            case .videoSaved: announcement = "Video saved"
            case .failed(let message): announcement = message
            }
            UIAccessibility.post(notification: .announcement, argument: announcement)
            mirrorCaptureResultTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                self?.mirrorCaptureResult = nil
            }
        }
    }

    @discardableResult
    func captureMirrorPhoto() -> Bool {
        guard selectedFeed.isMirror, mirrorEnabled else { return false }
        return mirrorProvider.capturePhoto()
    }

    @discardableResult
    func startMirrorRecording() -> Bool {
        guard selectedFeed.isMirror, mirrorEnabled else { return false }
        return mirrorProvider.startRecording()
    }

    func stopMirrorRecording() {
        mirrorProvider.stopRecording()
    }

    private func processFacePresence(_ isPresent: Bool) {
        guard attentionAwarenessEnabled,
              isPresent,
              isRunning,
              isAppActive else { return }

        switch ambientMode {
        case .dashboard:
            lastInteractionDate = Date()
        case .screensaver:
            guard screensaverAttentionDeadline.map({ Date() < $0 }) == true else { return }
            wakeAmbientDisplay()
        case .sleep:
            break
        }
    }

    private func attachCalendarCallbacks() {
        calendarProvider.onStoreChanged = { [weak self] in
            guard let self else { return }
            self.calendarOptions = self.calendarProvider.availableCalendars
            self.selectedCalendarIdentifiers = self.calendarProvider.selectedCalendarIdentifiers
            self.hasStoredCalendarSelection = self.calendarProvider.hasStoredCalendarSelection
            self.requestCalendar()
        }
    }

    private func attachHomeKitCallbacks() {
        homeCameraProvider.onStreamStateChanged = { [weak self] id, _ in
            guard let self else { return }
            let feedID = "homekit-\(id.uuidString)"
            guard self.activeFeedID == feedID else { return }
            self.activeHomeKitSource = nil
            self.activeHomeKitSourceFeedID = nil
            self.feedStatuses[feedID] = .offline
            Task { await self.refreshUpdates() }
        }
        homeCameraProvider.onControlsChanged = { [weak self] controls in
            guard let self else { return }
            self.homeControls = controls
            self.feedStatuses[FeedSource.homeControls.id] = controls.isEmpty ? .unavailable : .live
        }
    }

    private func syncMirrorStatus() {
        let feedID = feeds.first(where: \.isMirror)?.id ?? FeedSource.mirror.id
        switch mirrorProvider.status {
        case .live: feedStatuses[feedID] = .live
        case .denied: feedStatuses[feedID] = .denied
        case .unavailable: feedStatuses[feedID] = .unavailable
        case .requesting, .unknown: feedStatuses[feedID] = .starting
        case .stopped: feedStatuses[feedID] = .unavailable
        }
    }

    private func stopActiveFeed() {
        guard let feed = feeds.first(where: { $0.id == activeFeedID }) else { return }
        stopFeed(feed)
    }

    private func stopFeed(_ feed: FeedSource) {
        switch feed {
        case .mirror:
            // Feed paging only changes which surface is visible. Keep the
            // camera graph warm so returning to Mirror never requires a new
            // daemon/session startup. Explicit Mirror-off, app shutdown, and a
            // sustained background transition stop it directly.
            break
        case .homeKit(let id, _, _):
            homeKitStreamTask?.cancel()
            homeKitStreamTask = nil
            homeKitStreamGeneration &+= 1
            homeCameraProvider.stopStream(for: id)
            activeHomeKitSource = nil
            activeHomeKitSourceFeedID = nil
        case .map:
            break
        case .homeControls:
            break
        }
    }

    private func replaceFeeds(_ newFeeds: [FeedSource]) {
        guard !newFeeds.isEmpty else { return }
        let oldActiveFeed = feeds.first(where: { $0.id == activeFeedID })
        let activeStillExists = newFeeds.contains(where: { $0.id == activeFeedID })
        let selectedStillExists = newFeeds.contains(where: { $0.id == selectedFeedID })

        if !activeStillExists, let oldActiveFeed {
            stopFeed(oldActiveFeed)
        }

        feeds = newFeeds
        if !hasUserSelectedFeed,
           let preferredFeedID,
           newFeeds.contains(where: { $0.id == preferredFeedID }) {
            selectedFeedID = preferredFeedID
        } else if !selectedStillExists {
            selectedFeedID = newFeeds.first(where: { $0.isMirror })?.id
                ?? newFeeds[0].id
        }
        selectedFeedIndex = newFeeds.firstIndex(where: { $0.id == selectedFeedID }) ?? 0

        if activeFeedID != selectedFeedID,
           isRunning,
           isAppActive,
           ambientMode == .dashboard {
            scheduleActiveFeedStart(after: .milliseconds(220))
        }
    }

    private func prefetchHomeKitSnapshots(for cameras: [HomeKitCameraDescriptor]) {
        guard isRunning, isAppActive, hasLiveHomeKitDiscovery else { return }
        let pendingCameras = cameras.prefix(3).filter {
            homeKitSnapshots["homekit-\($0.id.uuidString)"] == nil
        }
        guard !pendingCameras.isEmpty else { return }

        cancelHomeKitSnapshotPrefetch()
        homeKitSnapshotGeneration &+= 1
        let generation = homeKitSnapshotGeneration
        for camera in pendingCameras {
            let feedID = "homekit-\(camera.id.uuidString)"
            homeKitSnapshotTasks[feedID] = Task { [weak self] in
                guard let self else { return }
                let snapshot = try? await homeCameraProvider.snapshot(for: camera.id)
                guard !Task.isCancelled, homeKitSnapshotGeneration == generation else { return }
                if let snapshot {
                    homeKitSnapshots[feedID] = snapshot
                    feedStatuses[feedID] = .snapshotAvailable
                }
                homeKitSnapshotTasks[feedID] = nil
            }
        }
    }

    private func cancelHomeKitSnapshotPrefetch() {
        homeKitSnapshotGeneration &+= 1
        homeKitSnapshotTasks.values.forEach { $0.cancel() }
        homeKitSnapshotTasks.removeAll()
    }

    private func configureMap(for items: [AgendaItem]) {
        guard let event = nextLocatedEvent(in: items) else {
            routeGeneration &+= 1
            routeTask?.cancel()
            routeTask = nil
            routeEventID = nil
            if let mapIndex = feeds.firstIndex(where: { $0.isMap }) {
                var nextFeeds = feeds
                nextFeeds.remove(at: mapIndex)
                replaceFeeds(nextFeeds)
                feedStatuses.removeValue(forKey: FeedSource.map.id)
            }
            routeState = .idle
            return
        }

        if !feeds.contains(where: { $0.isMap }) {
            let mirrorFeeds = feeds.filter(\.isMirror)
            let remainingFeeds = feeds.filter { !$0.isMirror && !$0.isMap }
            replaceFeeds(mirrorFeeds + [.map] + remainingFeeds)
            feedStatuses[FeedSource.map.id] = .starting
        }
        // Updates can use an already-authorized location without interrupting
        // launch. Selecting Map remains the explicit path that can request
        // Location Services when the person wants a route immediately.
        if selectedFeed.isMap {
            requestRoute(for: event, force: routeState.summary == nil, allowingLocationPrompt: true)
        } else if routeEventID != event.id || (routeState.summary == nil && routeState != .loading) {
            requestRoute(for: event, force: routeEventID == event.id, allowingLocationPrompt: false)
        } else if routeState.summary != nil {
            feedStatuses[FeedSource.map.id] = .live
        } else {
            feedStatuses[FeedSource.map.id] = .unavailable
        }
    }

    private func updateMusicProgress() {
        // The progress timer starts with the dashboard, but MusicKit must stay
        // dormant until the person has deliberately loaded or played music.
        // Calling into ApplicationMusicPlayer here would otherwise establish
        // its connection during every launch.
        guard currentMusicTrack != nil || !musicTracks.isEmpty || musicState.isPlaying else { return }
        if let playerTrack = musicProvider.currentTrack(),
           playerTrack.id != currentMusicTrack?.id {
            currentMusicTrack = playerTrack
            // MusicKit can advance the queue without any button action. Keep
            // the Updates "Now playing" item in step with the overlay.
            Task { [weak self] in
                await self?.refreshUpdates()
            }
        }
        let progress = musicProvider.playbackProgress()
        musicPlaybackTime = progress.time
        musicPlaybackDuration = progress.duration
    }

    private func nextLocatedEvent(in items: [AgendaItem]) -> AgendaItem? {
        items.sorted { $0.date < $1.date }.first(where: {
            guard $0.date > Date(),
                  let location = $0.location?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !location.isEmpty
        })
    }

    private func requestRoute(
        for event: AgendaItem,
        force: Bool = false,
        allowingLocationPrompt: Bool = true
    ) {
        guard force || routeEventID != event.id else { return }
        routeTask?.cancel()
        routeEventID = event.id
        routeGeneration &+= 1
        let generation = routeGeneration
        routeState = .loading
        feedStatuses[FeedSource.map.id] = .starting
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await routeProvider.route(
                    for: event,
                    transportMode: routeTransportMode,
                    allowingLocationPrompt: allowingLocationPrompt
                )
                guard !Task.isCancelled, self.routeGeneration == generation else { return }
                routeState = .loaded(summary)
                feedStatuses[FeedSource.map.id] = .live
                await refreshUpdates()
            } catch let error as ProviderError {
                guard !Task.isCancelled, self.routeGeneration == generation else { return }
                if allowingLocationPrompt {
                    routeState = .failed(error.localizedDescription)
                    feedStatuses[FeedSource.map.id] = .failed(error.localizedDescription)
                } else {
                    routeState = .idle
                    feedStatuses[FeedSource.map.id] = .unavailable
                }
                await refreshUpdates()
            } catch {
                guard !Task.isCancelled, self.routeGeneration == generation else { return }
                if allowingLocationPrompt {
                    routeState = .failed(error.localizedDescription)
                    feedStatuses[FeedSource.map.id] = .failed(error.localizedDescription)
                } else {
                    routeState = .idle
                    feedStatuses[FeedSource.map.id] = .unavailable
                }
                await refreshUpdates()
            }
        }
    }
}
