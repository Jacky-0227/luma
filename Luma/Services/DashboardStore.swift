import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    private(set) var dashboards: [DashboardConfiguration] = []
    var errorMessage: String?
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private var writesBlocked = false

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                self.storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumaDashboardUITests-\(UUID().uuidString)")
                    .appendingPathComponent("dashboards.json")
            } else {
                self.storageURL = Self.defaultURL
            }
            #else
            self.storageURL = Self.defaultURL
            #endif
        }
        load()
    }

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luma", isDirectory: true).appendingPathComponent("dashboards.json")
    }

    func save(_ dashboard: DashboardConfiguration) throws {
        var updated = dashboards
        let validated = try dashboard.validated()
        if let index = updated.firstIndex(where: { $0.id == validated.id }) {
            updated[index] = validated
        } else {
            guard updated.count < 64 else { throw DashboardStoreError.tooMany }
            updated.append(validated)
        }
        try persist(updated)
    }

    func delete(_ dashboard: DashboardConfiguration) throws {
        try persist(dashboards.filter { $0.id != dashboard.id })
    }

    func move(from offsets: IndexSet, to destination: Int) throws {
        guard destination >= 0, destination <= dashboards.count,
              offsets.allSatisfy({ dashboards.indices.contains($0) }) else {
            throw DashboardStoreError.invalidLayout
        }
        let moving = offsets.map { dashboards[$0] }
        var updated = dashboards.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        updated.insert(contentsOf: moving, at: insertion)
        try persist(updated)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            do {
                try persist([DashboardConfiguration(name: String(localized: "All cameras"), includesAllCameras: true)])
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        do {
            let size = try storageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2 * 1024 * 1024 else { throw DashboardStoreError.cannotLoad }
            let stored = try JSONDecoder().decode([DashboardConfiguration].self, from: Data(contentsOf: storageURL))
            guard stored.count <= 64, Set(stored.map(\.id)).count == stored.count else {
                throw DashboardStoreError.cannotLoad
            }
            dashboards = try stored.map { try $0.validated() }
        } catch {
            writesBlocked = true
            errorMessage = DashboardStoreError.cannotLoad.localizedDescription
        }
    }

    private func persist(_ updated: [DashboardConfiguration]) throws {
        guard !writesBlocked else { throw DashboardStoreError.cannotLoad }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(updated)
            guard data.count <= 2 * 1024 * 1024 else { throw DashboardStoreError.cannotSave }
            var directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
            dashboards = updated
            errorMessage = nil
        } catch {
            throw DashboardStoreError.cannotSave
        }
    }
}

enum DashboardStoreError: LocalizedError {
    case invalidName, invalidLayout, tooMany, cannotLoad, cannotSave
    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Enter a dashboard name between 1 and 40 characters.")
        case .invalidLayout: String(localized: "This dashboard layout is invalid. Select the cameras again.")
        case .tooMany: String(localized: "You can save up to 64 dashboards.")
        case .cannotLoad: String(localized: "Dashboards could not be read. The original file is preserved. Unlock your iPhone and reopen Luma.")
        case .cannotSave: String(localized: "The dashboard could not be saved. Check available storage and try again.")
        }
    }
}
