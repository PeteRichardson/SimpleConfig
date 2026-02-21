//
//  ConfigStorable.swift
//  SimpleConfig
//
//  Created by Peter Richardson on 2/9/26.
//

public protocol ConfigStorable: Comparable, CustomStringConvertible {
    var key: String { get }
    func read() throws -> String?
    func write(_ value: String) throws
    var description: String { get }
}

extension ConfigStorable {
    var description: String {
        "\(key) = \((try? read()) ?? "(not set)")"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.key < rhs.key
    }
}
