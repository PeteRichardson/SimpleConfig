# Enumeration + keyValuePairs() Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add namespace enumeration (`ConfigItem.items(inSuite:)`, `SecureConfigItem.items(inService:)`) and a chained `keyValuePairs()` conversion to plain tuples.

**Architecture:** Two static enumerators on the concrete types (no protocol change — the namespaces have genuinely different names), backed by `UserDefaults.persistentDomain(forName:)` and a new internal `Keychain.accounts` that queries attributes only, never secret values. A `Sequence` extension converts homogeneous item collections to `(key, value)` tuples — the "string view" that throws on read errors and drops `nil` reads.

**Tech Stack:** Swift 6.2 package, Foundation (`UserDefaults`), Security framework (Keychain generic passwords), Swift Testing framework (`@Test`, `#expect`, `#require` — NOT XCTest).

**Spec:** `docs/specs/2026-07-03-enumeration-design.md`

## Global Constraints

- TDD throughout: write each test, watch it fail (a compile error IS the correct RED in Swift), then implement. Run tests with `swift test`.
- **Test isolation:** Swift Testing runs tests in parallel. Every test that asserts an exact item list MUST use its own unique suite/service name (no sharing between tests), and must clean up what it wrote (`defer` + `delete()`/`removeObject`).
- No new error cases: invalid suite names throw the existing `ConfigError.unableToLoad`; Keychain failures throw `NSError(domain: "Keychain", code:)` matching the existing pattern. Do NOT migrate Keychain errors to `ConfigError` (out of scope).
- Enumeration is type-blind (every key in a domain becomes an item) and never reads Keychain secret values (`kSecReturnAttributes`, not `kSecReturnData`).
- `keyValuePairs()` throws on the first read **error** but silently drops `nil` reads (the string view).
- Enumerator results are sorted ascending by key. Doc comments use `///` style matching the existing files.
- No `associatedtype`/generic value machinery on `ConfigStorable` — explicitly rejected in the spec (YAGNI; the future `Data` feature adds parallel methods instead).

---

### Task 1: `ConfigItem.items(inSuite:)`

**Files:**
- Modify: `Sources/SimpleConfig/ConfigItem.swift` (refactor `defaults` accessor into a static helper; add static enumerator)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append new suite)

**Interfaces:**
- Consumes: existing `ConfigError.unableToLoad(reason:)`; existing `Comparable` conformance (sort by key).
- Produces: `public static func items(inSuite suiteName: String) throws -> [ConfigItem]`, and `private static func suite(named:) throws -> UserDefaults` (used only within `ConfigItem`). Task 3 chains `keyValuePairs()` onto this enumerator's result.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

(The spec mandates `Data`, not a bool, for the non-string test: `UserDefaults.string(forKey:)` coerces numbers to strings, but `Data` has no string form.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `type 'ConfigItem' has no member 'items'`.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SimpleConfig/ConfigItem.swift`, inside `ConfigItem`, replace the existing `defaults` accessor:

```swift
    /// `UserDefaults(suiteName:)` returns `nil` for reserved names rather
    /// than failing loudly; resolving it lazily per access lets `read`/`write`
    /// surface that as a thrown error instead of a force-unwrap crash.
    private var defaults: UserDefaults {
        get throws {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw ConfigError.unableToLoad(reason: "invalid UserDefaults suite name: \(suiteName)")
            }
            return defaults
        }
    }
```

with a static helper plus a delegating accessor (keeps the validation in one place for both instance methods and the new static enumerator):

```swift
    /// `UserDefaults(suiteName:)` returns `nil` for reserved names rather
    /// than failing loudly; validating here lets callers surface that as a
    /// thrown error instead of a force-unwrap crash.
    private static func suite(named suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ConfigError.unableToLoad(reason: "invalid UserDefaults suite name: \(suiteName)")
        }
        return defaults
    }

    private var defaults: UserDefaults {
        get throws { try Self.suite(named: suiteName) }
    }
```

Then add directly after the `delete()` method:

```swift
    /// All items stored in the given `UserDefaults` suite, sorted by key.
    /// Every key in the suite is included regardless of its value's type
    /// (enumeration is type-blind); an unused suite returns an empty array.
    ///
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public static func items(inSuite suiteName: String) throws -> [ConfigItem] {
        _ = try suite(named: suiteName)
        // persistentDomain, not dictionaryRepresentation(): the latter
        // merges in NSGlobalDomain and the rest of the search list.
        let domain = UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]
        return domain.keys
            .map { ConfigItem(suiteName: suiteName, key: $0) }
            .sorted()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (16 existing + 4 new). The NSGlobalDomain Foundation log line from reserved-name tests is expected noise, not a failure.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/ConfigItem.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add ConfigItem.items(inSuite:) enumeration"
```

---

### Task 2: `Keychain.accounts` and `SecureConfigItem.items(inService:)`

**Files:**
- Modify: `Sources/SimpleConfig/Keychain.swift` (add `accounts` after `delete`)
- Modify: `Sources/SimpleConfig/ConfigItem.swift` (add static enumerator to `SecureConfigItem`, after its `delete()`)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append new suite)

**Interfaces:**
- Consumes: existing `SecureConfigItem.write(_:)`/`delete()` (for test setup/teardown); existing `Comparable`.
- Produces: `public static func items(inService service: String) throws -> [SecureConfigItem]`; internal `static func accounts(service: String) throws -> [String]` on `Keychain`. Task 3's tests do not depend on these, but the API is part of the spec's public surface.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `type 'SecureConfigItem' has no member 'items'`.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SimpleConfig/Keychain.swift`, add directly after the `delete` method:

```swift
    /// All account names stored under the given service, unsorted.
    /// Values are never read (`kSecReturnAttributes`, not
    /// `kSecReturnData`), so listing is cheap and safe. An unused
    /// service returns an empty array rather than an error.
    static func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw NSError(
                domain: "Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to list keychain items"])
        }
        let attributes = result as? [[String: Any]] ?? []
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }
```

In `Sources/SimpleConfig/ConfigItem.swift`, add to `SecureConfigItem` directly after its `delete()` method:

```swift
    /// All items stored under the given Keychain service, sorted by key.
    /// Secret values are never read — the results are safe to display
    /// (printing an item shows the redacted form).
    public static func items(inService service: String) throws -> [SecureConfigItem] {
        try Keychain.accounts(service: service)
            .map { SecureConfigItem(service: service, key: $0) }
            .sorted()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (20 + 2 new). These tests hit the real Keychain; the delete check-in proved the runner has access. If `write` fails with `errSecMissingEntitlement` (-34018) or `errSecInteractionNotAllowed` (-25308), stop and report BLOCKED — do not weaken the tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/Keychain.swift Sources/SimpleConfig/ConfigItem.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add SecureConfigItem.items(inService:) backed by Keychain.accounts"
```

---

### Task 3: `keyValuePairs()`

**Files:**
- Modify: `Sources/SimpleConfig/ConfigStorable.swift` (append a `Sequence` extension at the end of the file)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append new suite)

**Interfaces:**
- Consumes: `ConfigItem.items(inSuite:)` from Task 1 (`static func items(inSuite suiteName: String) throws -> [ConfigItem]`); protocol members `key` and `read()`.
- Produces: `public func keyValuePairs() throws -> [(key: String, value: String)]` on `Sequence where Element: ConfigStorable`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `value of type '[ConfigItem]' has no member 'keyValuePairs'`.

- [ ] **Step 3: Write the minimal implementation**

Append at the end of `Sources/SimpleConfig/ConfigStorable.swift`:

```swift
extension Sequence where Element: ConfigStorable {
    /// The string view of these items: each item's key paired with its
    /// current value, in this sequence's order. Items whose value reads
    /// as `nil` (deleted since enumeration, or not representable as a
    /// string — e.g. a non-string `UserDefaults` value) are dropped.
    /// Reading a `SecureConfigItem` sequence materializes every secret
    /// in plaintext — call deliberately.
    ///
    /// Available on homogeneous sequences (`[ConfigItem]`,
    /// `[SecureConfigItem]`); Swift existentials don't conform to their
    /// own protocols, so a mixed `[any ConfigStorable]` needs a manual map.
    ///
    /// - Throws: The first error any item's `read()` throws.
    public func keyValuePairs() throws -> [(key: String, value: String)] {
        try compactMap { item in
            guard let value = try item.read() else { return nil }
            return (key: item.key, value: value)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (22 + 3 new = 25).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/ConfigStorable.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add keyValuePairs() string view for config item sequences"
```

---

### Task 4: Documentation (design doc + README)

**Files:**
- Modify: `docs/design.md` (three edits)
- Modify: `README.md` (three edits)

**Interfaces:**
- Consumes: the API names from Tasks 1–3 exactly as produced: `ConfigItem.items(inSuite:)`, `SecureConfigItem.items(inService:)`, `Keychain.accounts`, `keyValuePairs()`.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Update docs/design.md**

Read `docs/design.md`, then make exactly three edits:

1. In the **Architecture** intro paragraph, directly after the sentence about `delete()` being idempotent, add:

   ```
   Static enumerators (`ConfigItem.items(inSuite:)`, `SecureConfigItem.items(inService:)`) list a namespace's items sorted by key, and a `Sequence` extension, `keyValuePairs()`, converts items to plain `(key, value)` tuples — the string view, which throws on read errors and drops values that don't read as strings.
   ```

2. In the **Data Flow** section, append this as a new paragraph after the delete paragraph:

   ```
   Enumeration never reads secret values: `SecureConfigItem.items(inService:)` asks the Keychain for attributes only (`kSecReturnAttributes`, via the internal `Keychain.accounts`), and `ConfigItem.items(inSuite:)` reads the suite's `persistentDomain(forName:)` — not `dictionaryRepresentation()`, which would merge in the global domain. Listing config is therefore safe to display; extracting plaintext requires an explicit chained `keyValuePairs()` call.
   ```

3. In the **Document History** table, append:

   ```
   | 2026-07-03 | Added enumeration (`items(inSuite:)`, `items(inService:)`, `Keychain.accounts`) and `keyValuePairs()` |
   ```

- [ ] **Step 2: Update README.md**

Read `README.md`, then make exactly three edits:

1. In the **Quick Start** section, after the mixed-collection code block (the one ending with `// secrets stay redacted`), add:

   ````markdown
   Discover what a namespace contains — and, when you mean to, extract
   plain pairs:

   ```swift
   // Enumerate without reading secret values
   for item in try SecureConfigItem.items(inService: "com.example.myapp") {
       print(item)             // redacted, safe to log
   }

   // Explicitly materialize plain (key, value) tuples
   let pairs = try ConfigItem.items(inSuite: "com.example.myapp").keyValuePairs()
   // [(key: "host", value: "api.example.com")]
   ```
   ````

2. In the **API** section's list of `ConfigStorable` capabilities, after the `delete()` bullet, add:

   ```markdown
   - `ConfigItem.items(inSuite:)` / `SecureConfigItem.items(inService:)` — all items in a namespace, sorted by key; secret values are never read
   - `keyValuePairs()` (on homogeneous item sequences) — plain `(key, value)` tuples; throws on read errors, drops values with no string form
   ```

3. In **Known Limitations**, delete the entire bullet that begins "**No enumeration yet**" (the feature now exists).

- [ ] **Step 3: Verify the build still passes and docs are consistent**

Run: `swift test`
Expected: all 25 tests pass (docs-only change; this catches accidental source edits).

Run: `grep -n "No enumeration" README.md`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add docs/design.md README.md
git commit -m "docs: document enumeration and keyValuePairs in design doc and README"
```
