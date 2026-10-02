import SwiftUI

struct DashboardEditorView: View {
    let store: CameraStore
    let dashboards: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DashboardConfiguration
    @State private var message: InterfaceMessage?
    private let isNew: Bool

    init(store: CameraStore, dashboards: DashboardStore, dashboard: DashboardConfiguration?) {
        self.store = store
        self.dashboards = dashboards
        isNew = dashboard == nil
        var initial = dashboard ?? DashboardConfiguration(name: "")
        // This sheet intentionally owns an editable snapshot until Save.
        initial.cameraIDs = initial.cameras(from: store.cameras).map(\.id)
        _draft = State(initialValue: initial)
    }

    private var selectedCameras: [CameraConfiguration] { draft.cameras(from: store.cameras) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dashboard name") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("dashboard.name")
                }
                Section("Layout") {
                    Picker("Columns", selection: $draft.columns) {
                        Text("One column").tag(1)
                        Text("Two columns").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("dashboard.columns")
                }
                Section {
                    Toggle("Include all cameras", isOn: $draft.includesAllCameras)
                        .accessibilityIdentifier("dashboard.includesAll")
                } footer: {
                    Text("New cameras are added to this dashboard automatically.")
                }
                Section {
                    if selectedCameras.isEmpty {
                        Text("Select cameras below to build this dashboard.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedCameras) { camera in orderRow(camera) }
                    }
                } header: {
                    Text("Camera order")
                } footer: {
                    Text("The first four cameras appear on the dashboard cover.")
                }
                Section("Choose cameras") {
                    if store.cameras.isEmpty { Text("No cameras yet").foregroundStyle(.secondary) }
                    ForEach(store.cameras) { camera in
                        Button { toggle(camera) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedCameras.contains(where: { $0.id == camera.id }) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                Text(camera.name).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 32)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.includesAllCameras)
                        .accessibilityLabel(Text(camera.name))
                        .accessibilityIdentifier("dashboard.select.\(camera.id)")
                        .accessibilityValue(Text(selectedCameras.contains(where: { $0.id == camera.id }) ? String(localized: "Selected") : String(localized: "Not selected")))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background { LumaBackground() }
            .navigationTitle(isNew ? String(localized: "Add dashboard") : String(localized: "Edit dashboard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("dashboard.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("dashboard.save")
                }
            }
            .onChange(of: draft.includesAllCameras) { _, _ in draft.cameraIDs = selectedCameras.map(\.id) }
            .lumaAlert($message)
        }
    }

    private func orderRow(_ camera: CameraConfiguration) -> some View {
        HStack(spacing: 8) {
            Text(camera.name).frame(maxWidth: .infinity, alignment: .leading)
            Button("Move up", systemImage: "chevron.up") { move(camera, offset: -1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(minWidth: 40, minHeight: 44)
                .disabled(selectedCameras.first?.id == camera.id)
                .accessibilityIdentifier("dashboard.move-up.\(camera.id)")
            Button("Move down", systemImage: "chevron.down") { move(camera, offset: 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(minWidth: 40, minHeight: 44)
                .disabled(selectedCameras.last?.id == camera.id)
                .accessibilityIdentifier("dashboard.move-down.\(camera.id)")
        }
        .accessibilityIdentifier("dashboard.order.\(camera.id)")
    }

    private func toggle(_ camera: CameraConfiguration) {
        guard !draft.includesAllCameras else { return }
        if draft.cameraIDs.contains(camera.id) { draft.cameraIDs.removeAll { $0 == camera.id } }
        else { draft.cameraIDs.append(camera.id) }
    }

    private func move(_ camera: CameraConfiguration, offset: Int) {
        var ids = selectedCameras.map(\.id)
        guard let index = ids.firstIndex(of: camera.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        draft.cameraIDs = ids
    }

    private func save() {
        do {
            draft.cameraIDs = selectedCameras.map(\.id)
            try dashboards.save(draft)
            dismiss()
        } catch { message = InterfaceMessage(text: error.localizedDescription) }
    }
}

struct DashboardOrderView: View {
    let dashboards: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: InterfaceMessage?

    var body: some View {
        NavigationStack {
            List {
                ForEach(dashboards.dashboards) { dashboard in Text(dashboard.name) }
                    .onMove { offsets, destination in
                        do { try dashboards.move(from: offsets, to: destination) }
                        catch { message = InterfaceMessage(text: error.localizedDescription) }
                    }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder dashboards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .lumaAlert($message)
        }
    }
}
