import SwiftUI
import AppKit

public struct RunningInstanceRowView: View {
    public let instance: RunningInstance
    public var apiService: LambdaAPIService
    @State private var terminateConfirmationPresented = false

    public init(instance: RunningInstance, apiService: LambdaAPIService) {
        self.instance = instance
        self.apiService = apiService
    }

    private var statusColor: Color {
        switch instance.status {
        case "active": .green
        case "booting": .orange
        case "unhealthy": .red
        default: .secondary
        }
    }

    private var isTerminating: Bool {
        apiService.terminatingInstanceIds.contains(instance.id)
    }

    private var canTerminate: Bool {
        instance.status == "active" || instance.status == "booting" || instance.status == "unhealthy"
    }

    private var tooltip: String {
        var parts: [String] = []
        if let name = instance.name, !name.isEmpty {
            parts.append("Name: \(name)")
        }
        parts.append("ID: \(instance.id)")
        let s = instance.instanceType.specs
        parts.append("\(s.vcpus) vCPUs · \(s.memoryGib) GB RAM · \(s.storageGib) GB Storage")
        if let hostname = instance.hostname, !hostname.isEmpty {
            parts.append("Host: \(hostname)")
        }
        return parts.joined(separator: "\n")
    }

    private var accessibilityDescription: String {
        let type = instance.instanceType.description
        let region = instance.region.description
        let ip = instance.ip.map { ", IP \($0)" } ?? ""
        return "\(type), \(instance.status), \(region)\(ip)"
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(statusColor)
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.instanceType.description)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tooltip)

                HStack(spacing: 0) {
                    Text(instance.region.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let ip = instance.ip, !ip.isEmpty {
                        Text(" · ")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(ip)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 0) {
                    Text(instance.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    Text(" · ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(instance.instanceType.formattedPrice)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            stopControl
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("running-row-\(instance.id)")
        .sheet(isPresented: $terminateConfirmationPresented) {
            TerminateConfirmationSheet(
                instance: instance,
                apiService: apiService,
                isPresented: $terminateConfirmationPresented
            )
        }
    }

    @ViewBuilder
    private var stopControl: some View {
        if isTerminating {
            ProgressView()
                .scaleEffect(0.5)
                .frame(height: 16)
                .accessibilityIdentifier("terminate-progress-\(instance.id)")
        } else if canTerminate {
            Button {
                terminateConfirmationPresented = true
            } label: {
                Text("Terminate")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Terminate instance")
            .accessibilityIdentifier("terminate-button-\(instance.id)")
        } else {
            Text(instance.status.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let ip = instance.ip, !ip.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)
            } label: {
                Label("Copy IP Address", systemImage: "doc.on.clipboard")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh ubuntu@\(ip)", forType: .string)
            } label: {
                Label("Copy SSH Command", systemImage: "terminal")
            }
        }

        if let jupyterUrl = instance.jupyterUrl,
           let token = instance.jupyterToken,
           let url = URL(string: "\(jupyterUrl)?token=\(token)") {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Jupyter Notebook", systemImage: "safari")
            }
        }

        Divider()

        if !instance.id.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(instance.id, forType: .string)
            } label: {
                Label("Copy Instance ID", systemImage: "doc.on.clipboard")
            }
        }

        Button(role: .destructive) {
            terminateConfirmationPresented = true
        } label: {
            Label("Terminate Instance…", systemImage: "stop.fill")
        }
        .disabled(!canTerminate)
    }
}

// MARK: - Terminate sheet
//
// `.confirmationDialog` inside a `MenuBarExtra` panel (`.menuBarExtraStyle(.window)`)
// dismisses the popover when the destructive button is clicked, and the
// button's action is dropped on the floor while the dialog stays stuck in
// its presented state. Using a SwiftUI `.sheet` instead — same pattern as
// `LaunchConfigurationSheet` — keeps the dialog tied to the popover and
// fires the action reliably.

private struct TerminateConfirmationSheet: View {
    let instance: RunningInstance
    var apiService: LambdaAPIService
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminate Instance?")
                .font(.headline)
            Text(
                "This will terminate your \(instance.instanceType.description) in \(instance.region.description). You will be billed for usage up to this point."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("terminate-sheet-cancel")
                Spacer()
                // Intentionally NOT `role: .destructive`. Inside a SwiftUI
                // sheet hosted by `MenuBarExtra` (`.menuBarExtraStyle(.window)`)
                // a destructive button triggers an automatic dismissal that
                // collapses the menu-bar panel before this action closure
                // runs — the panel loses focus, the row view is torn down,
                // and `terminateInstance` is never called while
                // `isPresented` stays stuck at `true` (so the sheet appears
                // to reappear on next open). Plain Button + tint avoids that.
                Button("Terminate") {
                    apiService.terminateInstance(
                        id: instance.id,
                        description: instance.instanceType.description
                    )
                    isPresented = false
                }
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("terminate-sheet-confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 320, maxWidth: 360)
    }
}

// MARK: - Previews

#Preview("Active") {
    RunningInstanceRowView(instance: MockData.runningH100, apiService: PreviewService.populated())
        .padding()
}

#Preview("Booting") {
    RunningInstanceRowView(instance: MockData.bootingA100, apiService: PreviewService.populated())
        .padding()
}

#Preview("Terminating") {
    let service = PreviewService.populated()
    service.terminatingInstanceIds.insert(MockData.runningH100.id)
    return RunningInstanceRowView(instance: MockData.runningH100, apiService: service)
        .padding()
}
