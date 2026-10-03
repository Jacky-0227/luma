import SwiftUI

@main
struct LumaApp: App {
    @State private var store = LumaApp.makeStore()
    @AppStorage("luma.welcomeCompleted") private var hasCompletedWelcome = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedWelcome || hasExistingData || skipsWelcomeForTests {
                    TabView {
                        Tab("Cameras", systemImage: "video") { HomeView(store: store) }
                        Tab("Dashboard", systemImage: "square.grid.2x2") { DashboardView(store: store) }
                        Tab("Library", systemImage: "photo.on.rectangle") { MediaLibraryView(library: .shared) }
                    }
                } else {
                    WelcomeView { hasCompletedWelcome = true }
                }
            }
            .tint(LumaTheme.accent)
            .preferredColorScheme(testColorScheme)
            .onAppear {
                // Existing installations go straight to their cameras, including
                // when a saved configuration needs recovery instead of welcome.
                if hasExistingData { hasCompletedWelcome = true }
            }
        }
    }

    private var hasExistingData: Bool { !store.cameras.isEmpty || store.errorMessage != nil }

    private var skipsWelcomeForTests: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && !arguments.contains("--ui-test-welcome")
        #else
        return false
        #endif
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
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-welcome"), arguments.contains("--ui-test-reset-welcome") {
                UserDefaults.standard.removeObject(forKey: "luma.welcomeCompleted")
            }
            let location = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaUITests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("cameras.json")
            let store = CameraStore(storageURL: location, credentials: UITestCredentials())
            if arguments.contains("--ui-test-stream"),
               let port = ProcessInfo.processInfo.environment["LUMA_UI_RTSP_PORT"].flatMap(Int.init),
               (1...65535).contains(port) {
                let camera = CameraConfiguration(name: "Zoom test", host: "127.0.0.1", port: port, username: "viewer")
                try? store.save(camera, password: "luma-ui-fixture")
            }
            if arguments.contains("--ui-test-wall") {
                // Isolated UI fixtures; no user devices, accounts or saved data.
                for index in 1...16 {
                    let camera = CameraConfiguration(name: String(format: "View %02d", index), host: "127.0.0.1", port: 9)
                    try? store.save(camera, password: "")
                }
            }
            return store
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
