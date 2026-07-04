# Data-Valued Storage — Design Spec

*Date: 2026-07-03*
*Status: approved*

## Purpose

`ConfigStorable` is string-only today ("Typed values" is a documented
Non-Goal in `docs/design.md`), so anything binary — certificate bytes,
raw key material, random tokens, serialized blobs — must be
base64-encoded by the caller before storing it, inflating size ~33% and
adding boilerplate. Both backends already store bytes natively
underneath: the Keychain's `kSecValueData` is `Data`, and today's
`Keychain.write`/`read` are already a UTF-8 encode/decode layer on top
of it; `UserDefaults` has first-class `data(forKey:)`/`set(_:forKey:)`.
This is the third of three planned additions (after `delete()` and
enumeration).

Both the `delete()` fix's sequencing and the enumeration feature's
"Explicitly NOT prep for Data" section anticipated this: enumeration is
already type-blind (a `Data`-valued key still enumerates, per
`nonStringValueEnumerated`), and `Keychain.isPresent` (added when
`Keychain.read`'s error collapsing was fixed) is designed to be reused
by a Keychain `Data` primitive.

## API

New methods on the concrete types only — **not** added to
`ConfigStorable`. The protocol's job is to be the uniform *String*
abstraction ("Typed values... is the caller's job" stays true for the
protocol itself; only its two concrete conformers gain the extra
capability), matching how `items(inSuite:)`/`items(inService:)` were
added as concrete methods rather than protocol requirements.

```swift
extension ConfigItem {
    public func readData() throws -> Data?
    public func write(_ data: Data) throws
}

extension SecureConfigItem {
    public func readData() throws -> Data?
    public func write(_ data: Data) throws
}
```

`write` is a same-name overload distinguished by parameter type
(`write(_ value: String)` already exists; `write(_ data: Data)` is
added alongside it — unambiguous, since `String` and `Data` share no
overload-resolution surface). `read()` cannot be overloaded by return
type alone, so the Data-returning read gets its own name: `readData()`.

## Backend Behavior — Two Different Asymmetries

**`ConfigItem` / `UserDefaults`:** String and Data are genuinely
different property-list types stored under the same key — writing one
does not make the other accessor succeed. `write(_ value: String)`
followed by `readData()` returns `nil`; `write(_ data: Data)` followed
by `read()` returns `nil`. No conversion is attempted in either
direction. A key holds exactly one type at a time; the most recent
write fully determines which accessor will succeed.

- `readData()` → `defaults.data(forKey: key)`, through the existing
  throwing `defaults` accessor (so an invalid suite name throws
  `ConfigError.unableToLoad`, exactly as `read`/`write`/`delete` do).
- `write(_ data: Data)` → `defaults.set(data, forKey: key)`, same
  accessor.

**`SecureConfigItem` / `Keychain`:** the Keychain stores one blob of
raw bytes per item with no type tag — there is no "wrong type" to
reject. `write(_ value: String)` followed by `readData()` succeeds
(returns the UTF-8 bytes of the string that was written).
`write(_ data: Data)` followed by `read()` succeeds *if* those bytes
happen to decode as valid UTF-8, and returns `nil` otherwise — the
existing, already-correct "read() is the string view" behavior, simply
now reachable through a deliberate binary write instead of only through
external interference.

Refactor `Keychain.swift` so the byte-level operations are the
primitives and the string operations are thin wrappers (DRY, and sets
up cleanly for reuse):

```swift
static func readData(_ key: String, service: String) throws -> Data? {
    // same query as today's `read`, reusing `isPresent` (added in the
    // Keychain.read error-collapsing fix); returns the raw Data
    // instead of decoding it.
}

static func read(_ key: String, service: String) throws -> String? {
    guard let data = try readData(key, service: service) else { return nil }
    return String(data: data, encoding: .utf8)
}

static func write(_ data: Data, for key: String, service: String) throws {
    // same query/delete-then-add/error-throw logic as today's `write`,
    // just storing `data` directly instead of UTF-8-encoding a string first.
}

static func write(_ value: String, for key: String, service: String) throws {
    try write(value.data(using: .utf8)!, for: key, service: service)
}
```

No changes to `Keychain.delete` or `Keychain.accounts` — both already
operate at the key/item level regardless of value type.

## `description` — Distinguishing "Absent" from "Present but Binary"

Today, a value stored only as `Data` renders as `(not set)` — visible
already in the enumeration feature's `nonStringValueEnumerated` test.
That's misleading now that binary storage is a first-class,
intentional capability: something *is* stored. Both types gain (or, for
`SecureConfigItem`, extend) a testable static `describe` helper that
falls back to reporting the byte count when the string view comes back
empty:

```swift
// ConfigItem (new)
static func describe(key: String, stringValue: String?, dataByteCount: Int?) -> String {
    if let stringValue { return "\(key) = \(stringValue)" }
    if let dataByteCount { return "\(key) = (binary value, \(dataByteCount) bytes)" }
    return "\(key) = (not set)"
}

public var description: String {
    Self.describe(key: key, stringValue: try? read(), dataByteCount: (try? readData())?.count)
}
```

```swift
// SecureConfigItem (extends the existing `describe`)
static func describe(
    key: String, result: Result<String?, Error>,
    dataByteCount: @autoclosure () -> Int? = nil
) -> String {
    switch result {
    case .success(let value?): return "\(key) = \(redact(value))"
    case .success(nil):
        if let count = dataByteCount() { return "\(key) = (binary value, \(count) bytes)" }
        return "\(key) = (not set)"
    case .failure(let error): return "\(key) = (unreadable: \(error))"
    }
}

public var description: String {
    Self.describe(key: key, result: Result { try read() }, dataByteCount: (try? readData())?.count)
}
```

`dataByteCount` is `@autoclosure` with a default of `nil` on the
`SecureConfigItem` side specifically: a Keychain round-trip has real
(if small) IPC cost, and the vast majority of calls resolve in the
`.success(let value?)` or `.failure` branches, which never invoke the
closure — so a normal string-valued secret's `description` still costs
exactly one Keychain read, not two. The default `= nil` also means the
three existing `DescriptionTests` call sites (which call `describe`
with two arguments) keep compiling unchanged. `ConfigItem`'s version
skips the autoclosure — a second `UserDefaults` lookup has no
comparable cost, so the extra formality isn't worth it — but keeps the
same three-way shape for consistency between the two `describe`
helpers.

Byte count, not content, is shown for both types: safe for
`SecureConfigItem` too, since a length alone reveals nothing about the
secret's bytes (unlike the string redaction, there's no adjacent
"visible characters" leak to reason about here).

## Explicitly Unchanged / Out of Scope

- **`delete()`** — already key-level and type-agnostic; no change.
- **`items(inSuite:)`/`items(inService:)`** — already type-blind and
  already tested against a planted `Data` value; no change.
- **`keyValuePairs()`** — stays "the string view": still calls `read()`
  only, still drops values that come back `nil` (now including
  deliberately-binary ones, not just accidental non-string values). No
  behavior change — only its doc comment is reworded so "unreadable via
  `read()`" doesn't imply "inaccessible," since `readData()` now exists.
  A parallel `dataPairs()`-style variant is not requested and is
  explicit YAGNI for this check-in.
- **No `ConfigError` migration** for Keychain errors (separate,
  already-tracked open question).
- **No generic/associated-type redesign** of `ConfigStorable` (rejected
  during the enumeration brainstorm; still rejected here).

## Testing (TDD — tests written first, watched to fail)

**`ConfigItem`:**
1. `write(Data)` → `readData()` round-trip returns the same bytes.
2. `write(Data)` → `read()` (String) returns `nil` (type mismatch).
3. `write(String)` → `readData()` returns `nil` (type mismatch, other direction).
4. `readData()` on a reserved suite name throws `ConfigError`.
5. `readData()` on a never-written key returns `nil`.
6. `ConfigItem.describe`: `stringValue` present → renders the string
   (existing behavior, now via the extracted helper); `stringValue` nil
   + `dataByteCount` present → `(binary value, N bytes)`; both nil →
   `(not set)`.

**`SecureConfigItem` / `Keychain` (real Keychain — prior check-ins
proved test-runner access):**
7. `write(Data)` → `readData()` round-trip returns the same bytes.
8. `write(Data)` with genuinely non-UTF8 bytes (e.g. `[0xFF, 0xFE]`) →
   `read()` returns `nil`.
9. `write(String)` → `readData()` returns the UTF-8 bytes of the string
   that was written (succeeds, demonstrating the reverse-of-`ConfigItem`
   asymmetry).
10. `SecureConfigItem.describe`: `dataByteCount` present + `result` is
    `.success(nil)` → `(binary value, N bytes)`; existing three cases
    (present/absent/failure) still pass unchanged with the default
    `nil` `dataByteCount`.
11. The `@autoclosure` is not invoked when unnecessary: pass a
    `dataByteCount` argument that increments a counter, assert the
    counter is still `0` after calling `describe` with `result: .success("value")`
    and again with `result: .failure(...)`.

## Documentation

- `docs/design.md`: remove "Typed values" from Non-Goals (no longer
  accurate); add a Components note on the new methods and the two
  backends' opposite asymmetries; a Data Flow paragraph; reword
  `keyValuePairs()`'s existing mention per above; a Document History row.
- `README.md`: a Data usage example in Quick Start; API table additions
  for `readData()`/`write(Data)`.
