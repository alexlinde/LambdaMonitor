import Foundation
import UserNotifications

@MainActor
@Observable
public final class LambdaAPIService {
    private enum DefaultsKey {
        static let watchedTypes = "watchedInstanceTypes"
        static let autoLaunchTypes = "autoLaunchInstanceTypes"
        static let autoLaunchConfigs = "autoLaunchConfigs"
        static let sshKeyName = "sshKeyName"
        static let imageFamily = "imageFamily"

        static let all = [watchedTypes, autoLaunchTypes, autoLaunchConfigs, sshKeyName, imageFamily]
    }

    /// Every `UserDefaults` key the service persists. Exposed so UI-test /
    /// unit-test resets clear exactly the keys in use and can't drift.
    public static let persistedDefaultsKeys: [String] = DefaultsKey.all

    public var instances: [OfferedInstanceType] = []
    public var runningInstances: [RunningInstance] = []
    public var lastUpdated: Date?
    public var error: String?
    /// True while at least one `performFetch` is in flight. Settable so
    /// previews can force the loading state.
    public var isLoading = false

    /// Set when the most recently applied fetch could not load the running
    /// instance list. The previous list is kept (so the menu-bar badge doesn't
    /// drop to zero on a transient failure); cleared on the next success.
    public private(set) var runningInstancesError: String?

    /// Whether an API key is available (stored in Keychain or overridden).
    /// Cached so views don't hit the Keychain on every redraw, and stored so
    /// it is observable.
    public private(set) var hasStoredAPIKey: Bool

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

    /// Instance whose *auto-launch* settings the launch window is configuring.
    /// Set when the user toggles auto-launch on: the same dialog collects the
    /// SSH key + image to use when the instance later becomes available, but
    /// confirming stores the choice rather than launching immediately.
    public var pendingAutoLaunchConfig: OfferedInstanceType?

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

    /// Per-type SSH key + image to use when a watched type is auto-launched.
    /// Captured when the user enables auto-launch so each type keeps its own
    /// choice; falls back to the global last-used selection when absent.
    public var autoLaunchConfigs: [String: AutoLaunchConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(autoLaunchConfigs) {
                UserDefaults.standard.set(data, forKey: DefaultsKey.autoLaunchConfigs)
            }
        }
    }

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

    /// Monotonic id assigned to each `performFetch` at start. Results are only
    /// applied when newer than `lastAppliedGeneration`, so overlapping fetches
    /// (timer, manual refresh, post-launch/terminate) can't apply out of order.
    private var fetchGeneration = 0
    private var lastAppliedGeneration = 0
    private var inFlightFetchCount = 0

    /// Bumped whenever the API key is cleared/replaced, so in-flight SSH key
    /// and image fetches started under the old key are discarded.
    private var apiKeyEpoch = 0

    private let client: APIClient
    private let apiKeyOverride: String?
    /// In-memory copy of the Keychain key (nil when no key is stored).
    private var cachedAPIKey: String?

    public init(client: APIClient = LiveAPIClient(), apiKeyOverride: String? = nil) {
        self.client = client
        self.apiKeyOverride = apiKeyOverride
        // Never touch the real Keychain item when running with an override
        // (mock / UI-test / preview modes).
        let stored = apiKeyOverride == nil ? KeychainService.load() : nil
        cachedAPIKey = stored
        hasStoredAPIKey = apiKeyOverride != nil || !(stored ?? "").isEmpty
        watchedTypes = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.watchedTypes) ?? [])
        autoLaunchTypes = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.autoLaunchTypes) ?? [])
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.autoLaunchConfigs),
           let decoded = try? JSONDecoder().decode([String: AutoLaunchConfig].self, from: data) {
            autoLaunchConfigs = decoded
        } else {
            autoLaunchConfigs = [:]
        }
        selectedSSHKeyName = UserDefaults.standard.string(forKey: DefaultsKey.sshKeyName) ?? ""
        selectedImageFamily = UserDefaults.standard.string(forKey: DefaultsKey.imageFamily) ?? ""
    }

    public var hasAPIKey: Bool {
        hasStoredAPIKey
    }

    public var resolvedAPIKey: String? {
        apiKeyOverride ?? cachedAPIKey
    }

    public var hasAPIKeyOverride: Bool {
        apiKeyOverride != nil
    }

    /// Persists `key` to the Keychain and updates the cached state. With an
    /// `apiKeyOverride` (mock / UI-test mode) this is a no-op that returns
    /// true: the fake key must never overwrite the real Keychain item.
    @discardableResult
    public func saveAPIKey(_ key: String) -> Bool {
        guard apiKeyOverride == nil else { return true }
        guard KeychainService.save(apiKey: key) else { return false }
        if cachedAPIKey != key {
            apiKeyEpoch += 1
        }
        cachedAPIKey = key
        hasStoredAPIKey = !key.isEmpty
        return true
    }

    /// Removes the stored key and resets all account-derived state. In-flight
    /// fetches are invalidated so they can't repopulate data after clearing.
    /// No-op with an `apiKeyOverride` (the override can't be cleared).
    public func clearAPIKey() {
        guard apiKeyOverride == nil else { return }
        KeychainService.delete()
        cachedAPIKey = nil
        hasStoredAPIKey = false
        apiKeyEpoch += 1

        stopAutoRefresh()
        // Discard any fetch currently in flight.
        fetchGeneration += 1
        lastAppliedGeneration = fetchGeneration

        instances = []
        runningInstances = []
        runningInstancesError = nil
        sshKeys = []
        images = []
        selectedSSHKeyName = ""
        selectedImageFamily = ""
        lastUpdated = nil
        previousAvailableTypes = []
        hasCompletedInitialFetch = false
        error = "No API key configured"
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

    /// Awaitable refresh, for callers that need to know when the data has been
    /// updated (tests, pull-to-refresh style flows).
    public func refresh() async {
        await performFetch()
    }

    /// Awaitable refresh. Used by the periodic timer and `fetch()`, and also
    /// `await`ed by the launch/terminate flows so the progress window stays up
    /// until the running-instance list reflects the change.
    ///
    /// Fetches can overlap; each gets a generation number and its results are
    /// applied only if no newer fetch has already been applied.
    private func performFetch() async {
        fetchGeneration += 1
        let generation = fetchGeneration

        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            lastAppliedGeneration = max(lastAppliedGeneration, generation)
            error = "No API key configured"
            instances = []
            runningInstances = []
            return
        }

        inFlightFetchCount += 1
        isLoading = true
        defer {
            inFlightFetchCount -= 1
            isLoading = inFlightFetchCount > 0
        }

        async let typesTask = client.fetchInstanceTypes(apiKey: apiKey)
        async let runningTask = client.fetchRunningInstances(apiKey: apiKey)

        let typesResult: Result<[OfferedInstanceType], Error>
        do {
            typesResult = .success(try await typesTask)
        } catch {
            typesResult = .failure(error)
        }
        let runningResult: Result<[RunningInstance], Error>
        do {
            runningResult = .success(try await runningTask)
        } catch {
            runningResult = .failure(error)
        }

        // Drop stale results: a newer fetch already landed (or the key was
        // cleared while this one was in flight).
        guard generation > lastAppliedGeneration else { return }
        lastAppliedGeneration = generation

        switch typesResult {
        case .success(let result):
            applyInstanceTypes(result)
        case .failure(let error):
            self.error = error.localizedDescription
        }

        switch runningResult {
        case .success(let running):
            runningInstances = running
            runningInstancesError = nil
        case .failure(let error):
            // Keep the previous list; a transient failure must not look like
            // "0 running".
            runningInstancesError = error.localizedDescription
        }
    }

    private func applyInstanceTypes(_ result: [OfferedInstanceType]) {
        instances = result.sorted { lhs, rhs in
            if lhs.isAvailable != rhs.isAvailable {
                return lhs.isAvailable
            }
            return lhs.instanceType.description.localizedStandardCompare(rhs.instanceType.description) == .orderedAscending
        }
        lastUpdated = Date()
        error = nil

        let currentlyAvailable = Set(result.filter(\.isAvailable).map(\.instanceType.name))
        if hasCompletedInitialFetch {
            let newlyAvailable = currentlyAvailable.subtracting(previousAvailableTypes)
            let autoLaunchCandidates = newlyAvailable.intersection(autoLaunchTypes).sorted()
            for typeName in autoLaunchCandidates {
                guard let instance = result.first(where: { $0.instanceType.name == typeName }),
                      let region = instance.regionsWithCapacityAvailable.first else { continue }
                // Prefer the per-type choice captured when auto-launch was
                // enabled; fall back to the global last-used selection.
                let config = autoLaunchConfigs[typeName]
                let sshKey = config?.sshKeyName ?? selectedSSHKeyName
                let imageFamily = config?.imageFamily ?? selectedImageFamily
                guard !sshKey.isEmpty else {
                    // Leave auto-launch enabled so it fires once a key is set
                    // and the type becomes newly available again.
                    postAutoLaunchFailureNotification(
                        displayName: instance.instanceType.description,
                        error: "No SSH key configured for auto-launch"
                    )
                    continue
                }
                disableAutoLaunch(for: typeName)
                launchInstance(
                    typeName: typeName,
                    regionName: region.name,
                    autoLaunched: true,
                    displayName: instance.instanceType.description,
                    sshKeyName: sshKey,
                    imageFamily: imageFamily
                )
            }
        }
        previousAvailableTypes = currentlyAvailable
        hasCompletedInitialFetch = true
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
        let epoch = apiKeyEpoch
        Task {
            defer { self.isLoadingSSHKeys = false }
            do {
                let keys = try await client.fetchSSHKeys(apiKey: apiKey)
                guard epoch == self.apiKeyEpoch else { return }
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
        }
    }

    // MARK: - Images

    public func fetchImages() {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else { return }

        isLoadingImages = true
        let epoch = apiKeyEpoch
        Task {
            defer { self.isLoadingImages = false }
            do {
                let fetched = try await client.fetchImages(apiKey: apiKey)
                guard epoch == self.apiKeyEpoch else { return }
                self.images = fetched
                let families = Set(fetched.map(\.family))
                if !self.selectedImageFamily.isEmpty,
                   !families.contains(self.selectedImageFamily) {
                    self.selectedImageFamily = ""
                }
            } catch {
                // Image fetch failures are non-critical
            }
        }
    }

    // MARK: - Launch Instance

    public func launchInstance(
        typeName: String,
        regionName: String,
        instanceDescription: String? = nil,
        regionDescription: String? = nil,
        autoLaunched: Bool = false,
        displayName: String? = nil,
        sshKeyName: String? = nil,
        imageFamily: String? = nil
    ) {
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            if !autoLaunched {
                pendingAlert = AlertInfo(title: "Launch Failed", message: "No API key configured")
            }
            return
        }

        // Resolve the SSH key + image, defaulting to the global last-used
        // selection when no explicit override is provided.
        let keyName = sshKeyName ?? selectedSSHKeyName
        let resolvedImageFamily = imageFamily ?? selectedImageFamily

        guard !keyName.isEmpty else {
            if !autoLaunched {
                pendingAlert = AlertInfo(title: "Launch Failed", message: "No SSH key selected — choose one in the launch dialog")
            }
            return
        }

        launchingTypeNames.insert(typeName)

        if !autoLaunched {
            activeLaunchProgress = LaunchOperationProgress(
                typeName: typeName,
                instanceDescription: instanceDescription ?? typeName,
                regionDescription: regionDescription ?? regionName,
                sshKeyName: keyName,
                imageDescription: imageDisplayName(for: resolvedImageFamily)
            )
        }

        let imageFamilyParam = resolvedImageFamily.isEmpty ? nil : resolvedImageFamily

        Task {
            let started = ContinuousClock.now
            do {
                let instanceIds = try await client.launchInstance(
                    apiKey: apiKey,
                    typeName: typeName,
                    regionName: regionName,
                    sshKeyNames: [keyName],
                    imageFamily: imageFamilyParam
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
                var message = error.localizedDescription
                if Self.launchMayHaveSucceeded(despite: error) {
                    message += Self.launchMayHaveSucceededHint
                }
                if autoLaunched {
                    let name = displayName ?? typeName
                    self.postAutoLaunchFailureNotification(
                        displayName: name, error: message
                    )
                } else {
                    self.pendingAlert = AlertInfo(
                        title: "Launch Failed",
                        message: "\(typeName): \(message)"
                    )
                }
                // Refresh so an instance that launched despite the error
                // (e.g. a timed-out POST) shows up in the running list.
                self.fetch()
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
            // Clear the launch-window subject only once the operation finishes,
            // so the single launch dialog shows its in-progress spinner inline
            // (rather than swapping to a separate progress window) and then
            // dismisses itself.
            if !autoLaunched, self.pendingLaunch?.instanceType.name == typeName {
                self.pendingLaunch = nil
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

    static let launchMayHaveSucceededHint =
        " The instance may still have launched — check Running instances before retrying."

    /// Whether a launch error leaves the outcome unknown: the POST may have
    /// reached the server and created the instance even though we never saw
    /// the response (timeouts, dropped connections, gateway errors).
    nonisolated static func launchMayHaveSucceeded(despite error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .badServerResponse,
                 .cannotParseResponse, .zeroByteResource:
                return true
            default:
                return false
            }
        }
        if let apiError = error as? APIError, case .httpError(let code) = apiError {
            return [502, 503, 504].contains(code)
        }
        return false
    }

    private func imageDisplayName(for family: String) -> String {
        family.isEmpty ? "Lambda Stack (latest)" : family
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
            autoLaunchConfigs[typeName] = nil
        } else {
            types.insert(typeName)
        }
        autoLaunchTypes = types
        UserDefaults.standard.set(Array(autoLaunchTypes), forKey: DefaultsKey.autoLaunchTypes)
    }

    /// Enables auto-launch for `typeName`, capturing the SSH key + image to use
    /// when the type later becomes available. Also updates the global last-used
    /// selection so the next dialog preselects the same values.
    public func configureAutoLaunch(typeName: String, sshKeyName: String, imageFamily: String) {
        autoLaunchConfigs[typeName] = AutoLaunchConfig(sshKeyName: sshKeyName, imageFamily: imageFamily)
        var types = autoLaunchTypes
        types.insert(typeName)
        autoLaunchTypes = types
        UserDefaults.standard.set(Array(autoLaunchTypes), forKey: DefaultsKey.autoLaunchTypes)
        if !sshKeyName.isEmpty {
            selectedSSHKeyName = sshKeyName
        }
        selectedImageFamily = imageFamily
    }

    public func isAutoLaunch(_ typeName: String) -> Bool {
        autoLaunchTypes.contains(typeName)
    }

    private func disableAutoLaunch(for typeName: String) {
        var types = autoLaunchTypes
        types.remove(typeName)
        autoLaunchTypes = types
        UserDefaults.standard.set(Array(autoLaunchTypes), forKey: DefaultsKey.autoLaunchTypes)
        autoLaunchConfigs[typeName] = nil
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

// MARK: - Auto-launch config

/// SSH key + image family captured when a watched type's auto-launch is
/// enabled, used when the type later becomes available. An empty `imageFamily`
/// means "Lambda Stack (latest)".
public struct AutoLaunchConfig: Codable, Equatable, Sendable {
    public var sshKeyName: String
    public var imageFamily: String

    public init(sshKeyName: String, imageFamily: String) {
        self.sshKeyName = sshKeyName
        self.imageFamily = imageFamily
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
