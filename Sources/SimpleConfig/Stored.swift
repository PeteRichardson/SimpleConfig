//
//  Stored.swift
//  SimpleConfig
//
import Foundation

/// Reference-type box for a wrapper's most recent error. A struct
/// property's getter is nonmutating, so recording a failure from a
/// read requires the error to live behind a reference. Note the
/// consequence: copying a config struct copies the reference, so
/// copies share error state; separately constructed instances do not.
final class ErrorBox {
    var last: Error?
}

/// The `$property` view of a `@Stored` property.
public struct StoredProjection {
    /// The underlying item, or `nil` when no domain resolves
    /// (no explicit `suite:` and `SimpleConfig.defaultDomain` unset).
    public let item: ConfigItem?
    /// The most recent read/write's error; `nil` after a success.
    public let lastError: Error?
}

/// A live, `UserDefaults`-backed property: every `get` reads storage
/// and every `set` writes it immediately. The declared default is a
/// read-time fallback — returned when nothing is stored (or the read
/// fails, see `$property.lastError`) and never itself written to
/// storage. Optional values read `nil` when unset; assigning `nil`
/// deletes the stored value. Use `@Secure` instead for secrets.
@propertyWrapper
public struct Stored<Value: ConfigValue> {
    let key: String
    let explicitSuite: String?
    let defaultValue: Value
    let errorBox: ErrorBox

    /// Creates the wrapper. `wrappedValue` is supplied by the
    /// property's `= default` initializer expression.
    ///
    /// - Parameters:
    ///   - key: The `UserDefaults` key the value is stored under.
    ///   - suite: The suite name; `nil` falls back to
    ///     `SimpleConfig.defaultDomain` at access time.
    public init(wrappedValue: Value, _ key: String, suite: String? = nil) {
        self.defaultValue = wrappedValue
        self.key = key
        self.explicitSuite = suite
        self.errorBox = ErrorBox()
    }

    /// Resolved on each access (not cached) so `SimpleConfig.defaultDomain`
    /// may be set after the enclosing struct type is defined.
    var item: ConfigItem? {
        guard let suite = explicitSuite ?? SimpleConfig.defaultDomain else { return nil }
        return ConfigItem(suiteName: suite, key: key)
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

    public var projectedValue: StoredProjection {
        StoredProjection(item: item, lastError: errorBox.last)
    }
}

extension Stored where Value: ExpressibleByNilLiteral {
    /// Lets an optional property omit `= nil`:
    /// `@Stored("nickname") var nickname: String?`.
    public init(_ key: String, suite: String? = nil) {
        self.init(wrappedValue: nil, key, suite: suite)
    }
}
