import Foundation
import Testing
@testable import SimpleConfig

@Suite("SecureConfigItem redaction")
struct RedactionTests {
    let mask = String(repeating: ".", count: 20)

    @Test("secrets shorter than 5 characters are completely redacted")
    func shortSecretsFullyRedacted() {
        for secret in ["", "a", "ab", "abc", "abcd"] {
            #expect(SecureConfigItem.redact(secret) == mask)
        }
    }

    @Test("5-character secret shows one character on each side")
    func fiveCharacterSecret() {
        #expect(SecureConfigItem.redact("abcde") == "a\(mask)e")
    }

    @Test("10-character secret shows three characters on each side")
    func tenCharacterSecret() {
        #expect(SecureConfigItem.redact("0123456789") == "012\(mask)789")
    }

    @Test("long secrets show at most six characters on each side")
    func longSecret() {
        #expect(SecureConfigItem.redact("0123456789abcdefghij") == "012345\(mask)efghij")
    }

    @Test("at least three characters are always hidden")
    func atLeastThreeCharactersHidden() {
        for length in 5...30 {
            let secret = String(repeating: "x", count: length)
            let visibleCount = SecureConfigItem.redact(secret).count - mask.count
            #expect(length - visibleCount >= 3, "length \(length) hides only \(length - visibleCount)")
        }
    }
}

@Suite("SecureConfigItem description")
struct DescriptionTests {
    @Test("a failed read renders as unreadable instead of crashing")
    func failedRead() {
        struct FakeError: Error {}
        let output = SecureConfigItem.describe(key: "token", result: .failure(FakeError()))
        #expect(output.hasPrefix("token = (unreadable:"))
    }

    @Test("a missing value renders as not set")
    func missingValue() {
        #expect(SecureConfigItem.describe(key: "token", result: .success(nil)) == "token = (not set)")
    }

    @Test("a present value is redacted")
    func presentValue() {
        let output = SecureConfigItem.describe(key: "token", result: .success("0123456789"))
        #expect(output == "token = 012....................789")
    }
}

@Suite("ConfigItem invalid suite handling")
struct InvalidSuiteTests {
    @Test("reading from a reserved suite name throws instead of crashing")
    func readThrows() {
        let item = ConfigItem(suiteName: UserDefaults.globalDomain, key: "anything")
        #expect(throws: ConfigError.self) { try item.read() }
    }

    @Test("writing to a reserved suite name throws instead of crashing")
    func writeThrows() {
        let item = ConfigItem(suiteName: UserDefaults.globalDomain, key: "anything")
        #expect(throws: ConfigError.self) { try item.write("value") }
    }

    @Test("round-trip through a valid suite still works")
    func roundTrip() throws {
        let suiteName = "com.peterichardson.SimpleConfigTests"
        let item = ConfigItem(suiteName: suiteName, key: "greeting")
        try item.write("hello")
        #expect(try item.read() == "hello")
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: "greeting")
    }
}

@Suite("ConfigItem delete")
struct ConfigItemDeleteTests {
    let suiteName = "com.peterichardson.SimpleConfigTests"

    @Test("deleting a written value removes it")
    func deleteRemovesValue() throws {
        let item = ConfigItem(suiteName: suiteName, key: "doomed")
        try item.write("value")
        try item.delete()
        #expect(try item.read() == nil)
    }

    @Test("deleting a never-written value succeeds silently")
    func deleteMissingValueSucceeds() throws {
        let item = ConfigItem(suiteName: suiteName, key: "never-written")
        try item.delete()
        #expect(try item.read() == nil)
    }

    @Test("deleting from a reserved suite name throws instead of crashing")
    func deleteThrowsOnReservedSuite() {
        let item = ConfigItem(suiteName: UserDefaults.globalDomain, key: "anything")
        #expect(throws: ConfigError.self) { try item.delete() }
    }
}

@Suite("SecureConfigItem delete")
struct SecureConfigItemDeleteTests {
    @Test("deleting a non-existent keychain item succeeds silently")
    func deleteMissingItemSucceeds() throws {
        let item = SecureConfigItem(
            service: "com.peterichardson.SimpleConfigTests",
            key: "never-written"
        )
        try item.delete()
    }

    @Test("write then delete removes the secret")
    func writeDeleteRoundTrip() throws {
        let item = SecureConfigItem(
            service: "com.peterichardson.SimpleConfigTests",
            key: "doomed"
        )
        try item.write("secret")
        try item.delete()
        #expect(try item.read() == nil)
    }
}

@Suite("ConfigItem enumeration")
struct ConfigItemEnumerationTests {
    @Test("items(inSuite:) returns all written items sorted by key")
    func itemsReturnsAllSorted() throws {
        let suiteName = "com.peterichardson.SimpleConfigTests.enum-sorted"
        let keys = ["banana", "apple", "cherry"]
        for key in keys {
            try ConfigItem(suiteName: suiteName, key: key).write("value-\(key)")
        }
        defer {
            for key in keys { try? ConfigItem(suiteName: suiteName, key: key).delete() }
        }

        let items = try ConfigItem.items(inSuite: suiteName)
        #expect(items.map { $0.key } == ["apple", "banana", "cherry"])
    }

    @Test("an unused suite returns an empty array")
    func unusedSuiteIsEmpty() throws {
        let items = try ConfigItem.items(inSuite: "com.peterichardson.SimpleConfigTests.enum-never-used")
        #expect(items.isEmpty)
    }

    @Test("a reserved suite name throws")
    func reservedSuiteThrows() {
        #expect(throws: ConfigError.self) {
            try ConfigItem.items(inSuite: UserDefaults.globalDomain)
        }
    }

    @Test("non-string values are enumerated but read as nil")
    func nonStringValueEnumerated() throws {
        let suiteName = "com.peterichardson.SimpleConfigTests.enum-blob"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data([0xFF]), forKey: "blob")
        defer { defaults.removeObject(forKey: "blob") }

        let items = try ConfigItem.items(inSuite: suiteName)
        let blob = try #require(items.first { $0.key == "blob" })
        #expect(try blob.read() == nil)
    }
}

@Suite("SecureConfigItem enumeration")
struct SecureConfigItemEnumerationTests {
    @Test("items(inService:) returns all written items sorted by key")
    func itemsReturnsAllSorted() throws {
        let service = "com.peterichardson.SimpleConfigTests.enum-service"
        let beta = SecureConfigItem(service: service, key: "beta")
        let alpha = SecureConfigItem(service: service, key: "alpha")
        try beta.write("secret-b")
        try alpha.write("secret-a")
        defer {
            try? beta.delete()
            try? alpha.delete()
        }

        let items = try SecureConfigItem.items(inService: service)
        #expect(items.map { $0.key } == ["alpha", "beta"])
    }

    @Test("an unused service returns an empty array")
    func unusedServiceIsEmpty() throws {
        let items = try SecureConfigItem.items(inService: "com.peterichardson.SimpleConfigTests.enum-never-used")
        #expect(items.isEmpty)
    }
}

@Suite("keyValuePairs")
struct KeyValuePairsTests {
    @Test("pairs match written keys and values in sorted order")
    func pairsMatch() throws {
        let suiteName = "com.peterichardson.SimpleConfigTests.pairs-match"
        try ConfigItem(suiteName: suiteName, key: "two").write("2")
        try ConfigItem(suiteName: suiteName, key: "one").write("1")
        defer {
            try? ConfigItem(suiteName: suiteName, key: "one").delete()
            try? ConfigItem(suiteName: suiteName, key: "two").delete()
        }

        let pairs = try ConfigItem.items(inSuite: suiteName).keyValuePairs()
        #expect(pairs.map { $0.key } == ["one", "two"])
        #expect(pairs.map { $0.value } == ["1", "2"])
    }

    @Test("values that read as nil are dropped")
    func nilValuesDropped() throws {
        let suiteName = "com.peterichardson.SimpleConfigTests.pairs-nil"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data([0xFF]), forKey: "blob")
        try ConfigItem(suiteName: suiteName, key: "text").write("hello")
        defer {
            defaults.removeObject(forKey: "blob")
            try? ConfigItem(suiteName: suiteName, key: "text").delete()
        }

        let pairs = try ConfigItem.items(inSuite: suiteName).keyValuePairs()
        #expect(pairs.map { $0.key } == ["text"])
        #expect(pairs.map { $0.value } == ["hello"])
    }

    @Test("a read error propagates")
    func readErrorPropagates() {
        let items = [ConfigItem(suiteName: UserDefaults.globalDomain, key: "anything")]
        #expect(throws: ConfigError.self) { try items.keyValuePairs() }
    }
}
