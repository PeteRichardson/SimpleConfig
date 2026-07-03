//
//  ConfigError.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//

/// Errors thrown by the SimpleConfig library itself. (Keychain-level
/// failures currently surface as `NSError` from the Security framework
/// instead — see `Keychain`.)
public enum ConfigError: Error, CustomStringConvertible {
    /// The storage backend could not be opened — e.g. an invalid
    /// `UserDefaults` suite name. `reason` is human-readable detail.
    case unableToLoad(reason: String)
    /// Wraps an unexpected error from an underlying API.
    case unknown(Error)

    public var description: String {
        switch self {
        case .unableToLoad(let reason):
            return "Unable to load config: \(reason)"
        case .unknown(let error):
            return "Unknown error: \(error)"
        }
    }
}
