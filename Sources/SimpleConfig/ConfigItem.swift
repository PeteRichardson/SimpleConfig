//
//  ConfigItem.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//
import Foundation

/// A configuration item for non-sensitive values, stored in a
/// `UserDefaults` suite. Use ``SecureConfigItem`` instead for secrets.
public struct ConfigItem: ConfigStorable {
    /// The `UserDefaults` suite the value lives in. Reserved names
    /// (`NSGlobalDomain`, the app's own bundle identifier) are invalid
    /// and cause `read`/`write` to throw.
    public let suiteName: String
    /// The defaults key the value is stored under.
    public let key: String

    /// Renders as `key = value`. A missing value — or a failed read,
    /// since `description` cannot throw — renders as `(not set)`.
    public var description: String {
        "\(key) = \((try? read()) ?? "(not set)")"
    }

    /// `UserDefaults(suiteName:)` returns `nil` for reserved names rather
    /// than failing loudly; resolving it lazily per access lets `read`/`write`
    /// surface that as a thrown error instead of a force-unwrap crash.
    private var defaults: UserDefaults {
        get throws {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw ConfigError.unableToLoad(reason: "invalid UserDefaults suite name: \(suiteName)")
            }
            return defaults
        }
    }

    /// Reads the current value from the suite.
    ///
    /// - Returns: The stored string, or `nil` if no value is set.
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func read() throws -> String? {
        try defaults.string(forKey: key)
    }

    /// Writes a value to the suite, replacing any existing value.
    ///
    /// - Parameter value: The string to store.
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func write(_ value: String) throws {
        try defaults.set(value, forKey: key)
    }

    /// Ensures no value is stored for `key`. Deleting a value that
    /// does not exist succeeds silently.
    ///
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func delete() throws {
        try defaults.removeObject(forKey: key)
    }

    /// Creates an item backed by the given `UserDefaults` suite.
    ///
    /// - Parameters:
    ///   - suiteName: The defaults suite to store the value in.
    ///   - key: The key the value is stored under.
    public init(suiteName: String, key: String) {
        self.suiteName = suiteName
        self.key = key
    }
}

/// A configuration item for secrets (API keys, tokens), stored in the
/// Keychain as a generic-password item. Its `description` redacts the
/// value so items can appear in logs and listings safely.
public struct SecureConfigItem: ConfigStorable {
    /// The Keychain service the secret is filed under
    /// (`kSecAttrService`); lets multiple apps or tools keep
    /// their secrets separate.
    public let service: String
    /// The Keychain account name the secret is stored as (`kSecAttrAccount`).
    public let key: String

    /// Reads the secret from the Keychain.
    ///
    /// - Returns: The stored secret, or `nil` if none exists.
    public func read() throws -> String? {
        try Keychain.read(key, service: service)
    }

    /// Renders as `key = <redacted value>` — never the full secret.
    public var description: String {
        Self.describe(key: key, result: Result { try read() })
    }

    /// `description` can't propagate errors (`CustomStringConvertible`
    /// requires a non-throwing property), so a failed read is reported
    /// inline rather than crashing the caller.
    static func describe(key: String, result: Result<String?, Error>) -> String {
        switch result {
        case .success(let value?): "\(key) = \(redact(value))"
        case .success(nil): "\(key) = (not set)"
        case .failure(let error): "\(key) = (unreadable: \(error))"
        }
    }

    /// Masks a secret with a fixed-width run of dots so output doesn't leak
    /// its length. Secrets shorter than 5 characters are hidden entirely;
    /// otherwise at most 6 characters show on each side, capped so that at
    /// least 3 characters remain hidden.
    static func redact(_ value: String) -> String {
        let mask = String(repeating: ".", count: 20)
        guard value.count >= 5 else { return mask }
        let visible = min(6, (value.count - 3) / 2)
        return "\(value.prefix(visible))\(mask)\(value.suffix(visible))"
    }

    /// Writes the secret to the Keychain, replacing any existing value.
    ///
    /// - Parameter value: The secret to store.
    /// - Throws: An error if the Keychain rejects the write.
    public func write(_ value: String) throws {
        try Keychain.write(value, for: key, service: service)
    }

    /// Creates an item backed by the Keychain.
    ///
    /// - Parameters:
    ///   - service: The Keychain service to file the secret under.
    ///   - key: The account name the secret is stored as.
    public init(service: String, key: String) {
        self.service = service
        self.key = key
    }
}
