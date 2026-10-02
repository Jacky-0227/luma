import Foundation

struct ConfigurationBackup: Codable {
    let format: String
    let version: Int
    let cameras: [CameraConfiguration]

    init(cameras: [CameraConfiguration]) {
        format = "luma-configuration"
        version = 1
        self.cameras = cameras
    }

    static func decode(_ data: Data) throws -> [CameraConfiguration] {
        guard data.count <= 2_000_000 else { throw ConfigurationBackupError.invalidFile }
        do {
            let backup = try JSONDecoder().decode(Self.self, from: data)
            guard backup.format == "luma-configuration", backup.version == 1,
                  backup.cameras.count <= 1_000 else { throw ConfigurationBackupError.invalidFile }
            let cameras = try backup.cameras.map { try $0.validated() }
            guard Set(cameras.map(\.id)).count == cameras.count else { throw ConfigurationBackupError.invalidFile }
            return cameras
        } catch { throw ConfigurationBackupError.invalidFile }
    }
}

enum ConfigurationBackupError: LocalizedError {
    case invalidFile
    var errorDescription: String? {
        String(localized: "This is not a supported Luma backup. Choose a valid configuration file under 2 MB.")
    }
}
