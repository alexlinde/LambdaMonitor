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

### Unit tests (Swift Testing, via SwiftPM)

```bash
cd LambdaMonitor
swift test                                # all unit tests (~47)
swift test --filter ModelTests            # JSON decoding tests
swift test --filter LambdaAPIServiceTests # service logic tests
swift test --filter LiveAPIClientTests    # HTTP behavior tests
```

### UI tests (XCUITest, via Xcode project)

The UI test target lives in the generated Xcode project at `LambdaMonitor.xcodeproj`. XCUITest cannot be driven from SwiftPM, so UI tests live in a parallel target that builds the same sources as the SPM app.

```bash
cd LambdaMonitor
# Run the full UI test suite from the command line:
xcodebuild test \
  -project LambdaMonitor.xcodeproj \
  -scheme LambdaMonitor \
  -destination 'platform=macOS' \
  -configuration Debug

# Or open the project in Xcode and use Cmd+U:
open LambdaMonitor.xcodeproj
```

UI tests launch the app with `--ui-test`, which:
- Swaps `LambdaAPIService` to a deterministic `MockAPIClient.uiTest()` backend that simulates launch/terminate.
- Skips macOS notification permission so no system sheet blocks automation.
- Promotes activation policy to `.regular` so the window joins the normal accessibility tree.
- Resets `UserDefaults` for watched/auto-launch state and pre-watches `gpu_1x_h100_sxm5` so its row is always in the expanded WATCHED section (compact AVAILABLE rows hide their `Launch` button until hover).
- Opens an `NSWindow` titled `Lambda Monitor (UI Test)` hosting `InstanceListView`, since `MenuBarExtra` popovers are not addressable by XCUITest.

Tests live in `Tests/UI/LambdaMonitorUITests.swift`, organized into one `XCTestCase` subclass per flow:
- `LambdaMonitorSmokeTests` — window opens, toolbar buttons exist, refresh stays responsive.
- `LambdaMonitorWatchTests` — toggling a watch bell moves the row into WATCHED.
- `LambdaMonitorSettingsTests` — Settings window opens, API key field is reachable, Done dismisses it.
- `LambdaMonitorLaunchTests` — launch sheet appears, Confirm produces a new running row, Cancel does not.
- `LambdaMonitorTerminateTests` — terminate confirmation dialog appears, Terminate removes the row, Cancel keeps it.

If you regenerate the Xcode project (e.g. via XcodeGen / `project.yml`), keep it tracked in git: `.gitignore` includes `!/LambdaMonitor.xcodeproj/`.

### Previews

SwiftUI previews are available for all views in Xcode — each view file has `#Preview` blocks with various mock states (populated, loading, error, empty, launching).

### Adding accessibility identifiers for new XCUITest queries

SwiftUI propagates a root `accessibilityIdentifier` down to every descendant, **overriding** the more specific identifiers on child controls. When a parent must group children (`accessibilityElement(children: .contain)` + a row-level identifier is OK because `.contain` preserves child identifiers), do **not** add a plain `.accessibilityIdentifier(...)` on a screen / sheet / form root — apply identifiers only on the leaf controls tests need to find.

## Project Structure

```
Package.swift              — 3 SPM targets: LambdaMonitorCore (lib), LambdaMonitor (exe), LambdaMonitorTests
LambdaMonitor.xcodeproj/   — Xcode project (generated from project.yml) for XCUITest UI tests
project.yml                — XcodeGen config: LambdaMonitorCore framework, LambdaMonitor app, LambdaMonitorUITests target

Sources/
  App/
    LambdaMonitorApp.swift            — @main entry point, MenuBarExtra, --mock-api and --ui-test modes
  Core/
    Models/InstanceType.swift         — Codable models for all Lambda API endpoints
    Services/APIClient.swift          — APIClient protocol, LiveAPIClient, MockAPIClient
    Services/LambdaAPIService.swift   — @Observable service: fetch, launch, terminate, watch, auto-launch
    Services/KeychainService.swift    — Keychain wrapper for API key storage
    Testing/MockData.swift            — Shared mock fixtures, PreviewService helpers, MockAPIClient.uiTest()
    Views/InstanceListView.swift      — Main popover: instance list, error/empty/loading states
    Views/InstanceRowView.swift       — Row: watch bell, GPU name, price, region chips, launch sheet
    Views/RunningInstanceRowView.swift — Row for active running instances, terminate confirmation
    Views/SettingsView.swift          — API key input with save/test/clear, launch at login toggle
Tests/
  Unit/
    ModelTests.swift                  — JSON decode/encode round-trips for all model types
    LambdaAPIServiceTests.swift       — Service state: fetch, sort, watch, auto-launch, launch, terminate
    LiveAPIClientTests.swift          — HTTP construction, error mapping via URLProtocol mock
  UI/
    LambdaMonitorUITests.swift        — XCUITest flows: smoke, watch, settings, launch, terminate
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
