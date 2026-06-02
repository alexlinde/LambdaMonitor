import SwiftUI

// MARK: - Launch in progress

struct LaunchInProgressView: View {
    let progress: LaunchOperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Launching…")
                    .font(.headline)
                    .accessibilityIdentifier("launch-progress-title")
            }

            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: "Instance", value: progress.instanceDescription)
                detailRow(label: "Region", value: progress.regionDescription)
                detailRow(label: "SSH Key", value: progress.sshKeyName)
                detailRow(label: "Image", value: progress.imageDescription)
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("launch-progress-details")

            Text("This may take a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 300)
        .interactiveDismissDisabled()
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .lineLimit(2)
        }
    }
}

// MARK: - Terminate in progress

struct TerminateInProgressView: View {
    let progress: TerminateOperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Terminating…")
                    .font(.headline)
                    .accessibilityIdentifier("terminate-progress-title")
            }

            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: "Instance", value: progress.instanceDescription)
                detailRow(label: "Region", value: progress.regionDescription)
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminate-progress-details")

            Text("This may take a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 320, maxWidth: 360)
        .interactiveDismissDisabled()
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .lineLimit(2)
        }
    }
}

// MARK: - Previews

#Preview("Launching") {
    LaunchInProgressView(
        progress: LaunchOperationProgress(
            typeName: "gpu_1x_h100_sxm5",
            instanceDescription: "1x H100 (80 GB SXM5)",
            regionDescription: "US West",
            sshKeyName: "my-laptop",
            imageDescription: "Lambda Stack (latest)"
        )
    )
}

#Preview("Terminating") {
    TerminateInProgressView(
        progress: TerminateOperationProgress(
            instanceId: "i-abc123",
            instanceDescription: "1x H100 (80 GB SXM5)",
            regionDescription: "US West"
        )
    )
}
