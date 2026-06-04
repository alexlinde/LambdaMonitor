import SwiftUI
import AppKit
import ServiceManagement

public struct SettingsView: View {
    public var apiService: LambdaAPIService
    @Environment(\.dismiss) private var dismiss

    public init(apiService: LambdaAPIService) {
        self.apiService = apiService
    }

    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum TestResult {
        case success
        case failure(String)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                SecureField("API Key", text: $apiKey)
                    .accessibilityIdentifier("settings-api-key-field")

                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button("Test") {
                                testAPIKey()
                            }
                            .disabled(apiKey.isEmpty || isTesting)
                            .accessibilityIdentifier("settings-test-button")

                            if apiService.hasAPIKey {
                                Button("Clear Key", role: .destructive) {
                                    confirmAndClearKey()
                                }
                                .disabled(apiService.hasAPIKeyOverride)
                                .accessibilityIdentifier("settings-clear-button")
                            }
                        }
                        .padding(.top, 4)

                        if isTesting {
                            Text("Testing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let result = testResult {
                            resultBanner(result)
                        }

                        Text("Get your key from [cloud.lambdalabs.com/api-keys](https://cloud.lambdalabs.com/api-keys)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                Divider()

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

            }
            .formStyle(.columns)
            .padding()

            Divider()

            HStack {
                Spacer()

                Button("Done") {
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings-done-button")
            }
            .padding()
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: true)
        // No `.accessibilityIdentifier` here: a root identifier propagates to
        // every descendant in SwiftUI, overriding per-control identifiers like
        // `settings-api-key-field` that tests query.
        .onAppear {
            if let existing = apiService.resolvedAPIKey {
                apiKey = existing
                testAPIKey()
            }
            if apiService.sshKeys.isEmpty && apiService.hasAPIKey {
                apiService.fetchSSHKeys()
            }
            if apiService.images.isEmpty && apiService.hasAPIKey {
                apiService.fetchImages()
            }
        }
    }

    @ViewBuilder
    private func resultBanner(_ result: TestResult) -> some View {
        switch result {
        case .success:
            Label("API key is valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)

        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func testAPIKey() {
        isTesting = true
        testResult = nil
        Task {
            let result = await apiService.testAPIKey(apiKey)
            isTesting = false
            switch result {
            case .success:
                let saved = KeychainService.save(apiKey: apiKey)
                if saved {
                    testResult = .success
                    apiService.startAutoRefresh()
                    apiService.fetchSSHKeys()
                } else {
                    testResult = .failure("Failed to save key to Keychain")
                }
            case .failure(let error):
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private func done() {
        dismiss()
    }

    private func confirmAndClearKey() {
        let alert = NSAlert()
        alert.messageText = "Clear API Key?"
        alert.informativeText = "This will remove your saved API key. You'll need to re-enter it to continue monitoring."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn {
            KeychainService.delete()
            apiKey = ""
            testResult = nil
            apiService.stopAutoRefresh()
            apiService.instances = []
            apiService.sshKeys = []
            apiService.selectedSSHKeyName = ""
            apiService.images = []
            apiService.selectedImageFamily = ""
            apiService.error = "No API key configured"
        }
    }
}

// MARK: - Previews

#Preview("With Keys") {
    SettingsView(apiService: PreviewService.populated())
}

#Preview("No API Key") {
    SettingsView(apiService: PreviewService.empty())
}
