import SwiftUI

struct InstanceRowView: View {
    let instance: OfferedInstanceType
    var apiService: LambdaAPIService

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

    private var accessibilityDescription: String {
        let name = instance.instanceType.description
        let price = instance.instanceType.formattedPrice
        if instance.isAvailable {
            let regions = instance.regionsWithCapacityAvailable.map(\.description).joined(separator: ", ")
            return "\(name), \(price), available in \(regions)"
        } else {
            let watched = isWatched ? ", notifications on" : ""
            return "\(name), \(price), unavailable\(watched)"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            leadingIcon

            if instance.isAvailable {
                availableContent
                Spacer(minLength: 4)
                launchControl
            } else {
                unavailableContent
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .opacity(instance.isAvailable ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var availableContent: some View {
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
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .help(isWatched ? "Stop watching" : "Notify when available")
        .accessibilityLabel(isWatched ? "Stop watching for availability" : "Notify when available")
    }

    @ViewBuilder
    private var launchControl: some View {
        if isThisLaunching {
            ProgressView()
                .scaleEffect(0.5)
                .frame(height: 16)
        } else {
            Menu {
                if apiService.sshKeyName.isEmpty {
                    Text("Set SSH key name in Settings first")
                } else {
                    ForEach(instance.regionsWithCapacityAvailable) { region in
                        Button("Launch in \(region.description)") {
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
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .disabled(apiService.launchState == .launching)
            .help("Launch instance")
        }
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
                Label("Notify When Available", systemImage: "bell")
            }
        }
    }
}
