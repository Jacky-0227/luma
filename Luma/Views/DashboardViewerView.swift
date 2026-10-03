import SwiftUI
import UIKit

struct DashboardViewerView: View {
    let dashboard: DashboardConfiguration
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

    private var selectedCameras: [CameraConfiguration] { dashboard.cameras(from: store.cameras) }
    private var pageCount: Int { max(1, dashboard.pageCount(from: store.cameras)) }
    private var pageCameras: [CameraConfiguration] {
        dashboard.cameras(onPage: min(page, pageCount - 1), from: store.cameras)
    }
    private var columnCount: Int { dynamicTypeSize.isAccessibilitySize ? 1 : min(8, max(1, dashboard.columns)) }

    private struct CameraRow: Identifiable {
        let cameras: [DashboardCamera]
        var id: UUID { cameras[0].id }
    }

    private var cameraRows: [CameraRow] {
        stride(from: 0, to: session.cameras.count, by: columnCount).map { start in
            CameraRow(cameras: Array(session.cameras.dropFirst(start).prefix(columnCount)))
        }
    }
    private var hasPlayingCamera: Bool {
        session.cameras.contains { $0.player?.state == .playing }
    }

    var body: some View {
        content
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selectedCameras.isEmpty {
                    ContentUnavailableView("No cameras yet", systemImage: "square.grid.2x2", description: Text("Add a camera from the home screen to use the dashboard."))
                } else {
                    cameraGrid
                    if pageCount > 1 { pageControls }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background { LumaBackground() }
        .navigationTitle(dashboard.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reconnect cameras", systemImage: "arrow.clockwise") { synchronize(forceRestart: true) }
                    .disabled(selectedCameras.isEmpty || session.isTransitioning || isOpeningCamera)
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
        .onChange(of: selectedCameras) { _, _ in
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
        // Keep drawable identities stable while scrolling. The selected page
        // owns its streams; changing pages retires all of them before replacing.
        Grid(alignment: .top, horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(cameraRows) { row in
                GridRow {
                    ForEach(row.cameras) { camera in cameraButton(camera) }
                    ForEach(0..<(columnCount - row.cameras.count), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(camera.configuration.name))
        .accessibilityValue(Text(camera.player.map { DashboardCameraTile.status(for: $0.state) } ?? String(localized: "Connection unavailable")))
        .accessibilityHint(Text("Open live view"))
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
        // The destination is not created until all old page decoders finish
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
        // The cell determines its size. The native drawable only fills that
        // proposal and keeps the stream's display aspect ratio (letterboxed).
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let player = camera.player {
                    VideoSurface(player: player)
                    DashboardPlaybackOverlay(player: player)
                } else {
                    Image(systemName: "key.slash")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07), lineWidth: 0.5) }
    }

    static func status(for state: PlaybackState) -> String {
        switch state {
        case .idle: String(localized: "Paused")
        case .connecting: String(localized: "Connecting")
        case .buffering: String(localized: "Buffering")
        case .playing: String(localized: "Live · Muted")
        case .failed: String(localized: "Connection unavailable")
        }
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
