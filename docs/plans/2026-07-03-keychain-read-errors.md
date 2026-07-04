# Fix Keychain.read Error Collapsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Keychain.read` throw for genuine Keychain failures instead of silently collapsing them to `nil`, matching the pattern already used by `Keychain.write`/`delete`/`accounts`.

**Architecture:** Extract the OSStatus branching into a small internal helper, `Keychain.isPresent(_:) throws -> Bool`, that returns `true`/`false` for success/not-found and throws for anything else. `read()` calls it and keeps its existing UTF-8 decode step unchanged. The helper is unit-testable without needing a real Keychain failure.

**Tech Stack:** Swift 6.2 package, Security framework (Keychain generic passwords), Swift Testing framework (`@Test`, `#expect`) — NOT XCTest.

**Spec:** `docs/specs/2026-07-03-keychain-read-errors-design.md`

## Global Constraints

- TDD: write the tests, watch them fail for the right reason, then implement. Run with `swift test`.
- `Keychain.read` branches three ways: `errSecSuccess` → decode (unchanged); `errSecItemNotFound` → `nil`; any other status → throw `NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to read keychain item"])`.
- A successful status whose bytes aren't valid UTF-8 still returns `nil`, not a throw — unchanged from today's behavior, deliberate (see spec).
- Do NOT migrate `Keychain.write`, `Keychain.delete`, or `Keychain.accounts` to use the new `isPresent` helper — they already have correct, working inline logic; touching them is out of scope.
- Do NOT introduce `ConfigError` for Keychain failures — that's a separate, already-tracked open question; stay with the existing `NSError(domain: "Keychain")` pattern.
- Doc comments use `///` style matching the existing files.
- Commit only the files named in each task.

---

### Task 1: `Keychain.isPresent` helper and `Keychain.read` rewire

**Files:**
- Modify: `Sources/SimpleConfig/Keychain.swift` (add helper, rewrite `read`)
- Modify: `Sources/SimpleConfig/ConfigItem.swift` (update `SecureConfigItem.read()` doc comment)
- Test: `Tests/SimpleConfigTests/SimpleConfigTests.swift` (append two new suites)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `static func isPresent(_ status: OSStatus) throws -> Bool` on `Keychain` (internal, reachable in tests via `@testable import SimpleConfig` — same visibility pattern as `SecureConfigItem.redact`). `Keychain.read`'s public throwing behavior changes; no signature change.

- [ ] **Step 1: Write the failing tests for `isPresent`**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `type 'Keychain' has no member 'isPresent'`.

- [ ] **Step 3: Implement `isPresent` and rewire `read`**

In `Sources/SimpleConfig/Keychain.swift`, replace the existing `read` method (including its doc comment) with:

```swift
    /// `true` if `status` is `errSecSuccess`, `false` if
    /// `errSecItemNotFound`; throws for any other status.
    ///
    /// - Throws: `NSError(domain: "Keychain")` for a genuine failure status.
    static func isPresent(_ status: OSStatus) throws -> Bool {
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw NSError(
            domain: "Keychain", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Unable to read keychain item"])
    }

    /// Returns the stored secret for the service/account pair, or `nil`
    /// if there is none, or if the stored bytes aren't valid UTF-8.
    ///
    /// - Throws: An error for a genuine Keychain failure (e.g.
    ///   `errSecInteractionNotAllowed` while the device is locked) —
    ///   distinct from "not found", which returns `nil`.
    static func read(_ key: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard try isPresent(status) else { return nil }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass, including the 3 new `isPresent` tests (25 existing + 3 = 28).

- [ ] **Step 5: Update `SecureConfigItem.read()`'s doc comment**

In `Sources/SimpleConfig/ConfigItem.swift`, replace:

```swift
    /// Reads the secret from the Keychain.
    ///
    /// - Returns: The stored secret, or `nil` if none exists.
    public func read() throws -> String? {
        try Keychain.read(key, service: service)
    }
```

with:

```swift
    /// Reads the secret from the Keychain.
    ///
    /// - Returns: The stored secret, or `nil` if none exists.
    /// - Throws: An error if the Keychain read fails for a reason other
    ///   than the secret being absent.
    public func read() throws -> String? {
        try Keychain.read(key, service: service)
    }
```

- [ ] **Step 6: Add regression coverage for `Keychain.read` against the real Keychain**

Append to `Tests/SimpleConfigTests/SimpleConfigTests.swift` (this confirms the rewired `read()` still behaves correctly end-to-end through the real Keychain; both cases already pass under the pre-refactor code too, so this step is a regression guard for the refactor, not a new-behavior RED/GREEN cycle):

```swift
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
```

Run: `swift test`
Expected: all tests pass (28 + 2 = 30).

- [ ] **Step 7: Commit**

```bash
git add Sources/SimpleConfig/Keychain.swift Sources/SimpleConfig/ConfigItem.swift Tests/SimpleConfigTests/SimpleConfigTests.swift
git commit -m "fix: throw on genuine Keychain.read failures instead of returning nil"
```

---

### Task 2: Documentation (design doc)

**Files:**
- Modify: `docs/design.md` (four edits)

**Interfaces:**
- Consumes: the exact behavior from Task 1 (`Keychain.isPresent`, the three-way branch in `Keychain.read`).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Update docs/design.md**

Read `docs/design.md`, then make exactly four edits:

1. In the **Components** section's `Keychain` entry, find the sentence "This type is deliberately not public — consumers go through `SecureConfigItem`." and add directly before it:

   ```
   `read` distinguishes three outcomes: a successful fetch, an absent item (`errSecItemNotFound`), and a genuine failure — the first two return the decoded string or `nil` respectively, the third throws, via the internal `isPresent` helper.
   ```

2. In the **Data Flow** section, find the sentence "A `read()` builds the matching query, asks the Keychain for one result as `Data`, and decodes it as UTF-8, returning `nil` if the item doesn't exist." and replace it with:

   ```
   A `read()` builds the matching query and asks the Keychain for one result as `Data`; `errSecItemNotFound` and a successful-but-non-UTF8 decode both return `nil`, while any other non-success status throws.
   ```

3. In the **Open Questions** section, delete the entire bullet that begins "`Keychain.read` swallows all error statuses" (the issue is now fixed).

4. In the **Document History** table, append:

   ```
   | 2026-07-03 | `Keychain.read` throws for genuine failures instead of collapsing them to `nil` (resolves former open question) |
   ```

- [ ] **Step 2: Verify the build still passes**

Run: `swift test`
Expected: all 30 tests pass (docs-only change; this catches accidental source edits).

- [ ] **Step 3: Commit**

```bash
git add docs/design.md
git commit -m "docs: update design doc for Keychain.read error handling fix"
```
