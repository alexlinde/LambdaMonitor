# Lambda Monitor

macOS menu bar app showing real-time Lambda Labs GPU instance availability.

## Build & Run

```bash
cd LambdaMonitor
./build.sh            # builds, codesigns, and runs
./build.sh --mock-api # runs with mock data (no real API key needed)
./build.sh release    # builds release, installs to ~/Applications
```

Or open `LambdaMonitor/Package.swift` in Xcode and press Cmd+R (Xcode signs automatically).

**Why codesign?** The app uses Keychain for API key storage. Without a consistent signing identity, macOS prompts for Keychain access on every rebuild. Both `build.sh` and `release.sh` sign with hardened runtime and entitlements.

## Release & Distribution

```bash
cd LambdaMonitor

# One-time: store Apple notarization credentials in keychain
xcrun notarytool store-credentials LambdaMonitor

# Full release: build, sign, create DMG, notarize, staple
./release.sh

# Custom notary profile name
./release.sh --notary-profile MyProfile

# Skip notarization (for testing the DMG build locally)
./release.sh --skip-notarize
```

Output: `.build/LambdaMonitor.dmg` — a drag-to-Applications DMG, notarized and stapled.

`Entitlements.plist` grants `com.apple.security.network.client` for outbound API calls under hardened runtime.

## Testing

```bash
cd LambdaMonitor
swift test                                # all 37 tests
swift test --filter ModelTests            # JSON decoding tests
swift test --filter LambdaAPIServiceTests # service logic tests
swift test --filter LiveAPIClientTests    # HTTP behavior tests
```

SwiftUI previews are available for all views in Xcode — each view file has `#Preview` blocks with various mock states (populated, loading, error, empty, launching).

## Project Structure

```
Package.swift — 3 SPM targets: LambdaMonitorCore (lib), LambdaMonitor (exe), LambdaMonitorTests

Sources/
  App/
    LambdaMonitorApp.swift            — @main entry point, MenuBarExtra, mock mode support
  Core/
    Models/InstanceType.swift         — Codable models for all Lambda API endpoints
    Services/APIClient.swift          — APIClient protocol, LiveAPIClient, MockAPIClient
    Services/LambdaAPIService.swift   — @Observable service: fetch, launch, terminate, watch, auto-launch
    Services/KeychainService.swift    — Keychain wrapper for API key storage
    Testing/MockData.swift            — Shared mock fixtures and PreviewService helpers
    Views/InstanceListView.swift      — Main popover: instance list, error/empty/loading states
    Views/InstanceRowView.swift       — Row: watch bell, GPU name, price, region chips, specs
    Views/RunningInstanceRowView.swift — Row for active running instances
    Views/SettingsView.swift          — API key input with save/test/clear, launch at login toggle
Tests/
  ModelTests.swift                    — JSON decode/encode round-trips for all model types
  LambdaAPIServiceTests.swift         — Service state: fetch, sort, watch, auto-launch, launch, terminate
  LiveAPIClientTests.swift            — HTTP construction, error mapping via URLProtocol mock
Resources/
  lambda.icon                         — App icon in Apple Icon Composer format (macOS 15+)
Entitlements.plist                    — Hardened runtime entitlements (network.client)
release.sh                            — Release pipeline: build → sign → DMG → notarize → staple
```

## Architecture

- **SwiftUI only** — no AppKit views, no storyboards. AppKit is only used for `NSApp.setActivationPolicy(.accessory)` to hide the Dock icon.
- **State** — single `LambdaAPIService` (`@Observable`) owned by the app via `@State`, passed to child views as plain properties.
- **Injectable API layer** — `APIClient` protocol with `LiveAPIClient` (production) and `MockAPIClient` (tests/previews). Injected into `LambdaAPIService` via init.
- **API key** — stored in macOS Keychain under service `com.lambda-monitor.api-key`. Never persisted to disk or UserDefaults. Overridable via `apiKeyOverride` init param for tests/mock mode.
- **Menu bar icon** — template image that changes shape based on state: `icloud.slash` (disconnected / API error), `cloud` (connected, no watched availability), `cloud.fill` (watched instance available).
- **Launch at Login** — uses `SMAppService.mainApp` (ServiceManagement framework) via a toggle in Settings. No launch agent or installer logic needed.

## Lambda API

- Endpoint: `GET https://cloud.lambdalabs.com/api/v1/instance-types`
- Auth: `Authorization: Bearer {key}`
- Response: `{ "data": { "<type_name>": { "instance_type": {...}, "regions_with_capacity_available": [...] } } }`

## Conventions

- Swift 6, macOS 15+ minimum deployment target
- No third-party dependencies — only Foundation, SwiftUI, Security, AppKit, ServiceManagement
- All API/UI work runs on `@MainActor`
- Models use `CodingKeys` for snake_case JSON ↔ camelCase Swift mapping
- Views are small and single-purpose; compose via separate files
- Tests use Swift Testing framework (`import Testing`)
