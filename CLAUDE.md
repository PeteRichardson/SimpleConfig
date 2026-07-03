# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

SimpleConfig is a small Swift package (swift-tools-version 6.2, no external dependencies) providing key-value configuration storage on Apple platforms with two backends: `UserDefaults` for plain values and the Keychain for secrets.

## Commands

```sh
swift build                                  # Build the package
swift test                                   # Run all tests
swift test --filter <TestNameOrPattern>      # Run a single test
```

Tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect(...)`), not XCTest.

## Architecture

Everything hangs off the `ConfigStorable` protocol (`Sources/SimpleConfig/ConfigStorable.swift`): a `key` plus throwing `read()`/`write(_:)` returning/accepting `String`. It also conforms to `Comparable` (sorted by key) and `CustomStringConvertible`, with default implementations provided in a protocol extension.

Two conforming types live in `ConfigItem.swift`:

- `ConfigItem` — stores values in `UserDefaults(suiteName:)`; caller supplies the suite name.
- `SecureConfigItem` — stores values in the Keychain via the internal `Keychain` enum (`Keychain.swift`, a thin wrapper over the Security framework using generic-password items). The Keychain service name is passed in by the caller, not hardcoded. Its `description` redacts the value, showing only the first/last 6 characters.

`ConfigError` exists for library-level errors, though `Keychain` currently throws `NSError` directly.
