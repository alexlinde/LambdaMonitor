import SwiftUI
import AppKit
import UserNotifications
import LambdaMonitorCore

@main
struct LambdaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var apiService: LambdaAPIService

    /// Cached at process startup so the scene body and `AppDelegate` agree on
    /// whether to expose the UI-test window and skip notification permission.
    static let isUITest: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--ui-test")
        #else
        return false
        #endif
    }()

    init() {
        let service: LambdaAPIService
        #if DEBUG
        if Self.isUITest {
            // Clear persisted state so each UI-test launch starts from the
            // same known baseline (no watched/auto-launch types, no stale
            // SSH/image selections leaking across runs).
            for key in [
                "watchedInstanceTypes",
                "autoLaunchInstanceTypes",
                "selectedSSHKeyName",
                "selectedImageFamily",
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            service = LambdaAPIService(
                client: MockAPIClient.uiTest(),
                apiKeyOverride: "ui-test-key"
            )
            service.selectedSSHKeyName = "my-laptop"
            // Pre-watch H100 so its row renders in the always-expanded
            // "Watched" section and its `Launch` button is visible without a
            // hover (compact AVAILABLE rows hide their launch button until
            // the row is hovered, which is awkward in XCUITest).
            service.watchedTypes = ["gpu_1x_h100_sxm5"]
            MainActor.assumeIsolated {
                UITestServiceHolder.service = service
            }
        } else if CommandLine.arguments.contains("--mock-api") {
            service = LambdaAPIService(
                client: MockAPIClient.autoLaunchDemo(),
                apiKeyOverride: "mock-api-key"
            )
            service.watchedTypes = ["gpu_1x_a100_sxm4"]
            service.autoLaunchTypes = ["gpu_1x_a100_sxm4"]
            service.selectedSSHKeyName = "my-laptop"
        } else {
            service = LambdaAPIService()
        }
        #else
        service = LambdaAPIService()
        #endif

        _apiService = State(initialValue: service)
        // Hand the service to `AppDelegate` so it can begin polling in
        // `applicationDidFinishLaunching`, before the menu-bar popover is
        // ever opened. Without this, the popover's `.task` is the first
        // thing to call `startAutoRefresh()` — and with
        // `.menuBarExtraStyle(.window)` that view is built lazily on first
        // click, leaving the menu-bar icon's running-count badge stale on
        // cold launch.
        MainActor.assumeIsolated {
            AppServiceHolder.service = service
        }
    }

    var body: some Scene {
        MenuBarExtra {
            InstanceListView(apiService: apiService)
        } label: {
            MenuBarLabel(apiService: apiService)
        }
        .menuBarExtraStyle(.window)

        Window("Lambda Monitor Settings", id: "settings") {
            SettingsView(apiService: apiService)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// MainActor-isolated singleton that hands the running `LambdaAPIService` to
/// `AppDelegate`, so polling can start at process launch rather than waiting
/// for the user to open the menu-bar popover.
@MainActor
enum AppServiceHolder {
    static var service: LambdaAPIService?
}

#if DEBUG
/// MainActor-isolated singleton handing the running `LambdaAPIService` to the
/// `AppDelegate` so it can host the same service in a UI-test window.
@MainActor
enum UITestServiceHolder {
    static var service: LambdaAPIService?
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var uiTestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUITest = LambdaMonitorApp.isUITest

        // Under UI tests we promote the app to a regular activation policy so
        // XCUITest can drive a normal window; we also skip notification
        // permission so no system sheet blocks automation.
        NSApp.setActivationPolicy(isUITest ? .regular : .accessory)
        UNUserNotificationCenter.current().delegate = self
        if !isUITest {
            LambdaAPIService.requestNotificationPermission()
        }

        // Kick off polling immediately at process launch so the menu-bar
        // icon reflects running-instance count and watched-availability on
        // cold start — without this the first poll wouldn't run until the
        // user opened the popover. UI tests have their own bootstrap via
        // `presentUITestWindow`.
        if !isUITest, let service = AppServiceHolder.service, service.hasAPIKey {
            service.startAutoRefresh()
        }

        #if DEBUG
        if isUITest, let service = UITestServiceHolder.service {
            DispatchQueue.main.async { [weak self] in
                self?.presentUITestWindow(apiService: service)
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private func presentUITestWindow(apiService: LambdaAPIService) {
        // Intentionally no `.accessibilityIdentifier` at the root: SwiftUI
        // propagates a root identifier down to every descendant, overriding
        // the specific identifiers (`refresh-button`, `launch-button-...`,
        // etc.) that tests need to query by.
        let content = InstanceListView(apiService: apiService)
            .frame(width: 320, height: 480)
            .task { @MainActor in
                if apiService.hasAPIKey {
                    apiService.startAutoRefresh()
                }
            }
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lambda Monitor (UI Test)"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        uiTestWindow = window

        NSApp.activate(ignoringOtherApps: true)
    }
    #endif

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // No-op: just prevents macOS from trying to activate/foreground the app
        // in a way that confuses the MenuBarExtra panel state.
    }
}

private struct MenuBarLabel: View {
    var apiService: LambdaAPIService

    var body: some View {
        let isDisconnected = !apiService.hasAPIKey
            || apiService.isOffline
            || (apiService.error != nil && apiService.instances.isEmpty)
        let watchedAvailable = apiService.instances.contains { instance in
            instance.isAvailable && apiService.watchedTypes.contains(instance.instanceType.name)
        }
        let runningCount = apiService.runningInstances.count

        Image(nsImage: Self.makeMenuBarIcon(
            isDisconnected: isDisconnected,
            watchedAvailable: watchedAvailable,
            runningCount: runningCount
        ))
        .accessibilityLabel(accessibilityLabel(
            isDisconnected: isDisconnected,
            watchedAvailable: watchedAvailable,
            runningCount: runningCount
        ))
    }

    private func accessibilityLabel(
        isDisconnected: Bool, watchedAvailable: Bool, runningCount: Int
    ) -> String {
        let base: String =
            if isDisconnected { "Lambda: disconnected" }
            else if watchedAvailable { "Watched GPU available" }
            else { "No watched GPU available" }
        if runningCount > 0 {
            let plural = runningCount == 1 ? "" : "s"
            return "\(base), \(runningCount) instance\(plural) running"
        }
        return base
    }

    // MenuBarExtra's label silently flattens composite views (ZStack/overlay)
    // and only renders the first Image it finds, so we composite the cloud +
    // the count digit into a single NSImage ourselves. The result is kept as
    // a template image so the menu bar handles dark/light tinting
    // automatically.
    //
    // For an outline (`cloud`) we draw the digit normally — it becomes opaque
    // and templates to the menu bar foreground color, sitting inside the
    // cloud's transparent interior.
    //
    // For a filled (`cloud.fill`) cloud we draw the digit with
    // `.destinationOut` blending, which knocks alpha out of the canvas in the
    // shape of the digit. The cloud body templates to the foreground color
    // and the digit-shaped hole shows the menu bar background through it,
    // i.e. it inverts against the cloud — visible without breaking template
    // rendering.
    private static func makeMenuBarIcon(
        isDisconnected: Bool, watchedAvailable: Bool, runningCount: Int
    ) -> NSImage {
        let cloudName: String
        let cloudIsFilled: Bool
        if isDisconnected {
            cloudName = "icloud.slash"
            cloudIsFilled = false
        } else if watchedAvailable {
            cloudName = "cloud.fill"
            cloudIsFilled = true
        } else {
            cloudName = "cloud"
            cloudIsFilled = false
        }

        let cloudConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let cloud = NSImage(systemSymbolName: cloudName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cloudConfig)
        else {
            return NSImage()
        }

        guard !isDisconnected, runningCount > 0 else {
            cloud.isTemplate = true
            return cloud
        }

        let canvasSize = cloud.size
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()

        cloud.draw(
            in: NSRect(origin: .zero, size: canvasSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        let label = countLabel(for: runningCount)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: NSColor.black,
        ]
        let attrString = NSAttributedString(string: label, attributes: attrs)
        let textSize = attrString.size()
        let textOrigin = NSPoint(
            x: (canvasSize.width - textSize.width) / 2,
            y: (canvasSize.height - textSize.height) / 2 - 1
        )

        if cloudIsFilled {
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        }
        attrString.draw(at: textOrigin)
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    /// Single-character label for a count: 1–9 show the digit, 10+ shows "+".
    private static func countLabel(for count: Int) -> String {
        if count >= 1 && count <= 9 {
            return "\(count)"
        }
        return "+"
    }
}
