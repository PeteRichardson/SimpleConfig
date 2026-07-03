//
//  ConfigStorable.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//

/// A single named configuration value with string reads and writes,
/// regardless of where it is stored. Conforming types choose the backend
/// (`ConfigItem` uses `UserDefaults`, `SecureConfigItem` uses the Keychain),
/// so callers can hold, sort, and print a mixed collection of items
/// without caring which is which.
public protocol ConfigStorable: Comparable, CustomStringConvertible {
    /// The name the value is stored under; also the sort key.
    var key: String { get }
    /// Returns the stored value, or `nil` if none is set.
    func read() throws -> String?
    /// Stores a value, replacing any existing one.
    func write(_ value: String) throws
    var description: String { get }
}

extension ConfigStorable {
    /// Default `key = value` rendering. Note this is internal, so public
    /// conforming types must supply their own `description` to satisfy
    /// `CustomStringConvertible` (both current conformers do).
    var description: String {
        "\(key) = \((try? read()) ?? "(not set)")"
    }

    /// Items order by key so a collection of config items lists
    /// alphabetically regardless of backend.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.key < rhs.key
    }
}
