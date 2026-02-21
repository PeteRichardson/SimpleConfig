//
//  ConfigError.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//

public enum ConfigError: Error, CustomStringConvertible {
    case unableToLoad(reason: String)
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
