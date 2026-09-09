import Foundation
import Security

/// API keys live in the login keychain, one generic-password item per provider id, so
/// they never sit in UserDefaults or the dictation log.
enum APIKeyStore {
    private static let service = "com.codywright.aside.apikeys"

    static func key(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("Keychain read failed for \(providerID, privacy: .public): \(status, privacy: .public)")
        }
        guard status == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func set(_ key: String?, for providerID: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        // Update in place when the item exists, so an item this app created is simply
        // rewritten; fall back to add. Items created by other tools cannot be edited
        // by us, which the error log makes visible.
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        if update != errSecItemNotFound {
            Log.app.error("Keychain update failed for \(providerID, privacy: .public): \(update, privacy: .public); replacing")
            SecItemDelete(base as CFDictionary)
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.app.error("Keychain write failed for \(providerID, privacy: .public): \(status, privacy: .public)")
        }
    }
}
