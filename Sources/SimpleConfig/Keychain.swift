//
//  Keychain.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//
import Foundation
import Security

/// Minimal wrapper over the Security framework's generic-password API.
/// Deliberately not public — consumers go through `SecureConfigItem`.
enum Keychain {

    /// Stores `value` as a generic-password item, replacing any existing
    /// item for the same service/account pair.
    static func write(_ value: String, for key: String, service: String) throws {
        // Force-unwrap is safe: every Swift String is representable as UTF-8.
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // AfterFirstUnlock so background processes can still read the
            // value after a reboot, once the device has been unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Delete-then-add instead of SecItemUpdate: simpler, at the cost of
        // the item briefly not existing. Ignore the delete status — a missing
        // item (errSecItemNotFound) is expected on first write.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to save API key"])
        }
    }

    /// Returns the stored secret for the service/account pair, or `nil` if
    /// there is none. Caution: any non-success status is also reported as
    /// `nil`, so a genuine failure (e.g. `errSecInteractionNotAllowed` while
    /// the device is locked) is indistinguishable from a missing item.
    static func read(_ key: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?

        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            if let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }
}
