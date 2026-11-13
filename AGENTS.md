# Repository Guidelines

## Project Structure & Architecture

- `Apps/` contains the NimbusSync SwiftUI menu-bar app and Settings UI.
- `Extensions/` contains the Replicated File Provider and File Provider UI extensions.
- `Packages/` contains shared Swift modules for domain/auth, SQLite/App Group storage, events, File Provider adapters, product UI, diagnostics, and design tokens.
- `Tests/SwiftUnitTests/` and `Tests/FileProviderUnitTests/` hold automated tests; `Tests/schema-manifest.json` is the golden SQLite schema snapshot.
- The product is pure Swift; there is no Rust workspace.
- `Config/` holds entitlements, Info.plists, and build settings. Archived phase reports are in `docs/archive/reports/`; the unified build entry point is under `Scripts/`.

Keep remote identity, operation state, and secrets behind Store/Auth services. File Provider callbacks must not depend on the main app, old callback URLs, or detached in-memory work.

## Build, Test, and Development Commands

Run from the repository root unless noted:

```sh
swift test --disable-sandbox
xcodebuild -project NimbusSync.xcodeproj -scheme NimbusSync -configuration Debug CODE_SIGNING_ALLOWED=NO build
Scripts/build.sh
```

Use a temporary `BUILD_ROOT` for repeatable builds. Real Cloudreve and Finder validation is external to the local build; never commit credentials or response bodies.

## Coding Style & Naming

Use four-space indentation and UTF-8/ASCII by default. Swift types/protocols use `UpperCamelCase`; methods, properties, and tests use `lowerCamelCase` (for example, `DomainHealthReducer` and `testReplayCreate`). Prefer repository abstractions over direct SQL, raw HTTP, or new concurrency primitives. Run `git diff --check` before review.

## Testing Guidelines

Add focused XCTest coverage for protocol/store/core invariants. Test replay, stale versions, cancellation, pagination, anchor expiry, crash recovery, secret redaction, and fail-closed paths. Real Provider, signed Finder, notarization, and long-run evidence must be reported separately.

## Commit & Pull Request Guidelines

Use Conventional Commits with gitmoji, such as `feat: ✨ ...`, `fix: 🐛 ...`, `docs: 📝 ...`, or `chore: 🔧 ...`. PRs should explain scope/risk, link the phase or issue, list test commands, and include UI screenshots. Update the applicable phase report and separate verified evidence from environment-dependent gaps.

## Security & Configuration

Persist tokens and transfer secrets only in Keychain. Do not log Bearer headers, OAuth codes, signed URLs, file contents, or sensitive paths. Release entitlements must not contain File Provider testing mode or HTTP exceptions. Preserve local changes and never use destructive Git commands without explicit approval.
