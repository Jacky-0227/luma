import Foundation

enum StreamQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case main
    case sub

    var id: String { rawValue }
    var title: String { self == .main ? String(localized: "Clear") : String(localized: "Fluent") }
}

/// Connection metadata only. Camera passwords are stored separately in Keychain.
struct CameraConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var channel: Int
    var defaultQuality: StreamQuality
    var useTCP: Bool
    var customPath: String
    var ptzEnabled: Bool
    var controlPort: Int
    var controlUseHTTPS: Bool
    var ptzChannel: Int

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 554,
        username: String = "admin",
        channel: Int = 1,
        defaultQuality: StreamQuality = .sub,
        useTCP: Bool = true,
        customPath: String = "",
        ptzEnabled: Bool = false,
        controlPort: Int = 80,
        controlUseHTTPS: Bool = false,
        ptzChannel: Int = 1
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.channel = channel
        self.defaultQuality = defaultQuality
        self.useTCP = useTCP
        self.customPath = customPath
        self.ptzEnabled = ptzEnabled
        self.controlPort = controlPort
        self.controlUseHTTPS = controlUseHTTPS
        self.ptzChannel = ptzChannel
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, channel, defaultQuality, useTCP, customPath
        case ptzEnabled, controlPort, controlUseHTTPS, ptzChannel
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        channel = try values.decode(Int.self, forKey: .channel)
        defaultQuality = try values.decode(StreamQuality.self, forKey: .defaultQuality)
        useTCP = try values.decode(Bool.self, forKey: .useTCP)
        customPath = try values.decode(String.self, forKey: .customPath)
        ptzEnabled = try values.decodeIfPresent(Bool.self, forKey: .ptzEnabled) ?? false
        controlPort = try values.decodeIfPresent(Int.self, forKey: .controlPort) ?? 80
        controlUseHTTPS = try values.decodeIfPresent(Bool.self, forKey: .controlUseHTTPS) ?? false
        ptzChannel = try values.decodeIfPresent(Int.self, forKey: .ptzChannel) ?? 1
    }

    var displayAddress: String {
        // Refuse to display an unvalidated host that might contain pasted credentials.
        guard let camera = try? validated() else { return String(localized: "Address incomplete") }
        let address = camera.host.contains(":") ? "[\(camera.host)]" : camera.host
        return "\(address):\(camera.port)"
    }

    func validated() throws -> CameraConfiguration {
        var camera = self
        camera.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.customPath = customPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !camera.name.isEmpty, camera.name.count <= 80,
              !camera.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CameraValidationError.invalidName }
        guard (1...65_535).contains(port) else { throw CameraValidationError.invalidPort }
        guard (1...999).contains(channel) else { throw CameraValidationError.invalidChannel }
        guard (1...65_535).contains(controlPort) else { throw CameraValidationError.invalidControlPort }
        guard (1...999).contains(ptzChannel) else { throw CameraValidationError.invalidPTZChannel }
        guard !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CameraValidationError.invalidUsername }

        if camera.host.hasPrefix("[") && camera.host.hasSuffix("]") {
            camera.host = String(camera.host.dropFirst().dropLast())
            guard camera.host.contains(":") else { throw CameraValidationError.invalidHost }
        }
        guard Self.isValidHost(camera.host) else { throw CameraValidationError.invalidHost }

        if !camera.customPath.isEmpty {
            guard camera.customPath.hasPrefix("/"),
                  !camera.customPath.hasPrefix("//"),
                  !camera.customPath.contains("://"),
                  camera.customPath.rangeOfCharacter(from: CharacterSet(charactersIn: "@?#\\")) == nil,
                  !camera.customPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw CameraValidationError.invalidCustomPath }
        }
        return camera
    }

    /// Treats credentials as opaque text and escapes every reserved URL character.
    /// The returned URL contains a password and must never be logged or persisted.
    func streamURL(password: String, quality: StreamQuality? = nil) throws -> URL {
        let camera = try validated()
        let address = camera.host.contains(":") ? "[\(camera.host)]" : camera.host
        guard var components = URLComponents(string: "rtsp://\(address):\(camera.port)") else {
            throw CameraValidationError.invalidStreamURL
        }
        if !camera.username.isEmpty || !password.isEmpty {
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            components.percentEncodedUser = camera.username.addingPercentEncoding(withAllowedCharacters: unreserved)
            components.percentEncodedPassword = password.addingPercentEncoding(withAllowedCharacters: unreserved)
        }
        let selectedQuality = quality ?? camera.defaultQuality
        components.path = camera.customPath.isEmpty
            ? "/Streaming/Channels/\(camera.channel)\(selectedQuality == .main ? "01" : "02")"
            : camera.customPath
        guard let url = components.url else { throw CameraValidationError.invalidStreamURL }
        return url
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.contains(":") { return isIPv6(host) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4 && labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return isIPv4(host)
        }
        let dns = host.hasSuffix(".") ? String(host.dropLast()) : host
        return dns.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45
            }
        }
    }

    private static func isIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                && part.count <= 3 && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }

    private static func isIPv6(_ address: String) -> Bool {
        // Zone identifiers are deliberately excluded: users should use a reachable LAN address.
        guard !address.contains("%"), !address.contains(":::") else { return false }
        let compressed = address.components(separatedBy: "::")
        guard compressed.count <= 2 else { return false }
        guard compressed.allSatisfy({ !$0.hasPrefix(":") && !$0.hasSuffix(":") }) else { return false }
        let groups = address.split(separator: ":", omittingEmptySubsequences: true)
        var size = 0
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.count - 1, isIPv4(String(group)) else { return false }
                size += 2
            } else {
                guard (1...4).contains(group.count), group.utf8.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
                }) else { return false }
                size += 1
            }
        }
        if compressed.count == 2 { return size < 8 }
        return size == 8 && !address.hasPrefix(":") && !address.hasSuffix(":")
    }
}

enum CameraValidationError: LocalizedError {
    case invalidName, invalidHost, invalidPort, invalidChannel
    case invalidUsername, invalidCustomPath, invalidStreamURL
    case invalidControlPort, invalidPTZChannel

    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Enter a camera name between 1 and 80 characters.")
        case .invalidHost: String(localized: "Enter a valid IP address or hostname without rtsp://, a port, path, or credentials.")
        case .invalidPort: String(localized: "Enter a port between 1 and 65535. RTSP usually uses 554.")
        case .invalidChannel: String(localized: "Enter a channel between 1 and 999. Standalone cameras usually use 1.")
        case .invalidUsername: String(localized: "The username cannot contain line breaks or control characters.")
        case .invalidCustomPath: String(localized: "A custom path must start with / and cannot contain a URL, credentials, query parameters, or a fragment.")
        case .invalidStreamURL: String(localized: "Unable to create a stream address. Check the camera connection settings.")
        case .invalidControlPort: String(localized: "Enter a control port between 1 and 65535. HTTP usually uses 80; HTTPS uses 443.")
        case .invalidPTZChannel: String(localized: "Enter a PTZ channel between 1 and 999. This may differ from the video channel.")
        }
    }
}
