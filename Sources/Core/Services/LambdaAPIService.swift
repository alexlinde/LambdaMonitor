import Foundation
import UserNotifications

@MainActor
@Observable
public final class LambdaAPIService {
    private enum DefaultsKey {
        static let watchedTypes = "watchedInstanceTypes"
        static let autoLaunchTypes = "autoLaunchInstanceTypes"
        static let sshKeyName = "sshKeyName"
    }

    public var instances: [OfferedInstanceType] = []
    public var runningInstances: [RunningInstance] = []
    public var lastUpdated: Date?
    public var error: String?
    public var isLoading = false

    public var sshKeys: [SSHKey] = []
    public var isLoadingSSHKeys = false

    public var launchingTypeNames: Set<String> = []
    public var terminatingInstanceIds: Set<String> = []
    public var pendingAlert: AlertInfo?
    public var watchedTypes: Set<String>
    public var autoLaunchTypes: Set<String>

    private var timerTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 30
    private var previousAvailableTypes: Set<String> = []
    private var hasCompletedInitialFetch = false

    private let client: APIClient
    private let apiKeyOverride: String?

    public init(client: APIClient = LiveAPIClient(), apiKeyOverride: String? = nil) {
        self.client = client
        self.apiKeyOverride = apiKeyOverride
        watchedTypes = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.watchedTypes) ?? [])
        autoLaunchTypes = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.autoLaunchTypes) ?? [])
    }

    public var hasAPIKey: Bool {
        apiKeyOverride != nil || KeychainService.load() != nil
    }

    public var resolvedAPIKey: String? {
        if let override = apiKeyOverride { return override }
        return KeychainService.load()
    }

    public var hasAPIKeyOverride: Bool {
        apiKeyOverride != nil
    }

    public var selectedSSHKeyName: String {
        get { UserDefaults.standard.string(forKey: DefaultsKey.sshKeyName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.sshKeyName) }
    }

    // MARK: - Auto-refresh

    public func startAutoRefresh() {
        timerTask?.cancel()
        fetch()
        fetchSSHKeys()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                fetch()
            }
        }
    }

    public func stopAutoRefresh() {
        timerTask?.cancel()
        timerTask = nil
    }

    public func fetch() {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            error = "No API key configured"
            instances = []
            runningInstances = []
            return
        }

        isLoading = true
        error = nil

        Task {
            async let typesTask = client.fetchInstanceTypes(apiKey: apiKey)
            async let runningTask = client.fetchRunningInstances(apiKey: apiKey)

            do {
                let result = try await typesTask
                self.instances = result.sorted { lhs, rhs in
                    if lhs.isAvailable != rhs.isAvailable {
                        return lhs.isAvailable
                    }
                    return lhs.instanceType.description.localizedStandardCompare(rhs.instanceType.description) == .orderedAscending
                }
                self.lastUpdated = Date()
                self.error = nil

                let currentlyAvailable = Set(result.filter(\.isAvailable).map(\.instanceType.name))
                if self.hasCompletedInitialFetch && !self.selectedSSHKeyName.isEmpty {
                    let newlyAvailable = currentlyAvailable.subtracting(self.previousAvailableTypes)
                    let autoLaunchCandidates = newlyAvailable.intersection(self.autoLaunchTypes)
                    if let typeName = autoLaunchCandidates.first,
                       let instance = result.first(where: { $0.instanceType.name == typeName }),
                       let region = instance.regionsWithCapacityAvailable.first {
                        self.disableAutoLaunch(for: typeName)
                        self.launchInstance(typeName: typeName, regionName: region.name, autoLaunched: true, displayName: instance.instanceType.description)
                    }
                }
                self.previousAvailableTypes = currentlyAvailable
                self.hasCompletedInitialFetch = true
            } catch {
                self.error = error.localizedDescription
            }

            self.runningInstances = (try? await runningTask) ?? []
            self.isLoading = false
        }
    }

    // MARK: - SSH Keys

    public func fetchSSHKeys() {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else { return }

        isLoadingSSHKeys = true
        Task {
            do {
                let keys = try await client.fetchSSHKeys(apiKey: apiKey)
                self.sshKeys = keys.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if !self.selectedSSHKeyName.isEmpty,
                   !keys.contains(where: { $0.name == self.selectedSSHKeyName }) {
                    self.selectedSSHKeyName = ""
                }
                if self.selectedSSHKeyName.isEmpty, self.sshKeys.count == 1 {
                    self.selectedSSHKeyName = self.sshKeys[0].name
                }
            } catch {
                // SSH key fetch failures are non-critical
            }
            self.isLoadingSSHKeys = false
        }
    }

    // MARK: - Launch Instance

    public func launchInstance(typeName: String, regionName: String, autoLaunched: Bool = false, displayName: String? = nil) {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            if !autoLaunched {
                pendingAlert = AlertInfo(title: "Launch Failed", message: "No API key configured")
            }
            return
        }

        guard !selectedSSHKeyName.isEmpty else {
            if !autoLaunched {
                pendingAlert = AlertInfo(title: "Launch Failed", message: "No SSH key selected — choose one in Settings")
            }
            return
        }

        launchingTypeNames.insert(typeName)

        Task {
            do {
                let instanceIds = try await client.launchInstance(
                    apiKey: apiKey,
                    typeName: typeName,
                    regionName: regionName,
                    sshKeyNames: [selectedSSHKeyName]
                )
                if autoLaunched {
                    let name = displayName ?? typeName
                    self.postAutoLaunchNotification(
                        displayName: name, regionName: regionName, instanceId: instanceIds.first
                    )
                }
                self.fetch()
            } catch {
                if autoLaunched {
                    let name = displayName ?? typeName
                    self.postAutoLaunchFailureNotification(
                        displayName: name, error: error.localizedDescription
                    )
                } else {
                    self.pendingAlert = AlertInfo(
                        title: "Launch Failed",
                        message: "\(typeName): \(error.localizedDescription)"
                    )
                }
            }
            self.launchingTypeNames.remove(typeName)
        }
    }

    // MARK: - Terminate Instance

    public func terminateInstance(id: String, description: String) {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else { return }

        terminatingInstanceIds.insert(id)

        Task {
            do {
                try await client.terminateInstance(apiKey: apiKey, instanceIds: [id])
                self.fetch()
            } catch {
                self.pendingAlert = AlertInfo(
                    title: "Terminate Failed",
                    message: "\(description): \(error.localizedDescription)"
                )
            }
            self.terminatingInstanceIds.remove(id)
        }
    }

    // MARK: - Watch / Auto-launch

    public func toggleWatch(for typeName: String) {
        var types = watchedTypes
        if types.contains(typeName) {
            types.remove(typeName)
            disableAutoLaunch(for: typeName)
        } else {
            types.insert(typeName)
        }
        watchedTypes = types
        UserDefaults.standard.set(Array(watchedTypes), forKey: DefaultsKey.watchedTypes)
    }

    public func isWatched(_ typeName: String) -> Bool {
        watchedTypes.contains(typeName)
    }

    public func toggleAutoLaunch(for typeName: String) {
        var types = autoLaunchTypes
        if types.contains(typeName) {
            types.remove(typeName)
        } else {
            types.insert(typeName)
        }
        autoLaunchTypes = types
        UserDefaults.standard.set(Array(autoLaunchTypes), forKey: DefaultsKey.autoLaunchTypes)
    }

    public func isAutoLaunch(_ typeName: String) -> Bool {
        autoLaunchTypes.contains(typeName)
    }

    private func disableAutoLaunch(for typeName: String) {
        var types = autoLaunchTypes
        types.remove(typeName)
        autoLaunchTypes = types
        UserDefaults.standard.set(Array(autoLaunchTypes), forKey: DefaultsKey.autoLaunchTypes)
    }

    // MARK: - Notifications

    public static func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private nonisolated func postAutoLaunchNotification(displayName: String, regionName: String, instanceId: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Instance Auto-Launched"
        content.body = "\(displayName) launched in \(regionName)"
        // if let id = instanceId {
        //     content.body += "\nID: \(id)"
        // }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "auto-launch-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private nonisolated func postAutoLaunchFailureNotification(displayName: String, error: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Auto-Launch Failed"
        content.body = "\(displayName): \(error)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "auto-launch-fail-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - API Key Test

    public func testAPIKey(_ key: String) async -> Result<Void, Error> {
        do {
            _ = try await client.fetchInstanceTypes(apiKey: key)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Alert Info

public struct AlertInfo: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

// MARK: - API Errors

public enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .unauthorized:
            "Invalid API key"
        case .httpError(let code):
            "HTTP error \(code)"
        case .serverError(let message):
            message
        }
    }
}
