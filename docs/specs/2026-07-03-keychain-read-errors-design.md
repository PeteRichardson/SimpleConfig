# Fix `Keychain.read` Error Collapsing — Design Spec

*Date: 2026-07-03*
*Status: approved*

## Purpose

`Keychain.read` treats every non-`errSecSuccess` status identically —
returning `nil` — so a genuine failure (e.g. `errSecInteractionNotAllowed`
on a locked device, `errSecAuthFailed`) is indistinguishable from "no
value set." This is a tracked open question in `docs/design.md`.
`Keychain.write`, `Keychain.delete`, and `Keychain.accounts` already
distinguish "expected empty/absent result" from "genuine failure" and
throw for the latter; `read` is the one operation still collapsing them.

This fix is sequenced before the planned `Data`-values feature: the
correct OSStatus-branching logic this fix introduces is exactly what a
future `readData()` would also need, so writing it once now (rather than
inside a larger, less-reviewable Data change, or duplicated across both
paths later) is the smaller total change.

## Behavior

`Keychain.read(_:service:)` after `SecItemCopyMatching`:

- `errSecSuccess` + bytes decode as UTF-8 → return the decoded string
  (unchanged).
- `errSecSuccess` + bytes do **not** decode as UTF-8 → return `nil`.
  `read()` is the string view of a value; bytes that exist but aren't
  representable as a string are indistinguishable from "not set" for
  this method — consistent with `ConfigItem.read()`'s treatment of
  non-string `UserDefaults` values and `keyValuePairs()`'s nil-drop
  semantics. (Reachable today only if another process wrote non-UTF8
  bytes to the same Keychain item; not reachable through this library's
  own public API yet.)
- `errSecItemNotFound` → return `nil` (unchanged).
- Any other status → throw `NSError(domain: "Keychain", code: Int(status),
  userInfo: [NSLocalizedDescriptionKey: "Unable to read keychain item"])`,
  matching the existing pattern in `Keychain.write`/`delete`/`accounts`.

## Implementation

In `Sources/SimpleConfig/Keychain.swift`, extract the status branch into
a small internal helper so the throw/no-throw decision is unit-testable
without a real Keychain failure:

```swift
/// `true` if `status` is `errSecSuccess`, `false` if `errSecItemNotFound`;
/// throws for any other status.
///
/// - Throws: `NSError(domain: "Keychain")` for a genuine failure status.
static func isPresent(_ status: OSStatus) throws -> Bool {
    if status == errSecSuccess { return true }
    if status == errSecItemNotFound { return false }
    throw NSError(
        domain: "Keychain", code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Unable to read keychain item"])
}
```

`read` becomes:

```swift
static func read(_ key: String, service: String) throws -> String? {
    let query: [String: Any] = [ /* unchanged */ ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard try isPresent(status) else { return nil }
    guard let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
```

No changes needed in `Keychain.write`, `Keychain.delete`, or
`Keychain.accounts` — they already implement equivalent branching
inline; adopting `isPresent` for them is explicitly out of scope (see
below).

## Callers

`SecureConfigItem.read()` forwards the throw unchanged — no code change,
only its doc comment needs updating (see Documentation). Its
`description` property already routes reads through
`Self.describe(key:result:)` (added when `delete()` was implemented),
which renders a thrown error as `key = (unreadable: ...)` rather than
crashing — no change needed there either; this fix simply makes that
existing crash-safety path reachable for the first time.

## Testing

Real Keychain failures (locked device, missing entitlement) aren't
reliably producible in an automated test, so the plan tests the two
decomposed halves separately:

1. **`Keychain.isPresent` directly** (unit-testable, no Keychain access
   needed): `errSecSuccess` → `true`; `errSecItemNotFound` → `false`;
   any other status (e.g. `errSecAuthFailed`) → throws. This is the
   actual throw/no-throw decision logic and is fully covered without
   needing a real failure.
2. **`Keychain.read` end-to-end against the real Keychain** (already
   provable — prior check-ins confirmed test-runner access): a
   never-written key returns `nil` without throwing (exercises the
   `errSecItemNotFound` path through the real API); a written key reads
   back correctly (exercises the success path, regression-guards the
   existing behavior).

## Documentation

- `docs/design.md`: remove the resolved open question; update the
  `SecureConfigItem`/`Keychain` components and data-flow paragraphs to
  describe the new three-way branch; add a Document History row.
- `Keychain.swift` doc comment on `read`: update to state it throws for
  genuine failures, not just returning `nil`.
- `ConfigItem.swift` doc comment on `SecureConfigItem.read()`: add a
  `- Throws:` line noting it can throw for Keychain failures beyond an
  absent value.

## Out of Scope

- Migrating `Keychain.write`/`delete`/`accounts` to also use the new
  `isPresent` helper (they already have equivalent, working inline
  logic; refactoring them is unrelated to this fix).
- Standardizing on `ConfigError` instead of `NSError` for Keychain
  failures (existing, separate open question in `docs/design.md`).
- The `Data`-values feature (next planned check-in; this fix is
  sequenced ahead of it deliberately, per Purpose above).
