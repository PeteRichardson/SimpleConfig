# Config Groups (Property Wrappers) — Design Spec

*Date: 2026-07-05*
*Status: approved*

## Purpose

SimpleConfig manages individual items well, but a program's config is
usually a *struct* of related values, some plain and some secret. Today
each field means a separate `ConfigItem`/`SecureConfigItem` and a
separate throwing `read()`/`write()` call. This feature lets a user
declare a plain struct whose properties are live, storage-backed
values:

```swift
SimpleConfig.defaultDomain = "com.example.myapp"   // once, at startup

struct MyConfig: ConfigGroup {
    @Stored("defaultName") var defaultName: String = "Ernest"
    @Secure("apiKey")      var apiKey: String?
    @Secure("cert")        var cert: Data?
}

var config = try MyConfig.read()      // construct + validate every field
config.defaultName = "Gladys"         // written to UserDefaults immediately
print("Hello, \(config.defaultName)!")
```

## Decisions (and Rejected Alternatives)

**Live properties, not snapshot read/write.** Each `get` reads storage
and each `set` writes immediately, `@AppStorage`-style. A snapshot
model (`read()` pulls all values into memory, `write()` persists them
all) was considered and rejected in favor of the idiom Apple-platform
developers already know. `MyConfig.read()` (below) recovers the
one-line-load ergonomics on top of live semantics.

**Read-time fallback, never write-the-default.** The declared default
(`= "Ernest"`) is returned when nothing is stored; it is *never*
written to storage. Storage holds only explicit assignments — user
decisions — while defaults live in code, so shipping a new default in
a program update takes effect for every user who never customized the
value. Two alternatives were rejected:

- *Write-at-init:* clobbers user customizations on every launch (can't
  distinguish "never customized" from "customized to something else").
- *Provenance tagging* (store a source marker alongside each value;
  overwrite only program-default-sourced values): behaviorally
  identical to read-time fallback inside the program, doubles every key
  (value + tag), and breaks on external writes — a `defaults write`
  from the command line doesn't update the tag, so the next launch
  clobbers exactly the users most likely to notice.

This matches the philosophy of `UserDefaults.register(defaults:)`. The
accepted trade-off: external tools reading storage directly see "no
value," not the default.

**Errors: default + projected error, not silent, not trapping.**
Property wrapper accessors cannot throw, so failures fall back to the
default (reads) or are dropped (writes), with the error recorded in
`$property.lastError`. Silent-swallow (indistinguishable from "not
set") and `fatalError` (a locked Keychain at launch would crash the
app) were both rejected.

**Global default domain with per-property override.** Wrappers on a
struct cannot reach enclosing-type state, so the suite/service name is
resolved per access as `explicit argument ?? SimpleConfig.defaultDomain`.
Apps set the global once at startup; per-property `suite:`/`service:`
overrides remain for exceptions.

**Hand-written wrappers, not macros.** An attached macro
(`@ConfigGroup` synthesizing everything) would drag in a macro target
and the swift-syntax dependency — rejected for a package whose identity
is "small, zero dependencies." Two distinct wrappers (`@Stored`,
`@Secure`) rather than one parameterized wrapper, so the security
boundary is visible at the declaration site.

**Supported types: `String`, `String?`, `Data`, `Data?`.** Exactly what
SimpleConfig can store. Optionals read `nil` when unset; assigning
`nil` deletes the stored value. Non-optionals require a declared
default.

## Components

Three new files in `Sources/SimpleConfig/`; the existing
`ConfigStorable`, `ConfigItem`, `SecureConfigItem`, and `Keychain` do
not change at all — the wrappers are purely a layer on top.

### `ConfigValue.swift`

A protocol mapping each supported type onto the right existing calls:

```swift
public protocol ConfigValue {
    static func read(from item: ConfigItem) throws -> Self?
    static func read(from item: SecureConfigItem) throws -> Self?
    func write(to item: ConfigItem) throws
    func write(to item: SecureConfigItem) throws
}
```

- `String` conforms via `read()`/`write(_ value:)`.
- `Data` conforms via `readData()`/`write(_ data:)`.
- `Optional` conforms conditionally (`where Wrapped: ConfigValue`):
  reading passes through (`nil` stays `nil`); writing `nil` calls the
  item's existing `delete()`, writing non-`nil` delegates to the
  wrapped value.

The protocol must be `public` (it appears in the wrappers' generic
constraints) but is not a customization point — the four shipped
conformances are the complete set, and its doc comment says so.

### `Stored.swift` and `Secure.swift`

Two structurally identical wrappers differing only in backing type:

```swift
@propertyWrapper
public struct Stored<Value: ConfigValue> {
    public init(wrappedValue: Value, _ key: String, suite: String? = nil)
    public var wrappedValue: Value { get set }   // nonmutating get, mutating set
    public var projectedValue: StoredProjection<Value> { get }
}

@propertyWrapper
public struct Secure<Value: ConfigValue> {
    public init(wrappedValue: Value, _ key: String, service: String? = nil)
    // same shape; SecureProjection<Value>
}
```

For an optional `Value`, `wrappedValue` defaults to `nil`, so
`@Secure("apiKey") var apiKey: String?` needs no `= nil`.

Each wrapper stores the key, the optional explicit domain, the default
value, and an internal reference-type *error box* (getters must record
errors without mutating the struct). The underlying
`ConfigItem`/`SecureConfigItem` is constructed on **each access** from
`explicitDomain ?? SimpleConfig.defaultDomain` — the items are trivial
two-string structs, so there is nothing worth caching, and late
construction is what lets `defaultDomain` be set after the struct type
is defined. If neither domain exists, the access records
`ConfigError.noDomain` and behaves as a failed read/write.

Accessor behavior:

- `get`: build item, `Value.read(from:)`; on success return the value
  (or the default if `nil` for non-optional `Value` — for optional
  `Value`, `nil` *is* the value) and clear `lastError`; on throw,
  record the error and return the default.
- `set`: build item, `value.write(to:)`; on success clear `lastError`;
  on throw, record the error and drop the write (the next read reflects
  storage, not the attempted value).

The projection exposes:

```swift
public struct StoredProjection<Value: ConfigValue> {
    public var item: ConfigItem?      // nil when no domain resolves
    public var lastError: Error?      // most recent op's error; nil after success
}
```

`lastError` is per-wrapper-instance (it lives in the error box), so two
copies of a config struct have independent error state — acceptable for
a diagnostic affordance. Anyone needing throwing behavior uses
`$property.item` to reach the underlying item's throwing API.

### `SimpleConfig.swift`

A caseless `public enum SimpleConfig` namespace holding
`static var defaultDomain: String?` (initially `nil`), guarded by a
`Mutex` for Swift 6 strict concurrency.

### `ConfigGroup` (in `SimpleConfig.swift` or its own file)

```swift
public protocol ConfigGroup {
    init()
}

extension ConfigGroup {
    /// Probes every @Stored/@Secure property once; empty means healthy.
    public var configErrors: [String: Error] { get }
    public var isConfigValid: Bool { configErrors.isEmpty }

    /// Construct + validate in one call. Throws
    /// `ConfigError.invalidGroup(_:)` if any property fails to read.
    public static func read() throws -> Self
}
```

The `init()` requirement is satisfied automatically: every wrapped
property has a default (non-optionals must declare one; optionals
default to `nil`), so the struct's synthesized no-argument initializer
exists.

`configErrors` uses `Mirror` to find each wrapper (they conform to a
small internal probing protocol with a `probe() -> Error?` method that
performs one read), collecting failures keyed by property name (with
the wrapper's leading `_` stripped from the mirror label). Reflection
is read-only here and costs microseconds — fine for a startup check.
Probing matters because construction touches no storage: immediately
after `MyConfig()`, every `lastError` is `nil` no matter how broken
storage is, so an aggregate check must *perform* reads, not inspect
flags.

`read()` is `Self()` + `configErrors` + throw-if-non-empty. It
validates at that moment; properties stay live afterward, so a later
access can still fail (e.g. the Keychain locks) — `$property.lastError`
remains the tool for that.

### `ConfigError` additions

Two new cases:

- `noDomain` — no explicit `suite:`/`service:` and
  `SimpleConfig.defaultDomain` unset; message points at
  `SimpleConfig.defaultDomain`.
- `invalidGroup([String: Error])` — thrown by `ConfigGroup.read()`,
  carrying per-property failures.

Both are library-level configuration errors, which is `ConfigError`'s
job. The known open question about migrating *Keychain* errors to
`ConfigError` stays out of scope, as before.

## Error Handling Summary

The wrappers never throw and never crash. Failed read → declared
default + `lastError`. Failed write → not persisted + `lastError`; the
property visibly retains its old value. `lastError` holds the most
recent operation's error and is cleared by a subsequent success.
Aggregate checking goes through `ConfigGroup`: `try MyConfig.read()`
at startup, or `configErrors` on demand. No logging, no notifications,
no callbacks.

## Explicitly Unchanged / Out of Scope

- `ConfigStorable`, `ConfigItem`, `SecureConfigItem`, `Keychain` — no
  source changes.
- No macro target, no external dependencies.
- No typed/Codable values beyond `String`/`Data` and their optionals.
- No caching of the underlying items or values.
- No Keychain-error → `ConfigError` migration (separate, tracked).

## Testing (TDD — tests written first, watched to fail)

Appended to `Tests/SimpleConfigTests/SimpleConfigTests.swift`, real
UserDefaults suites and real Keychain, `defer`-based cleanup, ~20
tests.

**`@Stored` / `@Secure` behavior** (fixtures use *explicit*
`suite:`/`service:`):
1. Unset key reads the declared default; after assignment, reads the
   stored value.
2. Assigning `nil` to an optional property deletes the stored value
   (verified via a raw item on the same key).
3. `Data` and `Data?` round-trip through both wrappers.
4. The default is never written: after a read-only access, a raw item
   on the same key still reads `nil`.
5. `$property.item` reaches the underlying item; `$property.lastError`
   is `nil` after a successful operation.
6. Failed read (reserved suite name, e.g. `UserDefaults.globalDomain`)
   returns the default and sets `lastError`; a subsequent successful
   operation clears it.

**`ConfigGroup`:**
7. `configErrors` is empty for a healthy struct; keyed by property name
   for a fixture mixing one good and one bad-suite property.
8. `read()` returns a working instance on success; throws
   `ConfigError.invalidGroup` with the right keys on failure.
9. A struct mixing `@Stored` and `@Secure` probes both backends.

**`defaultDomain`** — process-global state, and Swift Testing runs
suites in parallel, so *all* tests touching it live in one suite marked
`.serialized`, which sets the domain, exercises fallback resolution
(no-argument wrapper uses it; no domain at all yields
`ConfigError.noDomain` in `lastError`/`configErrors`), and restores
`nil` afterward. Every other suite uses explicit domains and never
reads the global.

## Documentation

- `docs/design.md`: new Components entries for the wrappers,
  `ConfigValue`, `ConfigGroup`, and the `SimpleConfig` namespace; a
  Data Flow paragraph on live access, read-time fallback, and error
  funneling; a Document History row.
- `README.md`: a config-group example in Quick Start; API section
  additions for `@Stored`/`@Secure`/`ConfigGroup.read()`; note the
  read-time-fallback semantics for defaults.
