import SwiftUI
import UIKit

struct DashboardView: View {
    let store: CameraStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var session = DashboardSession()
    @State private var page = 0
    @State private var isVisible = false
    @State private var isOpeningCamera = false
    @State private var selectedCamera: CameraConfiguration?
    @State private var showingCamera = false
    @State private var navigationRequest: UUID?
    @State private var keepsScreenAwake = false

    private var pageCount: Int { max(1, (store.cameras.count + 3) / 4) }
    private var pageCameras: [CameraConfiguration] {
        Array(store.cameras.dropFirst(min(page, pageCount - 1) * 4).prefix(4))
    }
    private var hasPlayingCamera: Bool {
        session.cameras.contains { $0.player?.state == .playing }
    }

    var body: some View {
        NavigationStack { content }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every angle. Together.")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Up to four cameras at a time. Fluent streams, sound off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.cameras.isEmpty {
                    ContentUnavailableView("No cameras yet", systemImage: "square.grid.2x2", description: Text("Add a camera from the home screen to use the dashboard."))
                } else {
                    cameraGrid
                    if pageCount > 1 { pageControls }
                    Label("Tap a camera to open its live view and controls.", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if pageCameras.contains(where: { !$0.customPath.isEmpty }) {
                        Text("Cameras with a custom path use that stream in the dashboard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background { LumaBackground() }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reconnect cameras", systemImage: "arrow.clockwise") { synchronize(forceRestart: true) }
                    .disabled(store.cameras.isEmpty || session.isTransitioning || isOpeningCamera)
                    .accessibilityIdentifier("dashboard.reconnect")
            }
        }
        .navigationDestination(isPresented: $showingCamera) {
            if let selectedCamera {
                CameraConnectionView(configuration: selectedCamera, store: store)
            }
        }
        .onAppear {
            isVisible = true
            synchronize()
        }
        .onDisappear {
            releaseScreenAwake()
            isVisible = false
            navigationRequest = nil
            isOpeningCamera = false
            session.suspend()
        }
        .onChange(of: scenePhase) { _, _ in synchronize() }
        .onChange(of: hasPlayingCamera) { _, _ in updateScreenAwake() }
        .onChange(of: page) { _, _ in synchronize() }
        .onChange(of: store.cameras) { _, _ in
            let boundedPage = min(page, pageCount - 1)
            if boundedPage != page { page = boundedPage }
            else { synchronize() }
        }
        .onChange(of: showingCamera) { _, isShowing in
            if !isShowing {
                selectedCamera = nil
                synchronize()
            }
        }
    }

    private var cameraGrid: some View {
        // At most four surfaces: eager layout keeps an offscreen accessibility
        // row from being torn down/recreated by a lazy container while scrolling.
        Grid(alignment: .top, horizontalSpacing: 12, verticalSpacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(session.cameras) { camera in
                    GridRow { cameraButton(camera) }
                }
            } else {
                GridRow {
                    ForEach(session.cameras.prefix(2)) { camera in cameraButton(camera) }
                }
                if session.cameras.count > 2 {
                    GridRow {
                        ForEach(session.cameras.dropFirst(2)) { camera in cameraButton(camera) }
                    }
                }
            }
        }
        .overlay {
            if session.isTransitioning || isOpeningCamera {
                ProgressView("Preparing views…")
                    .padding(20)
                    .modifier(GlassPanel(radius: 20))
            }
        }
        .frame(minHeight: session.cameras.isEmpty ? 180 : 0)
    }

    private func cameraButton(_ camera: DashboardCamera) -> some View {
        Button { open(camera.configuration) } label: {
            DashboardCameraTile(camera: camera)
        }
        .buttonStyle(.plain)
        .disabled(isOpeningCamera || session.isTransitioning)
        .accessibilityIdentifier("dashboard.camera.\(camera.id)")
    }

    private var pageControls: some View {
        HStack(spacing: 18) {
            Button("Previous cameras", systemImage: "chevron.left") { page = max(0, page - 1) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.glass)
                .disabled(page == 0 || isOpeningCamera)
                .accessibilityIdentifier("dashboard.previous")
            Spacer(minLength: 0)
            Text(String(format: String(localized: "Page %lld of %lld"), Int64(page + 1), Int64(pageCount)))
                .font(.subheadline.monospacedDigit())
                .accessibilityIdentifier("dashboard.page")
            Spacer(minLength: 0)
            Button("Next cameras", systemImage: "chevron.right") { page = min(pageCount - 1, page + 1) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.glass)
                .disabled(page >= pageCount - 1 || isOpeningCamera)
                .accessibilityIdentifier("dashboard.next")
        }
    }

    private func synchronize(forceRestart: Bool = false) {
        let shouldPlay = isVisible && scenePhase == .active && !showingCamera && !isOpeningCamera
        session.show(pageCameras, store: store, active: shouldPlay, forceRestart: forceRestart)
        updateScreenAwake()
    }

    private func updateScreenAwake() {
        // A retained, hidden tab can still observe its players retiring. It must
        // not reset the idle timer while a different tab owns the visible video.
        guard isVisible, !showingCamera else { return }
        let shouldKeepAwake = scenePhase == .active && !isOpeningCamera && hasPlayingCamera
        guard keepsScreenAwake != shouldKeepAwake else { return }
        keepsScreenAwake = shouldKeepAwake
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }

    private func releaseScreenAwake() {
        guard keepsScreenAwake else { return }
        keepsScreenAwake = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func open(_ camera: CameraConfiguration) {
        guard !isOpeningCamera, isVisible, scenePhase == .active else { return }
        isOpeningCamera = true
        releaseScreenAwake()
        let request = UUID()
        navigationRequest = request
        // The destination is not created until all four old decoders finish
        // shutting down. Merely hiding their views would leave streams running.
        session.suspend()
        Task { @MainActor in
            await session.suspendAndWait()
            guard navigationRequest == request else { return }
            guard isVisible, scenePhase == .active else {
                navigationRequest = nil
                isOpeningCamera = false
                synchronize()
                return
            }
            selectedCamera = camera
            showingCamera = true
            isOpeningCamera = false
        }
    }
}

private struct DashboardCameraTile: View {
    let camera: DashboardCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let player = camera.player {
                    VideoSurface(player: player)
                    DashboardPlaybackOverlay(player: player)
                } else {
                    Image(systemName: "key.slash")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipped()
            VStack(alignment: .leading, spacing: 5) {
                Text(camera.configuration.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let player = camera.player {
                    DashboardStatusLabel(player: player)
                } else {
                    Text("Connection unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let failure = camera.failure {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Open live view"))
    }
}

private struct DashboardPlaybackOverlay: View {
    let player: CameraPlayer

    @ViewBuilder
    var body: some View {
        switch player.state {
        case .playing:
            EmptyView()
        case .connecting, .buffering:
            ProgressView().tint(.white)
        case .idle:
            Color.black
            Image(systemName: "pause.circle").font(.title2).foregroundStyle(.white.opacity(0.8))
        case .failed:
            Color.black
            Image(systemName: "video.slash").font(.title2).foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct DashboardStatusLabel: View {
    let player: CameraPlayer

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(player.state == .playing ? Color.accentColor : Color.secondary)
    }

    private var title: String {
        switch player.state {
        case .idle: String(localized: "Paused")
        case .connecting: String(localized: "Connecting")
        case .buffering: String(localized: "Buffering")
        case .playing: String(localized: "Live · Muted")
        case .failed: String(localized: "Connection unavailable")
        }
    }

    private var symbol: String {
        switch player.state {
        case .playing: "speaker.slash"
        case .connecting, .buffering: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.circle"
        case .idle: "pause.circle"
        }
    }
}
