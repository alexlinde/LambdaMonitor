import SwiftUI
import AppKit
import UserNotifications
import LambdaMonitorCore

@main
struct LambdaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var apiService: LambdaAPIService
    @State private var hasStarted = false

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--mock-api") {
            let service = LambdaAPIService(
                client: MockAPIClient.autoLaunchDemo(),
                apiKeyOverride: "mock-api-key"
            )
            service.watchedTypes = ["gpu_1x_a100_sxm4"]
            service.autoLaunchTypes = ["gpu_1x_a100_sxm4"]
            service.selectedSSHKeyName = "my-laptop"
            _apiService = State(initialValue: service)
        } else {
            _apiService = State(initialValue: LambdaAPIService())
        }
        #else
        _apiService = State(initialValue: LambdaAPIService())
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            InstanceListView(apiService: apiService)
                .task {
                    guard !hasStarted else { return }
                    hasStarted = true
                    if apiService.hasAPIKey {
                        apiService.startAutoRefresh()
                    }
                }
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        LambdaAPIService.requestNotificationPermission()
    }

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
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy),
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
