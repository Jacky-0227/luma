import SwiftUI
import UIKit

struct DashboardView: View {
    let store: CameraStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dashboards = DashboardStore()
    @State private var editor: DashboardEditorRoute?
    @State private var deleting: DashboardConfiguration?
    @State private var showingOrder = false
    @State private var message: InterfaceMessage?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every angle. Together.")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Arrange the views that matter to you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if dashboards.dashboards.isEmpty {
                        ContentUnavailableView {
                            Label("Your dashboards", systemImage: "rectangle.split.2x2")
                        } description: {
                            Text("Create a dashboard and bring your cameras together.")
                        } actions: {
                            Button("Add dashboard", systemImage: "plus") { editor = DashboardEditorRoute() }
                                .buttonStyle(.glassProminent)
                                .foregroundStyle(LumaTheme.onAccent)
                        }
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(dashboards.dashboards) { dashboard in dashboardCard(dashboard) }
                        }
                    }
                    if store.cameras.isEmpty {
                        Label("Add a camera from the home screen to use the dashboard.", systemImage: "video.badge.plus")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    Button("Add dashboard", systemImage: "plus") { editor = DashboardEditorRoute() }
                        .accessibilityIdentifier("dashboard.add")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Dashboard options", systemImage: "ellipsis") {
                        Button("Reorder dashboards", systemImage: "arrow.up.arrow.down") { showingOrder = true }
                            .disabled(dashboards.dashboards.count < 2)
                    }
                    .accessibilityIdentifier("dashboard.options")
                }
            }
            .sheet(item: $editor) { route in
                DashboardEditorView(store: store, dashboards: dashboards, dashboard: route.dashboard)
            }
            .sheet(isPresented: $showingOrder) { DashboardOrderView(dashboards: dashboards) }
            .confirmationDialog("Remove dashboard?", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { dashboard in
                Button("Remove", role: .destructive) {
                    do { try dashboards.delete(dashboard) }
                    catch { message = InterfaceMessage(text: error.localizedDescription) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                Text("Only this dashboard layout will be removed.")
            }
            .lumaAlert($message)
            .task {
                if let error = dashboards.errorMessage { message = InterfaceMessage(text: error) }
            }
        }
    }

    private func dashboardCard(_ dashboard: DashboardConfiguration) -> some View {
        let cameras = dashboard.cameras(from: store.cameras)
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                DashboardViewerView(dashboard: dashboard, store: store)
            } label: {
                DashboardMosaic(cameras: Array(cameras.prefix(dashboard.pageSize)), columns: dashboard.columns, store: store)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(dashboard.name))
            .accessibilityHint(Text("Open dashboard"))
            .accessibilityIdentifier("dashboard.card.\(dashboard.id)")
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dashboard.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(cameras.count == 1 ? String(localized: "1 camera") : String(format: String(localized: "%lld cameras"), Int64(cameras.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu("Dashboard actions", systemImage: "ellipsis") {
                    Button("Edit dashboard", systemImage: "pencil") { editor = DashboardEditorRoute(dashboard: dashboard) }
                    Button("Remove dashboard", systemImage: "trash", role: .destructive) { deleting = dashboard }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("dashboard.menu.\(dashboard.id)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 20))
    }
}

private struct DashboardEditorRoute: Identifiable {
    var dashboard: DashboardConfiguration?
    var id: String { dashboard?.id.uuidString ?? "new-dashboard" }
}

private struct DashboardMosaic: View {
    let cameras: [CameraConfiguration]
    let columns: Int
    let store: CameraStore
    private var columnCount: Int { min(max(1, cameras.count), min(8, max(1, columns))) }
    private var rowCount: Int { max(1, (cameras.count + columnCount - 1) / columnCount) }

    var body: some View {
        ZStack {
            Color.black
            if cameras.isEmpty {
                Image(systemName: "rectangle.split.2x2")
                    .font(.title2.weight(.light))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                GeometryReader { geometry in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount), spacing: 2) {
                        ForEach(cameras) { camera in
                            DashboardCameraThumbnail(camera: camera, store: store)
                                .frame(height: max(0, geometry.size.height - CGFloat(rowCount - 1) * 2) / CGFloat(rowCount))
                        }
                    }
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct DashboardCameraThumbnail: View {
    let camera: CameraConfiguration
    let store: CameraStore
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: "video")
                    .font(.body.weight(.light))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .clipped()
        .task(id: DashboardPreviewService.cacheKey(for: camera)) {
            thumbnail = nil
            guard let password = try? store.password(for: camera) else { return }
            let image = await DashboardPreviewService.shared.image(for: camera, password: password)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
