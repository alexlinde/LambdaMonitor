import SwiftUI
import AppKit
@preconcurrency import UserNotifications

@main
struct LambdaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var apiService = LambdaAPIService()
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(apiService: apiService, showSettings: $showSettings)
                .onAppear {
                    appDelegate.apiService = apiService
                    if apiService.hasAPIKey {
                        apiService.startAutoRefresh()
                    }
                }
        } label: {
            MenuBarLabel(apiService: apiService)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) var apiService: LambdaAPIService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let launchAction = UNNotificationAction(
            identifier: "LAUNCH_ACTION",
            title: "Launch Instance",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "INSTANCE_AVAILABLE",
            actions: [launchAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == "LAUNCH_ACTION" else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let typeName = userInfo["instanceTypeName"] as? String,
              let regionName = userInfo["regionName"] as? String,
              !regionName.isEmpty else { return }

        await apiService?.launchInstance(
            typeName: typeName,
            regionName: regionName,
            fromNotification: true
        )
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

private struct MenuBarContent: View {
    var apiService: LambdaAPIService
    @Binding var showSettings: Bool

    var body: some View {
        if showSettings {
            SettingsView(apiService: apiService, isPresented: $showSettings)
        } else {
            InstanceListView(apiService: apiService, showSettings: $showSettings)
        }
    }
}
