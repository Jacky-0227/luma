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
