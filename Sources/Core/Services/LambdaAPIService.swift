import Foundation
import UserNotifications

@MainActor
@Observable
public final class LambdaAPIService {
    private enum DefaultsKey {
        static let watchedTypes = "watchedInstanceTypes"
        static let autoLaunchTypes = "autoLaunchInstanceTypes"
        static let sshKeyName = "sshKeyName"
        static let imageFamily = "imageFamily"
    }

    public var instances: [OfferedInstanceType] = []
    public var runningInstances: [RunningInstance] = []
    public var lastUpdated: Date?
    public var error: String?
    public var isLoading = false

    public var sshKeys: [SSHKey] = []
    public var isLoadingSSHKeys = false

    public var images: [LambdaImage] = []
    public var isLoadingImages = false

    public var imageFamilies: [String] {
        let families = Set(images.map(\.family))
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var launchingTypeNames: Set<String> = []
    public var terminatingInstanceIds: Set<String> = []
    public var activeLaunchProgress: LaunchOperationProgress?
    public var activeTerminateProgress: TerminateOperationProgress?

    /// Instance the launch window is configuring. Held as a snapshot so a
    /// background refresh can't yank the subject out from under the dialog.
    /// The launch window is "done" once both this and `activeLaunchProgress`
    /// are nil.
    public var pendingLaunch: OfferedInstanceType?

    /// Instance the terminate window is confirming. Same snapshot rationale as
    /// `pendingLaunch`; the terminate window is "done" once both this and
    /// `activeTerminateProgress` are nil.
    public var pendingTerminate: RunningInstance?

    /// Minimum time the launch/terminate progress window stays on screen, so a
    /// fast API response doesn't make the window flash open and closed before
    /// the user can register it. Overridable for tests (set to `.zero`).
    public var minimumSpinnerDuration: Duration = .milliseconds(800)

    public var pendingAlert: AlertInfo?
    public var watchedTypes: Set<String>
    public var autoLaunchTypes: Set<String>

    public var selectedSSHKeyName: String {
        didSet {
            UserDefaults.standard.set(selectedSSHKeyName, forKey: DefaultsKey.sshKeyName)
        }
    }

    public var selectedImageFamily: String {
        didSet {
            UserDefaults.standard.set(selectedImageFamily, forKey: DefaultsKey.imageFamily)
        }
    }

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
        selectedSSHKeyName = UserDefaults.standard.string(forKey: DefaultsKey.sshKeyName) ?? ""
        selectedImageFamily = UserDefaults.standard.string(forKey: DefaultsKey.imageFamily) ?? ""
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

    // MARK: - Auto-refresh

    public func startAutoRefresh() {
        timerTask?.cancel()
        fetch()
        fetchSSHKeys()
        fetchImages()
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
        Task { await self.performFetch() }
    }

    /// Awaitable refresh. Used by the periodic timer and `fetch()`, and also
    /// `await`ed by the launch/terminate flows so the progress window stays up
    /// until the running-instance list reflects the change.
    private func performFetch() async {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            error = "No API key configured"
            instances = []
            runningInstances = []
            return
        }

        isLoading = true
        error = nil

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

    /// Keeps the progress window visible for at least `minimumSpinnerDuration`,
    /// so an instant API response doesn't make it flash open and closed.
    private func holdSpinnerVisible(since start: ContinuousClock.Instant) async {
        let elapsed = ContinuousClock.now - start
        if elapsed < minimumSpinnerDuration {
            try? await Task.sleep(for: minimumSpinnerDuration - elapsed)
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

    // MARK: - Images

    public func fetchImages() {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else { return }

        isLoadingImages = true
        Task {
            do {
                let fetched = try await client.fetchImages(apiKey: apiKey)
                self.images = fetched
                let families = Set(fetched.map(\.family))
                if !self.selectedImageFamily.isEmpty,
                   !families.contains(self.selectedImageFamily) {
                    self.selectedImageFamily = ""
                }
            } catch {
                // Image fetch failures are non-critical
            }
            self.isLoadingImages = false
        }
    }

    // MARK: - Launch Instance

    public func launchInstance(
        typeName: String,
        regionName: String,
        instanceDescription: String? = nil,
        regionDescription: String? = nil,
        autoLaunched: Bool = false,
        displayName: String? = nil
    ) {
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

        if !autoLaunched {
            activeLaunchProgress = LaunchOperationProgress(
                typeName: typeName,
                instanceDescription: instanceDescription ?? typeName,
                regionDescription: regionDescription ?? regionName,
                sshKeyName: selectedSSHKeyName,
                imageDescription: selectedImageDisplayName
            )
        }

        let imageFamily = selectedImageFamily.isEmpty ? nil : selectedImageFamily

        Task {
            let started = ContinuousClock.now
            do {
                let instanceIds = try await client.launchInstance(
                    apiKey: apiKey,
                    typeName: typeName,
                    regionName: regionName,
                    sshKeyNames: [selectedSSHKeyName],
                    imageFamily: imageFamily
                )
                if autoLaunched {
                    let name = displayName ?? typeName
                    self.postAutoLaunchNotification(
                        displayName: name, regionName: regionName, instanceId: instanceIds.first
                    )
                }
                // Awaited (not fire-and-forget) so the progress window stays up
                // until the newly launched instance appears in the running list.
                await self.performFetch()
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
            // Visible progress only exists for user-initiated launches; the
            // auto-launch path runs silently in the background.
            if !autoLaunched {
                await self.holdSpinnerVisible(since: started)
            }
            self.launchingTypeNames.remove(typeName)
            if self.activeLaunchProgress?.typeName == typeName {
                self.activeLaunchProgress = nil
            }
        }
    }

    // MARK: - Terminate Instance

    public func terminateInstance(
        id: String,
        description: String,
        regionDescription: String? = nil
    ) {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else { return }

        terminatingInstanceIds.insert(id)
        activeTerminateProgress = TerminateOperationProgress(
            instanceId: id,
            instanceDescription: description,
            regionDescription: regionDescription ?? ""
        )

        Task {
            let started = ContinuousClock.now
            do {
                try await client.terminateInstance(apiKey: apiKey, instanceIds: [id])
                // Awaited so the progress window stays up until the terminated
                // instance has dropped out of the running list.
                await self.performFetch()
            } catch {
                self.pendingAlert = AlertInfo(
                    title: "Terminate Failed",
                    message: "\(description): \(error.localizedDescription)"
                )
            }
            await self.holdSpinnerVisible(since: started)
            self.terminatingInstanceIds.remove(id)
            if self.activeTerminateProgress?.instanceId == id {
                self.activeTerminateProgress = nil
            }
        }
    }

    private var selectedImageDisplayName: String {
        if selectedImageFamily.isEmpty {
            return "Lambda Stack (latest)"
        }
        return selectedImageFamily
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

// MARK: - In-flight operations (drives progress sheets)

public struct LaunchOperationProgress: Equatable, Sendable, Identifiable {
    public var id: String { typeName }
    public let typeName: String
    public let instanceDescription: String
    public let regionDescription: String
    public let sshKeyName: String
    public let imageDescription: String

    public init(
        typeName: String,
        instanceDescription: String,
        regionDescription: String,
        sshKeyName: String,
        imageDescription: String
    ) {
        self.typeName = typeName
        self.instanceDescription = instanceDescription
        self.regionDescription = regionDescription
        self.sshKeyName = sshKeyName
        self.imageDescription = imageDescription
    }
}

public struct TerminateOperationProgress: Equatable, Sendable, Identifiable {
    public var id: String { instanceId }
    public let instanceId: String
    public let instanceDescription: String
    public let regionDescription: String

    public init(instanceId: String, instanceDescription: String, regionDescription: String) {
        self.instanceId = instanceId
        self.instanceDescription = instanceDescription
        self.regionDescription = regionDescription
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
