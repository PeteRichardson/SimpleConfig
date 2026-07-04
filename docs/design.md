# SimpleConfig — Design Document

*Last updated: 2026-07-03*

---

## Overview

SimpleConfig is a small Swift package that gives applications a uniform way to read and write string key-value configuration on Apple platforms, with a choice of backend per item: `UserDefaults` for ordinary settings, or the Keychain for secrets such as API keys. It exists so that consuming apps can treat plain and sensitive configuration identically at the call site, without touching the Security framework directly.

## Goals and Non-Goals

**Goals:**
- A single, minimal abstraction (`ConfigStorable`) over both plain and secure storage
- Zero external dependencies — Foundation and Security only
- Safe display of secrets (redacted `description` for Keychain-backed items)

**Non-Goals:**
- Typed values — everything is a `String`; encoding richer types is the caller's job
- Configuration file parsing (JSON, plist, TOML, etc.)
- Cross-platform (non-Apple) support — both backends are Apple OS services

---

## Architecture

The package is a single library target with four source files, organized around one protocol and two conforming value types.

`ConfigStorable` is the core abstraction: a `key` plus throwing `read()`/`write(_:)`/`delete()`. The `delete()` operation is idempotent — deleting a missing value succeeds silently. Static enumerators (`ConfigItem.items(inSuite:)`, `SecureConfigItem.items(inService:)`) list a namespace's items sorted by key, and a `Sequence` extension, `keyValuePairs()`, converts items to plain `(key, value)` tuples — the string view, which throws on read errors and drops values that don't read as strings. It also requires `Comparable` and `CustomStringConvertible`, and a protocol extension supplies defaults for both — items sort by key, and the default `description` renders `key = value` (or `(not set)`). This lets a consuming app hold a heterogeneous collection of config items, sort them, and print them without caring which backend each one uses.

### Components

**ConfigItem** (`Sources/SimpleConfig/ConfigItem.swift`)
The plain-storage implementation. Each item carries a `suiteName` and a `key`, and reads/writes through `UserDefaults(suiteName:)`. The suite name is caller-supplied, so multiple apps or tools can share (or isolate) their settings domains.

**SecureConfigItem** (`Sources/SimpleConfig/ConfigItem.swift`)
The secret-storage implementation. Each item carries a `service` and a `key`, mapping onto the Keychain's generic-password service/account model. Its `description` overrides the protocol default to redact the value, showing only the first and last six characters — secrets can appear in logs or listings without being fully exposed. The service name was originally hardcoded and is now passed in by the caller (see Key Design Decisions).

**Keychain** (`Sources/SimpleConfig/Keychain.swift`)
An internal enum wrapping the Security framework's C-style API (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) for generic-password items. Writes use delete-then-add rather than update, which keeps the code simple at the cost of briefly removing the item. Items are stored with `kSecAttrAccessibleAfterFirstUnlock` so background processes can read them after a reboot once the device has been unlocked. `read` distinguishes three outcomes: a successful fetch, an absent item (`errSecItemNotFound`), and a genuine failure — the first two return the decoded string or `nil` respectively, the third throws, via the internal `isPresent` helper. This type is deliberately not public — consumers go through `SecureConfigItem`.

**ConfigError** (`Sources/SimpleConfig/ConfigError.swift`)
A public error enum (`unableToLoad`, `unknown`) intended as the library's error surface. `ConfigItem` throws `.unableToLoad` when its `UserDefaults` suite can't be created (e.g. a reserved name like `NSGlobalDomain`); `Keychain` still throws raw `NSError` instead (see Open Questions).

### Data Flow

When an app calls `write("secret")` on a `SecureConfigItem`, the item forwards to `Keychain.write`, which builds a generic-password query from the item's service and key, deletes any existing entry, and adds the new one, throwing on any non-success status. A `read()` builds the matching query and asks the Keychain for one result as `Data`; `errSecItemNotFound` and a successful-but-non-UTF8 decode both return `nil`, while any other non-success status throws. The `ConfigItem` path is the same shape but delegates to `UserDefaults`, throwing `ConfigError.unableToLoad` if the suite name is invalid (e.g. `NSGlobalDomain` or the app's own bundle identifier); once the suite resolves, reads and writes themselves cannot fail.

A `delete()` is idempotent on both paths: `ConfigItem` calls `removeObject(forKey:)` (a no-op for missing keys) and `SecureConfigItem` calls `SecItemDelete`, treating `errSecItemNotFound` as success.

Enumeration never reads secret values: `SecureConfigItem.items(inService:)` asks the Keychain for attributes only (`kSecReturnAttributes`, via the internal `Keychain.accounts`), and `ConfigItem.items(inSuite:)` reads the suite's `persistentDomain(forName:)` — not `dictionaryRepresentation()`, which would merge in the global domain. Listing config is therefore safe to display; extracting plaintext requires an explicit chained `keyValuePairs()` call.

---

## Key Design Decisions

**Protocol-based backend selection.** Rather than one config type with a mode flag, each backend is its own struct conforming to `ConfigStorable`. The caller decides sensitivity item-by-item at construction time, and everything downstream (display, sorting, read/write) is uniform.

**Caller-supplied namespaces.** Both the `UserDefaults` suite name and the Keychain service name are constructor parameters rather than constants baked into the library (the service name was hardcoded until commit `5015c76`). This keeps the package reusable across apps and lets one app partition its configuration.

**Redaction over omission.** `SecureConfigItem.description` shows a few characters from each end of a secret rather than hiding it entirely — enough to confirm which value is stored without revealing it. The visible count scales with length (`SecureConfigItem.redact`): secrets under 5 characters are hidden completely, at most 6 characters show per side, at least 3 characters always stay hidden, and the mask is a fixed 20 dots so output doesn't leak the secret's length.

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
