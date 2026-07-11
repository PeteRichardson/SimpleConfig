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

    /// Orders items by suite and then key, consistent with memberwise
    /// equality. Within one suite this remains alphabetical by key.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.suiteName, lhs.key) < (rhs.suiteName, rhs.key)
    }

    /// Renders as `key = value`. A value stored only as `Data` renders
    /// as its byte count instead of the (misleading) `(not set)`; a
    /// failed read — e.g. an invalid suite name — also renders as
    /// `(not set)`, since `description` cannot throw.
    public var description: String {
        Self.describe(key: key, stringValue: try? read(), dataByteCount: (try? readData())?.count)
    }

    /// `description` can't propagate errors (`CustomStringConvertible`
    /// requires a non-throwing property), so both read paths are
    /// attempted with `try?`; a value present only as `Data` renders its
    /// byte count instead of `(not set)`.
    static func describe(key: String, stringValue: String?, dataByteCount: Int?) -> String {
        if let stringValue {
            return "\(key) = \(stringValue)"
        }
        if let dataByteCount {
            return "\(key) = (binary value, \(dataByteCount) bytes)"
        }
        return "\(key) = (not set)"
    }

    /// `UserDefaults(suiteName:)` returns `nil` for reserved names rather
    /// than failing loudly; validating here lets callers surface that as a
    /// thrown error instead of a force-unwrap crash.
    private static func suite(named suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ConfigError.unableToLoad(reason: "invalid UserDefaults suite name: \(suiteName)")
        }
        return defaults
    }

    private var defaults: UserDefaults {
        get throws { try Self.suite(named: suiteName) }
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

    /// Reads the current value from the suite as raw bytes. `UserDefaults`
    /// stores `String` and `Data` as distinct property-list types per key,
    /// so this only returns non-nil if the value was written with
    /// `write(_ data: Data)` — not if it was written as a `String`.
    ///
    /// - Returns: The stored bytes, or `nil` if no `Data` value is set.
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func readData() throws -> Data? {
        try defaults.data(forKey: key)
    }

    /// Writes raw bytes to the suite, replacing any existing value.
    /// Storing `Data` does not make `read()` succeed for the same key —
    /// see `readData()`.
    ///
    /// - Parameter data: The bytes to store.
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func write(_ data: Data) throws {
        try defaults.set(data, forKey: key)
    }

    /// Ensures no value is stored for `key`. Deleting a value that
    /// does not exist succeeds silently.
    ///
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func delete() throws {
        try defaults.removeObject(forKey: key)
    }

    /// All items stored in the given `UserDefaults` suite, sorted by key.
    /// Every key in the suite is included regardless of its value's type
    /// (enumeration is type-blind); an unused suite returns an empty array.
    ///
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public static func items(inSuite suiteName: String) throws -> [ConfigItem] {
        _ = try suite(named: suiteName)
        // persistentDomain, not dictionaryRepresentation(): the latter
        // merges in NSGlobalDomain and the rest of the search list.
        let domain = UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]
        return domain.keys
            .map { ConfigItem(suiteName: suiteName, key: $0) }
            .sorted()
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

    /// Orders items by service and then key, consistent with memberwise
    /// equality. Within one service this remains alphabetical by key.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.service, lhs.key) < (rhs.service, rhs.key)
    }

    /// Reads the secret from the Keychain.
    ///
    /// - Returns: The stored secret, or `nil` if none exists.
    /// - Throws: An error if the Keychain read fails for a reason other
    ///   than the secret being absent.
    public func read() throws -> String? {
        try Keychain.read(key, service: service)
    }

    /// Renders as `key = <redacted value>` — never the full secret. A
    /// value stored only as `Data` renders as its byte count instead of
    /// the (misleading) `(not set)`.
    public var description: String {
        Self.describe(
            key: key,
            result: Result { try read() },
            dataByteCount: (try? readData())?.count
        )
    }

    /// `description` can't propagate errors (`CustomStringConvertible`
    /// requires a non-throwing property), so a failed read is reported
    /// inline rather than crashing the caller. `dataByteCount` is
    /// `@autoclosure` so a normal string-valued secret never pays for a
    /// second Keychain round-trip — it's only evaluated when the string
    /// result comes back `nil`.
    static func describe(
        key: String, result: Result<String?, Error>,
        dataByteCount: @autoclosure () -> Int? = nil
    ) -> String {
        switch result {
        case .success(let value?): return "\(key) = \(redact(value))"
        case .success(nil):
            if let count = dataByteCount() { return "\(key) = (binary value, \(count) bytes)" }
            return "\(key) = (not set)"
        case .failure(let error): return "\(key) = (unreadable: \(error))"
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

    /// Reads the secret from the Keychain as raw bytes. Unlike
    /// `ConfigItem`, the Keychain stores one blob of bytes with no type
    /// tag, so this succeeds for any stored value — including one
    /// written as a `String` (its UTF-8 bytes are returned).
    ///
    /// - Returns: The stored bytes, or `nil` if none exists.
    public func readData() throws -> Data? {
        try Keychain.readData(key, service: service)
    }

    /// Writes raw bytes to the Keychain, replacing any existing value.
    /// `read()` will still succeed afterward if these bytes happen to
    /// decode as valid UTF-8.
    ///
    /// - Parameter data: The bytes to store.
    /// - Throws: An error if the Keychain rejects the write.
    public func write(_ data: Data) throws {
        try Keychain.write(data, for: key, service: service)
    }

    /// Ensures no secret is stored for `key`. Deleting a secret that
    /// does not exist succeeds silently.
    ///
    /// - Throws: An error if the Keychain rejects the delete.
    public func delete() throws {
        try Keychain.delete(key, service: service)
    }

    /// All items stored under the given Keychain service, sorted by key.
    /// Secret values are never read — the results are safe to display
    /// (printing an item shows the redacted form).
    public static func items(inService service: String) throws -> [SecureConfigItem] {
        try Keychain.accounts(service: service)
            .map { SecureConfigItem(service: service, key: $0) }
            .sorted()
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
