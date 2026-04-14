import SwiftUI
import AppKit

public struct InstanceListView: View {
    public var apiService: LambdaAPIService
    @Environment(\.openWindow) private var openWindow

    public init(apiService: LambdaAPIService) {
        self.apiService = apiService
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320)
        .onChange(of: apiService.pendingAlert) { _, alert in
            guard let alert else { return }
            apiService.pendingAlert = nil
            showAlert(title: alert.title, message: alert.message)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("λ")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text("Lambda Monitor")
                .font(.body.weight(.medium))

            Spacer()

            Button(action: { apiService.fetch() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .rotationEffect(.degrees(apiService.isLoading ? 360 : 0))
                    .animation(
                        apiService.isLoading
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: apiService.isLoading
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(apiService.isLoading)
            .accessibilityLabel("Refresh instances")
            .help("Refresh")

            Button(action: { openSettingsWindow() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
            .help("Settings")

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit")
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !apiService.hasAPIKey {
            noKeyView
        } else if let errorMsg = apiService.error, apiService.instances.isEmpty {
            errorView(errorMsg)
        } else if apiService.instances.isEmpty && apiService.isLoading {
            loadingView
        } else if apiService.instances.isEmpty {
            emptyView
        } else {
            instanceList
        }
    }

    private var watchedInstances: [OfferedInstanceType] {
        apiService.instances.filter { apiService.isWatched($0.instanceType.name) }
    }

    private var availableInstances: [OfferedInstanceType] {
        apiService.instances.filter { $0.isAvailable && !apiService.isWatched($0.instanceType.name) }
    }

    private var unavailableInstances: [OfferedInstanceType] {
        apiService.instances.filter { !$0.isAvailable && !apiService.isWatched($0.instanceType.name) }
    }

    private var instanceList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !apiService.runningInstances.isEmpty {
                    sectionHeader("Running")
                    ForEach(apiService.runningInstances) { instance in
                        RunningInstanceRowView(instance: instance, apiService: apiService)
                    }
                }

                if !watchedInstances.isEmpty {
                    sectionHeader("Watched")
                    ForEach(watchedInstances) { instance in
                        InstanceRowView(instance: instance, apiService: apiService)
                    }
                }

                if !availableInstances.isEmpty {
                    sectionHeader("Available")
                    ForEach(availableInstances) { instance in
                        InstanceRowView(instance: instance, apiService: apiService, compact: true)
                    }
                }

                if !unavailableInstances.isEmpty {
                    sectionHeader(
                        availableInstances.isEmpty && watchedInstances.isEmpty
                            ? "All Unavailable" : "Unavailable"
                    )
                    ForEach(unavailableInstances) { instance in
                        InstanceRowView(instance: instance, apiService: apiService, compact: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 400)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var noKeyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No API Key")
                .font(.headline)
            Text("Open settings to enter your Lambda API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { openSettingsWindow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { apiService.fetch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading instances...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No instances found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private var footer: some View {
        HStack {
            Spacer()

            if apiService.error != nil {
                Text("Not connected")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            } else if let lastUpdated = apiService.lastUpdated {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(lastUpdated))
                    let text = elapsed < 2
                        ? "Updated now"
                        : "Updated \(elapsed)s ago"
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Not connected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Previews

#Preview("Populated") {
    InstanceListView(apiService: PreviewService.populated())
}

#Preview("Loading") {
    InstanceListView(apiService: PreviewService.loading())
}

#Preview("Error") {
    InstanceListView(apiService: PreviewService.error())
}

#Preview("Empty") {
    InstanceListView(apiService: PreviewService.empty())
}

