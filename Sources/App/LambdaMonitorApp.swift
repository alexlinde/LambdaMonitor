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

        let symbolName = isDisconnected
            ? "icloud.slash"
            : (watchedAvailable ? "cloud.fill" : "cloud")

        Image(systemName: symbolName)
            .accessibilityLabel(
                isDisconnected
                    ? "Lambda: disconnected"
                    : (watchedAvailable ? "Watched GPU available" : "No watched GPU available")
            )
    }
}
