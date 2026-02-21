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

    public func read() throws -> String? {
        let defaults = UserDefaults(suiteName: suiteName)!
        let result = defaults.string(forKey: key)
        return result
    }

    public func write(_ value: String) throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults.set(value, forKey: key)
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
        let value = try! read() ?? "(not set)"
        return "\(key) = \(String(value.prefix(6)))....................\(String(value.suffix(6)))"
    }

    public func write(_ value: String) throws {
        try Keychain.write(value, for: key, service: service)
    }

    public init(service: String, key: String) {
        self.service = service
        self.key = key
    }
}
