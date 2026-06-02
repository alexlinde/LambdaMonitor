import SwiftUI
import AppKit

public struct RunningInstanceRowView: View {
    public let instance: RunningInstance
    public var apiService: LambdaAPIService
    @Environment(\.openWindow) private var openWindow

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
    }

    private func presentTerminateWindow() {
        apiService.pendingTerminate = instance
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "terminate")
    }

    @ViewBuilder
    private var stopControl: some View {
        if canTerminate {
            Button {
                presentTerminateWindow()
            } label: {
                Text("Terminate")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(apiService.terminatingInstanceIds.contains(instance.id))
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
            presentTerminateWindow()
        } label: {
            Label("Terminate Instance…", systemImage: "stop.fill")
        }
        .disabled(!canTerminate)
    }
}

// MARK: - Terminate window
//
// Hosted as a dedicated `Window` scene (see `LambdaMonitorApp`), NOT a
// `.sheet`/`.confirmationDialog` inside the `MenuBarExtra` popover. A
// confirmation presented inside the menu-bar panel is destroyed when the
// panel resigns key on the button click, dropping the action and hiding the
// spinner. A real window is stable. See DIALOG.md for the full rationale.
//
// Renders from `LambdaAPIService` state:
//   - `activeTerminateProgress != nil` -> spinner
//   - `pendingTerminate != nil`        -> confirmation
//   - both nil                         -> operation finished, dismiss self

public struct TerminateWindowView: View {
    public var apiService: LambdaAPIService
    @Environment(\.dismiss) private var dismiss

    public init(apiService: LambdaAPIService) {
        self.apiService = apiService
    }

    private var isFinished: Bool {
        apiService.pendingTerminate == nil && apiService.activeTerminateProgress == nil
    }

    public var body: some View {
        Group {
            if let progress = apiService.activeTerminateProgress {
                TerminateInProgressView(progress: progress)
            } else if let instance = apiService.pendingTerminate {
                TerminateConfirmationForm(instance: instance, apiService: apiService)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onChange(of: isFinished) { _, finished in
            if finished { dismiss() }
        }
    }
}

private struct TerminateConfirmationForm: View {
    let instance: RunningInstance
    var apiService: LambdaAPIService

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
                Button("Cancel") { apiService.pendingTerminate = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("terminate-sheet-cancel")
                Spacer()
                Button("Terminate") {
                    // Start the request first so `activeTerminateProgress` is
                    // set before we clear `pendingTerminate` — the window swaps
                    // to the spinner in place rather than briefly looking
                    // finished.
                    apiService.terminateInstance(
                        id: instance.id,
                        description: instance.instanceType.description,
                        regionDescription: instance.region.description
                    )
                    apiService.pendingTerminate = nil
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
    service.activeTerminateProgress = TerminateOperationProgress(
        instanceId: MockData.runningH100.id,
        instanceDescription: MockData.runningH100.instanceType.description,
        regionDescription: MockData.runningH100.region.description
    )
    return RunningInstanceRowView(instance: MockData.runningH100, apiService: service)
        .padding()
}
