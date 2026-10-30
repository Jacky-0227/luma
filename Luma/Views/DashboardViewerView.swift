import SwiftUI
import UIKit

struct DashboardViewerView: View {
    let dashboard: DashboardConfiguration
    let store: CameraStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("dashboard.showsNames") private var showsNames = true
    @State private var session = DashboardSession()
    @State private var page = 0
    @State private var isVisible = false
    @State private var isOpeningCamera = false
    @State private var showsPreparing = false
    @State private var selectedCamera: CameraConfiguration?
    @State private var showingCamera = false
    @State private var navigationRequest: UUID?
    @State private var keepsScreenAwake = false

    private static let spacing: CGFloat = 4
    private static let gutter: CGFloat = 8

    /// One ordered lookup per body evaluation; pages are slices of it.
    private struct Pages {
        let ordered: [CameraConfiguration]
        let size: Int

        var count: Int { max(1, (ordered.count + size - 1) / size) }

        func cameras(on page: Int) -> [CameraConfiguration] {
            guard !ordered.isEmpty else { return [] }
            let index = min(max(0, page), count - 1)
            let start = index * size
            return Array(ordered[start..<min(ordered.count, start + size)])
        }
    }

    private var pages: Pages {
        Pages(ordered: dashboard.cameras(from: store.cameras), size: min(64, max(1, dashboard.pageSize)))
    }

    var body: some View {
        let pages = pages
        GeometryReader { geometry in
            wall(in: geometry.size)
        }
        .background { Color.black.ignoresSafeArea() }
        .overlay {
            if pages.ordered.isEmpty {
                ContentUnavailableView("No cameras yet", systemImage: "square.grid.2x2",
                                       description: Text("Add a camera from the home screen to use the dashboard."))
            }
        }
        .overlay {
            if showsPreparing {
                ProgressView("Preparing views…")
                    .padding(20)
                    .modifier(GlassPanel(radius: 20))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(pageCount: pages.count)
        }
        .simultaneousGesture(pageSwipe(pageCount: pages.count))
        .navigationTitle(dashboard.name)
        .navigationSubtitle(liveSummary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(showsNames ? "Hide camera names" : "Show camera names",
                       systemImage: showsNames ? "text.below.photo.fill" : "text.below.photo") {
                    showsNames.toggle()
                }
                .accessibilityIdentifier("dashboard.names")
                Button("Reconnect cameras", systemImage: "arrow.clockwise") { synchronize(forceRestart: true) }
                    .disabled(pages.ordered.isEmpty || session.isTransitioning || isOpeningCamera)
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
        // Only leaving the foreground stops video. Control Center, banners and
        // the app switcher make the scene inactive without leaving it.
        .onChange(of: scenePhase) { old, new in
            if old == .background || new == .background { synchronize() }
            updateScreenAwake()
        }
        .onChange(of: session.playingCount) { _, _ in updateScreenAwake() }
        .onChange(of: page) { _, _ in synchronize() }
        .onChange(of: pages.ordered) { _, _ in
            let boundedPage = min(page, pages.count - 1)
            if boundedPage != page { page = boundedPage }
            else { synchronize() }
        }
        .onChange(of: showingCamera) { _, isShowing in
            if !isShowing {
                selectedCamera = nil
                synchronize()
            }
        }
        .task(id: session.isTransitioning || isOpeningCamera) {
            // A quick page change should not flash a progress panel.
            guard session.isTransitioning || isOpeningCamera else { showsPreparing = false; return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            showsPreparing = true
        }
        // The wall is always dark, like the full-screen player.
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
    }

    private var liveSummary: String {
        let total = session.cameras.count
        guard total > 0 else { return "" }
        return String(format: String(localized: "%lld of %lld live"), Int64(session.playingCount), Int64(total))
    }

    // MARK: Wall

    private func wall(in size: CGSize) -> some View {
        let layout = WallLayout(count: session.cameras.count, preferredColumns: preferredColumns,
                                size: size, spacing: Self.spacing, gutter: Self.gutter)
        return ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(Array(stride(from: 0, to: session.cameras.count, by: layout.columns)), id: \.self) { start in
                    HStack(spacing: Self.spacing) {
                        ForEach(session.cameras[start..<min(session.cameras.count, start + layout.columns)]) { camera in
                            DashboardCameraButton(camera: camera, showsName: showsNames && layout.cell.width >= 110,
                                                  isEnabled: !isOpeningCamera && !session.isTransitioning) {
                                open(camera.configuration)
                            }
                            .frame(width: layout.cell.width, height: layout.cell.height)
                            .onScrollVisibilityChange(threshold: 0.05) { visible in
                                session.setVisible(visible, for: camera.id)
                            }
                        }
                    }
                    // Keep a short last row aligned with the columns above.
                    .frame(maxWidth: layout.contentWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, Self.gutter)
            .frame(maxWidth: .infinity, minHeight: layout.fits ? size.height : 0)
        }
        .scrollDisabled(layout.fits)
        .scrollIndicators(.hidden)
        .onChange(of: layout.initiallyHiddenStart) { _, _ in reportInitialVisibility(layout) }
        .onChange(of: session.cameras.map(\.id)) { _, _ in reportInitialVisibility(layout) }
        .onAppear { reportInitialVisibility(layout) }
    }

    private var preferredColumns: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : min(8, max(1, dashboard.columns))
    }

    /// Tiles below the first screen start paused; scroll visibility takes over.
    private func reportInitialVisibility(_ layout: WallLayout) {
        let ids = session.cameras.map(\.id)
        session.setInitiallyHidden(Set(ids.dropFirst(layout.initiallyHiddenStart)))
    }

    // MARK: Paging

    @ViewBuilder
    private func footer(pageCount: Int) -> some View {
        VStack(spacing: 8) {
            if session.closingCount > 0 {
                Label("Some cameras are still closing. They will reconnect shortly.", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .modifier(GlassPanel(radius: 16))
            }
            if pageCount > 1 { pageBar(pageCount: pageCount) }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func pageBar(pageCount: Int) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                Button("Previous cameras", systemImage: "chevron.left") { page = max(0, page - 1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .disabled(page == 0 || isOpeningCamera)
                    .accessibilityIdentifier("dashboard.previous")
                Text(verbatim: "\(page + 1) / \(pageCount)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 56)
                    .accessibilityLabel(Text(String(format: String(localized: "Page %lld of %lld"),
                                                    Int64(page + 1), Int64(pageCount))))
                    .accessibilityIdentifier("dashboard.page")
                Button("Next cameras", systemImage: "chevron.right") { page = min(pageCount - 1, page + 1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .disabled(page >= pageCount - 1 || isOpeningCamera)
                    .accessibilityIdentifier("dashboard.next")
            }
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .foregroundStyle(.white)
    }

    private func pageSwipe(pageCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard pageCount > 1, !isOpeningCamera,
                      abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                if value.translation.width < 0 { page = min(pageCount - 1, page + 1) }
                else { page = max(0, page - 1) }
            }
    }

    // MARK: Lifecycle

    private func synchronize(forceRestart: Bool = false) {
        let shouldPlay = isVisible && scenePhase != .background && !showingCamera && !isOpeningCamera
        session.show(pages.cameras(on: page), store: store, active: shouldPlay, forceRestart: forceRestart)
        updateScreenAwake()
    }

    private func updateScreenAwake() {
        // A retained, hidden tab can still observe its players retiring. It must
        // not reset the idle timer while a different tab owns the visible video.
        guard isVisible, !showingCamera else { return }
        let shouldKeepAwake = scenePhase == .active && !isOpeningCamera && session.playingCount > 0
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
        guard !isOpeningCamera, isVisible, scenePhase != .background else { return }
        isOpeningCamera = true
        releaseScreenAwake()
        let request = UUID()
        navigationRequest = request
        // The destination is not created until the old page decoders finish
        // shutting down (bounded by the session's transition timeout).
        session.suspend()
        Task { @MainActor in
            await session.suspendAndWait()
            guard navigationRequest == request else { return }
            guard isVisible, scenePhase != .background else {
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

/// Sizes 16:9 cells to use the screen: fewer cameras than columns use fewer
/// columns, and a wall that nearly fits is scaled to fit without scrolling.
struct WallLayout: Equatable {
    let columns: Int
    let cell: CGSize
    let contentWidth: CGFloat
    let fits: Bool
    /// Index of the first tile that starts below the visible area.
    let initiallyHiddenStart: Int

    init(count: Int, preferredColumns: Int, size: CGSize, spacing: CGFloat, gutter: CGFloat) {
        let columns = max(1, min(preferredColumns, max(1, count)))
        let rows = max(1, (count + columns - 1) / columns)
        let width = max(1, size.width - gutter * 2)
        let height = max(1, size.height - gutter * 2)
        var cellWidth = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var cellHeight = cellWidth * 9 / 16
        let total = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
        var fits = total <= height
        if !fits {
            // Shrink to fit (letterboxed sideways) while tiles stay legible.
            let fittedHeight = (height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            if fittedHeight * 16 / 9 >= 100 {
                cellHeight = fittedHeight
                cellWidth = fittedHeight * 16 / 9
                fits = true
            }
        }
        self.columns = columns
        self.cell = CGSize(width: cellWidth, height: cellHeight)
        self.contentWidth = cellWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
        self.fits = fits
        let visibleRows = fits ? rows : Int((height / (cellHeight + spacing)).rounded(.up))
        self.initiallyHiddenStart = min(count, visibleRows * columns)
    }
}

/// A separate view so each tile observes only its own player's state.
private struct DashboardCameraButton: View {
    let camera: DashboardCamera
    let showsName: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardCameraTile(camera: camera, showsName: showsName)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(camera.configuration.name))
        .accessibilityValue(Text(DashboardCameraTile.status(for: camera)))
        .accessibilityHint(Text("Open live view"))
        .accessibilityIdentifier("dashboard.camera.\(camera.id)")
    }
}

private struct DashboardCameraTile: View {
    let camera: DashboardCamera
    let showsName: Bool

    var body: some View {
        // The cell determines its size. The native drawable only fills that
        // proposal and keeps the stream's display aspect ratio (letterboxed).
        Color.black
            .overlay {
                if let player = camera.player {
                    VideoSurface(player: player)
                    DashboardPlaybackOverlay(player: player)
                } else {
                    TileMessage(symbol: "key.slash", text: String(localized: "Password needed"))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsName { nameLabel }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
    }

    private var nameLabel: some View {
        HStack(spacing: 5) {
            if let player = camera.player {
                LiveDot(player: player)
            }
            Text(camera.configuration.name)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 2)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
    }

    static func status(for camera: DashboardCamera) -> String {
        guard let player = camera.player else { return String(localized: "Password needed") }
        switch player.state {
        case .idle: return String(localized: "Paused")
        case .connecting: return String(localized: "Connecting")
        case .buffering: return String(localized: "Buffering")
        case .playing: return String(localized: "Live · Muted")
        case .failed: return String(localized: "Offline · retrying")
        }
    }
}

private struct LiveDot: View {
    let player: CameraPlayer

    var body: some View {
        Circle()
            .fill(player.state == .playing ? Color.green : Color.white.opacity(0.4))
            .frame(width: 6, height: 6)
    }
}

private struct TileMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(text).font(.caption2).lineLimit(1)
            }
            Image(systemName: symbol).font(.body)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(6)
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
            Image(systemName: "pause.fill").font(.body).foregroundStyle(.white.opacity(0.5))
        case .failed:
            TileMessage(symbol: "video.slash", text: String(localized: "Offline · retrying"))
        }
    }
}
