import Foundation
@preconcurrency import UserNotifications

@MainActor
@Observable
final class LambdaAPIService {
    var instances: [OfferedInstanceType] = []
    var runningInstances: [RunningInstance] = []
    var lastUpdated: Date?
    var error: String?
    var isLoading = false

    var launchState: LaunchState?
    var launchInstanceTypeName: String?
    var terminatingInstanceIds: Set<String> = []
    var watchedTypes: Set<String>

    private var timerTask: Task<Void, Never>?
    private var launchDismissTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 30
    private var previousAvailableTypes: Set<String> = []
    private var hasCompletedInitialFetch = false

    init() {
        watchedTypes = Set(UserDefaults.standard.stringArray(forKey: "watchedInstanceTypes") ?? [])
    }

    var hasAPIKey: Bool {
        KeychainService.load() != nil
    }

    var sshKeyName: String {
        UserDefaults.standard.string(forKey: "sshKeyName") ?? ""
    }

    // MARK: - Auto-refresh

    func startAutoRefresh() {
        timerTask?.cancel()
        fetch()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                fetch()
            }
        }
    }

    func stopAutoRefresh() {
        timerTask?.cancel()
        timerTask = nil
    }

    func fetch() {
        guard let apiKey = KeychainService.load(), !apiKey.isEmpty else {
            error = "No API key configured"
            instances = []
            runningInstances = []
            return
        }

        isLoading = true
        error = nil

        Task {
            async let typesTask = Self.fetchInstanceTypesRaw(apiKey: apiKey)
            async let runningTask = Self.fetchRunningInstancesRaw(apiKey: apiKey)

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
                if self.hasCompletedInitialFetch {
                    let newlyAvailable = currentlyAvailable.subtracting(self.previousAvailableTypes)
                    let watchedNewlyAvailable = newlyAvailable.intersection(self.watchedTypes)
                    for typeName in watchedNewlyAvailable {
                        if let instance = result.first(where: { $0.instanceType.name == typeName }) {
                            self.sendAvailabilityNotification(for: instance)
                        }
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

    // MARK: - Launch Instance

    func launchInstance(typeName: String, regionName: String, fromNotification: Bool = false) {
        guard let apiKey = KeychainService.load(), !apiKey.isEmpty else {
            launchState = .failure("No API key configured")
            launchInstanceTypeName = typeName
            scheduleLaunchDismiss()
            return
        }

        guard !sshKeyName.isEmpty else {
            launchState = .failure("No SSH key name configured — set one in Settings")
            launchInstanceTypeName = typeName
            scheduleLaunchDismiss()
            return
        }

        launchDismissTask?.cancel()
        launchState = .launching
        launchInstanceTypeName = typeName

        Task {
            do {
                let instanceIds = try await Self.launchInstanceRaw(
                    apiKey: apiKey,
                    typeName: typeName,
                    regionName: regionName,
                    sshKeyNames: [sshKeyName]
                )
                self.launchState = .success(instanceIds: instanceIds)
                if fromNotification {
                    self.sendResultNotification(
                        title: "Instance Launched",
                        body: "\(typeName) launched successfully"
                    )
                }
            } catch {
                self.launchState = .failure(error.localizedDescription)
                if fromNotification {
                    self.sendResultNotification(
                        title: "Launch Failed",
                        body: error.localizedDescription
                    )
                }
            }
            self.scheduleLaunchDismiss()
        }
    }

    func clearLaunchState() {
        launchDismissTask?.cancel()
        launchState = nil
        launchInstanceTypeName = nil
    }

    private func scheduleLaunchDismiss() {
        launchDismissTask?.cancel()
        launchDismissTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self.launchState = nil
            self.launchInstanceTypeName = nil
        }
    }

    // MARK: - Terminate Instance

    func terminateInstance(id: String, description: String) {
        guard let apiKey = KeychainService.load(), !apiKey.isEmpty else { return }

        var ids = terminatingInstanceIds
        ids.insert(id)
        terminatingInstanceIds = ids

        Task {
            do {
                try await Self.terminateInstanceRaw(apiKey: apiKey, instanceIds: [id])
                self.fetch()
            } catch {
                self.launchState = .failure("Failed to terminate: \(error.localizedDescription)")
                self.launchInstanceTypeName = description
                self.scheduleLaunchDismiss()
            }
            var current = self.terminatingInstanceIds
            current.remove(id)
            self.terminatingInstanceIds = current
        }
    }

    // MARK: - Watch / Notifications

    func toggleWatch(for typeName: String) {
        var types = watchedTypes
        if types.contains(typeName) {
            types.remove(typeName)
        } else {
            types.insert(typeName)
            requestNotificationPermissionIfNeeded()
        }
        watchedTypes = types
        UserDefaults.standard.set(Array(watchedTypes), forKey: "watchedInstanceTypes")
    }

    func isWatched(_ typeName: String) -> Bool {
        watchedTypes.contains(typeName)
    }

    private static var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationPermissionIfNeeded() {
        guard Self.canUseNotifications else { return }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    private func sendAvailabilityNotification(for instance: OfferedInstanceType) {
        guard Self.canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "GPU Available"
        let regions = instance.regionsWithCapacityAvailable.map(\.description).joined(separator: ", ")
        content.body = "\(instance.instanceType.description) is now available in \(regions)"
        content.sound = .default
        content.categoryIdentifier = "INSTANCE_AVAILABLE"
        content.userInfo = [
            "instanceTypeName": instance.instanceType.name,
            "regionName": instance.regionsWithCapacityAvailable.first?.name ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "availability-\(instance.instanceType.name)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func sendResultNotification(title: String, body: String) {
        guard Self.canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "launch-result-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - API Key Test

    static func testAPIKey(_ key: String) async -> Result<Void, Error> {
        do {
            _ = try await fetchInstanceTypesRaw(apiKey: key)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Raw API Calls

    private static func fetchInstanceTypesRaw(apiKey: String) async throws -> [OfferedInstanceType] {
        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-types")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)
        return Array(decoded.data.values)
    }

    private static func fetchRunningInstancesRaw(apiKey: String) async throws -> [RunningInstance] {
        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instances")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)
        return decoded.data
    }

    private static func terminateInstanceRaw(apiKey: String, instanceIds: [String]) async throws {
        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-operations/terminate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = TerminateInstanceRequest(instanceIds: instanceIds)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(LambdaErrorResponse.self, from: data) {
                throw APIError.launchFailed(errorResponse.error.message)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    private static func launchInstanceRaw(
        apiKey: String,
        typeName: String,
        regionName: String,
        sshKeyNames: [String]
    ) async throws -> [String] {
        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-operations/launch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = LaunchInstanceRequest(
            regionName: regionName,
            instanceTypeName: typeName,
            sshKeyNames: sshKeyNames,
            quantity: 1
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(LambdaErrorResponse.self, from: data) {
                throw APIError.launchFailed(errorResponse.error.message)
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(LaunchInstanceResponse.self, from: data)
        return decoded.data.instanceIds
    }
}

// MARK: - Launch State

enum LaunchState: Equatable {
    case launching
    case success(instanceIds: [String])
    case failure(String)
}

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .unauthorized:
            "Invalid API key"
        case .httpError(let code):
            "HTTP error \(code)"
        case .launchFailed(let message):
            message
        }
    }
}
