import SwiftUI

private struct CameraEditorRoute: Identifiable {
    var camera: CameraConfiguration?
    var id: String { camera?.id.uuidString ?? "new-camera" }
}

struct HomeView: View {
    let store: CameraStore
    @State private var editor: CameraEditorRoute?
    @State private var deleting: CameraConfiguration?
    @State private var showingSettings = false
    @State private var message: InterfaceMessage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    introduction
                    if store.cameras.isEmpty {
                        EmptyCamerasView { editor = CameraEditorRoute() }
                    } else {
                        cameraCollection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background { LumaBackground() }
            .navigationTitle("Luma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                        .accessibilityIdentifier("settings.open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add camera", systemImage: "plus") { editor = CameraEditorRoute() }
                        .accessibilityIdentifier("camera.add")
                }
            }
            .sheet(item: $editor) { route in
                CameraEditorView(store: store, camera: route.camera)
            }
            .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
            .confirmationDialog("Remove camera?", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { camera in
                Button("Remove", role: .destructive) {
                    do { try store.delete(camera) }
                    catch { message = InterfaceMessage(text: error.localizedDescription) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                Text("This removes the saved connection and password from this iPhone.")
            }
            .lumaAlert($message)
            .task {
                if let error = store.errorMessage { message = InterfaceMessage(text: error) }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR PRIVATE VIEW")
                .font(.caption.weight(.semibold))
                .tracking(2.5)
                .foregroundStyle(.secondary)
            Text("Home. Within sight.")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .accessibilityAddTraits(.isHeader)
            Text(store.cameras.isEmpty ? String(localized: "A quieter way to keep an eye on home.") : String(localized: "Your cameras, one clear view."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var cameraCollection: some View {
        LazyVStack(spacing: 18) {
            ForEach(store.cameras) { camera in
                NavigationLink {
                    CameraConnectionView(configuration: camera, store: store)
                } label: {
                    CameraCard(camera: camera)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("camera.card.\(camera.id)")
                .contextMenu {
                    Button("Edit camera", systemImage: "pencil") { editor = CameraEditorRoute(camera: camera) }
                    Button("Remove camera", systemImage: "trash", role: .destructive) { deleting = camera }
                }
                .accessibilityAction(named: Text("Edit camera")) { editor = CameraEditorRoute(camera: camera) }
                .accessibilityAction(named: Text("Remove camera")) { deleting = camera }
            }
        }
    }
}

private struct EmptyCamerasView: View {
    let addCamera: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 184, height: 184)
                .clipShape(.rect(cornerRadius: 46))
                .accessibilityHidden(true)
                .padding(.top, 22)
            VStack(spacing: 10) {
                Text("A window to your world")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Connect your first camera and bring home a little closer.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: addCamera) {
                Label("Add your first camera", systemImage: "plus")
                    .foregroundStyle(LumaTheme.onAccent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("camera.add.first")
            Label("Direct connection. Yours alone.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 32))
    }
}

private struct CameraCard: View {
    let camera: CameraConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.035, green: 0.13, blue: 0.18), Color(red: 0.04, green: 0.07, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 100, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.12))
                    .accessibilityHidden(true)
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(22)
                    .modifier(GlassPanel(radius: 40))
                    .environment(\.colorScheme, .dark)
                    .accessibilityHidden(true)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text("READY TO CONNECT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(18)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(camera.name).font(.headline).foregroundStyle(.primary)
                    Text(camera.displayAddress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.body.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: LumaTheme.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(camera.name))
        .accessibilityHint(Text("Open live view"))
    }
}
