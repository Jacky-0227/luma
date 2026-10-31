import SwiftUI
import UIKit

struct DashboardViewerView: View {
    let dashboard: DashboardConfiguration
    let store: CameraStore
    let dashboards: DashboardStore
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
    @State private var message: InterfaceMessage?

    private static let spacing: CGFloat = 3
    private static let gutter: CGFloat = 4
    /// The split-screen choices of NVR apps. Other saved sizes stay available.
    static let layoutChoices = [1, 4, 9, 16]

    /// The saved dashboard, so a layout chosen here applies immediately.
    private var current: DashboardConfiguration {
        dashboards.dashboards.first { $0.id == dashboard.id } ?? dashboard
    }

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
        Pages(ordered: current.cameras(from: store.cameras), size: min(64, max(1, current.pageSize)))
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
        .navigationTitle(current.name)
        .navigationSubtitle(liveSummary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                layoutMenu
                Menu("Dashboard options", systemImage: "ellipsis") {
                    Toggle(isOn: $showsNames) {
                        Label("Show camera names", systemImage: "textformat")
                    }
                    .accessibilityIdentifier("dashboard.names")
                    Button("Reconnect cameras", systemImage: "arrow.clockwise") { synchronize(forceRestart: true) }
                        .disabled(pages.ordered.isEmpty || session.isTransitioning || isOpeningCamera)
                        .accessibilityIdentifier("dashboard.reconnect")
                }
                .accessibilityIdentifier("dashboard.more")
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
        .lumaAlert($message)
        // The wall is always dark. The app root sets the window's preferred
        // scheme, so a preference here would be overridden; set it locally.
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
    }

    private var liveSummary: String {
        let total = session.cameras.count
        guard total > 0 else { return "" }
        return String(format: String(localized: "%lld of %lld live"), Int64(session.playingCount), Int64(total))
    }

    // MARK: Layout

    /// Like the window-division button of NVR apps: choose how many cameras
    /// share the screen. Their arrangement follows the screen automatically.
    private var layoutMenu: some View {
        Menu {
            Picker("Views per page", selection: Binding(get: { current.pageSize }, set: { setPageSize($0) })) {
                ForEach(Self.layoutChoices, id: \.self) { count in
                    Label(Self.layoutTitle(count), systemImage: Self.layoutSymbol(count)).tag(count)
                }
                if !Self.layoutChoices.contains(current.pageSize) {
                    Label(Self.layoutTitle(current.pageSize), systemImage: Self.layoutSymbol(current.pageSize))
                        .tag(current.pageSize)
                }
            }
        } label: {
            Label("Views per page", systemImage: Self.layoutSymbol(current.pageSize))
        }
        .disabled(isOpeningCamera)
        .accessibilityIdentifier("dashboard.layout")
    }

    static func layoutTitle(_ count: Int) -> String {
        count == 1 ? String(localized: "1 view") : String(format: String(localized: "%lld views"), Int64(count))
    }

    static func layoutSymbol(_ count: Int) -> String {
        switch count {
        case ...1: "rectangle"
        case 2...4: "square.grid.2x2"
        case 5...9: "square.grid.3x3"
        default: "square.grid.4x3.fill"
        }
    }

    private func setPageSize(_ size: Int) {
        var updated = current
        guard updated.pageSize != size else { return }
        // Stay on the page that holds the first camera currently shown.
        let firstShown = page * updated.pageSize
        updated.pageSize = size
        updated.columns = DashboardConfiguration.coverColumns(forPageSize: size)
        do {
            try dashboards.save(updated)
        } catch {
            message = InterfaceMessage(text: error.localizedDescription)
            return
        }
        let target = firstShown / size
        if target != page { page = target } else { synchronize() }
    }

    // MARK: Wall

    private func wall(in size: CGSize) -> some View {
        let layout = WallLayout(count: session.cameras.count, maxColumns: maxColumns,
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
                    .frame(width: layout.contentWidth, alignment: .leading)
                }
            }
            .padding(Self.gutter)
            .frame(maxWidth: .infinity, minHeight: layout.fits ? size.height : 0)
        }
        .scrollDisabled(layout.fits)
        .scrollIndicators(.hidden)
        .onChange(of: layout.initiallyHiddenStart) { _, _ in reportInitialVisibility(layout) }
        .onChange(of: session.cameras.map(\.id)) { _, _ in reportInitialVisibility(layout) }
        .onAppear { reportInitialVisibility(layout) }
    }

    private var maxColumns: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 8
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

/// Picks the column count that gives the largest 16:9 tiles with every camera
/// on screen, like a video-call gallery: on a portrait phone four cameras
/// stack in one column, in landscape they form a 2 × 2 grid. When even the
/// best fit would make tiles too small to read, the wall scrolls instead.
struct WallLayout: Equatable {
    static let minimumTileWidth: CGFloat = 100
    static let columnPreference: CGFloat = 1.05

    let columns: Int
    let cell: CGSize
    let contentWidth: CGFloat
    let fits: Bool
    /// Index of the first tile that starts below the visible area.
    let initiallyHiddenStart: Int

    init(count: Int, maxColumns: Int, size: CGSize, spacing: CGFloat, gutter: CGFloat) {
        let tiles = max(1, count)
        let width = max(1, size.width - gutter * 2)
        let height = max(1, size.height - gutter * 2)
        let limit = max(1, min(maxColumns, tiles))
        var columns = 1
        var cellWidth: CGFloat = 0
        for candidate in 1...limit {
            let rows = (tiles + candidate - 1) / candidate
            let byWidth = (width - CGFloat(candidate - 1) * spacing) / CGFloat(candidate)
            let byHeight = (height - CGFloat(rows - 1) * spacing) / CGFloat(rows) * 16 / 9
            let candidateWidth = min(byWidth, byHeight)
            // Prefer fewer columns (a fuller grid) unless more columns give
            // clearly larger tiles, e.g. 3 × 3 over a ragged 5 + 4.
            if candidateWidth > cellWidth * Self.columnPreference {
                columns = candidate
                cellWidth = candidateWidth
            }
        }
        var fits = true
        if cellWidth < Self.minimumTileWidth {
            columns = max(1, min(limit, Int((width + spacing) / (Self.minimumTileWidth + spacing))))
            cellWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            fits = false
        }
        cellWidth = max(1, cellWidth)
        let cellHeight = cellWidth * 9 / 16
        let rows = (tiles + columns - 1) / columns
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
        // A visible slot, so connecting and offline tiles still read as a grid.
        Color(white: 0.13)
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
            .clipShape(.rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
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
