<!-- 🖊 TODO: Add logo to docs/images/logo.png and uncomment:
<p align="center">
  <img src="docs/images/logo.png" alt="SimpleConfig logo" width="200">
</p>
-->

<p align="center">
  <a href="https://github.com/PeteRichardson/SimpleConfig/tags"><img src="https://img.shields.io/github/v/tag/PeteRichardson/SimpleConfig" alt="Latest tag"></a>
  <img src="https://img.shields.io/badge/Swift-6.2-orange" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20iOS-blue" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/PeteRichardson/SimpleConfig" alt="License"></a>
</p>

# SimpleConfig

> _One API for app settings and secrets — UserDefaults or Keychain, chosen per item._

SimpleConfig is a small Swift package that stores string key-value configuration on Apple platforms behind a single protocol, `ConfigStorable`. Each item picks its backend at construction time: `ConfigItem` for ordinary settings (backed by a `UserDefaults` suite) and `SecureConfigItem` for secrets like API keys (backed by the Keychain), so the rest of your code reads, writes, deletes, sorts, and prints them identically — without ever touching the Security framework's C API. Secret values are automatically redacted when printed, so config listings are safe to log. The deliberate trade-off is simplicity: values are strings only, and the package is Apple-only.

> **Status:** Stable — breaking changes only on major versions.

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API](#api)
- [Known Limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **One protocol, two backends** — `ConfigStorable` gives every item the same `read()` / `write(_:)` / `delete()` surface whether it lives in `UserDefaults` or the Keychain; hold them together in one collection.
- **Safe-to-log secrets** — printing a `SecureConfigItem` redacts the value (`apiToken = sk-abc....................ghi789`): secrets under 5 characters are hidden entirely, at most 6 characters show per side, and the fixed-width mask never leaks the secret's length.
- **Idempotent delete** — `delete()` means "ensure absent"; deleting a value that was never set is success, not an error.
- **Caller-supplied namespaces** — you choose the `UserDefaults` suite name and Keychain service, so one app can partition its config and multiple tools can share (or isolate) theirs.
- **Errors instead of crashes** — invalid suite names throw `ConfigError.unableToLoad` rather than force-unwrap crashing.
- **Zero dependencies** — Foundation and Security only.

---

## Prerequisites

- **Swift 6.2** toolchain or later (Xcode 26 / recent toolchain with the Swift Testing framework)
- **An Apple platform** — macOS or iOS; both backends are Apple OS services

---

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PeteRichardson/SimpleConfig.git", from: "2.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["SimpleConfig"]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/PeteRichardson/SimpleConfig`.

### From source

```sh
git clone https://github.com/PeteRichardson/SimpleConfig.git
cd SimpleConfig
swift build
swift test
```

---

## Quick Start

```swift
import SimpleConfig

// A plain setting, stored in a UserDefaults suite
let host = ConfigItem(suiteName: "com.example.myapp", key: "host")
try host.write("api.example.com")
print(host)                     // host = api.example.com

// A secret, stored in the Keychain — redacted when printed
let token = SecureConfigItem(service: "com.example.myapp", key: "apiToken")
try token.write("sk-abc123def456ghi789")
print(token)                    // apiToken = sk-abc....................ghi789

// Uniform reads and removal, regardless of backend
let value = try token.read()    // "sk-abc123def456ghi789"
try token.delete()              // idempotent: safe even if already gone
try token.read()                // nil
```

Because both types conform to `ConfigStorable` (which is `Comparable` and
`CustomStringConvertible`), a mixed collection sorts by key and prints
safely:

```swift
let items: [any ConfigStorable] = [token, host]
for item in items.sorted(by: <) {
    print(item)                 // secrets stay redacted
}
```

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

Store binary values (certificates, key material, tokens) alongside
strings — each concrete type offers a `Data` overload:

```swift
let cert = SecureConfigItem(service: "com.example.myapp", key: "clientCert")
try cert.write(certificateData)          // Data, not String
try cert.readData()                      // Data? — the raw bytes back
print(cert)                              // clientCert = (binary value, 942 bytes)

// UserDefaults keeps String and Data separate per key — writing one
// type makes the other accessor return nil:
let cache = ConfigItem(suiteName: "com.example.myapp", key: "cachedBlob")
try cache.write(Data([0x01, 0x02]))
try cache.read()                         // nil — no String was ever written
```

---

## API

The whole surface is one protocol and two conforming structs:

| Type | Backend | Construction |
|------|---------|--------------|
| `ConfigItem` | `UserDefaults(suiteName:)` | `ConfigItem(suiteName:key:)` |
| `SecureConfigItem` | Keychain generic-password item | `SecureConfigItem(service:key:)` |

Every `ConfigStorable` provides:

- `read() throws -> String?` — the stored value, or `nil` if not set
- `write(_ value: String) throws` — store, replacing any existing value
- `readData() throws -> Data?` / `write(_ data: Data) throws` (on `ConfigItem` and `SecureConfigItem`, not part of `ConfigStorable`) — binary storage; `ConfigItem` keeps `String`/`Data` as separate types per key, `SecureConfigItem` treats both as the same underlying bytes
- `delete() throws` — ensure absent; deleting a missing value succeeds silently
- `ConfigItem.items(inSuite:)` / `SecureConfigItem.items(inService:)` — all items in a namespace, sorted by key; secret values are never read
- `keyValuePairs()` (on homogeneous item sequences) — plain `(key, value)` tuples; throws on read errors, drops values with no string form
- `description` — `key = value` rendering; `SecureConfigItem` redacts the value; a `Data`-only value renders as its byte count
- `Comparable` — items sort by `key`

Errors: `ConfigItem` throws `ConfigError.unableToLoad` when the suite name
is invalid (e.g. `NSGlobalDomain` or your app's own bundle identifier);
Keychain failures surface as `NSError` with the OSStatus code.

Architecture details live in [docs/design.md](docs/design.md).

---

## Known Limitations

- **No typed/Codable values** — only `String` and `Data` are supported; encoding richer types (e.g. via `Codable`) is the caller's job.
- **Apple platforms only** — both backends are Apple OS services; there is no Linux/Windows fallback.
- **Keychain reads collapse errors to `nil`** — a genuine failure (e.g. reading while the device is locked) is currently indistinguishable from "not set." Tracked as an open question in [docs/design.md](docs/design.md).
- **Keychain writes are delete-then-add** — the item briefly doesn't exist during a rewrite; there's no atomic update.

<!-- 🖊 TODO: Review — inferred from docs/design.md open questions and source. -->

---

## Contributing

Contributions welcome.

```sh
git clone https://github.com/PeteRichardson/SimpleConfig.git
cd SimpleConfig
swift test        # Swift Testing framework (@Test / #expect), not XCTest
```

Please open an issue before starting significant work.

---

## License

Licensed under the **MIT License** — see [LICENSE](LICENSE) for details.
