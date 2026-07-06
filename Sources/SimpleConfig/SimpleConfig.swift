//
//  SimpleConfig.swift
//  SimpleConfig
//
import Foundation

/// Namespace for package-wide configuration.
public enum SimpleConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _defaultDomain: String?

    /// Process-wide fallback domain: used as the `UserDefaults` suite
    /// name by `@Stored` and the Keychain service name by `@Secure`
    /// whenever a property doesn't pass one explicitly. Set it once at
    /// app startup. While it is `nil` (the initial value), a property
    /// with no explicit domain reports `ConfigError.noDomain` on access.
    public static var defaultDomain: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _defaultDomain
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _defaultDomain = newValue
        }
    }
}
