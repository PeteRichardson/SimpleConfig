//
//  ConfigValue.swift
//  SimpleConfig
//
import Foundation

/// A value type storable through the `@Stored`/`@Secure` property
/// wrappers. The four shipped conformances — `String`, `Data`, and
/// their optionals — are the complete set: this protocol is `public`
/// only because it appears in the wrappers' generic constraints, and
/// is not a customization point.
public protocol ConfigValue {
    static func read(from item: ConfigItem) throws -> Self?
    static func read(from item: SecureConfigItem) throws -> Self?
    func write(to item: ConfigItem) throws
    func write(to item: SecureConfigItem) throws
}

extension String: ConfigValue {
    public static func read(from item: ConfigItem) throws -> String? {
        try item.read()
    }
    public static func read(from item: SecureConfigItem) throws -> String? {
        try item.read()
    }
    public func write(to item: ConfigItem) throws {
        try item.write(self)
    }
    public func write(to item: SecureConfigItem) throws {
        try item.write(self)
    }
}

extension Data: ConfigValue {
    public static func read(from item: ConfigItem) throws -> Data? {
        try item.readData()
    }
    public static func read(from item: SecureConfigItem) throws -> Data? {
        try item.readData()
    }
    public func write(to item: ConfigItem) throws {
        try item.write(self)
    }
    public func write(to item: SecureConfigItem) throws {
        try item.write(self)
    }
}

/// An absent value reads as `.some(.none)` — "the read worked; the
/// value is nil" — which is what lets an optional wrapped property
/// read `nil` when unset instead of falling back to its declared
/// default. Writing `nil` deletes the stored value.
extension Optional: ConfigValue where Wrapped: ConfigValue {
    public static func read(from item: ConfigItem) throws -> Self? {
        .some(try Wrapped.read(from: item))
    }
    public static func read(from item: SecureConfigItem) throws -> Self? {
        .some(try Wrapped.read(from: item))
    }
    public func write(to item: ConfigItem) throws {
        if let wrapped = self {
            try wrapped.write(to: item)
        } else {
            try item.delete()
        }
    }
    public func write(to item: SecureConfigItem) throws {
        if let wrapped = self {
            try wrapped.write(to: item)
        } else {
            try item.delete()
        }
    }
}
