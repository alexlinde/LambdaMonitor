import Testing
import Foundation
@testable import LambdaMonitorCore

/// Saves a test API key to Keychain and returns a mock client + service.
/// Caller must call `cleanupTestState()` when done.
@MainActor
private func setUpTestService() -> (LambdaAPIService, MockAPIClient) {
    _ = KeychainService.save(apiKey: "test-key-12345")
    let mock = MockAPIClient()
    let service = LambdaAPIService(client: mock)
    return (service, mock)
}

@MainActor
private func cleanupTestState() {
    KeychainService.delete()
    UserDefaults.standard.removeObject(forKey: "watchedInstanceTypes")
    UserDefaults.standard.removeObject(forKey: "autoLaunchInstanceTypes")
    UserDefaults.standard.removeObject(forKey: "sshKeyName")
}

@Suite("LambdaAPIService", .serialized)
struct LambdaAPIServiceTests {

    // MARK: - Fetch

    @Test("fetch() populates instances and running instances")
    @MainActor
    func fetchPopulatesState() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([MockData.runningH100])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.instances.count == 5)
        #expect(service.runningInstances.count == 1)
        #expect(service.lastUpdated != nil)
        #expect(service.error == nil)
        #expect(!service.isLoading)
    }

    @Test("fetch() sorts available before unavailable, then alphabetically")
    @MainActor
    func fetchSortsCorrectly() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        let availableSlice = service.instances.prefix(while: \.isAvailable)
        let unavailableSlice = service.instances.drop(while: \.isAvailable)

        #expect(availableSlice.count == 3)
        #expect(unavailableSlice.count == 2)
        #expect(unavailableSlice.allSatisfy { !$0.isAvailable })
    }

    @Test("fetch() sets error on API failure")
    @MainActor
    func fetchError() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .failure(APIError.unauthorized)
        mock.runningInstancesResult = .success([])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.error != nil)
    }

    @Test("fetch() without API key sets error and clears data")
    @MainActor
    func fetchWithoutAPIKey() async throws {
        KeychainService.delete()
        defer { cleanupTestState() }

        let mock = MockAPIClient()
        let service = LambdaAPIService(client: mock)

        service.fetch()
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.error == "No API key configured")
        #expect(service.instances.isEmpty)
        #expect(service.runningInstances.isEmpty)
    }

    // MARK: - SSH Keys

    @Test("fetchSSHKeys() populates and sorts keys")
    @MainActor
    func fetchSSHKeys() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.sshKeysResult = .success([MockData.sshKey2, MockData.sshKey1])

        service.fetchSSHKeys()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.sshKeys.count == 2)
        #expect(service.sshKeys[0].name == "my-laptop")
        #expect(service.sshKeys[1].name == "work-desktop")
        #expect(!service.isLoadingSSHKeys)
    }

    @Test("fetchSSHKeys() auto-selects when only one key")
    @MainActor
    func fetchSSHKeysAutoSelects() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.sshKeysResult = .success([MockData.sshKey1])

        service.fetchSSHKeys()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.selectedSSHKeyName == "my-laptop")
    }

    // MARK: - Watch / Auto-launch

    @Test("toggleWatch adds and removes types")
    @MainActor
    func toggleWatch() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        #expect(!service.isWatched("gpu_1x_h100_sxm5"))

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        #expect(service.isWatched("gpu_1x_h100_sxm5"))
        #expect(service.watchedTypes.contains("gpu_1x_h100_sxm5"))

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        #expect(!service.isWatched("gpu_1x_h100_sxm5"))
    }

    @Test("toggleAutoLaunch adds and removes types")
    @MainActor
    func toggleAutoLaunch() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))

        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))

        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))
    }

    @Test("Unwatching a type also disables auto-launch")
    @MainActor
    func unwatchDisablesAutoLaunch() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))
    }

    // MARK: - Launch

    @Test("launchInstance() tracks launching type and calls API")
    @MainActor
    func launchSuccess() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-new-001"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])
        UserDefaults.standard.set("my-laptop", forKey: "sshKeyName")

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        #expect(service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))

        try await Task.sleep(for: .milliseconds(200))

        #expect(!service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))
        #expect(service.pendingAlert == nil)
        #expect(mock.launchCallCount == 1)
        #expect(mock.lastLaunchedTypeName == "gpu_1x_h100_sxm5")
        #expect(mock.lastLaunchedRegion == "us-west-1")
    }

    @Test("launchInstance() shows alert on error")
    @MainActor
    func launchFailure() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .failure(APIError.serverError("No capacity"))
        UserDefaults.standard.set("my-laptop", forKey: "sshKeyName")

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.pendingAlert != nil)
        #expect(service.pendingAlert?.title == "Launch Failed")
        #expect(service.pendingAlert?.message.contains("No capacity") == true)
        #expect(!service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))
    }

    @Test("launchInstance() shows alert without SSH key")
    @MainActor
    func launchWithoutSSHKey() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        UserDefaults.standard.set("", forKey: "sshKeyName")

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")

        #expect(service.pendingAlert != nil)
        #expect(service.pendingAlert?.message.contains("SSH key") == true)
        #expect(mock.launchCallCount == 0)
    }

    // MARK: - Terminate

    @Test("terminateInstance() tracks terminating IDs and calls API")
    @MainActor
    func terminateInstance() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])

        service.terminateInstance(id: "i-abc123", description: "1x H100")
        #expect(service.terminatingInstanceIds.contains("i-abc123"))

        try await Task.sleep(for: .milliseconds(200))

        #expect(mock.terminateCallCount == 1)
        #expect(mock.lastTerminatedIds == ["i-abc123"])
        #expect(!service.terminatingInstanceIds.contains("i-abc123"))
    }

    @Test("terminateInstance() shows alert on failure")
    @MainActor
    func terminateFailure() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.terminateResult = .failure(APIError.serverError("Cannot terminate"))

        service.terminateInstance(id: "i-abc123", description: "1x H100")
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.pendingAlert != nil)
        #expect(service.pendingAlert?.title == "Terminate Failed")
        #expect(service.pendingAlert?.message.contains("Cannot terminate") == true)
    }

    // MARK: - Auto-launch Detection

    @Test("Auto-launch triggers when watched type becomes newly available")
    @MainActor
    func autoLaunchTriggersOnNewAvailability() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        UserDefaults.standard.set("my-laptop", forKey: "sshKeyName")

        let h100Unavailable = OfferedInstanceType(
            instanceType: MockData.h100x1Info,
            regionsWithCapacityAvailable: []
        )
        mock.instanceTypesResult = .success([h100Unavailable])
        mock.runningInstancesResult = .success([])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))

        mock.instanceTypesResult = .success([MockData.h100x1Available])
        mock.launchResult = .success(["i-auto-launched"])

        service.fetch()
        try await Task.sleep(for: .milliseconds(200))

        #expect(mock.launchCallCount == 1)
        #expect(mock.lastLaunchedTypeName == "gpu_1x_h100_sxm5")
        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))
    }

    @Test("Auto-launch does NOT trigger on initial fetch")
    @MainActor
    func autoLaunchSkipsInitialFetch() async throws {
        defer { cleanupTestState() }

        _ = KeychainService.save(apiKey: "test-key-12345")
        UserDefaults.standard.set("my-laptop", forKey: "sshKeyName")
        UserDefaults.standard.set(["gpu_1x_h100_sxm5"], forKey: "watchedInstanceTypes")
        UserDefaults.standard.set(["gpu_1x_h100_sxm5"], forKey: "autoLaunchInstanceTypes")

        let mock = MockAPIClient()
        let freshService = LambdaAPIService(client: mock)
        mock.instanceTypesResult = .success([MockData.h100x1Available])
        mock.runningInstancesResult = .success([])

        freshService.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(mock.launchCallCount == 0)
    }
}
