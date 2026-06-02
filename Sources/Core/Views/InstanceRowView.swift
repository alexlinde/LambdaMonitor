import SwiftUI
import AppKit

public struct InstanceRowView: View {
    public let instance: OfferedInstanceType
    public var apiService: LambdaAPIService
    public var compact: Bool = false
    @Environment(\.openWindow) private var openWindow

    public init(instance: OfferedInstanceType, apiService: LambdaAPIService, compact: Bool = false) {
        self.instance = instance
        self.apiService = apiService
        self.compact = compact
    }

    private var isWatched: Bool {
        apiService.isWatched(instance.instanceType.name)
    }

    private var specsTooltip: String {
        let s = instance.instanceType.specs
        return "\(instance.instanceType.description)\n\(s.vcpus) vCPUs · \(s.memoryGib) GB RAM · \(s.storageGib) GB Storage"
    }

    private var regionsText: String {
        instance.regionsWithCapacityAvailable.map(\.description).joined(separator: " · ")
    }

    private var isAutoLaunch: Bool {
        apiService.isAutoLaunch(instance.instanceType.name)
    }

    private var accessibilityDescription: String {
        let name = instance.instanceType.description
        let price = instance.instanceType.formattedPrice
        if instance.isAvailable {
            let regions = instance.regionsWithCapacityAvailable.map(\.description).joined(separator: ", ")
            return "\(name), \(price), available in \(regions)"
        } else {
            let watched = isWatched ? ", watching" : ""
            let auto = isAutoLaunch ? ", auto-launch enabled" : ""
            return "\(name), \(price), unavailable\(watched)\(auto)"
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            leadingIcon

            if isWatched && !compact {
                watchedContent
            } else if instance.isAvailable && !compact {
                expandedContent
            } else {
                compactContent
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .opacity(instance.isAvailable || isWatched ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("instance-row-\(instance.instanceType.name)")
    }

    private var watchedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.instanceType.description)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(specsTooltip)

                if instance.isAvailable {
                    Text(regionsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(instance.instanceType.formattedPrice)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if instance.isAvailable {
                launchControl
            } else {
                autoLaunchToggle
            }
        }
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.instanceType.description)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(specsTooltip)

                Text(regionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(instance.instanceType.formattedPrice)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            launchControl
        }
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            Text(instance.instanceType.description)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(specsTooltip)

            Spacer(minLength: 4)

            Text(instance.instanceType.formattedPrice)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        Button {
            apiService.toggleWatch(for: instance.instanceType.name)
        } label: {
            Image(systemName: isWatched ? "bell.fill" : "bell")
                .font(.caption2)
                .foregroundStyle(isWatched ? .orange : .secondary)
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help(isWatched ? "Stop watching" : "Watch for availability")
        .accessibilityLabel(isWatched ? "Stop watching" : "Watch for availability")
        .accessibilityIdentifier("watch-toggle-\(instance.instanceType.name)")
    }

    private var needsLaunchDialog: Bool {
        instance.regionsWithCapacityAvailable.count > 1 || apiService.sshKeys.count > 1
    }

    @ViewBuilder
    private var launchControl: some View {
        Button("Launch") {
            launchOrShowDialog()
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(!instance.isAvailable || !apiService.launchingTypeNames.isEmpty)
        .help(instance.isAvailable ? "Launch instance" : "Unavailable")
        .accessibilityIdentifier("launch-button-\(instance.instanceType.name)")
    }

    private func launchOrShowDialog() {
        guard !apiService.sshKeys.isEmpty else {
            openSettingsWindow()
            return
        }

        if apiService.selectedSSHKeyName.isEmpty {
            if apiService.sshKeys.count == 1 {
                apiService.selectedSSHKeyName = apiService.sshKeys[0].name
            }
        }

        // Fast path: a single region + a chosen SSH key means there's nothing
        // to configure, so launch immediately. We still open the launch window
        // first so its spinner is visible while the request runs — otherwise
        // the launch would be invisible. The window dismisses itself when the
        // operation completes. (See DIALOG.md for why this is a Window and not
        // an in-popover sheet.)
        if !needsLaunchDialog,
           let region = instance.regionsWithCapacityAvailable.first,
           !apiService.selectedSSHKeyName.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            apiService.launchInstance(
                typeName: instance.instanceType.name,
                regionName: region.name,
                instanceDescription: instance.instanceType.description,
                regionDescription: region.description
            )
            openWindow(id: "launch")
            return
        }

        apiService.pendingLaunch = instance
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "launch")
    }

    private var autoLaunchToggle: some View {
        Toggle(isOn: Binding(
            get: { isAutoLaunch },
            set: { newValue in
                if newValue && apiService.selectedSSHKeyName.isEmpty {
                    openSettingsWindow()
                } else {
                    apiService.toggleAutoLaunch(for: instance.instanceType.name)
                }
            }
        )) {
            Text("Auto")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Automatically launch when available")
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if instance.isAvailable {
            Button {
                launchOrShowDialog()
            } label: {
                Label("Launch…", systemImage: "play.fill")
            }
        }

        Button {
            apiService.toggleWatch(for: instance.instanceType.name)
        } label: {
            if isWatched {
                Label("Stop Watching", systemImage: "bell.slash")
            } else {
                Label("Watch", systemImage: "bell")
            }
        }

        if isWatched {
            Button {
                if !isAutoLaunch && apiService.selectedSSHKeyName.isEmpty {
                    openSettingsWindow()
                } else {
                    apiService.toggleAutoLaunch(for: instance.instanceType.name)
                }
            } label: {
                if isAutoLaunch {
                    Label("Disable Auto-launch", systemImage: "bolt.slash")
                } else {
                    Label("Enable Auto-launch", systemImage: "bolt")
                }
            }
        }
    }
}

// MARK: - Launch window
//
// Hosted as a dedicated `Window` scene (see `LambdaMonitorApp`), NOT a
// `.sheet` inside the `MenuBarExtra` popover. A sheet presented inside the
// menu-bar panel is torn down when the panel resigns key (which a button
// click triggers), dropping the action and hiding the spinner. A real window
// is stable. See DIALOG.md for the full rationale.
//
// The window renders from `LambdaAPIService` state:
//   - `activeLaunchProgress != nil` -> spinner
//   - `pendingLaunch != nil`        -> region/SSH configuration form
//   - both nil                      -> operation finished, dismiss self

public struct LaunchWindowView: View {
    public var apiService: LambdaAPIService
    @Environment(\.dismiss) private var dismiss

    public init(apiService: LambdaAPIService) {
        self.apiService = apiService
    }

    private var isFinished: Bool {
        apiService.pendingLaunch == nil && apiService.activeLaunchProgress == nil
    }

    public var body: some View {
        Group {
            if let progress = apiService.activeLaunchProgress {
                LaunchInProgressView(progress: progress)
            } else if let instance = apiService.pendingLaunch {
                LaunchConfigurationForm(instance: instance, apiService: apiService)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onChange(of: isFinished) { _, finished in
            if finished { dismiss() }
        }
    }
}

private struct LaunchConfigurationForm: View {
    let instance: OfferedInstanceType
    var apiService: LambdaAPIService

    @State private var selectedRegionName: String
    @State private var selectedKeyName: String

    init(instance: OfferedInstanceType, apiService: LambdaAPIService) {
        self.instance = instance
        self.apiService = apiService
        let regions = instance.regionsWithCapacityAvailable
        _selectedRegionName = State(initialValue: regions.first?.name ?? "")
        let keys = apiService.sshKeys
        let stored = apiService.selectedSSHKeyName
        let initialKey: String
        if !stored.isEmpty, keys.contains(where: { $0.name == stored }) {
            initialKey = stored
        } else {
            initialKey = keys.first?.name ?? ""
        }
        _selectedKeyName = State(initialValue: initialKey)
    }

    private var selectedRegionDescription: String {
        instance.regionsWithCapacityAvailable
            .first { $0.name == selectedRegionName }?
            .description ?? selectedRegionName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch \(instance.instanceType.description)")
                .font(.headline)
            Text(instance.instanceType.formattedPrice)
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                if instance.regionsWithCapacityAvailable.count > 1 {
                    Picker("Region", selection: $selectedRegionName) {
                        ForEach(instance.regionsWithCapacityAvailable) { region in
                            Text(region.description).tag(region.name)
                        }
                    }
                    .accessibilityIdentifier("launch-sheet-region")
                }
                if apiService.sshKeys.count > 1 {
                    Picker("SSH Key", selection: $selectedKeyName) {
                        ForEach(apiService.sshKeys) { key in
                            Text(key.name).tag(key.name)
                        }
                    }
                    .accessibilityIdentifier("launch-sheet-ssh-key")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)

            HStack {
                Button("Cancel") { apiService.pendingLaunch = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("launch-sheet-cancel")
                Spacer()
                Button("Launch") {
                    if !selectedKeyName.isEmpty {
                        apiService.selectedSSHKeyName = selectedKeyName
                    }
                    // Start the request first so `activeLaunchProgress` is set
                    // before we clear `pendingLaunch` — the window swaps to the
                    // spinner in place rather than briefly looking finished.
                    apiService.launchInstance(
                        typeName: instance.instanceType.name,
                        regionName: selectedRegionName,
                        instanceDescription: instance.instanceType.description,
                        regionDescription: selectedRegionDescription
                    )
                    apiService.pendingLaunch = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRegionName.isEmpty || selectedKeyName.isEmpty)
                .accessibilityIdentifier("launch-sheet-confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 300)
        // No `.accessibilityIdentifier` at the root: SwiftUI propagates a root
        // identifier down to descendants and overrides the per-control
        // identifiers (`launch-sheet-confirm`, etc.) tests need to query.
    }
}

// MARK: - Previews

#Preview("Available (expanded)") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.h100x1Available, apiService: service)
        .padding()
}

#Preview("Unavailable (compact)") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.a100x1Unavailable, apiService: service, compact: true)
        .padding()
}

#Preview("Watched - Available") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.h100x1Available, apiService: service)
        .padding()
}

#Preview("Watched - Unavailable") {
    let service = PreviewService.populated()
    let instance = MockData.h200x1Unavailable
    service.watchedTypes.insert(instance.instanceType.name)
    return InstanceRowView(instance: instance, apiService: service)
        .padding()
}
