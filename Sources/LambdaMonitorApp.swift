import SwiftUI
import AppKit

@main
struct LambdaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var apiService = LambdaAPIService()
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(apiService: apiService, showSettings: $showSettings)
                .onAppear {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
