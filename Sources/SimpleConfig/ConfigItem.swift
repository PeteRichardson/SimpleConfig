//
//  ConfigItem.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//
import Foundation

public struct ConfigItem: ConfigStorable {
    public let suiteName: String
    public let key: String

    public var description: String {
        "\(key) = \((try? read()) ?? "(not set)")"
    }

    private var defaults: UserDefaults {
        get throws {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw ConfigError.unableToLoad(reason: "invalid UserDefaults suite name: \(suiteName)")
            }
            return defaults
        }
    }

    public func read() throws -> String? {
        try defaults.string(forKey: key)
    }

    public func write(_ value: String) throws {
        try defaults.set(value, forKey: key)
    }

    public init(suiteName: String, key: String) {
        self.suiteName = suiteName
        self.key = key
    }
}

public struct SecureConfigItem: ConfigStorable {
    public let service: String
    public let key: String

    public func read() throws -> String? {
        try Keychain.read(key, service: service)
    }

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

    public func write(_ value: String) throws {
        try Keychain.write(value, for: key, service: service)
    }

    public init(service: String, key: String) {
        self.service = service
        self.key = key
    }
}
