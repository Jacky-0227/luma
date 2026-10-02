import Foundation
import Security

protocol CameraCredentialStorage {
    func read(for cameraID: UUID) throws -> String?
    func set(_ password: String, for cameraID: UUID) throws
    func remove(for cameraID: UUID) throws
}

struct KeychainService: CameraCredentialStorage {
    private let service: String

    init(service: String = "app.luma.viewer.camera-passwords") {
        self.service = service
    }

    func read(for cameraID: UUID) throws -> String? {
        var query = baseQuery(cameraID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.operationFailed(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidData
        }
        return password
    }

    func set(_ password: String, for cameraID: UUID) throws {
        let query = baseQuery(cameraID)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialError.operationFailed(updateStatus) }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.operationFailed(status) }
    }

    func remove(for cameraID: UUID) throws {
        let status = SecItemDelete(baseQuery(cameraID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.operationFailed(status)
        }
    }

    private func baseQuery(_ cameraID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID.uuidString,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum CredentialError: LocalizedError {
    case missingPassword
    case invalidData
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingPassword: String(localized: "The camera password is missing. Edit the camera and save its password again.")
        case .invalidData: String(localized: "The saved password could not be read. Edit the camera and save its password again.")
        case .operationFailed: String(localized: "Unable to access Keychain. Unlock your iPhone and try again.")
        }
    }
}
