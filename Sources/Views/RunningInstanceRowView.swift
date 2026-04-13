import SwiftUI
import AppKit

struct RunningInstanceRowView: View {
    let instance: RunningInstance
    var apiService: LambdaAPIService

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

    var body: some View {
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

                Text(instance.instanceType.formattedPrice)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            stopControl
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var stopControl: some View {
        if isTerminating {
            ProgressView()
                .scaleEffect(0.5)
                .frame(height: 16)
        } else {
            Button {
                confirmAndTerminate()
            } label: {
                Text("Terminate")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Terminate instance")
        }
    }

    private func confirmAndTerminate() {
        let alert = NSAlert()
        alert.messageText = "Terminate Instance?"
        alert.informativeText = "This will terminate your \(instance.instanceType.description) in \(instance.region.description). You will be billed for usage up to this point."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn {
            apiService.terminateInstance(
                id: instance.id,
                description: instance.instanceType.description
            )
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
            confirmAndTerminate()
        } label: {
            Label("Terminate Instance…", systemImage: "stop.fill")
        }
    }
}
