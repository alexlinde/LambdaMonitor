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

        showLaunchDialog()
    }

    private func showLaunchDialog() {
        let regions = instance.regionsWithCapacityAvailable
        let keys = apiService.sshKeys

        let alert = NSAlert()
        alert.messageText = "Launch \(instance.instanceType.description)"
        alert.informativeText = instance.instanceType.formattedPrice
        alert.alertStyle = .informational
        alert.icon = NSImage(size: .zero)
        alert.addButton(withTitle: "Launch")
        alert.addButton(withTitle: "Cancel")

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for region in regions {
            regionPopup.addItem(withTitle: region.description)
            regionPopup.lastItem?.representedObject = region.name
        }
        if regions.count > 1 {
            let label = NSTextField(labelWithString: "Region:")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let row = NSStackView(views: [label, regionPopup])
            row.spacing = 6
            container.addArrangedSubview(row)
        }

        let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for key in keys {
            keyPopup.addItem(withTitle: key.name)
        }
        if let selected = keys.firstIndex(where: { $0.name == apiService.selectedSSHKeyName }) {
            keyPopup.selectItem(at: selected)
        }
        if keys.count > 1 {
            let label = NSTextField(labelWithString: "SSH Key:")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let row = NSStackView(views: [label, keyPopup])
            row.spacing = 6
            container.addArrangedSubview(row)
        }

        container.setFrameSize(container.fittingSize)
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selectedRegion = regionPopup.selectedItem?.representedObject as? String
            ?? regions.first?.name ?? ""
        let selectedKey = keyPopup.titleOfSelectedItem ?? apiService.selectedSSHKeyName

        if !selectedKey.isEmpty {
            apiService.selectedSSHKeyName = selectedKey
        }

        apiService.launchInstance(
            typeName: instance.instanceType.name,
            regionName: selectedRegion
        )
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
