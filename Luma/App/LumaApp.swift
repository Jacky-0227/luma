import SwiftUI

@main
struct LumaApp: App {
    @State private var store = LumaApp.makeStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Cameras", systemImage: "video") { HomeView(store: store) }
                Tab("Dashboard", systemImage: "square.grid.2x2") { DashboardView(store: store) }
                Tab("Library", systemImage: "photo.on.rectangle") { MediaLibraryView(library: .shared) }
            }
            .tint(LumaTheme.accent)
            .preferredColorScheme(testColorScheme)
        }
    }

    private var testColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-dark") { return .dark }
        #endif
        return nil
    }

    @MainActor
    private static func makeStore() -> CameraStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let location = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaUITests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("cameras.json")
            return CameraStore(storageURL: location, credentials: UITestCredentials())
        }
        #endif
        return CameraStore()
    }
}

#if DEBUG
private final class UITestCredentials: CameraCredentialStorage {
    private var values: [UUID: String] = [:]
    func read(for cameraID: UUID) throws -> String? { values[cameraID] }
    func set(_ password: String, for cameraID: UUID) throws { values[cameraID] = password }
    func remove(for cameraID: UUID) throws { values[cameraID] = nil }
}
#endif
