import AVFoundation
import AVKit
import Combine
import HomeKit
import MapKit
import PhotosUI
import SwiftUI
import UIKit

@main
struct FrameApp: App {
    var body: some Scene {
        WindowGroup {
            FrameRootView()
        }
    }
}

@MainActor
private struct FrameRootView: View {
    @StateObject private var model: DashboardModel

    init() {
        _model = StateObject(wrappedValue: DashboardModel.live())
    }

    var body: some View {
        ContentView(model: model)
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var model: DashboardModel
    @StateObject private var backgroundStore = FrameBackgroundStore()
    @Environment(\.scenePhase) private var scenePhase
    let isStartupReady: Bool

    init(model: DashboardModel, isStartupReady: Bool = true) {
        _model = StateObject(wrappedValue: model)
        self.isStartupReady = isStartupReady
    }

    var body: some View {
        ZStack {
            DashboardView(model: model)

            if model.showingSettings {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.24)) {
                            model.showingSettings = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(20)

                GeometryReader { geometry in
                    SettingsView(model: model)
                        .frame(width: min(max(430, geometry.size.width * 0.2), 590))
                        .frame(height: max(0, geometry.size.height - 48))
                        .padding(.vertical, 24)
                        .padding(.trailing, 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .zIndex(21)
            }

            if model.ambientMode == .screensaver {
                FrameScreensaverView(model: model, onWake: model.wakeAmbientDisplay)
                    .transition(.opacity)
                    .zIndex(100)
            } else if model.ambientMode == .sleep {
                FrameSleepModeView(model: model, onWake: model.wakeAmbientDisplay)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(backgroundStore)
        .environment(\.frameAccent, backgroundStore.usesLightAccent ? .white : FrameTheme.ink)
        .statusBarHidden(true)
        .sheet(isPresented: $model.showingUpdates) {
            UpdatesDetailView(model: model)
        }
        .onAppear {
            if isStartupReady, scenePhase == .active { model.start() }
        }
        .onChange(of: isStartupReady) { _, isReady in
            if isReady, scenePhase == .active { model.start() }
        }
        .task { await backgroundStore.loadPersistedPhotoIfNeeded() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.handleAppBackground(false)
                if isStartupReady { model.start() }
            case .background:
                model.handleAppBackground(true)
            case .inactive:
                // Permission sheets, Control Center, and app-switch animations
                // briefly make the scene inactive. Keep an already-running
                // camera alive, but do not begin a new capture session behind
                // a system sheet or while the app-switch animation is active.
                model.handleAppInactive()
            @unknown default:
                break
            }
        }
        .animation(.easeOut(duration: 0.24), value: model.showingSettings)
        .animation(.easeInOut(duration: 0.8), value: model.ambientMode)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in model.registerInteraction() }
        )
    }
}

private struct FrameScreensaverView: View {
    @ObservedObject var model: DashboardModel
    let onWake: () -> Void
    @State private var position = CGPoint.zero
    @State private var heading = CGFloat.random(in: 0...(2 * .pi))
    @State private var trail: [ScreensaverTrailPoint] = []
    private let movementTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let boxSize = screensaverBoxSize(in: geometry.size)

                ZStack {
                    Color.black

                    Canvas { context, _ in
                        for (index, point) in trail.enumerated() {
                            let progress = Double(index + 1) / Double(max(trail.count, 1))
                            let rect = CGRect(
                                x: point.position.x - boxSize.width / 2,
                                y: point.position.y - boxSize.height / 2,
                                width: boxSize.width,
                                height: boxSize.height
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 28),
                                with: .color(Color(hue: point.hue, saturation: 0.86, brightness: 0.92)
                                    .opacity(0.012 + progress * 0.075))
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 10) {
                        Text(timeline.date.formatted(.dateTime.hour().minute()))
                            .font(.system(size: min(76, geometry.size.width * 0.075), weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text(timeline.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .opacity(0.72)

                        if let weather = model.weatherState.summary {
                            HStack(spacing: 8) {
                                Image(systemName: weather.symbolName)
                                Text("\(weather.temperature)°")
                                Text(weather.condition)
                                    .opacity(0.64)
                            }
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .padding(.top, 6)
                            .opacity(0.68)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: boxSize.width, height: boxSize.height)
                    .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .position(resolvedPosition(in: geometry.size))
                    .animation(.linear(duration: 0.12), value: position)
                }
            }
            .onAppear {
                restartWalk(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                restartWalk(in: newSize)
            }
            .onReceive(movementTimer) { _ in
                advanceWalk(in: geometry.size)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onWake)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Frame screensaver. Tap to return to the dashboard.")
    }

    private func screensaverBoxSize(in canvasSize: CGSize) -> CGSize {
        CGSize(
            width: min(330, max(250, canvasSize.width * 0.28)),
            height: model.weatherState.summary == nil ? 142 : 172
        )
    }

    private func resolvedPosition(in canvasSize: CGSize) -> CGPoint {
        position == .zero
            ? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            : position
    }

    private func restartWalk(in canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        position = center
        heading = CGFloat.random(in: 0...(2 * .pi))
        trail = [ScreensaverTrailPoint(position: center, hue: Double.random(in: 0...1))]
    }

    private func advanceWalk(in canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let boxSize = screensaverBoxSize(in: canvasSize)
        let margin: CGFloat = 14
        let currentPosition = resolvedPosition(in: canvasSize)

        heading += CGFloat.random(in: -0.32...0.32)
        let step: CGFloat = 7
        let nextPosition = CGPoint(
            x: currentPosition.x + cos(heading) * step,
            y: currentPosition.y + sin(heading) * step
        )
        let horizontalInset = boxSize.width / 2 + margin
        let verticalInset = boxSize.height / 2 + margin
        let reachedEdge = nextPosition.x <= horizontalInset
            || nextPosition.x >= canvasSize.width - horizontalInset
            || nextPosition.y <= verticalInset
            || nextPosition.y >= canvasSize.height - verticalInset

        if reachedEdge {
            restartWalk(in: canvasSize)
            return
        }

        var nextTrail = trail
        nextTrail.append(ScreensaverTrailPoint(
            position: currentPosition,
            hue: (Date().timeIntervalSinceReferenceDate / 7).truncatingRemainder(dividingBy: 1)
        ))
        if nextTrail.count > 52 {
            nextTrail.removeFirst(nextTrail.count - 52)
        }
        trail = nextTrail
        position = nextPosition
    }
}

private struct ScreensaverTrailPoint: Identifiable {
    let id = UUID()
    let position: CGPoint
    let hue: Double
}

private struct FrameSleepModeView: View {
    @ObservedObject var model: DashboardModel
    let onWake: () -> Void

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let contentOffset = CGSize(
                    width: sin(phase / 97) * min(geometry.size.width * 0.045, 42),
                    height: cos(phase / 113) * min(geometry.size.height * 0.035, 26)
                )

                ZStack {
                    Color(red: 0.008, green: 0.01, blue: 0.018)
                    RadialGradient(
                        colors: [Color(red: 0.08, green: 0.07, blue: 0.13).opacity(0.42), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.62
                    )

                    VStack(spacing: 13) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 24, weight: .light))
                            .opacity(0.42)

                        Text(timeline.date.formatted(.dateTime.hour().minute()))
                            .font(.system(size: min(96, geometry.size.width * 0.105), weight: .ultraLight, design: .rounded))
                            .monospacedDigit()

                        Text(timeline.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .opacity(0.5)

                        HStack(spacing: 22) {
                            if model.showWeatherInSleepMode, let weather = model.weatherState.summary {
                                HStack(spacing: 7) {
                                    Image(systemName: weather.symbolName)
                                    Text("\(weather.temperature)°")
                                    Text("H \(weather.high)° · L \(weather.low)°")
                                        .opacity(0.55)
                                }
                            }

                            if model.showNextEventInSleepMode, let event = model.nextSleepModeEvent {
                                HStack(spacing: 7) {
                                    Image(systemName: "calendar")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.isPrivate ? "Private event" : event.title)
                                            .lineLimit(1)
                                        Text(event.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                            .opacity(0.55)
                                    }
                                }
                            }
                        }
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .padding(.top, 12)
                    }
                    .foregroundStyle(.white.opacity(0.58))
                    .offset(contentOffset)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onWake)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep display. Tap to return to the dashboard for thirty minutes.")
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("frame.updatesColumnRatio") private var updatesColumnRatio = 0.29

    var body: some View {
        GeometryReader { geometry in
            let updatesWidth = min(max(360, geometry.size.width * CGFloat(updatesColumnRatio)), 480)
            let dividerWidth: CGFloat = 44
            let updatesBottomExtension = 22 + geometry.safeAreaInsets.bottom

            ZStack {
                FrameAmbientBackground(
                    isPausedForPerformance: model.ambientMode != .dashboard || liveVideoIsVisible
                )

                VStack(spacing: 18) {
                    // Confine periodic clock invalidation to the header. Wrapping
                    // the whole dashboard in TimelineView caused UIKit-backed
                    // camera surfaces to be dismantled while capture stayed live.
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        AmbientHeaderView(model: model, date: timeline.date)
                    }

            GeometryReader { contentGeometry in
                let contentWidth = contentGeometry.size.width
                let panelWidth = max(360, contentWidth - updatesWidth - dividerWidth)
                // The divider track is laid out below the header, but the grab
                // bar should be centered against the full screen.
                let dividerVerticalOffset: CGFloat = -56

                        ZStack(alignment: .topLeading) {
                            UpdatesCardView(model: model)
                                .frame(width: updatesWidth, height: contentGeometry.size.height + updatesBottomExtension)
                                .offset(x: model.showingHome ? -updatesWidth - 42 : 0)
                                .opacity(model.showingHome ? 0 : 1)
                                .allowsHitTesting(!model.showingHome)
                                .zIndex(1)

                            ResizableDivider(panelName: "Updates", widenDragDelta: 24) { delta in
                                // The Updates divider sits on the panel's
                                // trailing edge, so dragging right widens it.
                                let nextRatio = updatesColumnRatio + Double(delta / max(geometry.size.width, 1))
                                updatesColumnRatio = min(max(nextRatio, 0.22), 0.38)
                            }
                            .frame(width: dividerWidth, height: contentGeometry.size.height + updatesBottomExtension)
                            .offset(x: updatesWidth, y: dividerVerticalOffset)
                            .opacity(model.showingHome ? 0 : 1)
                            .allowsHitTesting(!model.showingHome)
                            .zIndex(2)

                            DashboardMainColumn(model: model)
                                .frame(width: panelWidth, height: contentGeometry.size.height)
                                .offset(x: model.showingHome ? 0 : updatesWidth + dividerWidth)
                                .zIndex(3)

                            ResizableDivider(panelName: "Home", widenDragDelta: -24) { delta in
                                // The Home divider sits on the panel's leading
                                // edge. Dragging right moves that edge right,
                                // which narrows the panel.
                                let nextRatio = updatesColumnRatio - Double(delta / max(geometry.size.width, 1))
                                updatesColumnRatio = min(max(nextRatio, 0.22), 0.38)
                            }
                            .frame(width: dividerWidth, height: contentGeometry.size.height)
                            .offset(x: panelWidth, y: dividerVerticalOffset)
                            .opacity(model.showingHome ? 1 : 0)
                            .allowsHitTesting(model.showingHome)
                            .zIndex(5)

                            HomeSidePanelView(model: model)
                                .frame(width: updatesWidth, height: contentGeometry.size.height + updatesBottomExtension)
                                .offset(x: model.showingHome ? panelWidth + dividerWidth : contentWidth + updatesWidth)
                                .opacity(model.showingHome ? 1 : 0)
                                .allowsHitTesting(model.showingHome)
                                .zIndex(4)
                        }
                        .frame(width: contentWidth, height: contentGeometry.size.height + updatesBottomExtension, alignment: .leading)
                        .animation(.spring(response: 0.52, dampingFraction: 0.88), value: model.showingHome)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, updatesBottomExtension)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var liveVideoIsVisible: Bool {
        guard model.selectedFeedStatus == .live else { return false }
        switch model.selectedFeed {
        case .mirror, .homeKit:
            return true
        case .map, .homeControls:
            return false
        }
    }
}

private struct DashboardMainColumn: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                FeedCarouselView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZStack {
                    Text(model.greeting)
                        .font(.system(size: min(42, geometry.size.width * 0.052), weight: .medium, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .layoutPriority(1)

                    HStack {
                        if model.showingHome {
                            FrameGlassIconButton(
                                systemImage: "sparkles",
                                accessibilityLabel: "Return to Updates",
                                action: model.dismissHome
                            )
                        } else {
                            Spacer()
                        }

                        Spacer()

                        if !model.showingHome {
                            FrameGlassIconButton(
                                systemImage: "house.fill",
                                accessibilityLabel: "Open Home controls",
                                action: model.presentHome
                            )
                        } else {
                            Spacer()
                        }
                    }
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            let horizontalDistance = value.translation.width
                            let verticalDistance = value.translation.height
                            guard abs(horizontalDistance) > 48,
                                  abs(horizontalDistance) > abs(verticalDistance) * 1.25 else { return }

                            if horizontalDistance < 0 {
                                model.presentHome()
                            } else {
                                model.dismissHome()
                            }
                        }
                )
            }
        }
    }
}

struct ResizableDivider: View {
    let panelName: String
    let widenDragDelta: CGFloat
    let onDrag: (CGFloat) -> Void
    @Environment(\.frameAccent) private var accent
    @State private var lastTranslation: CGFloat?
    @State private var isInteracting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent.opacity(0.58))
                .frame(width: 5, height: 104)
                .frameGlass(.clear, in: Capsule(), interactive: true)
                .opacity(isInteracting ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !isInteracting {
                            withAnimation(.easeIn(duration: 0.12)) {
                                isInteracting = true
                            }
                        }
                        let previous = lastTranslation ?? value.translation.width
                        let delta = value.translation.width - previous
                        lastTranslation = value.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        lastTranslation = nil
                        withAnimation(.easeOut(duration: 0.3)) {
                            isInteracting = false
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.2), value: isInteracting)
            .accessibilityLabel("Adjust \(panelName) width")
            .accessibilityHint("Drag left or right to resize \(panelName). The handle follows the direction of the drag.")
            .accessibilityAction(named: "Widen \(panelName)") { onDrag(widenDragDelta) }
            .accessibilityAction(named: "Narrow \(panelName)") { onDrag(-widenDragDelta) }
    }
}

struct AmbientHeaderView: View {
    @ObservedObject var model: DashboardModel
    let date: Date
    @Environment(\.frameAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.shortDateFormatter.string(from: date))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent.opacity(0.62))
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 58, weight: .medium, design: .rounded))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
            }
            .frame(width: 132, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Today, \(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))")

            WeatherHeaderView(state: model.weatherState)

            Spacer(minLength: 30)

            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("CURRENT VIEW")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(accent.opacity(0.48))
                    Text(model.selectedFeed.displayName)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }

                AnalogClockView(date: date, action: model.startScreensaver)

                if model.focusStatus.showsGlyph {
                    FocusStatusIndicator(status: model.focusStatus)
                }

                FrameGlassIconButton(
                    systemImage: "slider.horizontal.3",
                    accessibilityLabel: "Open Frame settings",
                    action: { model.showingSettings = true }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM"
        return formatter
    }()
}

private struct FocusStatusIndicator: View {
    let status: FocusStatusState
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(status == .active ? FrameTheme.coral : accent.opacity(0.48))
            .frame(width: 48, height: 48)
            .frameGlass(.clear, in: Circle(), interactive: true)
            .accessibilityLabel(status.label)
    }
}

struct WeatherHeaderView: View {
    let state: WeatherState
    @Environment(\.frameAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            switch state {
            case .loading:
                ProgressView().tint(accent)
                Text("Finding weather")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
            case .loaded(let weather), .stale(let weather):
                Image(systemName: weather.symbolName)
                    .font(.system(size: 42, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(weather.locationName.localizedCapitalized)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.opacity(0.62))
                        .lineLimit(1)

                    HStack(alignment: .center, spacing: 8) {
                        Text("\(weather.temperature)°")
                            .font(.system(size: 58, weight: .medium, design: .rounded))
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("H: \(weather.high)°")
                            Text("L: \(weather.low)°")
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.opacity(0.62))
                    }
                }
            case .denied(let message), .unavailable(let message), .failed(let message):
                Image(systemName: "location.slash")
                    .font(.system(size: 21, weight: .medium))
                Text("Weather paused")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .help(message)
            }
        }
        .foregroundStyle(accent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch state {
        case .loaded(let weather), .stale(let weather): return "Weather, \(weather.temperature) degrees, high \(weather.high), low \(weather.low), \(weather.condition)"
        case .loading: return "Weather is loading"
        case .denied: return "Weather location permission denied"
        case .unavailable: return "Weather unavailable"
        case .failed: return "Weather failed to load"
        }
    }
}

struct AnalogClockView: View {
    let date: Date
    let action: () -> Void
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.clear)
                ForEach(0..<12, id: \.self) { tick in
                    Capsule()
                        .fill(accent.opacity(0.6))
                        .frame(width: tick.isMultiple(of: 3) ? 2.5 : 1.5, height: tick.isMultiple(of: 3) ? 7 : 4)
                        .offset(y: -18)
                        .rotationEffect(.degrees(Double(tick) * 30))
                }
                Rectangle()
                    .fill(accent)
                    .frame(width: 2.5, height: 17)
                    .offset(y: -8)
                    .rotationEffect(.degrees(hourAngle))
                Rectangle()
                    .fill(accent)
                    .frame(width: 2, height: 22)
                    .offset(y: -10)
                    .rotationEffect(.degrees(minuteAngle))
                Circle().fill(accent).frame(width: 5, height: 5)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Start screensaver")
        .frameGlass(.regular, in: Circle())
        .accessibilityHidden(true)
    }

    private var hourAngle: Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) % 12) * 30 + Double(components.minute ?? 0) * 0.5
    }

    private var minuteAngle: Double {
        Double(Calendar.current.component(.minute, from: date)) * 6
    }
}

struct UpdatesCardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent
    @State private var calendarPullDistance: CGFloat = 0
    @State private var isResyncingCalendar = false

    private let calendarRefreshThreshold: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("UPDATES")
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(accent.opacity(0.55))
                    if model.updates.isEmpty {
                        Text("All quiet here.")
                            .font(.system(size: 29, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }
                Spacer()
                Button {
                    model.presentClearedUpdates()
                } label: {
                    Image(systemName: model.updates.isEmpty ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(accent.opacity(0.78))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .frameGlass(.clear, in: Circle(), interactive: true)
                .accessibilityLabel("Show cleared updates from the last 24 hours")
            }

            GeometryReader { scrollGeometry in
                ZStack(alignment: .top) {
                    calendarRefreshIndicator
                        .zIndex(0)

                    ScrollView(.vertical, showsIndicators: false) {
                        if model.updates.isEmpty {
                            VStack {
                                Spacer(minLength: 0)
                                Text("Nothing needs your attention right now.")
                                    .font(.system(size: 20, weight: .medium, design: .rounded))
                                    .foregroundStyle(accent.opacity(0.62))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: scrollGeometry.size.height)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(todayUpdates) { update in
                                    UpdateRow(
                                        update: update,
                                        onTap: update.kind == .music ? { model.toggleMusicOverlay() } : nil
                                    )
                                        .transition(
                                            .asymmetric(
                                                insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity
                                            )
                                        )
                                }

                                if !todayUpdates.isEmpty && !futureUpdates.isEmpty {
                                    DayBoundaryDivider()
                                }

                                ForEach(futureUpdates) { update in
                                    UpdateRow(
                                        update: update,
                                        onTap: update.kind == .music ? { model.toggleMusicOverlay() } : nil
                                    )
                                        .transition(
                                            .asymmetric(
                                                insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity
                                            )
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: model.updates.map(\.id))
                        }
                    }
                    .zIndex(1)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                    } action: { _, newDistance in
                        calendarPullDistance = newDistance
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onEnded { value in
                                guard value.translation.height > 0,
                                      calendarPullDistance >= calendarRefreshThreshold else { return }
                                resyncCalendar()
                            }
                    )
                    .accessibilityHint("Pull down and release to resync Calendar")
                    .scrollBounceBehavior(.always)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .foregroundStyle(accent)
        .accessibilityElement(children: .contain)
    }

    private var calendarRefreshProgress: CGFloat {
        min(calendarPullDistance / calendarRefreshThreshold, 1)
    }

    private var calendarRefreshIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .tint(accent.opacity(0.58))
            .scaleEffect(isResyncingCalendar ? 1 : 0.8 + calendarRefreshProgress * 0.2)
            .opacity(isResyncingCalendar ? 1 : min(calendarPullDistance / 14, 1))
            .offset(y: isResyncingCalendar ? 3 : -20 + min(calendarPullDistance, 72) * 0.3)
            .accessibilityHidden(true)
    }

    private func resyncCalendar() {
        guard !isResyncingCalendar else { return }
        isResyncingCalendar = true
        Task {
            let refresh = model.requestCalendar(allowPermissionPrompt: true)
            await refresh.value
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                isResyncingCalendar = false
            }
        }
    }

    private var todayUpdates: [UpdateItem] {
        model.updates.filter { update in
            guard let date = update.date else { return true }
            return Calendar.current.isDateInToday(date)
        }
    }

    private var futureUpdates: [UpdateItem] {
        model.updates.filter { update in
            guard let date = update.date else { return false }
            return !Calendar.current.isDateInToday(date)
        }.sorted { lhs, rhs in
            let calendar = Calendar.current
            let lhsDate = lhs.date ?? .distantFuture
            let rhsDate = rhs.date ?? .distantFuture
            let lhsDay = calendar.startOfDay(for: lhsDate)
            let rhsDay = calendar.startOfDay(for: rhsDate)

            if lhsDay != rhsDay { return lhsDay < rhsDay }

            let lhsPriority = futurePriority(for: lhs)
            let rhsPriority = futurePriority(for: rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id < rhs.id
        }
    }

    private func futurePriority(for update: UpdateItem) -> Int {
        switch update.kind {
        case .weather:
            return 0
        case .calendar where update.detail.lowercased().hasPrefix("all day"):
            return 1
        default:
            return 2
        }
    }
}

private struct DayBoundaryDivider: View {
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Rectangle()
            .fill(accent.opacity(0.2))
            .frame(height: 1)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

struct HomeSidePanelView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent

    private let accessoryColumns = [
        GridItem(.flexible(minimum: 82), spacing: 6),
        GridItem(.flexible(minimum: 82), spacing: 6),
        GridItem(.flexible(minimum: 82), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("HOME")
                    .font(.system(size: 28, weight: .light, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(accent.opacity(0.55))

                Spacer(minLength: 0)

                Image(systemName: "house.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent.opacity(0.72))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !model.homeCameraFeeds.isEmpty {
                        homeSectionHeader("CAMERAS", count: model.homeCameraFeeds.count)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(model.homeCameraFeeds) { feed in
                                    HomeCameraShortcut(
                                        feed: feed,
                                        isSelected: feed.id == model.selectedFeed.id
                                    ) {
                                        model.selectFeed(id: feed.id)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if !thermostatControls.isEmpty {
                        homeSectionHeader("CLIMATE", count: thermostatControls.count)

                        VStack(spacing: 8) {
                            ForEach(thermostatControls) { control in
                                HomeSideThermostatControl(model: model, control: control)
                            }
                        }
                    }

                    if !otherHomeControls.isEmpty {
                        homeSectionHeader("ACCESSORIES", count: otherHomeControls.count)

                        LazyVGrid(columns: accessoryColumns, spacing: 10) {
                            ForEach(otherHomeControls) { control in
                                HomeSideControlCard(model: model, control: control)
                            }
                        }
                    }

                    if model.homeControls.isEmpty && model.homeCameraFeeds.isEmpty {
                        HomeDiscoveryButton(model: model)
                            .padding(.top, 4)
                    } else if model.homeCameraFeeds.isEmpty {
                        Button {
                            model.requestHomeKit()
                        } label: {
                            Label("Find cameras", systemImage: "video.badge.plus")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(accent.opacity(0.76))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .frameGlass(.clear, in: Capsule(), interactive: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frameGlassContainer(spacing: 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            if let message = model.homeControlMessage {
                Label(message, systemImage: "house.fill")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frameGlass(.clear, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .foregroundStyle(accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home controls")
    }

    private func homeSectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.2)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .opacity(0.55)
        }
        .foregroundStyle(accent.opacity(0.56))
    }

    private var thermostatControls: [HomeControl] {
        model.homeControls.filter { $0.kind == .thermostat }
    }

    private var otherHomeControls: [HomeControl] {
        model.homeControls.filter { $0.kind != .thermostat }
    }
}

private struct HomeCameraShortcut: View {
    let feed: FeedSource
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isSelected ? "video.fill" : "video")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent.opacity(isSelected ? 1 : 0.72))
                    .frame(width: 54, height: 54)
                    .frameGlass(.clear, in: Circle(), interactive: true)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Circle()
                                .fill(FrameTheme.mint)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
                        }
                    }

                Text(feed.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .frame(width: 66)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(feed.displayName) in the main panel")
        .accessibilityValue(isSelected ? "Selected" : feed.roomName)
    }
}

private struct HomeDiscoveryButton: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Button {
            model.requestHomeKit()
        } label: {
            VStack(spacing: 9) {
                if model.homeKitState == .loading {
                    ProgressView()
                        .tint(accent)
                } else {
                    Image(systemName: "house.fill")
                        .font(.system(size: 27, weight: .light))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(accent, Color(uiColor: .systemBackground))
                                .offset(x: 5, y: 4)
                        }
                }

                Text(discoveryTitle)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(discoveryDetail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.62)
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
        .disabled(model.homeKitState == .loading)
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
    }

    private var discoveryTitle: String {
        switch model.homeKitState {
        case .loading: return "Finding your Home"
        case .denied: return "Home access is off"
        case .noHomes: return "No Home found"
        case .failed: return "Home is unavailable"
        default: return "Connect your Home"
        }
    }

    private var discoveryDetail: String {
        switch model.homeKitState {
        case .denied: return "Allow Home access in Settings, then try again."
        case .noHomes: return "Add a Home in Apple Home, then refresh here."
        case .failed(let message): return message
        case .loading: return "Looking for cameras, lights, climate, and speakers."
        default: return "Find the accessories already approved on this iPad."
        }
    }
}

private struct HomeSideThermostatControl: View {
    @ObservedObject var model: DashboardModel
    let control: HomeControl
    @Environment(\.frameAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(control.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                    Text(control.currentTemperature.map { "\(TemperatureDisplay.string(fromCelsius: $0)) now" } ?? control.roomName)
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .opacity(0.58)
                .lineLimit(1)
            }
            .frame(minWidth: 92, maxWidth: 112, alignment: .leading)

            ThermostatScrollWheel(
                temperature: control.targetTemperature,
                compact: true
            ) { displayedTarget in
                model.setHomeThermostat(control.id, displayedTarget: displayedTarget)
            }
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(control.name), target \(TemperatureDisplay.string(fromCelsius: control.targetTemperature))")
    }
}

struct HomeSideControlCard: View {
    @ObservedObject var model: DashboardModel
    let control: HomeControl
    @State private var showingSpeakerVolumeControls = false
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Button(action: primaryAction) {
            VStack(spacing: 5) {
                Image(systemName: controlIcon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(controlBulbColor.opacity(control.isOn ? 1 : 0.68))
                    .frame(width: 58, height: 58)
                    .frameGlass(.clear, in: Circle(), interactive: true)

                Text(control.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.55) {
            guard control.kind == .speaker else { return }
            showingSpeakerVolumeControls = true
        }
        .popover(isPresented: $showingSpeakerVolumeControls, arrowEdge: .leading) {
            SpeakerVolumePopover(model: model, control: control)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(control.kind == .speaker ? "Press and hold to show volume controls" : "")
    }

    private var controlIcon: String {
        switch control.kind {
        case .light: return control.isOn ? "lightbulb.fill" : "lightbulb"
        case .thermostat: return "thermometer.medium"
        case .speaker: return control.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill"
        }
    }

    private var controlBulbColor: Color {
        guard control.kind == .light, control.isOn, let color = control.lightColor else { return accent }
        return Color(hue: color.hue, saturation: color.saturation, brightness: color.brightness)
    }

    private func primaryAction() {
        switch control.kind {
        case .light:
            model.toggleHomeLight(control.id)
        case .speaker:
            model.toggleHomeSpeaker(control.id)
        case .thermostat:
            break
        }
    }
}

private struct SpeakerVolumePopover: View {
    @ObservedObject var model: DashboardModel
    let control: HomeControl

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "speaker.wave.2.fill")
                Text(control.name)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))

            HStack(spacing: 14) {
                Button {
                    model.adjustHomeSpeakerVolume(control.id, delta: -10)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)

                Text("\(Int((control.volume ?? 0).rounded()))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 48)

                Button {
                    model.adjustHomeSpeakerVolume(control.id, delta: 10)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(minWidth: 220)
    }
}

private struct ThermostatScrollWheel: View {
    let temperature: Double?
    let compact: Bool
    let onSelect: (Int) -> Void

    @State private var selectedValue: Int
    @State private var dragStartValue: Int?
    @State private var dragOffset: CGFloat = 0

    private var minimumWheelWidth: CGFloat { compact ? 154 : 196 }
    private var wheelHeight: CGFloat { compact ? 46 : 56 }
    private var stepWidth: CGFloat { compact ? 36 : 44 }
    private var wheelCornerRadius: CGFloat { compact ? 9 : 12 }
    private var temperatureRange: ClosedRange<Int> {
        TemperatureDisplay.isMetric ? 5...30 : 41...86
    }

    init(temperature: Double?, compact: Bool, onSelect: @escaping (Int) -> Void) {
        self.temperature = temperature
        self.compact = compact
        self.onSelect = onSelect
        let range: ClosedRange<Int> = TemperatureDisplay.isMetric ? 5...30 : 41...86
        let fallback = TemperatureDisplay.isMetric ? 21 : 70
        let initialValue = TemperatureDisplay.displayedValue(fromCelsius: temperature) ?? fallback
        _selectedValue = State(initialValue: min(max(initialValue, range.lowerBound), range.upperBound))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: wheelCornerRadius, style: .continuous)
                .fill(.black.opacity(0.18))

            HStack(spacing: 0) {
                ForEach(-2...2, id: \.self) { relativeValue in
                    let value = selectedValue + relativeValue
                    Text(temperatureRange.contains(value) ? "\(value)°" : "")
                        .font(.system(
                            size: relativeValue == 0 ? (compact ? 16 : 19) : (compact ? 12 : 14),
                            weight: relativeValue == 0 ? .semibold : .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(relativeValue == 0 ? 0.98 : 0.48))
                        .frame(width: stepWidth, height: wheelHeight)
                        .scaleEffect(relativeValue == 0 ? 1 : 0.92)
                }
            }
            .offset(x: dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartValue == nil {
                            dragStartValue = selectedValue
                        }

                        let startingValue = dragStartValue ?? selectedValue
                        let rawSteps = Int((-value.translation.width / stepWidth).rounded(.towardZero))
                        let targetValue = min(
                            max(startingValue + rawSteps, temperatureRange.lowerBound),
                            temperatureRange.upperBound
                        )
                        dragOffset = value.translation.width + CGFloat(rawSteps) * stepWidth

                        guard targetValue != selectedValue else { return }
                        selectedValue = targetValue
                        onSelect(targetValue)
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            dragOffset = 0
                        }
                        dragStartValue = nil
                    }
            )
        }
        .frame(minWidth: minimumWheelWidth, maxWidth: .infinity, minHeight: wheelHeight, maxHeight: wheelHeight)
        .clipShape(RoundedRectangle(cornerRadius: wheelCornerRadius, style: .continuous))
        .onChange(of: temperature) { _, newValue in
            // While dragging, the local wheel is authoritative. HomeKit's
            // optimistic update arrives separately and must not reset it.
            guard dragStartValue == nil,
                  let displayed = TemperatureDisplay.displayedValue(fromCelsius: newValue) else { return }
            let boundedValue = min(max(displayed, temperatureRange.lowerBound), temperatureRange.upperBound)
            guard boundedValue != selectedValue else { return }
            selectedValue = boundedValue
        }
        .accessibilityLabel("Thermostat temperature wheel")
        .accessibilityValue("\(selectedValue) degrees")
        .accessibilityHint("Drag left or right to adjust the target temperature")
        .accessibilityAdjustableAction { direction in
            let delta: Int
            switch direction {
            case .increment:
                delta = 1
            case .decrement:
                delta = -1
            @unknown default:
                return
            }

            let newValue = min(max(selectedValue + delta, temperatureRange.lowerBound), temperatureRange.upperBound)
            guard newValue != selectedValue else { return }
            selectedValue = newValue
            onSelect(newValue)
        }
    }
}

struct UpdateRow: View {
    let update: UpdateItem
    let onTap: (() -> Void)?
    @Environment(\.frameAccent) private var accent

    init(update: UpdateItem, onTap: (() -> Void)? = nil) {
        self.update = update
        self.onTap = onTap
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens or closes the music overlay")
            } else {
                rowContent
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if let secondaryTitle = update.secondaryTitle,
           let secondaryDetail = update.secondaryDetail {
            VStack(spacing: 0) {
                updateSection(
                    systemImage: update.systemImage ?? icon,
                    title: update.title,
                    detail: update.detail
                )

                Rectangle()
                    .fill(primaryText.opacity(0.18))
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                updateSection(
                    systemImage: update.secondarySystemImage ?? icon,
                    title: secondaryTitle,
                    detail: secondaryDetail
                )
            }
            .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { cardBorder }
            .foregroundStyle(primaryText)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            updateSection(
                systemImage: update.systemImage ?? icon,
                title: update.title,
                detail: update.detail
            )
            .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { cardBorder }
            .foregroundStyle(primaryText)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func updateSection(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: update.accent))
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(primaryText.opacity(0.68))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.34), .white.opacity(0.08), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }

    private var icon: String {
        switch update.kind {
        case .calendar: return "calendar"
        case .weather: return weatherIcon(for: update.title)
        case .home: return "video.fill"
        case .frame: return "sparkles"
        case .music: return "music.note"
        case .sleep: return "bed.double.fill"
        case .sunriseSunset: return "sunrise.fill"
        }
    }

    private func weatherIcon(for condition: String) -> String {
        let condition = condition.lowercased()
        if condition.contains("thunder") || condition.contains("storm") { return "cloud.bolt.rain.fill" }
        if condition.contains("snow") || condition.contains("sleet") { return "snowflake" }
        if condition.contains("rain") || condition.contains("drizzle") { return "cloud.rain.fill" }
        if condition.contains("fog") || condition.contains("haze") { return "cloud.fog.fill" }
        if condition.contains("wind") { return "wind" }
        if condition.contains("partly") || condition.contains("mostly") { return "cloud.sun.fill" }
        if condition.contains("cloud") || condition.contains("overcast") { return "cloud.fill" }
        return condition.contains("sun") || condition.contains("clear") ? "sun.max.fill" : "cloud.sun.fill"
    }

    private var primaryText: Color {
        accent
    }
}

struct FeedCarouselView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                // This UIKit surface is deliberately outside the dynamic TabView
                // pages. HomeKit feed insertion and page recycling may rebuild a
                // FeedPageView, but they must never dismantle the live renderer.
                MirrorPreviewView(
                    renderer: model.mirrorProvider.previewRenderer
                )
                    .opacity(
                        model.selectedFeed.isMirror
                            && model.mirrorEnabled
                            && model.mirrorPresentationStatus == .live
                            ? 1
                            : 0
                    )
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))

                // Bind paging to a stable feed identity. HomeKit and Map feeds
                // arrive asynchronously; integer selection made those inserts
                // look like a page change and could detach/re-attach Mirror.
                TabView(selection: $model.selectedFeedID) {
                    ForEach(Array(model.feeds.enumerated()), id: \.element.id) { index, feed in
                        FeedPageView(
                            model: model,
                            feed: feed,
                            isActive: index == model.selectedFeedIndex,
                            showTileHeader: false
                        )
                            .tag(feed.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                .onChange(of: model.selectedFeedID) { _, newValue in
                    model.didChangeFeed(to: newValue)
                }

                Group {
                    if model.musicOverlayVisible {
                        MusicOverlayView(model: model, onCollapse: model.toggleMusicOverlay)
                            .transition(
                                .scale(scale: 0.08, anchor: .bottomTrailing)
                                    .combined(with: .opacity)
                            )
                    } else {
                        FrameGlassIconButton(
                            systemImage: "music.note",
                            accessibilityLabel: "Show music overlay",
                            action: model.toggleMusicOverlay,
                            size: 45
                        )
                        .transition(
                            .scale(scale: 0.08, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                        )
                    }
                }
                .padding(28)
                .zIndex(10)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.musicOverlayVisible)

            HStack(spacing: 7) {
                ForEach(model.feeds.indices, id: \.self) { index in
                    Button {
                        model.selectFeed(index)
                    } label: {
                        Capsule()
                            .fill(index == model.selectedFeedIndex ? accent : accent.opacity(0.26))
                            .frame(width: index == model.selectedFeedIndex ? 22 : 7, height: 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(Rectangle())
                            .animation(.easeInOut(duration: 0.2), value: model.selectedFeedIndex)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(model.feeds[index].displayName)")
                    .accessibilityAddTraits(index == model.selectedFeedIndex ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Feed \(model.selectedFeedIndex + 1) of \(model.feeds.count)")
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frameGlass(.clear, in: Capsule(), interactive: true)
        }
    }
}

struct FeedPageView: View {
    @ObservedObject var model: DashboardModel
    let feed: FeedSource
    let isActive: Bool
    let showTileHeader: Bool
    @Environment(\.frameAccent) private var accent

    init(model: DashboardModel, feed: FeedSource, isActive: Bool, showTileHeader: Bool = true) {
        self.model = model
        self.feed = feed
        self.isActive = isActive
        self.showTileHeader = showTileHeader
    }

    var body: some View {
        ZStack {
            feedContent

            if feed.isMirror, isActive, model.mirrorEnabled, model.mirrorPresentationStatus == .live {
                mirrorCaptureSurface
                    .zIndex(3)
            }

            VStack(alignment: .leading, spacing: 0) {
            if showTileHeader {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.displayName)
                                .font(.system(size: 27, weight: .semibold, design: .rounded))
                            Text(feed.roomName)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        if !(feed.isMirror && !model.mirrorEnabled) {
                            FeedStatusPill(
                                status: model.feedStatuses[feed.id] ?? .unavailable
                            )
                        }
                    }
                    .padding(24)
                    .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Spacer()

                HStack(alignment: .bottom) {
                    if feed.isMirror && isActive {
                        FrameGlassIconButton(
                            systemImage: model.mirrorEnabled ? "video.fill" : "video.slash.fill",
                            accessibilityLabel: model.mirrorEnabled ? "Turn Mirror off" : "Turn Mirror on",
                            action: model.toggleMirror,
                            size: 45
                        )
                    } else if feed.isHomeControls {
                        Text(model.homeControls.isEmpty ? "CONNECT HOMEKIT IN SETTINGS" : "TAP TO CHANGE YOUR HOME")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 12)
                }
                .environment(\.frameAccent, accent)
                .padding(.leading, 24)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }
            .foregroundStyle(.white)
            .zIndex(2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .animation(.easeInOut(duration: 0.24), value: model.mirrorEnabled)
        .accessibilityElement(children: .contain)
    }

    private var mirrorCaptureSurface: some View {
        GeometryReader { geometry in
            if model.mirrorRecordingStartedAt == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geometry.size.width * 0.46, height: geometry.size.height * 0.48)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .gesture(
                        LongPressGesture(minimumDuration: 0.55, maximumDistance: 28)
                            .exclusively(before: TapGesture())
                            .onEnded { result in
                                switch result {
                                case .first:
                                    model.startMirrorRecording()
                                case .second:
                                    model.captureMirrorPhoto()
                                }
                            }
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geometry.size.width * 0.46, height: geometry.size.height * 0.48)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            model.stopMirrorRecording()
                        }
                    )
            }

            if let startedAt = model.mirrorRecordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(recordingDuration(from: startedAt, to: timeline.date))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Circle()
                    .fill(.red)
                    .frame(width: 11, height: 11)
                    .shadow(color: .red.opacity(0.55), radius: 5)
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if let result = model.mirrorCaptureResult {
                HStack(spacing: 7) {
                    Image(systemName: mirrorCaptureResultIcon(result))
                    Text(mirrorCaptureResultText(result))
                }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(mirrorCaptureResultColor(result), in: Capsule())
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.scale(scale: 0.75).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.mirrorCaptureResult)
        .accessibilityLabel("Mirror camera shutter")
        .accessibilityHint("Tap for a photo. Touch and hold for video. Swipe or tap again to stop recording.")
    }

    private func mirrorCaptureResultIcon(_ result: MirrorCaptureResult) -> String {
        switch result {
        case .photoSaved: return "camera.fill"
        case .videoSaved: return "video.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func mirrorCaptureResultText(_ result: MirrorCaptureResult) -> String {
        switch result {
        case .photoSaved: return "Saved"
        case .videoSaved: return "Video saved"
        case .failed(let message): return message
        }
    }

    private func mirrorCaptureResultColor(_ result: MirrorCaptureResult) -> Color {
        switch result {
        case .photoSaved, .videoSaved: return .black.opacity(0.55)
        case .failed: return .red.opacity(0.76)
        }
    }

    private func recordingDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var feedContent: some View {
        if feed.isMirror {
            ZStack {
                if isActive,
                   model.mirrorEnabled,
                   model.mirrorPresentationStatus != .live {
                    PermissionStateView(status: model.mirrorPresentationStatus) {
                        model.retrySelectedFeed()
                    }
                }
            }
        } else if case .homeKit = feed,
                  isActive,
                  model.activeHomeKitSourceFeedID == feed.id,
                  let source = model.activeHomeKitSource {
            HomeKitSourceView(source: source)
        } else if case .homeKit = feed, let snapshot = model.homeKitSnapshots[feed.id] {
            HomeKitSourceView(source: snapshot)
        } else if feed.isHomeControls {
            HomeControlsCanvas(model: model)
        } else if feed.isMap {
            MapRouteCanvas(model: model)
        } else {
            Color.black
        }
    }
}

struct FeedStatusPill: View {
    let status: FeedStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status == .live ? FrameTheme.mint : .white.opacity(0.72))
                .frame(width: 7, height: 7)
            Text(status.label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frameGlass(.clear, in: Capsule())
    }
}

enum RouteMapViewStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid
    case muted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        case .muted: return "Muted"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "square.3.layers.3d"
        case .muted: return "map.fill"
        }
    }

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        case .muted: return .mutedStandard
        }
    }
}

struct MapRouteCanvas: View {
    @ObservedObject var model: DashboardModel
    private let mapText = Color(uiColor: .label)
    @State private var mapViewStyle: RouteMapViewStyle = .standard

    var body: some View {
        ZStack {
            switch model.routeState {
            case .loaded(let route):
                RouteMapView(route: route, mapViewStyle: mapViewStyle)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("UPCOMING EVENT")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .tracking(1.3)
                                .foregroundStyle(mapText.opacity(0.68))
                            Text(route.destinationName)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .lineLimit(2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(route.trafficLabel)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .tracking(1.3)
                                .foregroundStyle(mapText.opacity(0.76))
                            Text("\(route.travelTimeMinutes) min")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                        }
                    }
                    .padding(14)
                    .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Spacer()

                    MapRouteOptionsCard(
                        route: route,
                        mapViewStyle: $mapViewStyle,
                        onSelectTransportMode: model.setRouteTransportMode
                    )
                }
                .foregroundStyle(mapText)
                .padding(28)

            case .loading:
                Color(hex: "#D9E0D7")
                ProgressView("Calculating Apple Maps route…")
                    .tint(mapText)
                    .foregroundStyle(mapText)

            case .idle:
                Color(hex: "#D9E0D7")
                SourceStateView(
                    icon: "map",
                    title: "No upcoming route",
                    detail: "A future calendar event with a location will appear here."
                )
                .environment(\.frameAccent, mapText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .unavailable(let message), .failed(let message):
                Color(hex: "#D9E0D7")
                VStack(spacing: 12) {
                    SourceStateView(
                        icon: "location.viewfinder",
                        title: "Route unavailable",
                        detail: message
                    )
                    .environment(\.frameAccent, mapText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

}

private struct MapRouteOptionsCard: View {
    let route: MapRouteSummary
    @Binding var mapViewStyle: RouteMapViewStyle
    let onSelectTransportMode: (RouteTransportMode) -> Void
    @State private var showingOptions = false
    private let mapText = Color(uiColor: .label)

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: route.transportMode.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .frameGlass(.clear, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6){
                        Text("Apple Maps")
                        Spacer()
                        Text("\(route.transportMode.title.capitalized)")
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    HStack(spacing: 0) {
                        Text(route.distanceLabel)
                        Spacer()
                        Text("\(mapViewStyle.title)")
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(mapText.opacity(0.68))
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(mapText.opacity(0.65))
            }
            .foregroundStyle(mapText)
            .padding(12)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        .accessibilityLabel("Apple Maps, \(route.transportMode.title)")
        .accessibilityHint("Choose a travel mode or map view")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            MapRouteOptionsPopover(
                selectedTransportMode: route.transportMode,
                mapViewStyle: $mapViewStyle,
                onSelectTransportMode: onSelectTransportMode
            )
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct MapRouteOptionsPopover: View {
    let selectedTransportMode: RouteTransportMode
    @Binding var mapViewStyle: RouteMapViewStyle
    let onSelectTransportMode: (RouteTransportMode) -> Void
    private let optionText = Color(uiColor: .label)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MAP OPTIONS")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(optionText.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                Text("Travel mode")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                ForEach(RouteTransportMode.allCases) { mode in
                    optionButton(
                        title: mode.title,
                        symbolName: mode.symbolName,
                        isSelected: selectedTransportMode == mode
                    ) {
                        onSelectTransportMode(mode)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Map view")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                ForEach(RouteMapViewStyle.allCases) { style in
                    optionButton(
                        title: style.title,
                        symbolName: style.symbolName,
                        isSelected: mapViewStyle == style
                    ) {
                        mapViewStyle = style
                    }
                }
            }
        }
        .padding(20)
        .foregroundStyle(optionText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frameGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func optionButton(
        title: String,
        symbolName: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? optionText.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

struct RouteMapView: UIViewRepresentable {
    let route: MapRouteSummary
    let mapViewStyle: RouteMapViewStyle
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        mapView.mapType = mapViewStyle.mapType
        mapView.showsTraffic = true
        mapView.isZoomEnabled = true
        // Reserve one-finger swipes for the surrounding feed pager. Map
        // navigation requires two fingers so it cannot steal page changes.
        Self.requireTwoFingerMapPanning(in: mapView)
        DispatchQueue.main.async {
            Self.requireTwoFingerMapPanning(in: mapView)
        }
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .includingAll
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        mapView.mapType = mapViewStyle.mapType
        Self.requireTwoFingerMapPanning(in: mapView)
        let coordinates = route.points
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            .filter { CLLocationCoordinate2DIsValid($0) }
            .reduce(into: [CLLocationCoordinate2D]()) { result, coordinate in
                // MapKit can return repeated adjacent polyline points. A
                // zero-length overlay has an empty bounding rect and causes
                // Core Animation/MapKit to emit empty-clip and drawable-size
                // diagnostics while the map is being laid out.
                guard let previous = result.last else {
                    result.append(coordinate)
                    return
                }
                if abs(previous.latitude - coordinate.latitude) > 0.000_000_1 ||
                    abs(previous.longitude - coordinate.longitude) > 0.000_000_1 {
                    result.append(coordinate)
                }
            }
        guard coordinates.count > 1 else {
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations)
            context.coordinator.displayedRouteKey = nil
            return
        }

        context.coordinator.isApproximateTransitRoute = route.transportMode == .transit
        let routeKey = Coordinator.RouteKey(
            destinationName: route.destinationName,
            points: route.points,
            transportMode: route.transportMode
        )
        guard context.coordinator.displayedRouteKey != routeKey else { return }
        context.coordinator.displayedRouteKey = routeKey

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        guard !polyline.boundingMapRect.isNull,
              !polyline.boundingMapRect.isEmpty else {
            context.coordinator.displayedRouteKey = nil
            return
        }
        mapView.addOverlay(polyline)

        let destination = MKPointAnnotation()
        destination.coordinate = coordinates[coordinates.count - 1]
        destination.title = route.destinationName
        mapView.addAnnotation(destination)

        mapView.setVisibleMapRect(
            polyline.boundingMapRect,
            edgePadding: UIEdgeInsets(top: 140, left: 90, bottom: 160, right: 90),
            animated: false
        )
    }

    private static func requireTwoFingerMapPanning(in view: UIView) {
        view.gestureRecognizers?
            .compactMap { $0 as? UIPanGestureRecognizer }
            .forEach {
                $0.minimumNumberOfTouches = 2
                $0.maximumNumberOfTouches = 2
            }

        view.subviews.forEach { requireTwoFingerMapPanning(in: $0) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        struct RouteKey: Equatable {
            let destinationName: String
            let points: [MapRoutePoint]
            let transportMode: RouteTransportMode
        }

        var displayedRouteKey: RouteKey?
        var isApproximateTransitRoute = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 7
            renderer.lineJoin = .round
            renderer.lineCap = .round
            renderer.lineDashPattern = isApproximateTransitRoute
                ? [NSNumber(value: 12), NSNumber(value: 8)]
                : nil
            return renderer
        }
    }
}

@MainActor
final class MusicArtworkLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private var task: Task<Void, Never>?

    func load(url: URL?) {
        task?.cancel()
        image = nil

        guard let url else { return }
        task = Task { @MainActor [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            self?.image = image
        }
    }
}

struct MusicRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct MusicOverlayView: View {
    @ObservedObject var model: DashboardModel
    let onCollapse: () -> Void
    @StateObject private var artworkLoader = MusicArtworkLoader()
    private let tileCornerRadius: CGFloat = 18
    private let tileInset: CGFloat = 15

    var body: some View {
        HStack(spacing: tileInset) {
            artwork
                .frame(width: 138, height: 138)

            VStack(alignment: .leading, spacing: 4.5) {
                if let track = model.currentMusicTrack {
                    PassiveMarqueeText(
                        text: track.title,
                        font: .system(size: 24, weight: .semibold, design: .rounded),
                        height: 30
                    )
                    .padding(.trailing, 60)
                    Text(track.artist)
                        .font(.system(size: 16.5, weight: .medium, design: .rounded))
                        .foregroundStyle(contentColor.opacity(0.72))
                        .lineLimit(1)

                    if let musicErrorMessage {
                        Text(musicErrorMessage)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FrameTheme.coral)
                            .lineLimit(1)
                    }
                } else {
                    Text("Music")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(model.musicState.label)
                        .font(.system(size: 16.5, weight: .medium, design: .rounded))
                        .foregroundStyle(contentColor.opacity(0.72))
                        .lineLimit(1)
                }

                if model.musicPlaybackDuration > 0 {
                    MusicProgressBar(
                        value: Binding(
                            get: { min(model.musicPlaybackTime, model.musicPlaybackDuration) },
                            set: { model.seekMusic(to: $0) }
                        ),
                        duration: model.musicPlaybackDuration,
                        color: contentColor
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                }

                // Reserve the transport row in layout. The actual controls are
                // applied after the tile glass so each circle renders as glass
                // over glass, matching the collapse button.
                Color.clear
                    .frame(height: 45)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(tileInset)
        .frame(width: 408, height: 168)
        // Keep white metadata and controls legible even when this persistent
        // overlay sits above a bright MapKit surface or a light photo.
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous), interactive: true)
        .overlay(alignment: .bottomTrailing) {
            transportControls
                .frame(width: 225)
                .padding(.trailing, tileInset)
                .padding(.bottom, tileInset)
        }
        .overlay(alignment: .topTrailing) {
            FrameGlassIconButton(
                systemImage: "music.note",
                accessibilityLabel: "Hide music overlay",
                action: onCollapse,
                size: 45
            )
            .padding(tileInset)
        }
        .foregroundStyle(contentColor)
        .environment(\.frameAccent, contentColor)
        .environment(\.colorScheme, .dark)
        .onAppear {
            artworkLoader.load(url: model.currentMusicTrack?.artworkURL)
        }
        .onChange(of: model.currentMusicTrack?.id) { _, _ in
            artworkLoader.load(url: model.currentMusicTrack?.artworkURL)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = artworkLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(contentColor.opacity(0.16))
            Image(systemName: "music.note")
                .font(.system(size: 45, weight: .medium))
                .foregroundStyle(contentColor.opacity(0.74))
        }
    }

    private var musicIsLoading: Bool {
        model.musicState.isLoading
    }

    private var contentColor: Color {
        .white
    }

    private var artworkCornerRadius: CGFloat {
        12
    }

    private var musicErrorMessage: String? {
        switch model.musicState {
        case .denied(let message), .unavailable(let message), .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            musicButton(
                systemImage: "gobackward.15",
                accessibilityLabel: "Rewind 15 seconds",
                action: model.rewindMusic
            )
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in model.skipToPreviousMusic() }
            )

            Spacer(minLength: 0)

            musicButton(
                systemImage: model.musicState.isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: model.musicState.isPlaying ? "Pause music" : "Play music",
                showsProgress: musicIsLoading,
                action: model.toggleMusicPlayback
            )

            Spacer(minLength: 0)

            musicButton(
                systemImage: "forward.fill",
                accessibilityLabel: "Skip to next track",
                action: model.skipMusic
            )

            Spacer(minLength: 0)

            MusicRoutePickerView()
                .frame(width: 45, height: 45)
                .frameGlass(.clear, in: Circle(), interactive: true)
                .accessibilityLabel("Choose playback device")
        }
    }

    private func musicButton(
        systemImage: String,
        accessibilityLabel: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        FrameGlassIconButton(
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel,
            action: action,
            size: 45,
            variant: .clear,
            showsProgress: showsProgress,
            isDisabled: musicIsLoading
        )
    }

}

private struct PassiveMarqueeText: View {
    let text: String
    let font: Font
    let height: CGFloat

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .background {
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear { contentWidth = textGeometry.size.width }
                            .onChange(of: textGeometry.size.width) { _, width in
                                contentWidth = width
                            }
                    }
                }
                .onAppear { containerWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in
                    containerWidth = width
                }
        }
        .frame(height: height)
        .clipped()
        .task(id: animationID) {
            await runMarquee()
        }
        .accessibilityLabel(text)
    }

    private var animationID: String {
        "\(text)|\(Int(contentWidth.rounded()))|\(Int(containerWidth.rounded()))"
    }

    @MainActor
    private func runMarquee() async {
        offset = 0
        let overflow = contentWidth - containerWidth
        guard overflow > 1 else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            let travelDuration = max(2.5, Double(overflow / 24))
            withAnimation(.linear(duration: travelDuration)) {
                offset = -overflow
            }
            try? await Task.sleep(for: .seconds(travelDuration + 1.2))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.35)) {
                offset = 0
            }
            try? await Task.sleep(for: .seconds(0.35))
        }
    }
}

private struct MusicProgressBar: View {
    @Binding var value: TimeInterval
    let duration: TimeInterval
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let progress = duration > 0 ? min(max(value / duration, 0), 1) : 0
            let thumbRadius: CGFloat = 4
            let usableWidth = max(0, geometry.size.width - thumbRadius * 2)
            let x = thumbRadius + usableWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.28))
                    .frame(height: 3)
                Capsule()
                    .fill(color.opacity(0.82))
                    .frame(width: max(3, x), height: 3)
                Circle()
                    .fill(color)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .position(x: x, y: geometry.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = min(max(gesture.location.x - thumbRadius, 0), usableWidth)
                        value = duration * (position / max(usableWidth, 1))
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Music progress")
        .accessibilityValue(progressAccessibilityValue)
    }

    private var progressAccessibilityValue: String {
        guard duration > 0 else { return "Not available" }
        return "(Int(value.rounded())) of (Int(duration.rounded())) seconds"
    }
}

struct HomeControlsCanvas: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ZStack {
            Color.clear

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your home")
                            .font(.system(size: 29, weight: .semibold, design: .rounded))
                        Text("Home controls")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer()
                }

                if model.homeControls.isEmpty {
                    Spacer()
                    Button {
                        model.requestHomeKit()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "house.badge.exclamationmark")
                                .font(.system(size: 38, weight: .light))
                            Text("No HomeKit controls yet")
                                .font(.system(size: 21, weight: .semibold, design: .rounded))
                            Text("Tap to find authorized lights and thermostat controls.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(model.homeControls) { control in
                                HomeControlCard(model: model, control: control)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)

                    if let message = model.homeControlMessage {
                        Text(message)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 36, style: .continuous), interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
    }
}

struct HomeControlCard: View {
    @ObservedObject var model: DashboardModel
    let control: HomeControl

    var body: some View {
        Group {
            switch control.kind {
            case .light:
                Button {
                    model.toggleHomeLight(control.id)
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: control.isOn ? "lightbulb.fill" : "lightbulb")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(lightBulbColor)
                        Text(control.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            case .thermostat:
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 30, weight: .medium))
                        Text(TemperatureDisplay.string(fromCelsius: control.targetTemperature))
                            .font(.system(size: 35, weight: .medium, design: .rounded))
                        Text(control.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(control.currentTemperature.map { "Current \(TemperatureDisplay.string(fromCelsius: $0))" } ?? control.roomName)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.64))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ThermostatScrollWheel(
                        temperature: control.targetTemperature,
                        compact: false
                    ) { displayedTarget in
                        model.setHomeThermostat(control.id, displayedTarget: displayedTarget)
                    }
                }
            case .speaker:
                Button {
                    model.toggleHomeSpeaker(control.id)
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: control.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 32, weight: .medium))
                        Text(control.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text("\(Int((control.volume ?? 0).rounded()))%")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.64))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
        .padding(17)
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch control.kind {
        case .light:
            return "\(control.name), \(control.isOn ? "on" : "off")"
        case .thermostat:
            return "\(control.name), target \(TemperatureDisplay.string(fromCelsius: control.targetTemperature))"
        case .speaker:
            return "\(control.name), \(control.isOn ? "on" : "off"), volume \(Int((control.volume ?? 0).rounded())) percent"
        }
    }


    private var lightBulbColor: Color {
        guard control.isOn, let color = control.lightColor else { return .white }
        return Color(hue: color.hue, saturation: color.saturation, brightness: color.brightness)
    }
}

struct PermissionStateView: View {
    let status: MirrorPermissionState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 33, weight: .medium))
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            if status == .denied || status == .unavailable {
                Button(status == .unavailable ? "Retry Mirror" : "Open Settings") {
                    if status == .denied,
                       let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsURL)
                    } else {
                        retry()
                    }
                }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .buttonStyle(.plain)
                    .frameGlass(.clear, in: Capsule(), interactive: true)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
    }

    private var title: String {
        switch status {
        case .denied: return "Mirror is private"
        case .unavailable: return "Camera unavailable"
        case .requesting: return "Starting Mirror"
        default: return "Mirror is paused"
        }
    }

    private var message: String {
        switch status {
        case .denied: return "Allow camera access in Settings to use the Mirror and capture photos or videos you choose."
        case .unavailable: return "The front camera did not start. Retry after any other camera app has closed."
        case .requesting: return "Frame is waiting for camera access."
        default: return "Select Mirror to start the local preview."
        }
    }

    private var icon: String {
        switch status {
        case .denied: return "camera.slash"
        case .unavailable: return "exclamationmark.triangle"
        case .requesting: return "camera"
        default: return "pause.circle"
        }
    }
}

struct SourceStateView: View {
    let icon: String
    let title: String
    let detail: String
    @Environment(\.frameAccent) private var accent

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(accent.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(accent.opacity(0.62))
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject private var backgroundStore: FrameBackgroundStore
    @Environment(\.frameAccent) private var accent
    @State private var name: String
    @State private var weatherLocation: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingPhoto: UIImage?
    @State private var showingPhotoCrop = false
    @State private var showingAdvanced = false

    init(model: DashboardModel) {
        self.model = model
        _name = State(initialValue: model.displayName)
        _weatherLocation = State(initialValue: model.weatherLocationName)
    }

    var body: some View {
        ZStack {
            if showingAdvanced {
                advancedPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                    .zIndex(1)
            } else {
                basicSettingsPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .zIndex(0)
            }
        }
        .animation(.easeInOut(duration: 0.34), value: showingAdvanced)
        .clipped()
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .frameGlass(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(accent.opacity(0.12), lineWidth: 1)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    pendingPhoto = image
                    showingPhotoCrop = true
                }
            }
        }
        .fullScreenCover(isPresented: $showingPhotoCrop, onDismiss: {
            pendingPhoto = nil
            selectedPhoto = nil
        }) {
            if let pendingPhoto {
                FramePhotoCropView(
                    image: pendingPhoto,
                    onCancel: { showingPhotoCrop = false },
                    onApply: { croppedData in
                        backgroundStore.setPhotoData(croppedData)
                        showingPhotoCrop = false
                    }
                )
            }
        }
    }

    private var basicSettingsPage: some View {
        VStack(spacing: 0) {
            settingsHeader(title: "Settings", showsBackButton: false)
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Personalize the essentials here. One-time setup and fine tuning live in Advanced.")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    SettingsSection(title: "YOUR FRAME") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GREETING NAME")
                                .font(.system(size: 16, weight: .light, design: .rounded))
                            TextField("Your name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.setDisplayName(name) }
                        }
                        .padding(.vertical, 14)
                    }

                    SettingsSection(title: "APPEARANCE") {
                        backgroundSettings
                    }

                    SettingsSection(title: "DAILY DISPLAY") {
                        everydayDisplaySettings
                    }

                    SettingsSection(title: "MUSIC") {
                        MusicSettingsView(model: model)
                    }

                    SettingsNavigationRow(action: showAdvanced)
                }
                .padding(24)
            }
        }
    }

    private var advancedPage: some View {
        VStack(spacing: 0) {
            settingsHeader(title: "Advanced", showsBackButton: true)
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Connections, schedules, filters, and fine tuning.")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    advancedSettings
                }
                .padding(24)
            }
        }
    }

    private func settingsHeader(title: String, showsBackButton: Bool) -> some View {
        ZStack {
            Text(title)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            HStack {
                if showsBackButton {
                    FrameGlassIconButton(
                        systemImage: "chevron.up",
                        accessibilityLabel: "Back to settings",
                        action: showBasicSettings,
                        size: 38
                    )
                } else {
                    Color.clear
                        .frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                }

                Spacer()

                FrameGlassIconButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Close settings",
                    action: closeSettings,
                    size: 38
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .foregroundStyle(accent)
    }

    private func showAdvanced() {
        model.setDisplayName(name)
        withAnimation(.easeInOut(duration: 0.34)) {
            showingAdvanced = true
        }
    }

    private func showBasicSettings() {
        withAnimation(.easeInOut(duration: 0.34)) {
            showingAdvanced = false
        }
    }

    private func closeSettings() {
        model.setDisplayName(name)
        withAnimation(.easeOut(duration: 0.24)) {
            model.showingSettings = false
        }
    }

    private var backgroundSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: "Dynamic waves",
                detail: backgroundStore.style == .photo
                    ? "Color themes move softly; photos remain still"
                    : "Let soft waves drift through the selected color theme",
                isOn: backgroundStore.isDynamic
            ) { backgroundStore.setDynamic($0) }

            Divider().opacity(0.25)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(FrameBackgroundStyle.allCases.filter { $0 != .photo || backgroundStore.photoData != nil }) { style in
                    Button {
                        backgroundStore.setStyle(style)
                    } label: {
                        FrameBackgroundSwatch(
                            style: style,
                            isSelected: backgroundStore.style == style,
                            photoData: backgroundStore.photoData
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(style.title) background")
                }
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                Label("Choose a photo", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)

            if backgroundStore.photoData != nil {
                Button("Remove photo") {
                    backgroundStore.clearPhoto()
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .buttonStyle(.borderless)
            }
        }
    }

    private var everydayDisplaySettings: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Screensaver",
                detail: "Show a dim, slowly moving clock after inactivity",
                isOn: model.screensaverEnabled
            ) { model.setScreensaverEnabled($0) }

            Divider().opacity(0.25)

            SettingsToggleRow(
                title: "Sleep display",
                detail: "Use a darker overnight clock",
                isOn: model.sleepModeEnabled
            ) { model.setSleepModeEnabled($0) }
        }
    }

    private var dynamicTuningSettings: some View {
        VStack(spacing: 14) {
            SettingsSliderRow(
                title: "Speed",
                valueText: String(format: "%.2f×", backgroundStore.dynamicSpeed),
                value: backgroundStore.dynamicSpeed,
                range: 0.4...2,
                step: 0.05,
                action: backgroundStore.setDynamicSpeed
            )
            SettingsSliderRow(
                title: "Crispness",
                valueText: "\(Int((backgroundStore.dynamicCrispness * 100).rounded()))%",
                value: backgroundStore.dynamicCrispness,
                range: 0.2...1,
                step: 0.05,
                action: backgroundStore.setDynamicCrispness
            )
            SettingsSliderRow(
                title: "Color intensity",
                valueText: "\(Int((backgroundStore.dynamicIntensity * 100).rounded()))%",
                value: backgroundStore.dynamicIntensity,
                range: 0.5...1.5,
                step: 0.05,
                action: backgroundStore.setDynamicIntensity
            )
            SettingsSliderRow(
                title: "Wave count",
                valueText: "\(Int(backgroundStore.dynamicWaveCount))",
                value: backgroundStore.dynamicWaveCount,
                range: 3...12,
                step: 1,
                action: backgroundStore.setDynamicWaveCount
            )
            SettingsSliderRow(
                title: "Vertical spread",
                valueText: "\(Int((backgroundStore.dynamicVerticalSpread * 100).rounded()))%",
                value: backgroundStore.dynamicVerticalSpread,
                range: 0.6...1.25,
                step: 0.05,
                action: backgroundStore.setDynamicVerticalSpread
            )

            HStack {
                Text("Saved automatically")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    backgroundStore.resetDynamicTuning()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .buttonStyle(.borderless)
            }
        }
    }

    private var displayDetailSettings: some View {
        VStack(spacing: 0) {
            if model.screensaverEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screensaver starts after")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Any touch resets the inactivity timer")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Screensaver delay", selection: Binding(
                        get: { model.screensaverDelay },
                        set: { model.setScreensaverDelay($0) }
                    )) {
                        Text("2 min").tag(TimeInterval(120))
                        Text("5 min").tag(TimeInterval(300))
                        Text("10 min").tag(TimeInterval(600))
                        Text("20 min").tag(TimeInterval(1_200))
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 10)
            }

            if model.screensaverEnabled, model.sleepModeEnabled {
                Divider().opacity(0.25)
            }

            if model.sleepModeEnabled {
                DatePicker(
                    "Sleep starts",
                    selection: Binding(
                        get: { model.sleepStartDate },
                        set: { model.setSleepStartDate($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.vertical, 9)

                Divider().opacity(0.25)
                DatePicker(
                    "Wake time",
                    selection: Binding(
                        get: { model.sleepEndDate },
                        set: { model.setSleepEndDate($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.vertical, 9)

                Divider().opacity(0.25)
                SettingsToggleRow(
                    title: "Require an active Focus",
                    detail: "Only enter the sleep display when Focus is active during these hours",
                    isOn: model.requireFocusDuringSleepWindow
                ) { model.setRequireFocusDuringSleepWindow($0) }

                Divider().opacity(0.25)
                SettingsToggleRow(
                    title: "Show weather",
                    detail: "Include temperature and the day’s high and low",
                    isOn: model.showWeatherInSleepMode
                ) { model.setShowWeatherInSleepMode($0) }

                Divider().opacity(0.25)
                SettingsToggleRow(
                    title: "Show next event",
                    detail: "Private calendar events remain labeled Private event",
                    isOn: model.showNextEventInSleepMode
                ) { model.setShowNextEventInSleepMode($0) }
            }

            if model.screensaverEnabled || model.sleepModeEnabled {
                Divider().opacity(0.25)
            }

            SettingsToggleRow(
                title: "Wake when iPad moves",
                detail: "Use Core Motion when the iPad is picked up or repositioned",
                isOn: model.motionWakeEnabled
            ) { model.setMotionWakeEnabled($0) }
        }
    }

    private var liveSourceSettings: some View {
        VStack(spacing: 0) {
            SettingsActionRow(title: "WeatherKit", detail: weatherDetail, systemImage: "cloud.sun.fill", actionTitle: "Connect") {
                model.requestWeather()
            }
            Divider().opacity(0.25)
            SettingsActionRow(title: "Health sleep", detail: sleepDetail, systemImage: "bed.double.fill", actionTitle: "Enable") {
                model.requestSleep()
            }
            Divider().opacity(0.25)
            SettingsActionRow(title: "Calendar", detail: calendarDetail, systemImage: "calendar", actionTitle: "Enable") {
                model.requestCalendar()
            }
            Divider().opacity(0.25)
            SettingsActionRow(title: "HomeKit cameras", detail: homeKitDetail, systemImage: "video.fill", actionTitle: "Find") {
                model.requestHomeKit()
            }
            Divider().opacity(0.25)
            SettingsActionRow(title: "Focus status", detail: focusDetail, systemImage: "moon.fill", actionTitle: focusActionTitle) {
                model.requestFocusStatus()
            }
        }
    }

    private var weatherLocationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leave blank to use the iPad’s current location, or enter a city/address for a stable WeatherKit location.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            TextField("Current location", text: $weatherLocation)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
            HStack {
                Button("Save location") {
                    model.setWeatherLocation(weatherLocation)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frameGlass(.clear, in: Capsule(), interactive: true)
                Spacer()
                if !weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Use current location") {
                        weatherLocation = ""
                        model.setWeatherLocation("")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    private var privacyAndAttributionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 21))
                    .foregroundStyle(FrameTheme.coral)
                Text("Mirror requests camera access only when selected. Photos and videos are captured only by your gesture and saved directly to Photos.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
            }
            Text("The front camera remains stopped whenever another feed is active. Frame does not upload captured media.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Divider().opacity(0.25)
            WeatherAttributionView(attribution: model.weatherAttribution)
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            if backgroundStore.isDynamic, backgroundStore.style != .photo {
                SettingsSection(title: "BACKGROUND MOTION LAB") {
                    dynamicTuningSettings
                }
            }

            SettingsSection(title: "DISPLAY DETAILS") {
                displayDetailSettings
            }

            SettingsSection(title: "CONNECTIONS") {
                liveSourceSettings
            }

            SettingsSection(title: "WEATHER LOCATION") {
                weatherLocationSettings
            }

            SettingsSection(title: "UPDATES & CALENDARS") {
                VStack(spacing: 12) {
                    SettingsToggleRow(
                        title: "Sunrise & sunset",
                        detail: "Include solar times in the Updates list",
                        isOn: model.showSunriseSunsetUpdate
                    ) { model.setShowSunriseSunsetUpdate($0) }
                    Divider().opacity(0.25)
                    CalendarSelectionView(model: model)
                }
            }

            SettingsSection(title: "PRIVACY & ATTRIBUTION") {
                privacyAndAttributionSettings
            }

            Text("No account, analytics, or cloud sync")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var weatherDetail: String {
        switch model.weatherState {
        case .loaded(let weather), .stale(let weather): return "\(weather.temperature)° · \(weather.locationName)"
        case .loading: return "Finding current conditions"
        case .denied: return "Location permission denied"
        case .unavailable, .failed: return "Unavailable right now"
        }
    }

    private var calendarDetail: String {
        switch model.calendarState {
        case .loaded(let items): return "\(items.count) upcoming \(items.count == 1 ? "event" : "events")"
        case .empty: return "No upcoming events"
        case .loading: return "Reading selected calendars"
        case .denied: return "Access denied"
        case .failed: return "Could not refresh"
        case .idle: return "Not connected"
        }
    }

    private var sleepDetail: String {
        switch model.sleepState {
        case .idle: return "Read last night from Health"
        case .loading: return "Reading last night"
        case .loaded(let summary): return "Last night · \(summary.durationLabel)"
        case .noData: return "No sleep samples for last night"
        case .denied: return "Health access denied"
        case .unavailable, .failed: return "Unavailable right now"
        }
    }

    private var homeKitDetail: String {
        switch model.homeKitState {
        case .loaded(let cameras): return "\(cameras.count) camera \(cameras.count == 1 ? "feed" : "feeds") · \(model.homeControls.count) controls"
        case .loading: return "Looking for accessible homes"
        case .noHomes: return "No HomeKit homes available"
        case .noCameras: return "No cameras · \(model.homeControls.count) controls"
        case .denied: return "Access denied"
        case .failed: return "Could not refresh"
        case .idle: return "Not connected"
        }
    }

    private var focusActionTitle: String {
        model.focusStatus.isAuthorized ? "Refresh" : "Allow"
    }

    private var focusDetail: String {
        switch model.focusStatus {
        case .active: return "Focus is on"
        case .inactive: return "No active Focus"
        case .loading: return "Checking current Focus"
        case .notDetermined: return "Allow Frame to show a Focus glyph"
        case .denied: return "Access denied in Settings"
        case .restricted: return "Restricted on this iPad"
        case .unavailable: return "Enable Communication Notifications in Xcode"
        }
    }

}

struct MusicSettingsView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(FrameTheme.coral)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Soundtrack")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(model.selectedMusicPlaylistName)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Load playlists") {
                    model.loadMusicPlaylists()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frameGlass(.clear, in: Capsule(), interactive: true)
            }

            if model.musicPlaylists.isEmpty {
                Text("Favorites Mix is the default. Load your library playlists to choose a different soundtrack.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button {
                        model.selectMusicPlaylist(nil)
                    } label: {
                        HStack {
                            Text("Favorites Mix")
                            if model.selectedMusicPlaylistID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    ForEach(model.musicPlaylists) { playlist in
                        Button {
                            model.selectMusicPlaylist(playlist.id)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                if model.selectedMusicPlaylistID == playlist.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Choose playlist")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Spacer()
                        Text(model.selectedMusicPlaylistName)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            content
                .padding(16)
                .frameGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct FramePhotoCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onApply: (Data) -> Void

    @State private var committedZoom: CGFloat = 1
    @State private var committedOffset = CGSize.zero
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gestureOffset = CGSize.zero

    private let cropAspectRatio: CGFloat = 4 / 3

    var body: some View {
        GeometryReader { geometry in
            let cropSize = resolvedCropSize(in: geometry.size)
            let zoom = min(max(committedZoom * gestureZoom, 1), 6)
            let proposedOffset = CGSize(
                width: committedOffset.width + gestureOffset.width,
                height: committedOffset.height + gestureOffset.height
            )
            let offset = clampedOffset(proposedOffset, zoom: zoom, cropSize: cropSize)

            ZStack {
                Color.black.ignoresSafeArea()

                cropCanvas(size: cropSize, zoom: zoom, offset: offset)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                VStack(spacing: 0) {
                    HStack {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .frameGlass(.clear, in: Circle(), interactive: true)
                        .accessibilityLabel("Cancel photo crop")

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Position your background")
                                .font(.system(size: 21, weight: .semibold, design: .rounded))
                            Text("Pinch to zoom · drag to reposition")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                        }

                        Spacer()

                        Button {
                            let finalOffset = clampedOffset(
                                committedOffset,
                                zoom: committedZoom,
                                cropSize: cropSize
                            )
                            if let data = renderedCropData(
                                cropSize: cropSize,
                                zoom: committedZoom,
                                offset: finalOffset
                            ) {
                                onApply(data)
                            }
                        } label: {
                            Label("Use Photo", systemImage: "checkmark")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 17)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .frameGlass(.prominent, in: Capsule(), interactive: true)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 22)

                    Spacer()

                    Text("Guides show where the dashboard glass will sit. They won’t appear in the saved photo.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .frameGlass(.clear, in: Capsule())
                        .padding(.bottom, 20)
                }
                .foregroundStyle(.white)
            }
        }
        .statusBarHidden(true)
    }

    private func cropCanvas(size: CGSize, zoom: CGFloat, offset: CGSize) -> some View {
        let imageSize = displayedImageSize(cropSize: size, zoom: zoom)

        return ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .frame(width: imageSize.width, height: imageSize.height)
                .offset(offset)

            FrameCropGuides(size: size)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.76), lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnificationGesture()
                .updating($gestureZoom) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    committedZoom = min(max(committedZoom * value, 1), 6)
                    committedOffset = clampedOffset(
                        committedOffset,
                        zoom: committedZoom,
                        cropSize: size
                    )
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .updating($gestureOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    let proposed = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                    committedOffset = clampedOffset(proposed, zoom: committedZoom, cropSize: size)
                }
        )
        .accessibilityLabel("Background photo crop with Updates, center view, and Home layout guides")
    }

    private func resolvedCropSize(in availableSize: CGSize) -> CGSize {
        let maxWidth = max(240, availableSize.width - 48)
        let maxHeight = max(180, availableSize.height - 154)
        let width = min(maxWidth, maxHeight * cropAspectRatio)
        return CGSize(width: width, height: width / cropAspectRatio)
    }

    private func displayedImageSize(cropSize: CGSize, zoom: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return cropSize }
        let baseScale = max(
            cropSize.width / image.size.width,
            cropSize.height / image.size.height
        )
        return CGSize(
            width: image.size.width * baseScale * zoom,
            height: image.size.height * baseScale * zoom
        )
    }

    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat, cropSize: CGSize) -> CGSize {
        let displayedSize = displayedImageSize(cropSize: cropSize, zoom: zoom)
        let maximumX = max(0, (displayedSize.width - cropSize.width) / 2)
        let maximumY = max(0, (displayedSize.height - cropSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func renderedCropData(cropSize: CGSize, zoom: CGFloat, offset: CGSize) -> Data? {
        guard cropSize.width > 0, cropSize.height > 0 else { return nil }
        let outputSize = CGSize(width: 2048, height: 1536)
        let displayedSize = displayedImageSize(cropSize: cropSize, zoom: zoom)
        let outputScale = outputSize.width / cropSize.width
        let imageOrigin = CGPoint(
            x: ((cropSize.width - displayedSize.width) / 2 + offset.width) * outputScale,
            y: ((cropSize.height - displayedSize.height) / 2 + offset.height) * outputScale
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let croppedImage = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: CGRect(
                origin: imageOrigin,
                size: CGSize(
                    width: displayedSize.width * outputScale,
                    height: displayedSize.height * outputScale
                )
            ))
        }
        return croppedImage.jpegData(compressionQuality: 0.88)
    }
}

private struct FrameCropGuides: View {
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            FrameCropGuide(
                title: "UPDATES",
                color: .cyan,
                normalizedFrame: CGRect(x: 0.025, y: 0.12, width: 0.275, height: 0.82),
                canvasSize: size
            )

            FrameCropGuide(
                title: "CENTER VIEW",
                color: .white,
                normalizedFrame: CGRect(x: 0.315, y: 0.12, width: 0.66, height: 0.72),
                canvasSize: size
            )

            FrameCropGuide(
                title: "HOME",
                color: .orange,
                normalizedFrame: CGRect(x: 0.70, y: 0.12, width: 0.275, height: 0.82),
                canvasSize: size
            )
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct FrameCropGuide: View {
    let title: String
    let color: Color
    let normalizedFrame: CGRect
    let canvasSize: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(color.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            }
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(color)
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(8)
            }
            .frame(
                width: canvasSize.width * normalizedFrame.width,
                height: canvasSize.height * normalizedFrame.height
            )
            .position(
                x: canvasSize.width * (normalizedFrame.minX + normalizedFrame.width / 2),
                y: canvasSize.height * (normalizedFrame.minY + normalizedFrame.height / 2)
            )
    }
}

struct FrameBackgroundSwatch: View {
    let style: FrameBackgroundStyle
    let isSelected: Bool
    let photoData: Data?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if style == .photo,
               let photoData,
               let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                let colors = style.colors.map { Color(hex: $0) }
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(style.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(style.detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.78)
            }
            .foregroundStyle(.white)
            .padding(10)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .frameGlass(.clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let action: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text(valueText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: action), in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

struct SettingsNavigationRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Connections, schedules, filters, and fine tuning")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .contentShape(Rectangle())
            .padding(16)
        }
        .buttonStyle(.plain)
        .frameGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        .accessibilityLabel("Open advanced settings")
    }
}

struct CalendarSelectionView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.frameAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which calendars can appear in Frame. Frame only reads the calendars you select here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            if model.calendarOptions.isEmpty {
                Text("Calendars will appear after Calendar access is enabled.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.calendarOptions) { calendar in
                    Toggle(isOn: Binding(
                        get: { isSelected(calendar.id) },
                        set: { setSelection(calendar.id, isOn: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text(calendar.sourceName)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                }
            }
        }
    }

    private func isSelected(_ id: String) -> Bool {
        !model.hasStoredCalendarSelection || model.selectedCalendarIdentifiers.contains(id)
    }

    private func setSelection(_ id: String, isOn: Bool) {
        var selection = model.hasStoredCalendarSelection
            ? model.selectedCalendarIdentifiers
            : Set(model.calendarOptions.map(\.id))
        if isOn {
            selection.insert(id)
        } else {
            selection.remove(id)
        }
        model.setCalendarSelection(selection)
    }
}

struct SettingsActionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frameGlass(.clear, in: Capsule(), interactive: true)
        }
        .padding(.vertical, 8)
    }
}

struct UpdatesDetailView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if displayedPastUpdates.isEmpty {
                        ContentUnavailableView("No cleared updates", systemImage: "checkmark.seal", description: Text("Cleared updates from the last 24 hours will appear here."))
                    } else {
                        ForEach(displayedPastUpdates.reversed()) { update in
                            UpdateRow(
                                update: update,
                                onTap: update.kind == .music ? { model.toggleMusicOverlay() } : nil
                            )
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Text("Cleared in the last 24 hours")
                        .textCase(nil)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.opacity(0.82))
            .navigationTitle("Updates")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.frameAccent, .white)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var displayedPastUpdates: [UpdateItem] {
        updatesWithUniqueIDs(model.pastUpdates)
    }

    private func updatesWithUniqueIDs(_ updates: [UpdateItem]) -> [UpdateItem] {
        var seenIDs = Set<String>()
        return updates.filter { seenIDs.insert($0.id).inserted }
    }

}

struct WeatherAttributionView: View {
    let attribution: WeatherAttributionInfo?

    var body: some View {
        HStack(spacing: 12) {
            if let url = attribution?.markURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 84, height: 28)
            } else {
                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(FrameTheme.coral)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attribution?.serviceName ?? "Apple Weather")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if let legalURL = attribution?.legalURL {
                    Link("Legal attribution", destination: legalURL)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
            }
            Spacer()
        }
    }
}

struct MirrorPreviewView: UIViewRepresentable {
    let renderer: MirrorPreviewRenderer

    func makeUIView(context: Context) -> MirrorPreviewUIView {
        let view = MirrorPreviewUIView()
        view.renderer = renderer
        renderer.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ view: MirrorPreviewUIView, context: Context) {
        if view.renderer !== renderer {
            view.renderer?.detach(view.displayLayer)
            view.renderer = renderer
        }
        renderer.attach(view.displayLayer)
    }

    static func dismantleUIView(_ view: MirrorPreviewUIView, coordinator: ()) {
        view.renderer?.detach(view.displayLayer)
        view.renderer = nil
    }
}

final class MirrorPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var renderer: MirrorPreviewRenderer?
}

struct HomeKitSourceView: UIViewRepresentable {
    let source: HMCameraSource

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.backgroundColor = .black
        view.cameraSource = source
        return view
    }

    func updateUIView(_ view: HMCameraView, context: Context) {
        view.cameraSource = source
    }
}

struct FrameAmbientBackground: View {
    let isPausedForPerformance: Bool
    @EnvironmentObject private var backgroundStore: FrameBackgroundStore
    @Environment(\.frameAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if backgroundStore.style == .photo,
                   let image = backgroundStore.photoImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.12))
                } else {
                    let colors = backgroundStore.style.colors.map { Color(hex: $0) }
                    LinearGradient(
                        colors: colors.map { $0.opacity(0.96) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    if backgroundStore.isDynamic {
                        TimelineView(.animation(
                            minimumInterval: 1.0 / 20.0,
                            paused: reduceMotion || scenePhase != .active || isPausedForPerformance
                        )) { timeline in
                            FrameWaveCanvas(
                                colors: colors,
                                date: reduceMotion ? .distantPast : timeline.date,
                                speed: backgroundStore.dynamicSpeed,
                                crispness: backgroundStore.dynamicCrispness,
                                intensity: backgroundStore.dynamicIntensity,
                                waveCount: Int(backgroundStore.dynamicWaveCount),
                                verticalSpread: backgroundStore.dynamicVerticalSpread
                            )
                        }
                    } else {
                        Circle()
                            .fill((colors.first ?? FrameTheme.sun).opacity(0.28))
                            .frame(width: 480, height: 480)
                            .blur(radius: 5)
                            .offset(x: -420, y: -320)
                        Circle()
                            .fill((colors.last ?? FrameTheme.mint).opacity(0.22))
                            .frame(width: 460, height: 460)
                            .blur(radius: 3)
                            .offset(x: 420, y: 320)
                        Canvas { context, size in
                            guard size.width > 0, size.height > 0 else { return }
                            let spacing: CGFloat = 28
                            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                                    let dot = Path(ellipseIn: CGRect(x: x, y: y, width: 2.2, height: 2.2))
                                    context.fill(dot, with: .color(accent.opacity(0.055)))
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct FrameWaveCanvas: View {
    let colors: [Color]
    let date: Date
    let speed: Double
    let crispness: Double
    let intensity: Double
    let waveCount: Int
    let verticalSpread: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let blurScale = 0.024 - (0.016 * crispness)
            context.addFilter(.blur(radius: max(4, min(size.width, size.height) * blurScale)))

            let time = date.timeIntervalSinceReferenceDate
            let palette = colors.isEmpty ? [FrameTheme.sun, FrameTheme.sky, FrameTheme.mint] : colors

            let resolvedWaveCount = max(waveCount, 1)
            for index in 0..<resolvedWaveCount {
                let progress = CGFloat(index) / CGFloat(max(resolvedWaveCount - 1, 1))
                let spreadPosition = 0.5 + (Double(progress) - 0.5) * 0.96 * verticalSpread
                let centerY = size.height * CGFloat(spreadPosition)
                let amplitude = size.height * (0.045 + CGFloat(index % 2) * 0.02)
                let thickness = size.height * (0.14 + CGFloat(index % 2) * 0.025)
                let phaseSpeed = (0.11 + Double(index) * 0.017) * speed
                let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
                let phase = CGFloat(time * phaseSpeed * direction) + CGFloat(index) * 1.45
                let wavelength = max(size.width * (0.54 + CGFloat(index) * 0.075), 1)
                var path = Path()

                path.move(to: CGPoint(x: -size.width * 0.12, y: centerY))
                for x in stride(from: -size.width * 0.12, through: size.width * 1.12, by: 18) {
                    let primary = sin((x / wavelength) * 2 * .pi + phase)
                    let secondary = sin((x / wavelength) * .pi - phase * 0.62 + CGFloat(index)) * 0.32
                    path.addLine(to: CGPoint(x: x, y: centerY + amplitude * (primary + secondary)))
                }
                path.addLine(to: CGPoint(x: size.width * 1.12, y: centerY + thickness))
                path.addLine(to: CGPoint(x: -size.width * 0.12, y: centerY + thickness))
                path.closeSubpath()

                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            palette[index % palette.count].opacity(0.16 * intensity),
                            palette[(index + 1) % palette.count].opacity(0.42 * intensity),
                            palette[(index + 2) % palette.count].opacity(0.18 * intensity)
                        ]),
                        startPoint: CGPoint(x: 0, y: centerY),
                        endPoint: CGPoint(x: size.width, y: centerY + thickness)
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum FrameGlassVariant {
    case regular
    case clear
    case prominent
}

struct FrameGlassModifier<S: Shape>: ViewModifier {
    let variant: FrameGlassVariant
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = switch variant {
            case .regular:
                .regular
            case .clear:
                .clear
            case .prominent:
                .regular.tint(FrameTheme.coral.opacity(0.72))
            }
            content.glassEffect(glass.interactive(interactive), in: shape)
        } else {
            content.background(
                variant == .clear ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.regularMaterial),
                in: shape
            )
        }
    }
}

extension View {
    func frameGlass<S: Shape>(
        _ variant: FrameGlassVariant = .regular,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(FrameGlassModifier(variant: variant, shape: shape, interactive: interactive))
    }

    @ViewBuilder
    func frameGlassContainer(spacing: CGFloat = 0) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

struct FrameGlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    var size: CGFloat = 48
    var variant: FrameGlassVariant = .clear
    var showsProgress = false
    var isDisabled = false
    @Environment(\.frameAccent) private var accent

    var body: some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .tint(accent)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frameGlass(variant, in: Circle(), interactive: true)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
    }
}

enum FrameTheme {
    static let ink = Color(hex: "#173B48")
    static let sun = Color(hex: "#F8E58B")
    static let sky = Color(hex: "#8CC8D4")
    static let meadow = Color(hex: "#A8D49C")
    static let mint = Color(hex: "#BDE8D8")
    static let coral = Color(hex: "#F47F6B")
    static let cardBlue = Color(hex: "#8BC3D0")
}

private struct FrameAccentKey: EnvironmentKey {
    static let defaultValue = FrameTheme.ink
}

extension EnvironmentValues {
    var frameAccent: Color {
        get { self[FrameAccentKey.self] }
        set { self[FrameAccentKey.self] = newValue }
    }
}

extension Color {
    nonisolated init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }
}
