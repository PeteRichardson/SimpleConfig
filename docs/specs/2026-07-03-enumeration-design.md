# Enumeration + `keyValuePairs()` — Design Spec

*Date: 2026-07-03*
*Status: approved*

## Purpose

Config items can be read, written, and deleted individually, but there is no
way to discover what a suite or service contains — "show me all my config"
requires knowing every key in advance. Both backends support enumeration
natively (`UserDefaults.persistentDomain(forName:)`,
`SecItemCopyMatching` with `kSecMatchLimitAll`), so this check-in adds it,
plus a chained conversion from items to plain `(key, value)` pairs.

This is the second of three planned additions (after `delete()`, before
`Data` values).

## API

### `ConfigItem.items(inSuite:)`

```swift
/// All items stored in the given `UserDefaults` suite, sorted by key.
/// Every key in the suite is included regardless of its value's type;
/// an unused suite returns an empty array.
///
/// - Throws: `ConfigError.unableToLoad` if the suite name is invalid.
public static func items(inSuite suiteName: String) throws -> [ConfigItem]
```

Behavior:

- Validates the suite exactly as `read`/`write`/`delete` do (guard
  `UserDefaults(suiteName:)` non-nil, else throw
  `ConfigError.unableToLoad`), so reserved names like `NSGlobalDomain`
  throw instead of misbehaving.
- Reads `UserDefaults.standard.persistentDomain(forName: suiteName)` —
  deliberately NOT `dictionaryRepresentation()`, which merges in the
  global domain and other search-list domains.
- A `nil` domain (suite never written to) returns `[]`.
- Every key in the domain becomes a `ConfigItem`, **including keys whose
  stored value is not a `String`**. This is deliberate
  forward-compatibility for the planned `Data` feature: enumeration is
  type-blind. Note `string(forKey:)` coerces number values to strings, so
  a bool/int written by other code reads as `"1"`/`"42"`; values with no
  string form (`Data`, arrays, dictionaries) read as `nil`.
- Result sorted ascending by `key` (the existing `Comparable`), for
  deterministic output.

### `SecureConfigItem.items(inService:)`

```swift
/// All items stored under the given Keychain service, sorted by key.
/// Secret values are never read — enumeration is safe to display.
public static func items(inService service: String) throws -> [SecureConfigItem]
```

Behavior:

- Delegates to a new internal `Keychain.accounts(service: String) throws
  -> [String]`.
- `Keychain.accounts` queries `SecItemCopyMatching` with:
  `kSecClass = kSecClassGenericPassword`, `kSecAttrService = service`,
  `kSecMatchLimit = kSecMatchLimitAll`, `kSecReturnAttributes = true`
  (NOT `kSecReturnData` — values are never touched), and extracts
  `kSecAttrAccount` from each result dictionary.
- `errSecItemNotFound` → `[]` (an unused service is empty, not an error).
- Any other non-success status → `NSError(domain: "Keychain",
  code: Int(status))`, matching the existing `Keychain.write`/`delete`
  pattern. `ConfigError` standardization remains out of scope.
- Result sorted ascending by `key`.

### `keyValuePairs()`

```swift
extension Sequence where Element: ConfigStorable {
    /// The string view of these items: each item's key paired with its
    /// current value. Items whose value reads as `nil` (deleted since
    /// enumeration, or not representable as a string — e.g. a non-string
    /// UserDefaults value, or binary data once `Data` support lands) are
    /// dropped. Reading a `SecureConfigItem` sequence materializes every
    /// secret in plaintext — call deliberately.
    ///
    /// - Throws: The first error any item's `read()` throws.
    public func keyValuePairs() throws -> [(key: String, value: String)]
}
```

Behavior:

- Order-preserving: pairs come back in the sequence's order (sorted, when
  chained on `items(...)`).
- Returns tuples, not a `Dictionary`, so duplicate keys across
  concatenated sources cannot crash; callers wanting a dictionary use
  `Dictionary(_:uniquingKeysWith:)`.
- Throws on the first `read()` **error**; drops `nil` reads silently
  (documented as the string view).
- Lives in `ConfigStorable.swift`.
- Known limitation (documented in the doc comment or design doc): Swift
  existentials don't conform to their own protocols, so this is available
  on homogeneous sequences (`[ConfigItem]`, `[SecureConfigItem]`) but not
  on a mixed `[any ConfigStorable]`.

## Explicitly NOT prep for `Data` (YAGNI)

No `associatedtype Value` or generic value machinery on `ConfigStorable`.
The `Data` feature adds parallel `readData()`/`write(_ data: Data)`
methods later; enumeration and `keyValuePairs()` as specified already
tolerate non-string values (type-blind enumeration, nil-dropping).

## Testing (TDD — tests written first, watched to fail)

`ConfigItem.items(inSuite:)`:
1. Write 3 keys to a dedicated test suite → enumeration returns exactly
   those items, sorted by key (clean up afterward).
2. A never-used suite name returns `[]`.
3. A reserved suite name (`NSGlobalDomain`) throws `ConfigError`.
4. A `Data` value planted via raw `UserDefaults`
   (`set(Data([0xFF]), forKey:)`) still appears in enumeration; its
   `read()` returns `nil`. (`Data` is used, not a bool, because
   `string(forKey:)` coerces numbers to strings.)

`SecureConfigItem.items(inService:)` (real Keychain — the delete
check-in proved the test runner has access):
5. Write 2 secrets under a uniquely-named test service → enumeration
   returns exactly those 2, sorted → clean up via `delete()`.
6. A never-used service returns `[]`.

`keyValuePairs()`:
7. On the suite from test 1: pairs match the written keys/values, in
   sorted key order.
8. The planted `Data` value from test 4 is dropped from the pairs.
9. `[ConfigItem(suiteName: NSGlobalDomain, ...)].keyValuePairs()` throws
   (error propagation).

## Documentation

- `docs/design.md`: Components (new operations + `Keychain.accounts`),
  Data Flow (enumeration paragraph), Document History row.
- `README.md`: add an enumeration example to Quick Start / API section.

## Out of Scope

- `Data`-valued items (next check-in)
- `ConfigError` standardization for Keychain errors (existing open question)
- Enumeration across mixed backends in one call (callers concatenate)
- A dictionary-returning variant of `keyValuePairs()` (one initializer away)
