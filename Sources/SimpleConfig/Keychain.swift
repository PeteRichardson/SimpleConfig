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

    /// Stores `data` as a generic-password item, replacing any existing
    /// item for the same service/account pair.
    static func write(_ data: Data, for key: String, service: String) throws {
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

    /// Stores `value` as a generic-password item, replacing any existing
    /// item for the same service/account pair.
    static func write(_ value: String, for key: String, service: String) throws {
        // Force-unwrap is safe: every Swift String is representable as UTF-8.
        try write(value.data(using: .utf8)!, for: key, service: service)
    }

    /// `true` if `status` is `errSecSuccess`, `false` if
    /// `errSecItemNotFound`; throws for any other status.
    ///
    /// - Throws: `NSError(domain: "Keychain")` for a genuine failure status.
    static func isPresent(_ status: OSStatus) throws -> Bool {
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw NSError(
            domain: "Keychain", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Unable to read keychain item"])
    }

    /// Returns the stored bytes for the service/account pair, or `nil`
    /// if there is none.
    ///
    /// - Throws: An error for a genuine Keychain failure (e.g.
    ///   `errSecInteractionNotAllowed` while the device is locked) —
    ///   distinct from "not found", which returns `nil`.
    static func readData(_ key: String, service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard try isPresent(status) else { return nil }
        return result as? Data
    }

    /// Returns the stored secret for the service/account pair, or `nil`
    /// if there is none, or if the stored bytes aren't valid UTF-8.
    ///
    /// - Throws: An error for a genuine Keychain failure (e.g.
    ///   `errSecInteractionNotAllowed` while the device is locked) —
    ///   distinct from "not found", which returns `nil`.
    static func read(_ key: String, service: String) throws -> String? {
        guard let data = try readData(key, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the generic-password item for the service/account pair.
    /// Deleting an item that does not exist is not an error — delete
    /// means "ensure absent".
    static func delete(_ key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: "Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to delete keychain item"])
        }
    }

    /// All account names stored under the given service, unsorted.
    /// Values are never read (`kSecReturnAttributes`, not
    /// `kSecReturnData`), so listing is cheap and safe. An unused
    /// service returns an empty array rather than an error.
    static func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw NSError(
                domain: "Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to list keychain items"])
        }
        let attributes = result as? [[String: Any]] ?? []
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
