import Foundation

/// Dashboard membership references local camera IDs, never credentials or addresses.
struct DashboardConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var cameraIDs: [UUID]
    var columns: Int
    var pageSize: Int
    var includesAllCameras: Bool

    init(id: UUID = UUID(), name: String, cameraIDs: [UUID] = [], columns: Int = 2,
         pageSize: Int = 4, includesAllCameras: Bool = false) {
        self.id = id
        self.name = name
        self.cameraIDs = cameraIDs
        self.columns = columns
        self.pageSize = pageSize
        self.includesAllCameras = includesAllCameras
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cameraIDs, columns, pageSize, includesAllCameras
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        cameraIDs = try values.decode([UUID].self, forKey: .cameraIDs)
        columns = try values.decode(Int.self, forKey: .columns)
        // Existing dashboards used four cameras per page without storing it.
        pageSize = try values.decodeIfPresent(Int.self, forKey: .pageSize) ?? 4
        includesAllCameras = try values.decode(Bool.self, forKey: .includesAllCameras)
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

    func pageCount(from available: [CameraConfiguration]) -> Int {
        guard (1...64).contains(pageSize) else { return 0 }
        let count = cameras(from: available).count
        return count / pageSize + (count % pageSize == 0 ? 0 : 1)
    }

    /// Page indices are zero-based; a deleted last page or invalid selection is
    /// empty rather than silently playing cameras from a different page.
    func cameras(onPage index: Int, from available: [CameraConfiguration]) -> [CameraConfiguration] {
        guard index >= 0, (1...64).contains(pageSize) else { return [] }
        let ordered = cameras(from: available)
        guard !ordered.isEmpty, index <= (ordered.count - 1) / pageSize else { return [] }
        let start = index * pageSize
        let end = start + min(pageSize, ordered.count - start)
        return Array(ordered[start..<end])
    }

    func validated() throws -> DashboardConfiguration {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 40,
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw DashboardStoreError.invalidName }
        guard (1...8).contains(columns), (1...64).contains(pageSize), cameraIDs.count <= 1024,
              Set(cameraIDs).count == cameraIDs.count else { throw DashboardStoreError.invalidLayout }
        return value
    }
}
