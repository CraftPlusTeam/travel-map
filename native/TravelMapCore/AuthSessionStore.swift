import Foundation
#if canImport(Security)
import Security
#endif

struct AuthSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String
}

protocol AuthSessionStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
}

#if canImport(Security)
/// Tokens never enter UserDefaults, app documents, source files, or logs.
struct KeychainSessionStore: AuthSessionStore {
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "anonymous-session"]
    }

    func load() throws -> AuthSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            throw TravelMapError.sessionStorage
        }
        return session
    }

    func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TravelMapError.sessionStorage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw TravelMapError.sessionStorage
        }
    }
}
#else
// Foundation-only Linux builds support model/transport tests. iOS/macOS always use Keychain.
struct UnavailableSessionStore: AuthSessionStore {
    func load() throws -> AuthSession? { nil }
    func save(_ session: AuthSession) throws { }
}
#endif
