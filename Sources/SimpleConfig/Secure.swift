//
//  Secure.swift
//  SimpleConfig
//
import Foundation

/// The `$property` view of a `@Secure` property.
public struct SecureProjection {
    /// The underlying item, or `nil` when no domain resolves
    /// (no explicit `service:` and `SimpleConfig.defaultDomain` unset).
    public let item: SecureConfigItem?
    /// The most recent read/write's error; `nil` after a success.
    public let lastError: Error?
}

/// A live, Keychain-backed property: every `get` reads storage and
/// every `set` writes it immediately. The declared default is a
/// read-time fallback — returned when nothing is stored (or the read
/// fails, see `$property.lastError`) and never itself written to the
/// Keychain. Optional values read `nil` when unset; assigning `nil`
/// deletes the stored secret. Use `@Stored` for non-sensitive values.
@propertyWrapper
public struct Secure<Value: ConfigValue> {
    let key: String
    let explicitService: String?
    let defaultValue: Value
    let errorBox: ErrorBox

    /// Creates the wrapper. `wrappedValue` is supplied by the
    /// property's `= default` initializer expression.
    ///
    /// - Parameters:
    ///   - key: The Keychain account name the secret is stored as.
    ///   - service: The Keychain service; `nil` falls back to
    ///     `SimpleConfig.defaultDomain` at access time.
    public init(wrappedValue: Value, _ key: String, service: String? = nil) {
        self.defaultValue = wrappedValue
        self.key = key
        self.explicitService = service
        self.errorBox = ErrorBox()
    }

    /// Resolved on each access (not cached) so `SimpleConfig.defaultDomain`
    /// may be set after the enclosing struct type is defined.
    var item: SecureConfigItem? {
        guard let service = explicitService ?? SimpleConfig.defaultDomain else { return nil }
        return SecureConfigItem(service: service, key: key)
    }

    public var wrappedValue: Value {
        get {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return defaultValue
            }
            do {
                let value = try Value.read(from: item)
                errorBox.last = nil
                return value ?? defaultValue
            } catch {
                errorBox.last = error
                return defaultValue
            }
        }
        set {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return
            }
            do {
                try newValue.write(to: item)
                errorBox.last = nil
            } catch {
                errorBox.last = error
            }
        }
    }

    public var projectedValue: SecureProjection {
        SecureProjection(item: item, lastError: errorBox.last)
    }
}

extension Secure where Value: ExpressibleByNilLiteral {
    /// Lets an optional property omit `= nil`:
    /// `@Secure("apiKey") var apiKey: String?`.
    public init(_ key: String, service: String? = nil) {
        self.init(wrappedValue: nil, key, service: service)
    }
}
