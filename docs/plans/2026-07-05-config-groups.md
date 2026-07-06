# Config Groups (Property Wrappers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users declare a plain struct of `@Stored` (UserDefaults) and `@Secure` (Keychain) properties with live storage-backed access, read-time default fallback, per-property error projection, and a one-call `MyConfig.read()` validation via a `ConfigGroup` protocol that recurses into nested groups.

**Architecture:** A `ConfigValue` protocol maps `String`, `Data`, and their optionals onto the existing `ConfigItem`/`SecureConfigItem` calls. Two structurally identical property wrappers (`Stored`, `Secure`) resolve their backing item on each access from an explicit `suite:`/`service:` argument or the process-wide `SimpleConfig.defaultDomain`, never throw (failures fall back to the declared default and are recorded in a reference-type error box exposed via `$property.lastError`), and delete on `nil` assignment. `ConfigGroup` (sole requirement: `init()`) supplies `configErrors`/`isConfigValid`/`read()` via `Mirror`-based probing that recurses into nested `ConfigGroup` members with property-path-prefixed error keys.

**Tech Stack:** Swift 6.2 package, Foundation (`UserDefaults`, `NSLock`, `Mirror`), Security framework (Keychain, via the existing internal `Keychain` enum only), Swift Testing framework (`@Test`, `#expect`, `#require`, `.serialized`) — NOT XCTest.

**Spec:** `docs/specs/2026-07-05-config-groups-design.md`

## Global Constraints

- TDD: write the tests, run to watch them fail (a compile error IS the correct RED in Swift), then implement. Run with `swift test`.
- The existing `ConfigStorable.swift`, `ConfigItem.swift`, and `Keychain.swift` do NOT change at all. `ConfigError.swift` gains exactly two cases (Task 1) and nothing else.
- Zero new dependencies, no macro target — `Package.swift` does not change.
- `SimpleConfig.defaultDomain` is guarded with `NSLock` (manual `lock()`/`unlock()`), NOT `Synchronization.Mutex` — `Mutex` would force a macOS 15+/iOS 18+ platform floor onto a package that currently declares no platform requirements.
- `configErrors` keys are Swift property paths (`"serverConfig.apiKey"`), never storage keys.
- Every test fixture uses explicit `suite:`/`service:` arguments EXCEPT the tests in the single `.serialized` suite `"SimpleConfig.defaultDomain"` (Tasks 1 and 6) — Swift Testing runs everything else in parallel, and only that suite may read or write the process-global `SimpleConfig.defaultDomain`.
- Within a test suite, tests run in parallel too: each test touches only its own storage keys (the fixtures below are keyed per test — keep it that way).
- Doc comments use `///` style matching the existing files.
- Commit only the files named in each task.

---

### Task 1: `ConfigError` cases and the `SimpleConfig` namespace

**Files:**
- Create: `Sources/SimpleConfig/SimpleConfig.swift`
- Modify: `Sources/SimpleConfig/ConfigError.swift`
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append two new suites)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ConfigError.noDomain` and `ConfigError.invalidGroup([String: Error])` (used by Tasks 3–6); `SimpleConfig.defaultDomain: String?` static get/set (used by Tasks 3, 4, 6).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `type 'ConfigError' has no member 'noDomain'` and `cannot find 'SimpleConfig' in scope` (the type, not the module — the test file already imports the module).

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SimpleConfig/SimpleConfig.swift`:

```swift
//
//  SimpleConfig.swift
//  SimpleConfig
//
import Foundation

/// Namespace for package-wide configuration.
public enum SimpleConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _defaultDomain: String?

    /// Process-wide fallback domain: used as the `UserDefaults` suite
    /// name by `@Stored` and the Keychain service name by `@Secure`
    /// whenever a property doesn't pass one explicitly. Set it once at
    /// app startup. While it is `nil` (the initial value), a property
    /// with no explicit domain reports `ConfigError.noDomain` on access.
    public static var defaultDomain: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _defaultDomain
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _defaultDomain = newValue
        }
    }
}
```

(`nonisolated(unsafe)` + `NSLock` rather than `Synchronization.Mutex`: `Mutex` would force a macOS 15+ platform floor; the lock makes the unsafe annotation actually safe.)

In `Sources/SimpleConfig/ConfigError.swift`, add two cases after `case unknown(Error)`:

```swift
    /// A `@Stored`/`@Secure` property had no explicit `suite:`/`service:`
    /// argument and `SimpleConfig.defaultDomain` is unset.
    case noDomain
    /// One or more properties of a `ConfigGroup` failed to read, keyed
    /// by property path. Thrown by `ConfigGroup.read()`.
    case invalidGroup([String: Error])
```

and two matching branches in the `description` switch, after the `.unknown` case:

```swift
        case .noDomain:
            return "No config domain: set SimpleConfig.defaultDomain or pass suite:/service: explicitly"
        case .invalidGroup(let errors):
            let details = errors.keys.sorted()
                .map { "\($0): \(errors[$0]!)" }
                .joined(separator: "; ")
            return "Config group invalid: \(details)"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (45 existing + 3 new = 48).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/SimpleConfig.swift Sources/SimpleConfig/ConfigError.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add SimpleConfig.defaultDomain and group-related ConfigError cases"
```

---

### Task 2: The `ConfigValue` protocol and its four conformances

**Files:**
- Create: `Sources/SimpleConfig/ConfigValue.swift`
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append one new suite)

**Interfaces:**
- Consumes: existing `ConfigItem`/`SecureConfigItem` methods `read()`, `readData()`, `write(_ value: String)`, `write(_ data: Data)`, `delete()`.
- Produces: `protocol ConfigValue` with `static func read(from item: ConfigItem) throws -> Self?`, `static func read(from item: SecureConfigItem) throws -> Self?`, `func write(to item: ConfigItem) throws`, `func write(to item: SecureConfigItem) throws`; conformances for `String`, `Data`, `Optional where Wrapped: ConfigValue`. Tasks 3–5 rely on these exact signatures.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `value of type 'String' has no member 'write'` (and similar).

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SimpleConfig/ConfigValue.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (48 + 6 = 54).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/ConfigValue.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add ConfigValue protocol mapping String/Data/optionals onto config items"
```

---

### Task 3: The `@Stored` property wrapper

**Files:**
- Create: `Sources/SimpleConfig/Stored.swift`
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append one new suite)

**Interfaces:**
- Consumes: `ConfigValue` (Task 2 — exact signatures above); `SimpleConfig.defaultDomain` and `ConfigError.noDomain` (Task 1).
- Produces: `@propertyWrapper struct Stored<Value: ConfigValue>` with `init(wrappedValue:_:suite:)`, a no-value `init(_:suite:)` for `ExpressibleByNilLiteral` values, `wrappedValue`, `projectedValue: StoredProjection`; `struct StoredProjection` with `let item: ConfigItem?` and `let lastError: Error?`; internal `final class ErrorBox` with `var last: Error?` (reused by Task 4); internal computed `var item: ConfigItem?` on `Stored` (used by Task 5's probe).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`. Note the fileprivate suite constant above the `@Suite`, and that each test touches only its own storage keys (tests in a suite run in parallel):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `unknown attribute 'Stored'` / `cannot find 'Stored' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SimpleConfig/Stored.swift`:

```swift
//
//  Stored.swift
//  SimpleConfig
//
import Foundation

/// Reference-type box for a wrapper's most recent error. A struct
/// property's getter is nonmutating, so recording a failure from a
/// read requires the error to live behind a reference. Note the
/// consequence: copying a config struct copies the reference, so
/// copies share error state; separately constructed instances do not.
final class ErrorBox {
    var last: Error?
}

/// The `$property` view of a `@Stored` property.
public struct StoredProjection {
    /// The underlying item, or `nil` when no domain resolves
    /// (no explicit `suite:` and `SimpleConfig.defaultDomain` unset).
    public let item: ConfigItem?
    /// The most recent read/write's error; `nil` after a success.
    public let lastError: Error?
}

/// A live, `UserDefaults`-backed property: every `get` reads storage
/// and every `set` writes it immediately. The declared default is a
/// read-time fallback — returned when nothing is stored (or the read
/// fails, see `$property.lastError`) and never itself written to
/// storage. Optional values read `nil` when unset; assigning `nil`
/// deletes the stored value. Use `@Secure` instead for secrets.
@propertyWrapper
public struct Stored<Value: ConfigValue> {
    let key: String
    let explicitSuite: String?
    let defaultValue: Value
    let errorBox: ErrorBox

    /// Creates the wrapper. `wrappedValue` is supplied by the
    /// property's `= default` initializer expression.
    ///
    /// - Parameters:
    ///   - key: The `UserDefaults` key the value is stored under.
    ///   - suite: The suite name; `nil` falls back to
    ///     `SimpleConfig.defaultDomain` at access time.
    public init(wrappedValue: Value, _ key: String, suite: String? = nil) {
        self.defaultValue = wrappedValue
        self.key = key
        self.explicitSuite = suite
        self.errorBox = ErrorBox()
    }

    /// Resolved on each access (not cached) so `SimpleConfig.defaultDomain`
    /// may be set after the enclosing struct type is defined.
    var item: ConfigItem? {
        guard let suite = explicitSuite ?? SimpleConfig.defaultDomain else { return nil }
        return ConfigItem(suiteName: suite, key: key)
    }

    public var wrappedValue: Value {
        get {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return defaultValue
            }
            do {
                let value = try Value.read(from: item)
                errorBox.last = nil
                return value ?? defaultValue
            } catch {
                errorBox.last = error
                return defaultValue
            }
        }
        set {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return
            }
            do {
                try newValue.write(to: item)
                errorBox.last = nil
            } catch {
                errorBox.last = error
            }
        }
    }

    public var projectedValue: StoredProjection {
        StoredProjection(item: item, lastError: errorBox.last)
    }
}

extension Stored where Value: ExpressibleByNilLiteral {
    /// Lets an optional property omit `= nil`:
    /// `@Stored("nickname") var nickname: String?`.
    public init(_ key: String, suite: String? = nil) {
        self.init(wrappedValue: nil, key, suite: suite)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (54 + 8 = 62).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/Stored.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add @Stored property wrapper for live UserDefaults-backed config"
```

---

### Task 4: The `@Secure` property wrapper

**Files:**
- Create: `Sources/SimpleConfig/Secure.swift`
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append one new suite)

**Interfaces:**
- Consumes: `ConfigValue` (Task 2); `SimpleConfig.defaultDomain`, `ConfigError.noDomain` (Task 1); internal `ErrorBox` (Task 3).
- Produces: `@propertyWrapper struct Secure<Value: ConfigValue>` with `init(wrappedValue:_:service:)`, a no-value `init(_:service:)` for `ExpressibleByNilLiteral` values, `wrappedValue`, `projectedValue: SecureProjection`; `struct SecureProjection` with `let item: SecureConfigItem?` and `let lastError: Error?`; internal computed `var item: SecureConfigItem?` on `Secure` (used by Task 5's probe).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `unknown attribute 'Secure'` / `cannot find 'Secure' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SimpleConfig/Secure.swift` — the structural twin of `Stored`, backed by `SecureConfigItem` (reuses Task 3's internal `ErrorBox`):

```swift
//
//  Secure.swift
//  SimpleConfig
//
import Foundation

/// The `$property` view of a `@Secure` property.
public struct SecureProjection {
    /// The underlying item, or `nil` when no domain resolves
    /// (no explicit `service:` and `SimpleConfig.defaultDomain` unset).
    public let item: SecureConfigItem?
    /// The most recent read/write's error; `nil` after a success.
    public let lastError: Error?
}

/// A live, Keychain-backed property: every `get` reads storage and
/// every `set` writes it immediately. The declared default is a
/// read-time fallback — returned when nothing is stored (or the read
/// fails, see `$property.lastError`) and never itself written to the
/// Keychain. Optional values read `nil` when unset; assigning `nil`
/// deletes the stored secret. Use `@Stored` for non-sensitive values.
@propertyWrapper
public struct Secure<Value: ConfigValue> {
    let key: String
    let explicitService: String?
    let defaultValue: Value
    let errorBox: ErrorBox

    /// Creates the wrapper. `wrappedValue` is supplied by the
    /// property's `= default` initializer expression.
    ///
    /// - Parameters:
    ///   - key: The Keychain account name the secret is stored as.
    ///   - service: The Keychain service; `nil` falls back to
    ///     `SimpleConfig.defaultDomain` at access time.
    public init(wrappedValue: Value, _ key: String, service: String? = nil) {
        self.defaultValue = wrappedValue
        self.key = key
        self.explicitService = service
        self.errorBox = ErrorBox()
    }

    /// Resolved on each access (not cached) so `SimpleConfig.defaultDomain`
    /// may be set after the enclosing struct type is defined.
    var item: SecureConfigItem? {
        guard let service = explicitService ?? SimpleConfig.defaultDomain else { return nil }
        return SecureConfigItem(service: service, key: key)
    }

    public var wrappedValue: Value {
        get {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return defaultValue
            }
            do {
                let value = try Value.read(from: item)
                errorBox.last = nil
                return value ?? defaultValue
            } catch {
                errorBox.last = error
                return defaultValue
            }
        }
        set {
            guard let item else {
                errorBox.last = ConfigError.noDomain
                return
            }
            do {
                try newValue.write(to: item)
                errorBox.last = nil
            } catch {
                errorBox.last = error
            }
        }
    }

    public var projectedValue: SecureProjection {
        SecureProjection(item: item, lastError: errorBox.last)
    }
}

extension Secure where Value: ExpressibleByNilLiteral {
    /// Lets an optional property omit `= nil`:
    /// `@Secure("apiKey") var apiKey: String?`.
    public init(_ key: String, service: String? = nil) {
        self.init(wrappedValue: nil, key, service: service)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (62 + 6 = 68).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/Secure.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add @Secure property wrapper for live Keychain-backed config"
```

---

### Task 5: `ConfigGroup` — probing, `configErrors`, `read()`, nested recursion

**Files:**
- Create: `Sources/SimpleConfig/ConfigGroup.swift`
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append one new suite)

**Interfaces:**
- Consumes: `Stored`/`Secure` internals — `var item`, `errorBox`, generic `Value` (Tasks 3–4); `ConfigError.noDomain`/`invalidGroup` (Task 1).
- Produces: `public protocol ConfigGroup { init() }` with extension members `var configErrors: [String: Error]`, `var isConfigValid: Bool`, `static func read() throws -> Self`; internal `protocol ConfigProbeable { func probe() -> Error? }` conformed by `Stored` and `Secure` (used by Task 6's tests).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
private let groupSuite = "com.peterichardson.SimpleConfigTests.config-group"
private let groupService = "com.peterichardson.SimpleConfigTests.config-group"

@Suite("ConfigGroup")
struct ConfigGroupTests {
    struct HealthyGroup: ConfigGroup {
        @Stored("cg-host", suite: groupSuite) var host: String = "localhost"
        @Secure("cg-token", service: groupService) var token: String?
    }

    struct BrokenGroup: ConfigGroup {
        @Stored("cg-good", suite: groupSuite) var good: String = "ok"
        @Stored("cg-bad", suite: UserDefaults.globalDomain) var bad: String = "x"
    }

    struct Inner: ConfigGroup {
        @Stored("cg-inner-bad", suite: UserDefaults.globalDomain) var innerBad: String = "x"
    }
    struct Outer: ConfigGroup {
        var inner = Inner()
        @Stored("cg-outer-good", suite: groupSuite) var outerGood: String = "ok"
    }

    struct PlainMember {
        var untouched = 1
    }
    struct OuterWithPlain: ConfigGroup {
        var plain = PlainMember()
        @Stored("cg-owp-good", suite: groupSuite) var good: String = "ok"
    }

    @Test("a healthy group (mixing both backends) has no configErrors and is valid")
    func healthyGroupIsValid() {
        let group = HealthyGroup()
        #expect(group.configErrors.isEmpty)
        #expect(group.isConfigValid)
    }

    @Test("configErrors is keyed by property name, only for failing properties")
    func brokenGroupErrorsKeyedByName() {
        let errors = BrokenGroup().configErrors
        #expect(Array(errors.keys) == ["bad"])
    }

    @Test("read() returns a working instance for a healthy group")
    func readSucceeds() throws {
        let group = try HealthyGroup.read()
        #expect(group.host == "localhost")
    }

    @Test("read() throws invalidGroup naming the failing property")
    func readThrowsOnBrokenGroup() throws {
        do {
            _ = try BrokenGroup.read()
            Issue.record("expected ConfigError.invalidGroup to be thrown")
        } catch let ConfigError.invalidGroup(errors) {
            #expect(Array(errors.keys) == ["bad"])
        }
    }

    @Test("nested group failures surface under a property-path key")
    func nestedErrorsArePrefixed() {
        let errors = Outer().configErrors
        #expect(Array(errors.keys) == ["inner.innerBad"])
    }

    @Test("plain non-group members are not probed")
    func plainMembersIgnored() {
        #expect(OuterWithPlain().configErrors.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `cannot find type 'ConfigGroup' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SimpleConfig/ConfigGroup.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (68 + 6 = 74).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/ConfigGroup.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add ConfigGroup with recursive probing, configErrors, and one-call read()"
```

---

### Task 6: `defaultDomain` fallback behavior (serialized tests)

**Files:**
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (extend the existing `DefaultDomainTests` suite from Task 1)

No production code — every behavior below was implemented in Tasks 3–5; this task pins down the global-fallback paths that no other suite may touch (see Global Constraints: only this `.serialized` suite reads or writes `SimpleConfig.defaultDomain`).

**Interfaces:**
- Consumes: `Stored`/`Secure` no-explicit-domain resolution (Tasks 3–4), `ConfigGroup.configErrors` (Task 5), `SimpleConfig.defaultDomain` and `ConfigError.noDomain` (Task 1).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Write the tests (RED not expected — see Step 2)**

In `Tests/SimpleConfigTests/SimpleConfigTests.swift`, find `@Suite("SimpleConfig.defaultDomain", .serialized) struct DefaultDomainTests` (added in Task 1, currently one test) and add these four `@Test` functions inside it. Every test leaves `defaultDomain` as `nil` on exit:

```swift
    @Test("a wrapper with no explicit suite uses the default domain")
    func wrapperUsesDefaultDomain() throws {
        SimpleConfig.defaultDomain = "com.peterichardson.SimpleConfigTests.default-domain"
        defer { SimpleConfig.defaultDomain = nil }
        struct Fixture {
            @Stored("dd-name") var name: String = "Ernest"
        }
        var fixture = Fixture()
        defer {
            try? ConfigItem(
                suiteName: "com.peterichardson.SimpleConfigTests.default-domain",
                key: "dd-name"
            ).delete()
        }
        fixture.name = "Gladys"
        #expect(fixture.name == "Gladys")
        #expect(fixture.$name.item?.suiteName == "com.peterichardson.SimpleConfigTests.default-domain")
    }

    @Test("no domain at all yields ConfigError.noDomain and a nil item")
    func noDomainYieldsError() throws {
        SimpleConfig.defaultDomain = nil
        struct Fixture {
            @Stored("dd-orphan") var orphan: String = "fallback"
            @Secure("dd-secret") var secret: String?
        }
        let fixture = Fixture()
        #expect(fixture.orphan == "fallback")
        #expect(fixture.secret == nil)
        #expect(fixture.$orphan.item == nil)
        #expect(fixture.$secret.item == nil)
        let error = try #require(fixture.$orphan.lastError as? ConfigError)
        guard case .noDomain = error else {
            Issue.record("expected ConfigError.noDomain, got \(error)")
            return
        }
    }

    @Test("a subsequent successful operation clears lastError")
    func successClearsLastError() {
        SimpleConfig.defaultDomain = nil
        struct Fixture {
            @Stored("dd-clear") var value: String = "fallback"
        }
        let fixture = Fixture()
        _ = fixture.value                    // fails: no domain
        #expect(fixture.$value.lastError != nil)
        SimpleConfig.defaultDomain = "com.peterichardson.SimpleConfigTests.default-domain"
        defer { SimpleConfig.defaultDomain = nil }
        _ = fixture.value                    // succeeds now (reads nil → default)
        #expect(fixture.$value.lastError == nil)
    }

    @Test("a group probe reports noDomain per property")
    func noDomainInConfigErrors() {
        SimpleConfig.defaultDomain = nil
        struct Group: ConfigGroup {
            @Stored("dd-group-value") var value: String = "x"
        }
        let errors = Group().configErrors
        #expect(Array(errors.keys) == ["value"])
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (74 + 4 = 78). These are characterization tests of already-implemented behavior, so GREEN on first run is correct here. If any FAILS, the corresponding Task 3–5 implementation has a bug — fix the implementation, not the test.

- [ ] **Step 3: Commit**

```bash
git add Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "test: pin down defaultDomain fallback, noDomain errors, and lastError clearing"
```

---

### Task 7: Documentation (design doc and README)

**Files:**
- Modify: `docs/design.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the exact public API names from Tasks 1–5: `SimpleConfig.defaultDomain`, `@Stored`, `@Secure`, `StoredProjection`/`SecureProjection` (`item`, `lastError`), `ConfigGroup` (`configErrors`, `isConfigValid`, `read()`), `ConfigError.noDomain`/`.invalidGroup`.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Update docs/design.md**

Read `docs/design.md` first to confirm current wording (if a sentence has drifted, locate the semantically equivalent text and apply the edit to it). Make these edits:

**1a. Header date** — change `*Last updated: 2026-07-03*` to `*Last updated: 2026-07-05*`.

**1b. Architecture intro** — the paragraph starting "The package is a single library target with four source files". Change its opening sentence:

Old:
```
The package is a single library target with four source files, organized around one protocol and two conforming value types.
```

New:
```
The package is a single library target with nine source files, organized around one protocol and two conforming value types, plus a property-wrapper layer for struct-of-config ("config group") access.
```

Then append to the end of that same paragraph (after "...without caring which backend each one uses."):

```
On top of the item types sits an optional property-wrapper layer: `@Stored` and `@Secure` make struct properties live storage-backed values, and the `ConfigGroup` protocol turns such a struct into a validated unit (`try MyConfig.read()`).
```

**1c. Components** — after the **ConfigError** component paragraph, add four new component entries:

```markdown
**SimpleConfig** (`Sources/SimpleConfig/SimpleConfig.swift`)
A caseless enum namespace. Its one member, `defaultDomain: String?`, is the process-wide fallback for wrapper properties declared without an explicit `suite:`/`service:` — set once at app startup. It is guarded by an `NSLock` (not `Synchronization.Mutex`, which would force a macOS 15+ platform floor).

**ConfigValue** (`Sources/SimpleConfig/ConfigValue.swift`)
The protocol the wrappers are generic over, mapping each supported type onto the right item calls. Exactly four conformances ship — `String`, `Data`, and their optionals — and the protocol is public only because it appears in the wrappers' generic constraints; it is not a customization point. The `Optional` conformance encodes two decisions: an absent value reads as `.some(nil)` so optional properties read `nil` when unset instead of falling back to their default, and writing `nil` deletes the stored value.

**Stored / Secure** (`Sources/SimpleConfig/Stored.swift`, `Sources/SimpleConfig/Secure.swift`)
Structurally identical property wrappers over `ConfigItem` and `SecureConfigItem` respectively. Every `get` reads storage and every `set` writes immediately; the underlying item is rebuilt on each access so `defaultDomain` may be set after the struct type is defined. The declared default is a read-time fallback, never written to storage. Accessors cannot throw, so failures fall back to the default (reads) or are dropped (writes) and are recorded in a reference-type error box exposed through the projection: `$property.item` (the underlying item, or `nil` when no domain resolves) and `$property.lastError` (the most recent operation's error, cleared on success). Copies of a config struct share the error box; separately constructed instances do not.

**ConfigGroup** (`Sources/SimpleConfig/ConfigGroup.swift`)
A protocol whose only requirement, `init()`, is synthesized for any struct whose properties all have defaults — conformance is effectively free. Its extension supplies `configErrors` (a `Mirror`-based probe that performs one real read per wrapped property, recursing into members that are themselves `ConfigGroup`s and prefixing error keys with the property path, e.g. `"serverConfig.apiKey"`), `isConfigValid`, and `read()` — construct-and-validate in one call, throwing `ConfigError.invalidGroup` keyed by property path. Probing performs real reads because construction touches no storage: right after `MyConfig()`, every `lastError` is `nil` no matter how broken storage is. Nesting is code organization only — keys stay flat within the domain.
```

**1d. Data Flow** — append a new paragraph after the `readData()`/binary-storage paragraph (the one ending "...costs exactly one Keychain read."):

```
The wrapper layer routes everything through the same item calls. Reading `config.host` builds a `ConfigItem` from the property's explicit suite or `SimpleConfig.defaultDomain`, calls `read()` (or `readData()` for `Data` properties, via the `ConfigValue` conformances), and returns the stored value or the declared read-time default; assignment is a `write(_:)` and assigning `nil` to an optional property is a `delete()`. No failure escapes as a thrown error — reads fall back to the default, writes are dropped, and either way the error lands in `$property.lastError`. `try MyConfig.read()` performs one probe read per wrapped property (nested groups recursively) and throws `ConfigError.invalidGroup` if any fail, giving startup code a single validation point; properties stay live afterward.
```

**1e. Key Design Decisions** — append a new decision paragraph after **Redaction over omission**:

```
**Read-time fallback for wrapper defaults.** A wrapped property's declared default (`= "Ernest"`) is returned when nothing is stored, and is never written to storage. Storage holds only user decisions; defaults live in code, so a program update with a new default takes effect for every user who never customized the value. Write-at-init was rejected because it clobbers customizations, and provenance tagging (a stored source marker per value) was rejected because external writes — e.g. the `defaults` CLI — bypass the tag and reintroduce the clobbering for exactly the users most likely to notice. This matches the philosophy of `UserDefaults.register(defaults:)`.
```

**1f. Document History** — append:

```
| 2026-07-05 | Added the property-wrapper layer: `@Stored`/`@Secure`, `ConfigValue`, `ConfigGroup` (with recursive probing and `read()`), `SimpleConfig.defaultDomain`, and `ConfigError.noDomain`/`.invalidGroup` |
```

Run: `swift test`
Expected: all 78 tests still pass (docs-only change; this catches accidental source edits).

- [ ] **Step 2: Update README.md**

Read `README.md` first (same caveat as above). Make these edits:

**2a. Intro paragraph** — the sentence "The deliberate trade-off is simplicity: values are strings only, and the package is Apple-only." is stale (binary values shipped earlier). Change to:

```
The deliberate trade-off is simplicity: values are strings and raw bytes only, and the package is Apple-only.
```

**2b. Features** — add a bullet after the **One protocol, two backends** bullet:

```markdown
- **Config structs, not just items** — declare a plain struct with `@Stored`/`@Secure` properties and get live storage-backed values, code-defined defaults, and one-call validation with `try MyConfig.read()`; groups can nest.
```

**2c. Quick Start** — after the binary-values code block (the one ending `try cache.read()                         // nil — no String was ever written` and its closing fence) and before the `---` / `## API` heading, add:

````markdown
Or skip individual items entirely: declare your config as a struct.
Properties are live (every get reads storage, every set writes it),
defaults are read-time fallbacks that are never written to storage,
and one call validates everything:

```swift
SimpleConfig.defaultDomain = "com.example.myapp"   // once, at startup

struct MyConfig: ConfigGroup {
    @Stored("defaultName") var defaultName: String = "Ernest"
    @Secure("apiKey")      var apiKey: String?     // nil = not set
}

var config = try MyConfig.read()   // throws if any property is unreadable
print("Hello, \(config.defaultName)!")             // "Ernest" until customized
config.defaultName = "Gladys"                      // written immediately
config.apiKey = nil                                // deletes from the Keychain
```

Wrapper accessors never throw: a failed read returns the default and a
failed write is dropped, with the error recorded on the projection —
check `config.$apiKey.lastError`, or reach the throwing API via
`config.$apiKey.item`. Groups nest (a `ConfigGroup` member is validated
recursively); supported property types are `String`, `String?`, `Data`,
and `Data?`.
````

**2d. API section** — after the `Comparable` bullet (the last one in the "Every `ConfigStorable` provides:" list), add a short subsection before the "Errors:" paragraph:

```markdown
The property-wrapper layer adds:

- `@Stored("key")` / `@Secure("key")` — live struct properties backed by `UserDefaults`/Keychain; explicit `suite:`/`service:` beats the process-wide `SimpleConfig.defaultDomain`
- `$property.item` / `$property.lastError` — the underlying item and the most recent failure (accessors never throw)
- `ConfigGroup` — free conformance for all-defaults structs: `configErrors` / `isConfigValid` probe every property (nested groups recursively), `try MyConfig.read()` constructs and validates in one call
```

Also extend the "Errors:" paragraph. Change:

```markdown
Errors: `ConfigItem` throws `ConfigError.unableToLoad` when the suite name
is invalid (e.g. `NSGlobalDomain` or your app's own bundle identifier);
Keychain failures surface as `NSError` with the OSStatus code.
```

to:

```markdown
Errors: `ConfigItem` throws `ConfigError.unableToLoad` when the suite name
is invalid (e.g. `NSGlobalDomain` or your app's own bundle identifier);
Keychain failures surface as `NSError` with the OSStatus code. The wrapper
layer adds `ConfigError.noDomain` (no explicit domain and
`SimpleConfig.defaultDomain` unset) and `ConfigError.invalidGroup` (thrown
by `ConfigGroup.read()`, keyed by property path).
```

Run: `swift test`
Expected: all 78 tests still pass.

- [ ] **Step 3: Fix the stale Keychain-limitation bullet (separate commit)**

`README.md`'s Known Limitations still lists "**Keychain reads collapse errors to `nil`**" — that was fixed in commit `b3c2f79` (genuine failures now throw) but the README bullet survived. Delete this entire bullet:

```markdown
- **Keychain reads collapse errors to `nil`** — a genuine failure (e.g. reading while the device is locked) is currently indistinguishable from "not set." Tracked as an open question in [docs/design.md](docs/design.md).
```

Commit it separately (it is unrelated to config groups):

```bash
git add README.md
git commit -m "docs: drop stale Keychain error-collapsing limitation from README"
```

- [ ] **Step 4: Commit the config-groups documentation**

```bash
git add docs/design.md README.md
git commit -m "docs: document config groups, property wrappers, and defaultDomain"
```
