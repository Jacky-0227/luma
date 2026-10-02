import SwiftUI
import UniformTypeIdentifiers

private struct ConfigurationDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ConfigurationBackupError.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ConfigurationBackupView: View {
    let store: CameraStore
    @State private var document = ConfigurationDocument()
    @State private var exporting = false
    @State private var importing = false
    @State private var message: InterfaceMessage?
    @State private var importedCount: Int?

    var body: some View {
        Form {
            Section {
                Label("Keep a copy of your camera settings.", systemImage: "externaldrive")
                Text("Backups include device names, addresses and usernames. Passwords, snapshots and recordings are not included.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Export configuration", systemImage: "square.and.arrow.up") {
                    do {
                        document = ConfigurationDocument(data: try store.exportConfiguration())
                        exporting = true
                    } catch { message = InterfaceMessage(text: error.localizedDescription) }
                }
                .disabled(store.cameras.isEmpty)
                Button("Import configuration", systemImage: "square.and.arrow.down") { importing = true }
            } footer: {
                Text("Import adds new cameras and keeps existing settings. Enter each imported camera’s password before connecting.")
            }
            if let importedCount {
                Section {
                    Text(String(format: String(localized: "%lld cameras added."), Int64(importedCount)))
                }
            }
        }
        .navigationTitle("Configuration backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Luma-configuration") { result in
            if case .failure = result { message = InterfaceMessage(text: String(localized: "The backup could not be exported. Try another location.")) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw ConfigurationBackupError.invalidFile }
                importedCount = try store.importConfiguration(Data(contentsOf: url))
            } catch {
                message = InterfaceMessage(text: String(localized: "The backup could not be imported. Choose a valid Luma configuration file under 2 MB."))
            }
        }
        .lumaAlert($message)
    }
}
