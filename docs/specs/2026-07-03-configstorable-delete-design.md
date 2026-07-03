# ConfigStorable `delete()` — Design Spec

*Date: 2026-07-03*
*Status: approved*

## Purpose

`ConfigStorable` can set a value but never unset it — the most glaring gap
in the unified API. Both backends support removal natively
(`UserDefaults.removeObject(forKey:)`, `SecItemDelete`), so a `delete()`
requirement keeps the protocol's promise that every operation works
uniformly across backends with nothing faked.

This is the first of three planned additions identified from a survey of
the underlying APIs; enumeration and `Data` values follow as separate
check-ins.

## Contract

Add to `ConfigStorable`:

```swift
/// Ensures no value is stored for `key`. Deleting a value that does
/// not exist succeeds silently.
func delete() throws
```

Semantics: **idempotent** — `delete()` means "ensure absent," not "remove
the thing that must exist." Deleting a missing value is success, matching
both backends' natural behavior and the existing `Keychain.write`
delete-then-add pattern, which already ignores `errSecItemNotFound`.

## Implementation

**`ConfigItem`** (`Sources/SimpleConfig/ConfigItem.swift`)

```swift
public func delete() throws {
    try defaults.removeObject(forKey: key)
}
```

Uses the existing throwing `defaults` accessor, so an invalid suite name
throws `ConfigError.unableToLoad` exactly as `read`/`write` do.
`removeObject(forKey:)` is a no-op for missing keys — idempotency is free.

**`SecureConfigItem`** (same file) delegates to a new internal
`Keychain.delete(_:service:)`:

```swift
public func delete() throws {
    try Keychain.delete(key, service: service)
}
```

**`Keychain.delete`** (`Sources/SimpleConfig/Keychain.swift`) builds the
same generic-password service/account query as `read` (no
`kSecReturnData`/`kSecMatchLimit` keys) and calls `SecItemDelete`.
Status handling:

- `errSecSuccess` and `errSecItemNotFound` → success (idempotent)
- any other status → throw `NSError(domain: "Keychain", code: status)`,
  matching the existing `Keychain.write` error pattern

Standardizing Keychain errors on `ConfigError` is an existing open
question in `docs/design.md` and is deliberately **out of scope** — this
change introduces no new error cases and does not partially migrate.

## Testing (TDD — tests written first, watched to fail)

`ConfigItem`:
1. write → delete → read returns `nil` (round-trip removal)
2. delete on a never-written key succeeds silently
3. delete on a reserved suite name (`NSGlobalDomain`) throws `ConfigError`

`SecureConfigItem` / `Keychain`:
4. delete on a non-existent keychain item succeeds silently (runs without
   fixtures or entitlements)
5. write → delete → read returns `nil` against the real Keychain —
   include only if the test runner proves able to access the Keychain;
   otherwise tests 1–4 carry the contract and this is noted in the test
   file as a deliberate omission

## Documentation

Update `docs/design.md` in the same change: protocol description in the
Components section, the data-flow paragraph, and a Document History entry.

## Out of Scope

- Enumeration of all items in a suite/service (next check-in)
- `Data`-valued items (after enumeration)
- `ConfigError` standardization for Keychain errors (existing open question)
- An `exists` convenience (`read() != nil` already answers it)
