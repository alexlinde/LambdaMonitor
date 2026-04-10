import SwiftUI

struct SettingsView: View {
    var apiService: LambdaAPIService
    @Binding var isPresented: Bool

    @State private var apiKey: String = ""
    @State private var sshKeyName: String = UserDefaults.standard.string(forKey: "sshKeyName") ?? ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showClearConfirmation = false

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: { isPresented = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to instance list")

                Spacer()

                Text("Settings")
                    .font(.headline)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Lambda API Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SecureField("Enter your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Get your key from [cloud.lambdalabs.com/api-keys](https://cloud.lambdalabs.com/api-keys)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SSH Key Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("e.g. my-laptop-key", text: $sshKeyName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: sshKeyName) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "sshKeyName")
                    }

                Text("Required for launching instances. Manage keys at [cloud.lambdalabs.com/ssh-keys](https://cloud.lambdalabs.com/ssh-keys)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let result = testResult {
                resultBanner(result)
            }

            HStack {
                Button("Save & Test") {
                    saveAndTest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKey.isEmpty || isTesting)

                if isTesting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }

                Spacer()

                if KeychainService.load() != nil {
                    Button("Clear Key", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .controlSize(.small)
                }
            }

        }
        .alert("Clear API Key?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                KeychainService.delete()
                apiKey = ""
                testResult = nil
                apiService.stopAutoRefresh()
                apiService.instances = []
                apiService.error = "No API key configured"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your saved API key. You'll need to re-enter it to continue monitoring.")
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            if let existing = KeychainService.load() {
                apiKey = existing
            }
        }
    }

    @ViewBuilder
    private func resultBanner(_ result: TestResult) -> some View {
        switch result {
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("API key is valid")
                    .font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .failure(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func saveAndTest() {
        isTesting = true
        testResult = nil

        Task {
            let result = await LambdaAPIService.testAPIKey(apiKey)
            isTesting = false
            switch result {
            case .success:
                let saved = KeychainService.save(apiKey: apiKey)
                if saved {
                    testResult = .success
                    apiService.startAutoRefresh()
                } else {
                    testResult = .failure("Failed to save key to Keychain")
                }
            case .failure(let error):
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}
