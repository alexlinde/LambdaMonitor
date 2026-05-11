import SwiftUI
import AppKit

public struct InstanceRowView: View {
    public let instance: OfferedInstanceType
    public var apiService: LambdaAPIService
    public var compact: Bool = false
    @Environment(\.openWindow) private var openWindow
    @State private var launchConfigurationPresented = false

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

    private var isThisLaunching: Bool {
        apiService.launchingTypeNames.contains(instance.instanceType.name)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .sheet(isPresented: $launchConfigurationPresented) {
            LaunchConfigurationSheet(
                instance: instance,
                apiService: apiService,
                isPresented: $launchConfigurationPresented
            )
        }
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
    }

    private var needsLaunchDialog: Bool {
        instance.regionsWithCapacityAvailable.count > 1 || apiService.sshKeys.count > 1
    }

    @ViewBuilder
    private var launchControl: some View {
        if isThisLaunching {
            ProgressView()
                .scaleEffect(0.5)
                .frame(height: 16)
        } else {
            Button("Launch") {
                launchOrShowDialog()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(!instance.isAvailable || !apiService.launchingTypeNames.isEmpty)
            .help(instance.isAvailable ? "Launch instance" : "Unavailable")
        }
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

        if !needsLaunchDialog,
           let region = instance.regionsWithCapacityAvailable.first,
           !apiService.selectedSSHKeyName.isEmpty {
            apiService.launchInstance(
                typeName: instance.instanceType.name,
                regionName: region.name
            )
            return
        }

        launchConfigurationPresented = true
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

// MARK: - Launch sheet (SwiftUI avoids NSAlert.runModal issues in MenuBarExtra panels)

private struct LaunchConfigurationSheet: View {
    let instance: OfferedInstanceType
    var apiService: LambdaAPIService
    @Binding var isPresented: Bool

    @State private var selectedRegionName: String
    @State private var selectedKeyName: String

    init(instance: OfferedInstanceType, apiService: LambdaAPIService, isPresented: Binding<Bool>) {
        self.instance = instance
        self.apiService = apiService
        self._isPresented = isPresented
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
                }
                if apiService.sshKeys.count > 1 {
                    Picker("SSH Key", selection: $selectedKeyName) {
                        ForEach(apiService.sshKeys) { key in
                            Text(key.name).tag(key.name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Launch") {
                    if !selectedKeyName.isEmpty {
                        apiService.selectedSSHKeyName = selectedKeyName
                    }
                    apiService.launchInstance(
                        typeName: instance.instanceType.name,
                        regionName: selectedRegionName
                    )
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRegionName.isEmpty || selectedKeyName.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
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
