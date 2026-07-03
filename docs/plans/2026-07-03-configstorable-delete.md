# ConfigStorable `delete()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an idempotent `delete()` operation to the `ConfigStorable` protocol and both conformers, so config values can be removed as uniformly as they are read and written.

**Architecture:** Implement `delete()` on `ConfigItem` (via `UserDefaults.removeObject`) and `SecureConfigItem` (via a new internal `Keychain.delete` using `SecItemDelete`) first, then add the protocol requirement last so the package compiles after every task. Semantics are "ensure absent": deleting a missing value succeeds silently.

**Tech Stack:** Swift 6.2 package, Foundation (`UserDefaults`), Security framework (Keychain generic passwords), Swift Testing framework (`@Test`, `#expect` — NOT XCTest).

**Spec:** `docs/specs/2026-07-03-configstorable-delete-design.md`

## Global Constraints

- TDD throughout: write each test, watch it fail, then implement. Run tests with `swift test`.
- Idempotent semantics: deleting a value that does not exist is success, never an error.
- No new error cases: `ConfigItem` paths throw the existing `ConfigError.unableToLoad`; `Keychain` throws `NSError(domain: "Keychain", code:)` matching the existing `Keychain.write` pattern. Do NOT migrate Keychain errors to `ConfigError` (explicitly out of scope).
- Doc comments use Swift `///` style matching the existing files.
- The working tree already has uncommitted doc-comment changes to all four source files; commits in this plan must `git add` only the files named in the task.

---

### Task 1: `ConfigItem.delete()`

**Files:**
- Modify: `Sources/SimpleConfig/ConfigItem.swift` (add method to `ConfigItem`, after `write(_:)`)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append new suite)

**Interfaces:**
- Consumes: `ConfigItem.defaults` — existing `private var defaults: UserDefaults { get throws }` that throws `ConfigError.unableToLoad` for invalid suite names.
- Produces: `public func delete() throws` on `ConfigItem` — Task 3 adds the matching protocol requirement.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `value of type 'ConfigItem' has no member 'delete'`. (In a compiled language, "test fails because the feature is missing" surfaces as a compile error; that is the correct RED.)

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SimpleConfig/ConfigItem.swift`, add to `ConfigItem` directly after the `write(_:)` method:

```swift
    /// Ensures no value is stored for `key`. Deleting a value that
    /// does not exist succeeds silently.
    ///
    /// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
    public func delete() throws {
        try defaults.removeObject(forKey: key)
    }
```

(`removeObject(forKey:)` is already a no-op for missing keys, which provides the idempotent behavior; the throwing `defaults` accessor provides the invalid-suite error.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass, including the 3 new ones. A Foundation log line about `NSGlobalDomain` ("does not make sense") is expected noise from the reserved-suite tests, not a failure.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/ConfigItem.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add ConfigItem.delete() for removing stored values"
```

---

### Task 2: `Keychain.delete` and `SecureConfigItem.delete()`

**Files:**
- Modify: `Sources/SimpleConfig/Keychain.swift` (add `delete` after `read`)
- Modify: `Sources/SimpleConfig/ConfigItem.swift` (add method to `SecureConfigItem`, after its `write(_:)`)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append new suite)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public func delete() throws` on `SecureConfigItem`; internal `static func delete(_ key: String, service: String) throws` on `Keychain`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `value of type 'SecureConfigItem' has no member 'delete'`.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SimpleConfig/Keychain.swift`, add directly after the `read` method:

```swift
    /// Removes the generic-password item for the service/account pair.
    /// Deleting an item that does not exist is not an error — delete
    /// means "ensure absent".
    static func delete(_ key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: "Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to delete keychain item"])
        }
    }
```

In `Sources/SimpleConfig/ConfigItem.swift`, add to `SecureConfigItem` directly after its `write(_:)` method:

```swift
    /// Ensures no secret is stored for `key`. Deleting a secret that
    /// does not exist succeeds silently.
    ///
    /// - Throws: An error if the Keychain rejects the delete.
    public func delete() throws {
        try Keychain.delete(key, service: service)
    }
```

- [ ] **Step 4: Run tests to verify they pass — with a spec-mandated fallback**

Run: `swift test`

Expected: all tests pass. **However**, the `writeDeleteRoundTrip` test touches the real Keychain, and the spec says to include it only if the test runner can access the Keychain. If (and only if) it fails with a Keychain *access* error — e.g. `errSecMissingEntitlement` (-34018) or `errSecInteractionNotAllowed` (-25308) thrown from `write` — delete that one test and put this comment in its place, then re-run `swift test` until green:

```swift
    // A write→delete→read round-trip against the real Keychain is
    // deliberately omitted: the test runner lacks Keychain access
    // (see docs/specs/2026-07-03-configstorable-delete-design.md).
```

Any other failure (wrong value, item still present after delete) is a real bug: fix the implementation, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimpleConfig/Keychain.swift Sources/SimpleConfig/ConfigItem.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "feat: add SecureConfigItem.delete() backed by Keychain.delete"
```

---

### Task 3: Protocol requirement and design-doc update

**Files:**
- Modify: `Sources/SimpleConfig/ConfigStorable.swift` (add requirement)
- Modify: `docs/design.md` (three edits)

**Interfaces:**
- Consumes: `delete() throws` implementations on both conformers (Tasks 1–2). Adding the requirement before both exist would break the build — this task must run last.
- Produces: `func delete() throws` as a `ConfigStorable` protocol requirement.

- [ ] **Step 1: Add the protocol requirement**

In `Sources/SimpleConfig/ConfigStorable.swift`, inside `protocol ConfigStorable`, directly after the `write` requirement (`func write(_ value: String) throws`), add:

```swift
    /// Ensures no value is stored for `key`. Deleting a value that
    /// does not exist succeeds silently.
    func delete() throws
```

- [ ] **Step 2: Verify the build and full suite**

Run: `swift test`
Expected: builds cleanly (both conformers already implement `delete()`), all tests pass. If a conformer were missing the method, the error would be "type 'X' does not conform to protocol 'ConfigStorable'" — that means Task 1 or 2 was not completed.

- [ ] **Step 3: Update docs/design.md**

Read `docs/design.md`, then make exactly three edits:

1. In the **Architecture** intro paragraph, find the sentence describing the protocol as "a `key` plus throwing `read()`/`write(_:)`" (exact wording may vary slightly) and extend the operation list to include `delete()`, e.g. change `read()`/`write(_:)` to `read()`/`write(_:)`/`delete()`, adding: `delete()` is idempotent — deleting a missing value succeeds silently.

2. In the **Data Flow** section, append this sentence to the end of the existing paragraph:

   ```
   A `delete()` is idempotent on both paths: `ConfigItem` calls `removeObject(forKey:)` (a no-op for missing keys) and `SecureConfigItem` calls `SecItemDelete`, treating `errSecItemNotFound` as success.
   ```

3. In the **Document History** table, append this row:

   ```
   | 2026-07-03 | Added idempotent `delete()` to `ConfigStorable` and both conformers |
   ```

- [ ] **Step 4: Commit**

```bash
git add Sources/SimpleConfig/ConfigStorable.swift docs/design.md
git commit -m "feat: require delete() on ConfigStorable; update design doc"
```
