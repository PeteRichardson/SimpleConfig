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

    @Test("a byte count renders as a binary value when the result is nil")
    func binaryValue() {
        let output = SecureConfigItem.describe(key: "token", result: .success(nil), dataByteCount: 3)
        #expect(output == "token = (binary value, 3 bytes)")
    }

    @Test("dataByteCount is not evaluated when a string value is present")
    func dataByteCountNotEvaluatedForPresentValue() {
        var callCount = 0
        func count() -> Int? { callCount += 1; return 99 }
        _ = SecureConfigItem.describe(key: "token", result: .success("value"), dataByteCount: count())
        #expect(callCount == 0)
    }

    @Test("dataByteCount is not evaluated on failure")
    func dataByteCountNotEvaluatedForFailure() {
        struct FakeError: Error {}
        var callCount = 0
        func count() -> Int? { callCount += 1; return 99 }
        _ = SecureConfigItem.describe(key: "token", result: .failure(FakeError()), dataByteCount: count())
        #expect(callCount == 0)
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

@Suite("Keychain.isPresent")
struct KeychainIsPresentTests {
    @Test("errSecSuccess is present")
    func successIsPresent() throws {
        #expect(try Keychain.isPresent(errSecSuccess) == true)
    }

    @Test("errSecItemNotFound is not present")
    func notFoundIsNotPresent() throws {
        #expect(try Keychain.isPresent(errSecItemNotFound) == false)
    }

    @Test("any other status throws")
    func otherStatusThrows() {
        #expect(throws: NSError.self) {
            try Keychain.isPresent(errSecAuthFailed)
        }
    }
}

@Suite("Keychain.read error handling")
struct KeychainReadErrorTests {
    @Test("a never-written key returns nil without throwing")
    func neverWrittenReturnsNil() throws {
        let item = SecureConfigItem(
            service: "com.peterichardson.SimpleConfigTests.read-errors",
            key: "never-written"
        )
        #expect(try item.read() == nil)
    }

    @Test("a written key still reads back correctly")
    func writtenKeyReadsBack() throws {
        let item = SecureConfigItem(
            service: "com.peterichardson.SimpleConfigTests.read-errors",
            key: "present"
        )
        try item.write("hello")
        defer { try? item.delete() }
        #expect(try item.read() == "hello")
    }
}

@Suite("ConfigItem Data values")
struct ConfigItemDataTests {
    let suiteName = "com.peterichardson.SimpleConfigTests.data-values"

    @Test("write(Data) then readData() round-trips the same bytes")
    func dataRoundTrip() throws {
        let item = ConfigItem(suiteName: suiteName, key: "blob")
        let bytes = Data([0x01, 0x02, 0x03])
        try item.write(bytes)
        defer { try? item.delete() }
        #expect(try item.readData() == bytes)
    }

    @Test("write(Data) then read() returns nil (type mismatch)")
    func dataThenStringReadIsNil() throws {
        let item = ConfigItem(suiteName: suiteName, key: "blob-vs-string")
        try item.write(Data([0xFF]))
        defer { try? item.delete() }
        #expect(try item.read() == nil)
    }

    @Test("write(String) then readData() returns nil (type mismatch)")
    func stringThenDataReadIsNil() throws {
        let item = ConfigItem(suiteName: suiteName, key: "string-vs-blob")
        try item.write("hello")
        defer { try? item.delete() }
        #expect(try item.readData() == nil)
    }

    @Test("readData() on a reserved suite name throws")
    func readDataThrowsOnReservedSuite() {
        let item = ConfigItem(suiteName: UserDefaults.globalDomain, key: "anything")
        #expect(throws: ConfigError.self) { try item.readData() }
    }

    @Test("readData() on a never-written key returns nil")
    func readDataOnMissingKeyIsNil() throws {
        let item = ConfigItem(suiteName: suiteName, key: "never-written-blob")
        #expect(try item.readData() == nil)
    }
}

@Suite("SecureConfigItem Data values")
struct SecureConfigItemDataTests {
    let service = "com.peterichardson.SimpleConfigTests.data-values"

    @Test("write(Data) then readData() round-trips the same bytes")
    func dataRoundTrip() throws {
        let item = SecureConfigItem(service: service, key: "blob")
        let bytes = Data([0x01, 0x02, 0x03])
        try item.write(bytes)
        defer { try? item.delete() }
        #expect(try item.readData() == bytes)
    }

    @Test("write(Data) with non-UTF8 bytes then read() returns nil")
    func nonUTF8DataThenStringReadIsNil() throws {
        let item = SecureConfigItem(service: service, key: "non-utf8")
        try item.write(Data([0xFF, 0xFE]))
        defer { try? item.delete() }
        #expect(try item.read() == nil)
    }

    @Test("write(String) then readData() returns its UTF-8 bytes")
    func stringThenDataReadSucceeds() throws {
        let item = SecureConfigItem(service: service, key: "string-as-data")
        try item.write("hello")
        defer { try? item.delete() }
        #expect(try item.readData() == "hello".data(using: .utf8))
    }

    @Test("readData() on a never-written key returns nil")
    func readDataOnMissingItemIsNil() throws {
        let item = SecureConfigItem(service: service, key: "never-written-blob")
        #expect(try item.readData() == nil)
    }
}

@Suite("ConfigItem description")
struct ConfigItemDescriptionTests {
    @Test("a present string value renders directly")
    func presentString() {
        let output = ConfigItem.describe(key: "host", stringValue: "example.com", dataByteCount: nil)
        #expect(output == "host = example.com")
    }

    @Test("no string but a byte count renders as a binary value")
    func binaryValue() {
        let output = ConfigItem.describe(key: "blob", stringValue: nil, dataByteCount: 3)
        #expect(output == "blob = (binary value, 3 bytes)")
    }

    @Test("neither a string nor a byte count renders as not set")
    func notSet() {
        let output = ConfigItem.describe(key: "missing", stringValue: nil, dataByteCount: nil)
        #expect(output == "missing = (not set)")
    }
}

@Suite("ConfigError group cases")
struct ConfigErrorGroupTests {
    @Test("noDomain description points at SimpleConfig.defaultDomain")
    func noDomainDescription() {
        #expect(ConfigError.noDomain.description.contains("SimpleConfig.defaultDomain"))
    }

    @Test("invalidGroup description names the failing properties")
    func invalidGroupDescription() {
        let error = ConfigError.invalidGroup(["apiKey": ConfigError.noDomain])
        #expect(error.description.contains("apiKey"))
    }
}

@Suite("SimpleConfig.defaultDomain", .serialized)
struct DefaultDomainTests {
    @Test("set and get round-trip, and reset to nil")
    func setAndGetRoundTrip() {
        SimpleConfig.defaultDomain = "com.peterichardson.SimpleConfigTests.default-domain"
        #expect(SimpleConfig.defaultDomain == "com.peterichardson.SimpleConfigTests.default-domain")
        SimpleConfig.defaultDomain = nil
        #expect(SimpleConfig.defaultDomain == nil)
    }
}

@Suite("ConfigValue conformances")
struct ConfigValueTests {
    let suiteName = "com.peterichardson.SimpleConfigTests.config-value"
    let service = "com.peterichardson.SimpleConfigTests.config-value"

    @Test("String round-trips through a ConfigItem")
    func stringThroughConfigItem() throws {
        let item = ConfigItem(suiteName: suiteName, key: "cv-string")
        defer { try? item.delete() }
        try "hello".write(to: item)
        #expect(try String.read(from: item) == "hello")
    }

    @Test("Data round-trips through a ConfigItem")
    func dataThroughConfigItem() throws {
        let item = ConfigItem(suiteName: suiteName, key: "cv-data")
        defer { try? item.delete() }
        try Data([0x01, 0x02]).write(to: item)
        #expect(try Data.read(from: item) == Data([0x01, 0x02]))
    }

    @Test("writing nil through Optional deletes the stored value")
    func optionalNilWriteDeletes() throws {
        let item = ConfigItem(suiteName: suiteName, key: "cv-opt-delete")
        try "x".write(to: item)
        let none: String? = nil
        try none.write(to: item)
        #expect(try item.read() == nil)
    }

    @Test("Optional reads distinguish absent from present")
    func optionalReadDistinguishesPresence() throws {
        let item = ConfigItem(suiteName: suiteName, key: "cv-opt-read")
        defer { try? item.delete() }
        // Absent reads as .some(.none): "the read worked; the value is nil."
        #expect(try Optional<String>.read(from: item) == .some(.none))
        try "y".write(to: item)
        #expect(try Optional<String>.read(from: item) == "y")
    }

    @Test("String round-trips through a SecureConfigItem")
    func stringThroughSecureItem() throws {
        let item = SecureConfigItem(service: service, key: "cv-secure-string")
        defer { try? item.delete() }
        try "hush".write(to: item)
        #expect(try String.read(from: item) == "hush")
    }

    @Test("writing nil through Optional deletes a Keychain value")
    func optionalNilWriteDeletesSecure() throws {
        let item = SecureConfigItem(service: service, key: "cv-secure-opt")
        try "x".write(to: item)
        let none: String? = nil
        try none.write(to: item)
        #expect(try item.read() == nil)
    }
}

private let storedSuite = "com.peterichardson.SimpleConfigTests.stored-wrapper"

@Suite("Stored wrapper")
struct StoredWrapperTests {
    struct Fixture {
        @Stored("sw-roundtrip", suite: storedSuite) var roundtrip: String = "unset"
        @Stored("sw-default", suite: storedSuite) var defaultOnly: String = "DefaultOnly"
        @Stored("sw-unset-opt", suite: storedSuite) var unsetOpt: String?
        @Stored("sw-nickname", suite: storedSuite) var nickname: String?
        @Stored("sw-blob", suite: storedSuite) var blob: Data?
        @Stored("sw-broken", suite: UserDefaults.globalDomain) var broken: String = "fallback"
    }

    @Test("an unset key reads the declared default, and the default is never written")
    func defaultWhenUnset() throws {
        let fixture = Fixture()
        #expect(fixture.defaultOnly == "DefaultOnly")
        // Read-time fallback only — nothing was persisted by that read:
        #expect(try ConfigItem(suiteName: storedSuite, key: "sw-default").read() == nil)
    }

    @Test("assignment writes through to UserDefaults immediately")
    func writeThenRead() throws {
        var fixture = Fixture()
        defer { try? ConfigItem(suiteName: storedSuite, key: "sw-roundtrip").delete() }
        fixture.roundtrip = "Gladys"
        #expect(fixture.roundtrip == "Gladys")
        // Really in UserDefaults, not cached in the struct:
        #expect(try ConfigItem(suiteName: storedSuite, key: "sw-roundtrip").read() == "Gladys")
    }

    @Test("an optional property reads nil when unset")
    func optionalNilWhenUnset() {
        let fixture = Fixture()
        #expect(fixture.unsetOpt == nil)
    }

    @Test("assigning nil to an optional property deletes the stored value")
    func assignNilDeletes() throws {
        var fixture = Fixture()
        fixture.nickname = "Ernie"
        #expect(try ConfigItem(suiteName: storedSuite, key: "sw-nickname").read() == "Ernie")
        fixture.nickname = nil
        #expect(try ConfigItem(suiteName: storedSuite, key: "sw-nickname").read() == nil)
        #expect(fixture.nickname == nil)
    }

    @Test("Data? round-trips through the wrapper")
    func dataRoundTrip() throws {
        var fixture = Fixture()
        defer { try? ConfigItem(suiteName: storedSuite, key: "sw-blob").delete() }
        fixture.blob = Data([0x01, 0x02, 0x03])
        #expect(fixture.blob == Data([0x01, 0x02, 0x03]))
    }

    @Test("the projection exposes the underlying item")
    func projectionItem() {
        let fixture = Fixture()
        #expect(fixture.$roundtrip.item?.suiteName == storedSuite)
        #expect(fixture.$roundtrip.item?.key == "sw-roundtrip")
    }

    @Test("a failed read returns the default and sets lastError")
    func failedReadFallsBack() {
        let fixture = Fixture()
        #expect(fixture.broken == "fallback")
        #expect(fixture.$broken.lastError != nil)
    }

    @Test("a successful read leaves lastError nil")
    func successfulReadLeavesNoError() {
        let fixture = Fixture()
        _ = fixture.defaultOnly
        #expect(fixture.$defaultOnly.lastError == nil)
    }
}

private let secureService = "com.peterichardson.SimpleConfigTests.secure-wrapper"

@Suite("Secure wrapper")
struct SecureWrapperTests {
    struct Fixture {
        @Secure("sec-roundtrip", service: secureService) var roundtrip: String = "unset"
        @Secure("sec-default", service: secureService) var defaultOnly: String = "DefaultOnly"
        @Secure("sec-unset-opt", service: secureService) var unsetOpt: String?
        @Secure("sec-token", service: secureService) var token: String?
        @Secure("sec-blob", service: secureService) var blob: Data?
    }

    @Test("an unset key reads the declared default, and the default is never written")
    func defaultWhenUnset() throws {
        let fixture = Fixture()
        #expect(fixture.defaultOnly == "DefaultOnly")
        #expect(try SecureConfigItem(service: secureService, key: "sec-default").read() == nil)
    }

    @Test("assignment writes through to the Keychain immediately")
    func writeThenRead() throws {
        var fixture = Fixture()
        defer { try? SecureConfigItem(service: secureService, key: "sec-roundtrip").delete() }
        fixture.roundtrip = "sk-12345"
        #expect(fixture.roundtrip == "sk-12345")
        #expect(try SecureConfigItem(service: secureService, key: "sec-roundtrip").read() == "sk-12345")
    }

    @Test("an optional property reads nil when unset")
    func optionalNilWhenUnset() {
        let fixture = Fixture()
        #expect(fixture.unsetOpt == nil)
    }

    @Test("assigning nil to an optional property deletes the Keychain value")
    func assignNilDeletes() throws {
        var fixture = Fixture()
        fixture.token = "temporary"
        #expect(try SecureConfigItem(service: secureService, key: "sec-token").read() == "temporary")
        fixture.token = nil
        #expect(try SecureConfigItem(service: secureService, key: "sec-token").read() == nil)
        #expect(fixture.token == nil)
    }

    @Test("Data? round-trips through the wrapper")
    func dataRoundTrip() throws {
        var fixture = Fixture()
        defer { try? SecureConfigItem(service: secureService, key: "sec-blob").delete() }
        fixture.blob = Data([0xFF, 0xFE])
        #expect(fixture.blob == Data([0xFF, 0xFE]))
    }

    @Test("the projection exposes the underlying item")
    func projectionItem() {
        let fixture = Fixture()
        #expect(fixture.$roundtrip.item?.service == secureService)
        #expect(fixture.$roundtrip.item?.key == "sec-roundtrip")
    }
}
