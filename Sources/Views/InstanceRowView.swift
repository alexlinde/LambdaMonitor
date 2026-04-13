import SwiftUI

struct InstanceRowView: View {
    let instance: OfferedInstanceType
    var apiService: LambdaAPIService
    var compact: Bool = false
    @Binding var showSettings: Bool

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
        apiService.launchInstanceTypeName == instance.instanceType.name
            && apiService.launchState == .launching
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

    var body: some View {
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

    @ViewBuilder
    private var launchControl: some View {
        if isThisLaunching {
            ProgressView()
                .scaleEffect(0.5)
                .frame(height: 16)
        } else {
            Menu {
                ForEach(instance.regionsWithCapacityAvailable) { region in
                    Button("Launch in \(region.description)") {
                        if apiService.sshKeyName.isEmpty {
                            apiService.showSSHKeyWarning = true
                            showSettings = true
                        } else {
                            apiService.launchInstance(
                                typeName: instance.instanceType.name,
                                regionName: region.name
                            )
                        }
                    }
                }
            } label: {
                Text("Launch")
                    .font(.caption2)
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
            .disabled(!instance.isAvailable || apiService.launchState == .launching)
            .help(instance.isAvailable ? "Launch instance" : "Unavailable")
        }
    }

    private var autoLaunchToggle: some View {
        Toggle(isOn: Binding(
            get: { isAutoLaunch },
            set: { newValue in
                if newValue && apiService.sshKeyName.isEmpty {
                    apiService.showSSHKeyWarning = true
                    showSettings = true
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

    @ViewBuilder
    private var contextMenuContent: some View {
        if instance.isAvailable && !apiService.sshKeyName.isEmpty {
            ForEach(instance.regionsWithCapacityAvailable) { region in
                Button {
                    apiService.launchInstance(
                        typeName: instance.instanceType.name,
                        regionName: region.name
                    )
                } label: {
                    Label("Launch in \(region.description)", systemImage: "play.fill")
                }
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
                if !isAutoLaunch && apiService.sshKeyName.isEmpty {
                    apiService.showSSHKeyWarning = true
                    showSettings = true
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
