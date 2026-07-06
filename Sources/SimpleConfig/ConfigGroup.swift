//
//  ConfigGroup.swift
//  SimpleConfig
//
import Foundation

/// A struct of `@Stored`/`@Secure` properties. Conformance is free —
/// the only requirement, `init()`, is synthesized as long as every
/// property has a default (non-optionals must declare one; optionals
/// default to `nil`). Groups may nest: a member that is itself a
/// `ConfigGroup` (with a default, e.g. `= ServerConfig()`) is
/// validated recursively. Keys stay flat within the domain regardless
/// of nesting depth — distinct nested groups must use distinct keys.
public protocol ConfigGroup {
    init()
}

/// Internal hook `configErrors` uses to find wrappers via `Mirror`.
protocol ConfigProbeable {
    /// Performs one read; returns (and records in the wrapper's error
    /// box) the failure, if any.
    func probe() -> Error?
}

extension Stored: ConfigProbeable {
    func probe() -> Error? {
        guard let item else {
            errorBox.last = ConfigError.noDomain
            return ConfigError.noDomain
        }
        do {
            _ = try Value.read(from: item)
            errorBox.last = nil
            return nil
        } catch {
            errorBox.last = error
            return error
        }
    }
}

extension Secure: ConfigProbeable {
    func probe() -> Error? {
        guard let item else {
            errorBox.last = ConfigError.noDomain
            return ConfigError.noDomain
        }
        do {
            _ = try Value.read(from: item)
            errorBox.last = nil
            return nil
        } catch {
            errorBox.last = error
            return error
        }
    }
}

extension ConfigGroup {
    /// Probes every `@Stored`/`@Secure` property once — nested
    /// `ConfigGroup` members recursively — collecting failures keyed
    /// by property path (`"serverConfig.apiKey"`). Empty means
    /// healthy. Probing performs real reads: constructing a group
    /// touches no storage, so a health check must read, not just
    /// inspect `lastError` flags.
    public var configErrors: [String: Error] {
        var errors: [String: Error] = [:]
        collectErrors(prefix: "", into: &errors)
        return errors
    }

    /// `configErrors.isEmpty` as a one-call health check.
    public var isConfigValid: Bool { configErrors.isEmpty }

    /// Constructs the group and validates every property in one call.
    /// Properties stay live afterward — a later access can still fail
    /// (see `$property.lastError`); this validates *now*.
    ///
    /// - Throws: `ConfigError.invalidGroup`, keyed by property path,
    ///   if any property fails to read.
    public static func read() throws -> Self {
        let instance = Self()
        let errors = instance.configErrors
        guard errors.isEmpty else { throw ConfigError.invalidGroup(errors) }
        return instance
    }

    private func collectErrors(prefix: String, into errors: inout [String: Error]) {
        for child in Mirror(reflecting: self).children {
            guard let label = child.label else { continue }
            if let probeable = child.value as? ConfigProbeable {
                // A wrapped property mirrors as "_name"; report "name".
                let name = label.hasPrefix("_") ? String(label.dropFirst()) : label
                if let error = probeable.probe() {
                    errors[prefix + name] = error
                }
            } else if let nested = child.value as? ConfigGroup {
                nested.collectErrors(prefix: prefix + label + ".", into: &errors)
            }
        }
    }
}
