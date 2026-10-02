import Foundation

/// Dashboard membership references local camera IDs, never credentials or addresses.
struct DashboardConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var cameraIDs: [UUID]
    var columns: Int
    var includesAllCameras: Bool

    init(id: UUID = UUID(), name: String, cameraIDs: [UUID] = [], columns: Int = 2,
         includesAllCameras: Bool = false) {
        self.id = id
        self.name = name
        self.cameraIDs = cameraIDs
        self.columns = columns
        self.includesAllCameras = includesAllCameras
    }

    func cameras(from available: [CameraConfiguration]) -> [CameraConfiguration] {
        var seen = Set<UUID>()
        var result = cameraIDs.compactMap { id -> CameraConfiguration? in
            guard seen.insert(id).inserted else { return nil }
            return available.first { $0.id == id }
        }
        if includesAllCameras {
            result += available.filter { seen.insert($0.id).inserted }
        }
        return result
    }

    func validated() throws -> DashboardConfiguration {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 40,
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw DashboardStoreError.invalidName }
        guard (1...2).contains(columns), cameraIDs.count <= 1024,
              Set(cameraIDs).count == cameraIDs.count else { throw DashboardStoreError.invalidLayout }
        return value
    }
}
