# Lambda Monitor

macOS menu bar app showing real-time Lambda Labs GPU instance availability.

## Build & Run

```bash
cd LambdaMonitor
./build.sh   # builds, codesigns, and runs
```

Or open `LambdaMonitor/Package.swift` in Xcode and press Cmd+R (Xcode signs automatically).

**Why codesign?** The app uses Keychain for API key storage. Without a consistent signing identity, macOS prompts for Keychain access on every rebuild.

## Project Structure

All source lives under `LambdaMonitor/`:

- `Package.swift` — SPM executable target, macOS 15+, Swift 6, zero external dependencies
- `Sources/LambdaMonitorApp.swift` — App entry point using `MenuBarExtra` with `.window` style
- `Sources/Models/InstanceType.swift` — Codable models for the Lambda API response
- `Sources/Services/KeychainService.swift` — Keychain wrapper for API key storage
- `Sources/Services/LambdaAPIService.swift` — Async API client with 30-second auto-refresh
- `Sources/Views/InstanceListView.swift` — Main popover: instance list, error/empty/loading states
- `Sources/Views/InstanceRowView.swift` — Row: watch bell, GPU name, price, region chips, specs
- `Sources/Views/RunningInstanceRowView.swift` — Row for active running instances
- `Sources/Views/SettingsView.swift` — API key input with save/test/clear
- `Resources/lambda.icon` — App icon in Apple Icon Composer format (macOS 15+)

## Architecture

- **SwiftUI only** — no AppKit views, no storyboards. AppKit is only used for `NSApp.setActivationPolicy(.accessory)` to hide the Dock icon.
- **State** — single `LambdaAPIService` (`@Observable`) owned by the app via `@State`, passed to child views as plain properties.
- **API key** — stored in macOS Keychain under service `com.lambda-monitor.api-key`. Never persisted to disk or UserDefaults.
- **Menu bar icon** — template image that changes shape based on state: `icloud.slash` (disconnected / API error), `cloud` (connected, no watched availability), `cloud.fill` (watched instance available).

## Lambda API

- Endpoint: `GET https://cloud.lambdalabs.com/api/v1/instance-types`
- Auth: `Authorization: Bearer {key}`
- Response: `{ "data": { "<type_name>": { "instance_type": {...}, "regions_with_capacity_available": [...] } } }`

## Conventions

- Swift 6, macOS 15+ minimum deployment target
- No third-party dependencies — only Foundation, SwiftUI, Security, AppKit
- All API/UI work runs on `@MainActor`
- Models use `CodingKeys` for snake_case JSON ↔ camelCase Swift mapping
- Views are small and single-purpose; compose via separate files
