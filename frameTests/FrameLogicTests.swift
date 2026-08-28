import XCTest
@testable import frame

@MainActor
final class FrameLogicTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20,
            hour: hour,
            minute: minute
        ))!
    }

    private func ambientConfiguration(
        screensaverEnabled: Bool = true,
        screensaverDelay: TimeInterval = 300,
        sleepModeEnabled: Bool = true,
        requireFocus: Bool = false
    ) -> AmbientModeConfiguration {
        AmbientModeConfiguration(
            screensaverEnabled: screensaverEnabled,
            screensaverDelay: screensaverDelay,
            sleepModeEnabled: sleepModeEnabled,
            sleepStartMinute: 22 * 60,
            sleepEndMinute: 7 * 60,
            requireFocusDuringSleepWindow: requireFocus
        )
    }

    func testMergingOverlappingIntervalsDoesNotDoubleCount() {
        let base = Date(timeIntervalSince1970: 0)
        let intervals = [
            (base, base.addingTimeInterval(60 * 60)),
            (base.addingTimeInterval(30 * 60), base.addingTimeInterval(90 * 60)),
            (base.addingTimeInterval(3 * 60 * 60), base.addingTimeInterval(4 * 60 * 60))
        ]

        XCTAssertEqual(IntervalMath.mergedMinutes(intervals), 150)
    }

    func testMergingIgnoresReversedIntervals() {
        let base = Date(timeIntervalSince1970: 0)
        let intervals = [
            (base.addingTimeInterval(10 * 60), base),
            (base, base.addingTimeInterval(20 * 60))
        ]

        XCTAssertEqual(IntervalMath.mergedMinutes(intervals), 20)
    }

    func testLeaveByUsesTheEventStartAsArrivalTime() {
        let eventStart = date(hour: 18, minute: 30)

        XCTAssertEqual(
            TravelTimeMath.leaveByDate(arrivalDate: eventStart, travelTimeMinutes: 45),
            date(hour: 17, minute: 45)
        )
    }

    func testLeaveByDoesNotAddTimeForNegativeTravelDuration() {
        let eventStart = date(hour: 18, minute: 30)

        XCTAssertEqual(
            TravelTimeMath.leaveByDate(arrivalDate: eventStart, travelTimeMinutes: -10),
            eventStart
        )
    }

    func testLegacyUpdateItemDecodesAsARegularCard() throws {
        let data = Data("{\"id\":\"legacy\",\"title\":\"Design review\",\"detail\":\"Today at 4:00 PM\",\"kind\":\"calendar\",\"accent\":\"#FF3B30\",\"date\":null}".utf8)
        let update = try JSONDecoder().decode(UpdateItem.self, from: data)

        XCTAssertNil(update.secondaryTitle)
        XCTAssertNil(update.secondaryDetail)
        XCTAssertNil(update.systemImage)
        XCTAssertNil(update.secondarySystemImage)
    }

    func testDoubleHeightUpdateContentSurvivesPersistence() throws {
        let update = UpdateItem(
            id: "travel",
            title: "Travel time · 25 min",
            detail: "Leave by 5:35 PM",
            kind: .calendar,
            accent: "#FF3B30",
            date: date(hour: 18),
            secondaryTitle: "Dinner with Ryan",
            secondaryDetail: "Today at 6:00 PM · Downtown",
            systemImage: "clock.fill",
            secondarySystemImage: "calendar"
        )

        let restored = try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(update))
        XCTAssertEqual(restored, update)
    }

    func testAgendaItemDefaultsSupportLiveCalendarMetadata() {
        let item = AgendaItem(
            id: "event",
            title: "Design review",
            date: Date(timeIntervalSince1970: 100),
            calendarName: "Work",
            isPrivate: false,
            location: "Apple Park"
        )

        XCTAssertNil(item.endDate)
        XCTAssertNil(item.calendarIdentifier)
        XCTAssertNil(item.locationCoordinate)
        XCTAssertFalse(item.isAllDay)
    }

    func testAgendaItemCanRetainStructuredLocationCoordinate() {
        let item = AgendaItem(
            id: "event",
            title: "Transit appointment",
            date: Date(timeIntervalSince1970: 100),
            calendarName: "Work",
            isPrivate: false,
            location: "Downtown station",
            locationCoordinate: MapRoutePoint(latitude: 34.414, longitude: -119.848)
        )

        XCTAssertEqual(item.locationCoordinate, MapRoutePoint(latitude: 34.414, longitude: -119.848))
    }

    func testOvernightSleepWindowWrapsAcrossMidnight() {
        XCTAssertTrue(AmbientModeResolver.isWithinSleepWindow(
            date(hour: 23),
            startMinute: 22 * 60,
            endMinute: 7 * 60,
            calendar: utcCalendar
        ))
        XCTAssertTrue(AmbientModeResolver.isWithinSleepWindow(
            date(hour: 6, minute: 30),
            startMinute: 22 * 60,
            endMinute: 7 * 60,
            calendar: utcCalendar
        ))
        XCTAssertFalse(AmbientModeResolver.isWithinSleepWindow(
            date(hour: 12),
            startMinute: 22 * 60,
            endMinute: 7 * 60,
            calendar: utcCalendar
        ))
    }

    func testSleepModeTakesPriorityOverIdleScreensaver() {
        let now = date(hour: 23)
        let mode = AmbientModeResolver.resolve(
            now: now,
            lastInteraction: now.addingTimeInterval(-3_600),
            focusIsActive: false,
            sleepOverrideUntil: nil,
            configuration: ambientConfiguration(),
            calendar: utcCalendar
        )

        XCTAssertEqual(mode, .sleep)
    }

    func testFocusRequirementPreventsUnfocusedSleepMode() {
        let now = date(hour: 23)
        let mode = AmbientModeResolver.resolve(
            now: now,
            lastInteraction: now,
            focusIsActive: false,
            sleepOverrideUntil: nil,
            configuration: ambientConfiguration(requireFocus: true),
            calendar: utcCalendar
        )

        XCTAssertEqual(mode, .dashboard)
    }

    func testScreensaverStartsAfterIdleDelay() {
        let now = date(hour: 14)
        let mode = AmbientModeResolver.resolve(
            now: now,
            lastInteraction: now.addingTimeInterval(-301),
            focusIsActive: false,
            sleepOverrideUntil: nil,
            configuration: ambientConfiguration(sleepModeEnabled: false),
            calendar: utcCalendar
        )

        XCTAssertEqual(mode, .screensaver)
    }

    func testTemporaryWakeSuppressesSleepMode() {
        let now = date(hour: 23)
        let mode = AmbientModeResolver.resolve(
            now: now,
            lastInteraction: now,
            focusIsActive: true,
            sleepOverrideUntil: now.addingTimeInterval(30 * 60),
            configuration: ambientConfiguration(requireFocus: true),
            calendar: utcCalendar
        )

        XCTAssertEqual(mode, .dashboard)
    }

    func testBackgroundMotionPreferenceDefaultsOnAndPersists() {
        let suiteName = "FrameLogicTests.backgroundMotion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialStore = FrameBackgroundStore(defaults: defaults)
        XCTAssertTrue(initialStore.isDynamic)

        initialStore.setDynamic(false)

        let restoredStore = FrameBackgroundStore(defaults: defaults)
        XCTAssertFalse(restoredStore.isDynamic)
    }

    func testLegacyBackgroundStylesMigrateToCaliforniaThemes() {
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue("sunrise"), .losAngeles)
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue("coastal"), .santaBarbara)
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue("meadow"), .tahoe)
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue("dusk"), .redwood)
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue("graphite"), .sanFrancisco)
        XCTAssertEqual(FrameBackgroundStyle.resolvingStoredValue(nil), .tahoe)
    }

    func testDynamicTuningPersistsAndClamps() {
        let suiteName = "FrameLogicTests.dynamicTuning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FrameBackgroundStore(defaults: defaults)

        store.setDynamicSpeed(8)
        store.setDynamicCrispness(-1)
        store.setDynamicIntensity(4)
        store.setDynamicWaveCount(40)
        store.setDynamicVerticalSpread(8)
        XCTAssertEqual(store.dynamicSpeed, 2)
        XCTAssertEqual(store.dynamicCrispness, 0.2)
        XCTAssertEqual(store.dynamicIntensity, 1.5)
        XCTAssertEqual(store.dynamicWaveCount, 12)
        XCTAssertEqual(store.dynamicVerticalSpread, 1.25)

        let restoredStore = FrameBackgroundStore(defaults: defaults)
        XCTAssertEqual(restoredStore.dynamicSpeed, 2)
        XCTAssertEqual(restoredStore.dynamicCrispness, 0.2)
        XCTAssertEqual(restoredStore.dynamicIntensity, 1.5)
        XCTAssertEqual(restoredStore.dynamicWaveCount, 12)
        XCTAssertEqual(restoredStore.dynamicVerticalSpread, 1.25)

        store.resetDynamicTuning()
        XCTAssertEqual(store.dynamicSpeed, 1)
        XCTAssertEqual(store.dynamicCrispness, 0.75)
        XCTAssertEqual(store.dynamicIntensity, 1)
        XCTAssertEqual(store.dynamicWaveCount, 8)
        XCTAssertEqual(store.dynamicVerticalSpread, 1)

        let relaunchedStore = FrameBackgroundStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.dynamicSpeed, 1)
        XCTAssertEqual(relaunchedStore.dynamicCrispness, 0.75)
        XCTAssertEqual(relaunchedStore.dynamicIntensity, 1)
        XCTAssertEqual(relaunchedStore.dynamicWaveCount, 8)
        XCTAssertEqual(relaunchedStore.dynamicVerticalSpread, 1)
    }

    func testHomeDiscoveryStateCanBeRestoredFromCache() throws {
        let camera = HomeKitCameraDescriptor(
            id: UUID(),
            name: "Entry",
            roomName: "Hallway",
            homeName: "Home",
            supportsStream: true,
            supportsSnapshot: true
        )
        let control = HomeControl(
            id: "light-entry",
            name: "Entry Light",
            roomName: "Hallway",
            kind: .light,
            isOn: true,
            currentTemperature: nil,
            targetTemperature: nil,
            volume: nil,
            isMuted: nil,
            lightColor: .init(hue: 0.1, saturation: 0.7, brightness: 0.8)
        )

        let cameras = try JSONDecoder().decode(
            [HomeKitCameraDescriptor].self,
            from: JSONEncoder().encode([camera])
        )
        let controls = try JSONDecoder().decode(
            [HomeControl].self,
            from: JSONEncoder().encode([control])
        )

        XCTAssertEqual(cameras, [camera])
        XCTAssertEqual(controls, [control])
    }

    func testReadingMirrorPreviewSessionDoesNotConstructCaptureGraph() {
        let provider = AVFoundationMirrorProvider()

        XCTAssertNil(provider.session)
        XCTAssertNil(provider.session)
        XCTAssertEqual(provider.status, .stopped)
    }

    func testMirrorFrameLivenessRequiresAndPublishesOneFirstFramePerGeneration() {
        var uptime: TimeInterval = 10
        let liveness = MirrorFrameLiveness(now: { uptime })

        XCTAssertNil(liveness.frameAge())
        liveness.begin(generation: 41)
        XCTAssertEqual(liveness.frameAge(), 0)

        uptime = 13.5
        XCTAssertEqual(liveness.frameAge(), 3.5)
        XCTAssertEqual(liveness.noteFrame(), 41)
        XCTAssertNil(liveness.noteFrame())
        XCTAssertEqual(liveness.frameAge(), 0)

        uptime = 20
        liveness.begin(generation: 42)
        XCTAssertEqual(liveness.frameAge(), 0)
        XCTAssertEqual(liveness.noteFrame(), 42)
        XCTAssertNil(liveness.noteFrame())
    }

    func testMirrorFrameLivenessStopClearsStaleFrameState() {
        var uptime: TimeInterval = 100
        let liveness = MirrorFrameLiveness(now: { uptime })

        liveness.begin(generation: 8)
        XCTAssertEqual(liveness.noteFrame(), 8)
        uptime = 104
        XCTAssertEqual(liveness.frameAge(), 4)

        liveness.stop()
        XCTAssertNil(liveness.frameAge())
        XCTAssertNil(liveness.noteFrame())
    }
}
