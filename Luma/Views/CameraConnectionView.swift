import SwiftUI

struct CameraConnectionView: View {
    let configuration: CameraConfiguration
    let store: CameraStore
    @State private var player: CameraPlayer?
    @State private var ptz: PTZController?
    @State private var ptzDiscovery: PTZDiscoveryResult?
    @State private var connectionPassword: String?
    @State private var failure: String?
    @State private var controlDetectionAttempt = 0

    var body: some View {
        Group {
            if let player {
                LiveCameraView(player: player, configuration: configuration, ptz: ptz,
                               ptzDiscovery: ptzDiscovery, retryControls: retryControls)
            } else if let failure {
                ContentUnavailableView {
                    Label("Unable to open camera", systemImage: "video.slash")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again", action: preparePlayer).buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Preparing live view…")
            }
        }
        .navigationTitle(configuration.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if player == nil { preparePlayer() } }
        .task(id: ControlDetectionID(ready: player != nil, attempt: controlDetectionAttempt)) {
            guard player != nil, let connectionPassword else { return }
            await detectControls(password: connectionPassword)
        }
    }

    private func retryControls() {
        ptz?.stop()
        ptz = nil
        ptzDiscovery = nil
        controlDetectionAttempt += 1
    }

    private func preparePlayer() {
        do {
            let password = try store.password(for: configuration)
            connectionPassword = password
            player = CameraPlayer(configuration: configuration, password: password,
                                  savesPreview: true, thumbnailStore: store.thumbnails)
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    private func detectControls(password: String) async {
        do {
            let result: PTZDiscoveryResult
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-ptz") {
                // Deterministic UI coverage with no HTTP probe or device account.
                result = .available(PTZCapabilities(channel: configuration.channel, panTilt: true, zoom: true))
            } else {
                result = try await PTZDiscovery.shared.detect(configuration: configuration, password: password,
                                                            forceRefresh: controlDetectionAttempt > 0)
            }
            #else
            result = try await PTZDiscovery.shared.detect(configuration: configuration, password: password,
                                                        forceRefresh: controlDetectionAttempt > 0)
            #endif
            guard !Task.isCancelled else { return }
            ptzDiscovery = result
            if case .available(let capabilities) = result {
                var controls = configuration
                controls.ptzEnabled = true
                controls.ptzChannel = capabilities.channel
                ptz = PTZController(configuration: controls, password: password,
                                    capabilities: capabilities)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            ptzDiscovery = .unknown
        }
    }
}

private struct ControlDetectionID: Hashable {
    let ready: Bool
    let attempt: Int
}

private struct LiveCameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let player: CameraPlayer
    let configuration: CameraConfiguration
    let ptz: PTZController?
    let ptzDiscovery: PTZDiscoveryResult?
    let retryControls: () -> Void
    @State private var fullscreen = false
    @State private var zoomResetID = UUID()
    @State private var showingPTZ = false
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                videoStage
                    .frame(height: fullscreen ? geometry.size.height : min(geometry.size.width * 9 / 16, geometry.size.height * 0.55))
                    .clipShape(.rect(cornerRadius: fullscreen ? 0 : 24))
                    .padding(.horizontal, fullscreen ? 0 : 16)
                    .padding(.top, fullscreen ? 0 : 16)
                if !fullscreen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 14) {
                                controlBar
                                statusMessages
                            }
                            if let ptz { PTZControlsView(controller: ptz) }
                            else { automaticControlStatus }
                            connectionDetails
                        }
                        .padding(24)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("player.controls")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { if fullscreen { Color.black.ignoresSafeArea() } else { LumaBackground() } }
        }
        .preferredColorScheme(.dark)
        .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(fullscreen)
        .task(id: ControlReadinessID(controller: ptz.map(ObjectIdentifier.init),
                                    active: isVisible && scenePhase == .active)) {
            guard isVisible, scenePhase == .active, let ptz else { return }
            await ptz.keepConnectionReady()
        }
        .sheet(isPresented: $showingPTZ) {
            if let ptz {
                NavigationStack {
                    ScrollView { PTZControlsView(controller: ptz, showsTitle: false).padding(24) }
                        .navigationTitle("Pan, tilt & zoom")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPTZ = false } } }
                }
                .presentationDetents([.fraction(0.62), .large])
                .presentationDragIndicator(.visible)
                // Over full-screen video, like the player itself.
                .preferredColorScheme(.dark)
            }
        }
        // Turning the phone sideways shows the camera full screen, as in
        // NVR apps; turning it back restores the controls.
        .onChange(of: verticalSizeClass) { _, sizeClass in
            guard rotatesToFullscreen else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { fullscreen = sizeClass == .compact }
        }
        .onAppear {
            isVisible = true
            if rotatesToFullscreen, verticalSizeClass == .compact { fullscreen = true }
            if scenePhase == .active {
                player.play()
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        .onDisappear {
            isVisible = false
            ptz?.stop()
            player.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where isVisible:
                player.play()
                UIApplication.shared.isIdleTimerDisabled = true
            case .background:
                ptz?.stop()
                player.stop()
                if isVisible { UIApplication.shared.isIdleTimerDisabled = false }
            default:
                // Control Center, banners and the app switcher only make the
                // scene inactive. Keep video and any recording; stop movement,
                // since the finger may no longer be on the control.
                ptz?.stop()
            }
        }
        .onChange(of: player.captureMessage) { _, message in announce(message) }
        .onChange(of: player.captureError) { _, error in announce(error) }
        .onChange(of: ptz?.errorMessage) { _, error in announce(error) }
        .onChange(of: player.state) { _, state in
            if case .failed(let message) = state { announce(message) }
        }
        .accessibilityAction(.escape) {
            guard fullscreen else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { fullscreen = false }
        }
        .onChange(of: player.state) { _, state in
            if isVisible {
                UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && state == .playing
            }
        }
    }

    /// Results appear outside the VoiceOver cursor; speak them when they change.
    private func announce(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    private struct ControlReadinessID: Equatable {
        let controller: ObjectIdentifier?
        let active: Bool
    }

    @ViewBuilder
    private var automaticControlStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch ptzDiscovery {
            case nil:
                ProgressView("Detecting camera controls…")
            case .unavailable:
                Label("The device reports that PTZ controls are disabled or unavailable on this channel.", systemImage: "video")
                    .font(.footnote).foregroundStyle(.secondary)
            case .unknown:
                Label("PTZ detection is unavailable. Check the control port and device account; live view can continue.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .permissionDenied:
                Label("PTZ access was denied. Check the device username, password, and PTZ permissions; live view can continue.", systemImage: "lock.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .unsupported:
                Label("PTZ was detected, but this device's movement method is not supported yet.", systemImage: "move.3d")
                    .font(.footnote).foregroundStyle(.secondary)
            case .available:
                EmptyView()
            }
            if canRetryControlDetection {
                Button("Detect controls again", systemImage: "arrow.clockwise", action: retryControls)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("ptz.detectAgain")
            }
        }
    }

    private var canRetryControlDetection: Bool {
        switch ptzDiscovery {
        case .unknown, .unavailable, .unsupported, .permissionDenied: true
        case nil, .available: false
        }
    }

    private var videoStage: some View {
        ZStack {
            Color.black
            ZoomableVideoSurface(player: player, isZoomEnabled: fullscreen, resetID: zoomResetID)
            playbackOverlay
        }
        .overlay(alignment: .topLeading) {
            Label(player.state.displayTitle, systemImage: player.state.statusSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .modifier(GlassPanel(radius: 30))
                .padding(14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(player.state.displayTitle))
                .accessibilityIdentifier("player.status")
        }
        .overlay(alignment: .bottomTrailing) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    if fullscreen {
                        Button { zoomResetID = UUID() } label: {
                            Text("1×").font(.subheadline.monospacedDigit().weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(Text("Reset digital zoom"))
                        .accessibilityIdentifier("player.zoom.reset")
                    }
                    if ptz != nil && fullscreen {
                        Button { showingPTZ = true } label: {
                            Image(systemName: "move.3d").frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(Text("Pan, tilt & zoom"))
                        .accessibilityIdentifier("player.ptz")
                    }
                    Button {
                        player.setMuted(!player.isMuted)
                    } label: {
                        Image(systemName: player.isMuted ? "speaker.slash" : "speaker.wave.2")
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(player.isMuted ? Text("Enable sound") : Text("Mute"))
                    .accessibilityIdentifier("player.mute")
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { fullscreen.toggle() }
                    } label: {
                        Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(fullscreen ? Text("Exit full screen") : Text("Full screen"))
                    .accessibilityIdentifier("player.fullscreen")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.white)
                // Fixed-size tool buttons: long-press shows their labels at
                // accessibility text sizes.
                .accessibilityShowsLargeContentViewer()
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var playbackOverlay: some View {
        switch player.state {
        case .idle, .connecting:
            ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
        case .buffering:
            ProgressView().tint(.white).accessibilityLabel(Text("Buffering"))
        case .failed(let message):
            Color.black.opacity(0.8)
            if fullscreen {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(message).font(.body).multilineTextAlignment(.center)
                        Button("Reconnect") { player.retry() }.buttonStyle(.glass)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 64)
                }
            } else {
                Button("Reconnect") { player.retry() }.buttonStyle(.glass)
                    .foregroundStyle(.white)
            }
        case .playing:
            EmptyView()
        }
    }

    /// Phones only: an iPad keeps a regular height in landscape.
    private var rotatesToFullscreen: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private var isRecording: Bool { player.captureState == .recording }

    /// One row of player tools under the video, like the toolbar of NVR apps.
    private var controlBar: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                 count: dynamicTypeSize.isAccessibilitySize ? 2 : 5),
                  spacing: 16) {
            Button("Snapshot", systemImage: "camera") { player.captureSnapshot() }
                .disabled(player.state != .playing || player.captureState != .idle)
                .accessibilityIdentifier("player.snapshot")
            Button {
                player.toggleRecording()
            } label: {
                Label(isRecording ? String(localized: "Stop") : String(localized: "Record"),
                      systemImage: isRecording ? "stop.fill" : "record.circle")
            }
            .labelStyle(LiveControlLabelStyle(tint: isRecording ? .red : .primary))
            .accessibilityLabel(isRecording ? Text("Stop recording") : Text("Record"))
            .disabled((player.captureState != .idle && !isRecording) || (player.state != .playing && !isRecording))
            .accessibilityIdentifier("player.record")
            Menu {
                Picker("Stream quality", selection: Binding(get: { player.quality }, set: { player.setQuality($0) })) {
                    ForEach(StreamQuality.allCases) { quality in Text(quality.title).tag(quality) }
                }
            } label: {
                Label(player.quality.title, systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel(Text("Stream quality"))
            .accessibilityValue(Text(player.quality.title))
            .disabled(!configuration.customPath.isEmpty)
            .accessibilityIdentifier("player.quality")
            Button {
                player.setAspectFill(!player.aspectFill)
            } label: {
                Label("Fill", systemImage: player.aspectFill ? "aspectratio.fill" : "aspectratio")
            }
            .labelStyle(LiveControlLabelStyle(tint: player.aspectFill ? LumaTheme.accent : .primary))
            .accessibilityLabel(Text("Fill video frame"))
            .accessibilityAddTraits(player.aspectFill ? .isSelected : [])
            .accessibilityIdentifier("player.fill")
            Button("Reconnect", systemImage: "arrow.clockwise") { player.retry() }
                .accessibilityIdentifier("player.reconnect")
        }
        .buttonStyle(.plain)
        .labelStyle(LiveControlLabelStyle())
    }

    @ViewBuilder
    private var statusMessages: some View {
        if case .failed(let message) = player.state {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !configuration.customPath.isEmpty {
            Text("This camera uses a custom stream path.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let startedAt = player.recordingStartedAt {
            HStack {
                Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
                Text(startedAt, style: .timer).monospacedDigit()
            }
            .font(.subheadline)
        }
        if player.captureState == .savingSnapshot || player.captureState == .startingRecording || player.captureState == .finishingRecording {
            ProgressView(player.captureState == .startingRecording
                         ? String(localized: "Starting recording…") : String(localized: "Saving media…"))
        }
        if let message = player.captureMessage {
            Label(message, systemImage: "checkmark.circle").font(.callout)
        }
        if let error = player.captureError {
            Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 15) {
                LabeledContent("Device", value: configuration.host)
                Divider()
                LabeledContent("Channel", value: configuration.channel.formatted())
                Divider()
                LabeledContent("Transport", value: configuration.useTCP ? "RTSP · TCP" : "RTSP · UDP")
            }
            .font(.subheadline)
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            Text("Live view pauses when Luma is in the background. Recordings stop automatically after 5 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An icon in a glass circle with a caption below it.
private struct LiveControlLabelStyle: LabelStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        LiveControlLabel(icon: configuration.icon, title: configuration.title, tint: tint)
    }
}

private struct LiveControlLabel<Icon: View, Title: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let icon: Icon
    let title: Title
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            icon
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .modifier(GlassPanel(radius: 26))
            title
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private extension PlaybackState {
    var displayTitle: String {
        switch self {
        case .idle: String(localized: "Paused")
        case .connecting: String(localized: "Connecting")
        case .playing: String(localized: "Live")
        case .buffering: String(localized: "Buffering")
        case .failed: String(localized: "Connection unavailable")
        }
    }

    var statusSymbol: String {
        switch self {
        case .playing: "dot.radiowaves.left.and.right"
        case .failed: "exclamationmark.circle"
        case .idle: "pause.circle"
        case .connecting, .buffering: "arrow.triangle.2.circlepath"
        }
    }
}
