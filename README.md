# Lambda Monitor

A macOS menu bar app that shows real-time availability of Lambda Labs GPU instances.

## Requirements

- macOS 15 (Sequoia) or later
- Swift 6+
- Xcode 16+ (or Swift toolchain)

## Build & Run

```bash
cd LambdaMonitor
./build.sh   # builds, codesigns, and runs
```

Or open `Package.swift` in Xcode and press Cmd+R (Xcode signs automatically).

**Why codesign?** The app uses Keychain for API key storage. Without a consistent signing identity, macOS prompts for Keychain access on every rebuild.

## Usage

1. The app appears as a cloud icon in your menu bar
2. Click the icon to see the instance availability popover
3. Click the gear icon to open settings and enter your Lambda API key
4. The app auto-refreshes every 30 seconds

### Menu Bar Icons

- `icloud.slash` — disconnected or API error
- `cloud` — connected, no watched instance available
- `cloud.fill` — a watched instance type is available

### Watch & Launch

- Click the bell icon on any instance to watch it — you'll get a notification when it becomes available
- Use the Launch button or notification action to spin up an instance directly
