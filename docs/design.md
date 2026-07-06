# SimpleConfig — Design Document

*Last updated: 2026-07-05*

---

## Overview

SimpleConfig is a small Swift package that gives applications a uniform way to read and write string key-value configuration on Apple platforms, with a choice of backend per item: `UserDefaults` for ordinary settings, or the Keychain for secrets such as API keys. It exists so that consuming apps can treat plain and sensitive configuration identically at the call site, without touching the Security framework directly.

## Goals and Non-Goals

**Goals:**
- A single, minimal abstraction (`ConfigStorable`) over both plain and secure storage
- Zero external dependencies — Foundation and Security only
- Safe display of secrets (redacted `description` for Keychain-backed items)

**Non-Goals:**
- Configuration file parsing (JSON, plist, TOML, etc.)
- Cross-platform (non-Apple) support — both backends are Apple OS services

---

## Architecture

The package is a single library target with nine source files, organized around one protocol and two conforming value types, plus a property-wrapper layer for struct-of-config ("config group") access.

`ConfigStorable` is the core abstraction: a `key` plus throwing `read()`/`write(_:)`/`delete()`. The `delete()` operation is idempotent — deleting a missing value succeeds silently. Static enumerators (`ConfigItem.items(inSuite:)`, `SecureConfigItem.items(inService:)`) list a namespace's items sorted by key, and a `Sequence` extension, `keyValuePairs()`, converts items to plain `(key, value)` tuples — the string view, which throws on read errors and drops values that don't read as strings. `ConfigStorable` itself stays String-only; both concrete types additionally offer `readData()`/`write(_ data: Data)` for binary values, added directly to `ConfigItem` and `SecureConfigItem` rather than to the protocol. It also requires `Comparable` and `CustomStringConvertible`, and a protocol extension supplies defaults for both — items sort by key, and the default `description` renders `key = value` (or `(not set)`). This lets a consuming app hold a heterogeneous collection of config items, sort them, and print them without caring which backend each one uses.

On top of the item types sits an optional property-wrapper layer: `@Stored` and `@Secure` make struct properties live storage-backed values, and the `ConfigGroup` protocol turns such a struct into a validated unit (`try MyConfig.read()`).

### Components

**ConfigItem** (`Sources/SimpleConfig/ConfigItem.swift`)
The plain-storage implementation. Each item carries a `suiteName` and a `key`, and reads/writes through `UserDefaults(suiteName:)`. The suite name is caller-supplied, so multiple apps or tools can share (or isolate) their settings domains. `readData()`/`write(_ data: Data)` use `UserDefaults`'s native `Data` accessors; because `UserDefaults` stores `String` and `Data` as distinct property-list types per key, writing one type makes the other accessor return `nil` — there is no cross-type conversion.

**SecureConfigItem** (`Sources/SimpleConfig/ConfigItem.swift`)
The secret-storage implementation. Each item carries a `service` and a `key`, mapping onto the Keychain's generic-password service/account model. Its `description` overrides the protocol default to redact the value, showing only the first and last six characters — secrets can appear in logs or listings without being fully exposed. The service name was originally hardcoded and is now passed in by the caller (see Key Design Decisions). `readData()`/`write(_ data: Data)` expose the Keychain's underlying bytes directly; since the Keychain stores one blob per item with no type tag, a `String` written this way is still readable via `readData()` (its UTF-8 bytes), and `Data` written this way is still readable via `read()` if it happens to decode as valid UTF-8 — the opposite of `ConfigItem`'s type-exclusive behavior.

**Keychain** (`Sources/SimpleConfig/Keychain.swift`)
An internal enum wrapping the Security framework's C-style API (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) for generic-password items. Writes use delete-then-add rather than update, which keeps the code simple at the cost of briefly removing the item. Items are stored with `kSecAttrAccessibleAfterFirstUnlock` so background processes can read them after a reboot once the device has been unlocked. `readData`/`write(_ data:for:service:)` are the byte-level primitives; `read`/`write(_ value: String, ...)` are thin wrappers that add a UTF-8 encode/decode step. `readData` (and so `read`) distinguishes three outcomes: a successful fetch, an absent item (`errSecItemNotFound`), and a genuine failure — the first two return the stored bytes (or `nil`) respectively, the third throws, via the internal `isPresent` helper. This type is deliberately not public — consumers go through `SecureConfigItem`.

**ConfigError** (`Sources/SimpleConfig/ConfigError.swift`)
A public error enum (`unableToLoad`, `unknown`) intended as the library's error surface. `ConfigItem` throws `.unableToLoad` when its `UserDefaults` suite can't be created (e.g. a reserved name like `NSGlobalDomain`); `Keychain` still throws raw `NSError` instead (see Open Questions).

**SimpleConfig** (`Sources/SimpleConfig/SimpleConfig.swift`)
A caseless enum namespace. Its one member, `defaultDomain: String?`, is the process-wide fallback for wrapper properties declared without an explicit `suite:`/`service:` — set once at app startup. It is guarded by an `NSLock` (not `Synchronization.Mutex`, which would force a macOS 15+ platform floor).

**ConfigValue** (`Sources/SimpleConfig/ConfigValue.swift`)
The protocol the wrappers are generic over, mapping each supported type onto the right item calls. Exactly four conformances ship — `String`, `Data`, and their optionals — and the protocol is public only because it appears in the wrappers' generic constraints; it is not a customization point. The `Optional` conformance encodes two decisions: an absent value reads as `.some(nil)` so optional properties read `nil` when unset instead of falling back to their default, and writing `nil` deletes the stored value.

**Stored / Secure** (`Sources/SimpleConfig/Stored.swift`, `Sources/SimpleConfig/Secure.swift`)
Structurally identical property wrappers over `ConfigItem` and `SecureConfigItem` respectively. Every `get` reads storage and every `set` writes immediately; the underlying item is rebuilt on each access so `defaultDomain` may be set after the struct type is defined. The declared default is a read-time fallback, never written to storage. Accessors cannot throw, so failures fall back to the default (reads) or are dropped (writes) and are recorded in a reference-type error box exposed through the projection: `$property.item` (the underlying item, or `nil` when no domain resolves) and `$property.lastError` (the most recent operation's error, cleared on success). Copies of a config struct share the error box; separately constructed instances do not.

**ConfigGroup** (`Sources/SimpleConfig/ConfigGroup.swift`)
A protocol whose only requirement, `init()`, is synthesized for any struct whose properties all have defaults — conformance is effectively free. Its extension supplies `configErrors` (a `Mirror`-based probe that performs one real read per wrapped property, recursing into members that are themselves `ConfigGroup`s and prefixing error keys with the property path, e.g. `"serverConfig.apiKey"`), `isConfigValid`, and `read()` — construct-and-validate in one call, throwing `ConfigError.invalidGroup` keyed by property path. Probing performs real reads because construction touches no storage: right after `MyConfig()`, every `lastError` is `nil` no matter how broken storage is. Nesting is code organization only — keys stay flat within the domain.

### Data Flow

When an app calls `write("secret")` on a `SecureConfigItem`, the item forwards to `Keychain.write`, which builds a generic-password query from the item's service and key, deletes any existing entry, and adds the new one, throwing on any non-success status. A `read()` builds the matching query and asks the Keychain for one result as `Data`; `errSecItemNotFound` and a successful-but-non-UTF8 decode both return `nil`, while any other non-success status throws. The `ConfigItem` path is the same shape but delegates to `UserDefaults`, throwing `ConfigError.unableToLoad` if the suite name is invalid (e.g. `NSGlobalDomain` or the app's own bundle identifier); once the suite resolves, reads and writes themselves cannot fail.

A `delete()` is idempotent on both paths: `ConfigItem` calls `removeObject(forKey:)` (a no-op for missing keys) and `SecureConfigItem` calls `SecItemDelete`, treating `errSecItemNotFound` as success.

Enumeration never reads secret values: `SecureConfigItem.items(inService:)` asks the Keychain for attributes only (`kSecReturnAttributes`, via the internal `Keychain.accounts`), and `ConfigItem.items(inSuite:)` reads the suite's `persistentDomain(forName:)` — not `dictionaryRepresentation()`, which would merge in the global domain. Listing config is therefore safe to display; extracting plaintext requires an explicit chained `keyValuePairs()` call.

`readData()`/`write(_ data: Data)` add binary storage on both concrete types, with opposite backend behavior. `ConfigItem` stores `String` and `Data` as distinct `UserDefaults` property-list types per key — writing one type makes the other accessor return `nil`, with no conversion. `SecureConfigItem` has no such distinction, since the Keychain stores one untyped blob of bytes per item — `write(_ value: String)` followed by `readData()` always succeeds (the UTF-8 bytes), and `write(_ data: Data)` followed by `read()` succeeds only if those bytes happen to decode as valid UTF-8. `description` on both types falls back to reporting the stored byte count (`(binary value, N bytes)`) instead of the misleading `(not set)` when a value exists only as `Data`; on `SecureConfigItem` this fallback lookup is `@autoclosure`, so a normal string-valued secret's `description` still costs exactly one Keychain read.

The wrapper layer routes everything through the same item calls. Reading `config.host` builds a `ConfigItem` from the property's explicit suite or `SimpleConfig.defaultDomain`, calls `read()` (or `readData()` for `Data` properties, via the `ConfigValue` conformances), and returns the stored value or the declared read-time default; assignment is a `write(_:)` and assigning `nil` to an optional property is a `delete()`. No failure escapes as a thrown error — reads fall back to the default, writes are dropped, and either way the error lands in `$property.lastError`. `try MyConfig.read()` performs one probe read per wrapped property (nested groups recursively) and throws `ConfigError.invalidGroup` if any fail, giving startup code a single validation point; properties stay live afterward.

---

## Key Design Decisions

**Protocol-based backend selection.** Rather than one config type with a mode flag, each backend is its own struct conforming to `ConfigStorable`. The caller decides sensitivity item-by-item at construction time, and everything downstream (display, sorting, read/write) is uniform.

**Caller-supplied namespaces.** Both the `UserDefaults` suite name and the Keychain service name are constructor parameters rather than constants baked into the library (the service name was hardcoded until commit `5015c76`). This keeps the package reusable across apps and lets one app partition its configuration.

**Redaction over omission.** `SecureConfigItem.description` shows a few characters from each end of a secret rather than hiding it entirely — enough to confirm which value is stored without revealing it. The visible count scales with length (`SecureConfigItem.redact`): secrets under 5 characters are hidden completely, at most 6 characters show per side, at least 3 characters always stay hidden, and the mask is a fixed 20 dots so output doesn't leak the secret's length.

**Read-time fallback for wrapper defaults.** A wrapped property's declared default (`= "Ernest"`) is returned when nothing is stored, and is never written to storage. Storage holds only user decisions; defaults live in code, so a program update with a new default takes effect for every user who never customized the value. Write-at-init was rejected because it clobbers customizations, and provenance tagging (a stored source marker per value) was rejected because external writes — e.g. the `defaults` CLI — bypass the tag and reintroduce the clobbering for exactly the users most likely to notice. This matches the philosophy of `UserDefaults.register(defaults:)`.

No ADRs exist yet; the rationale above is inferred from the code and git history.

---

## External Dependencies

None beyond the platform. The package uses only Foundation (`UserDefaults`) and Security (Keychain); `Package.swift` declares no external packages.

---

## Configuration and Environment

Nothing to configure. Development requires a Swift 6.2 toolchain on an Apple platform (the Keychain and `UserDefaults` backends need macOS/iOS). Build with `swift build`, test with `swift test`; tests use the Swift Testing framework (`@Test` / `#expect`), not XCTest.

---

## Open Questions

- [ ] `Keychain.write` still throws an ad-hoc `NSError` (with a misleading hardcoded message, "Unable to save API key") instead of `ConfigError`, which `ConfigItem` now uses. Should the library standardize on `ConfigError` throughout?
- [ ] There is no test coverage of either storage backend (the redaction logic is tested).

---

## Document History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial document generated from codebase |
| 2026-07-03 | Length-aware redaction in `SecureConfigItem` (resolves former open question) |
| 2026-07-03 | Removed crash paths: `ConfigItem` throws `ConfigError` on invalid suite; `description` renders read failures instead of `try!` |
| 2026-07-03 | Added idempotent `delete()` to `ConfigStorable` and both conformers |
| 2026-07-03 | Added enumeration (`items(inSuite:)`, `items(inService:)`, `Keychain.accounts`) and `keyValuePairs()` |
| 2026-07-03 | `Keychain.read` throws for genuine failures instead of collapsing them to `nil` (resolves former open question) |
| 2026-07-03 | Added `readData()`/`write(_ data: Data)` to `ConfigItem` and `SecureConfigItem`; `description` on both types renders binary values by byte count |
| 2026-07-05 | Added the property-wrapper layer: `@Stored`/`@Secure`, `ConfigValue`, `ConfigGroup` (with recursive probing and `read()`), `SimpleConfig.defaultDomain`, and `ConfigError.noDomain`/`.invalidGroup` |
