import Foundation
#if canImport(Security)
import Security
#endif

/// Stores workstation tokens. Apple platforms use the Keychain; on Linux
/// (tests and the probe) tokens live in process memory only, never on disk.
public final class TokenStore {
    public static let shared = TokenStore()

    private let service: String
    private let lock = NSLock()

    #if !canImport(Security)
    /// File-free fallback. Not persisted across launches, by design.
    private var memory: [String: String] = [:]
    #endif

    public init(service: String = "local.proteus.app") {
        self.service = service
    }

    public func token(for workstationId: String) -> String? {
        read(account: workstationId)
    }

    public func setToken(_ token: String?, for workstationId: String) {
        if let token, !token.isEmpty {
            write(token, account: workstationId)
        } else {
            delete(account: workstationId)
        }
    }

    // MARK: - Apple Keychain

    #if canImport(Security)
    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ token: String, account: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #else
    private func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return memory[account]
    }

    private func write(_ token: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        memory[account] = token
    }

    private func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        memory.removeValue(forKey: account)
    }
    #endif
}
