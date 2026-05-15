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
    UserDefaults.standard.removeObject(forKey: "imageFamily")
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

    // MARK: - Cold-launch polling

    /// Regression: with `.menuBarExtraStyle(.window)` the popover content is
    /// built lazily, so historically nothing fetched running instances until
    /// the user clicked the menu-bar icon. `AppDelegate` now calls
    /// `startAutoRefresh()` at process launch — this test pins the contract
    /// that the entry point fetches *running* instances (not just instance
    /// types) so the menu-bar icon's running-count badge is accurate on cold
    /// launch.
    @Test("startAutoRefresh() immediately polls running instances")
    @MainActor
    func startAutoRefreshPollsRunningInstancesAtLaunch() async throws {
        let (service, mock) = setUpTestService()
        defer {
            service.stopAutoRefresh()
            cleanupTestState()
        }

        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([MockData.runningH100])

        service.startAutoRefresh()
        try await Task.sleep(for: .milliseconds(100))

        #expect(mock.fetchRunningInstancesCallCount >= 1)
        #expect(mock.fetchInstanceTypesCallCount >= 1)
        #expect(service.runningInstances.count == 1)
        #expect(service.runningInstances.first?.id == MockData.runningH100.id)
        #expect(service.lastUpdated != nil)
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

    // MARK: - Images

    @Test("fetchImages() populates images and derives sorted unique families")
    @MainActor
    func fetchImagesPopulates() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        let extraLambdaStack = LambdaImage(
            id: "lambda-stack-other-region",
            createdTime: Date(timeIntervalSince1970: 0),
            updatedTime: Date(timeIntervalSince1970: 0),
            name: "lambda-stack-22.04",
            description: "Lambda Stack",
            family: "lambda-stack",
            version: "22.04",
            architecture: .x86_64,
            region: MockData.usEast1
        )
        mock.imagesResult = .success([MockData.ubuntuLtsImage, MockData.lambdaStackImage, extraLambdaStack])

        service.fetchImages()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.images.count == 3)
        #expect(service.imageFamilies == ["lambda-stack", "ubuntu-lts"])
        #expect(!service.isLoadingImages)
    }

    @Test("fetchImages() resets selection if family no longer exists")
    @MainActor
    func fetchImagesResetsMissingSelection() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedImageFamily = "no-longer-exists"
        mock.imagesResult = .success([MockData.lambdaStackImage])

        service.fetchImages()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.selectedImageFamily == "")
    }

    @Test("fetchImages() preserves selection when family still present")
    @MainActor
    func fetchImagesPreservesValidSelection() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedImageFamily = "ubuntu-lts"
        mock.imagesResult = .success(MockData.mixedImages)

        service.fetchImages()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.selectedImageFamily == "ubuntu-lts")
    }

    @Test("selectedImageFamily persists via UserDefaults")
    @MainActor
    func selectedImageFamilyPersists() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedImageFamily = "ubuntu-lts"
        #expect(UserDefaults.standard.string(forKey: "imageFamily") == "ubuntu-lts")
        #expect(service.selectedImageFamily == "ubuntu-lts")
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
        service.selectedSSHKeyName = "my-laptop"

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        #expect(service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))

        try await Task.sleep(for: .milliseconds(200))

        #expect(!service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))
        #expect(service.pendingAlert == nil)
        #expect(mock.launchCallCount == 1)
        #expect(mock.lastLaunchedTypeName == "gpu_1x_h100_sxm5")
        #expect(mock.lastLaunchedRegion == "us-west-1")
        #expect(mock.lastLaunchedSSHKeyNames == ["my-laptop"])
        #expect(mock.lastLaunchedImageFamily == nil)
    }

    @Test("launchInstance() forwards selected SSH key as a single-element array")
    @MainActor
    func launchForwardsSSHKey() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-new-ssh"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])
        service.selectedSSHKeyName = "alex-macbook"

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await Task.sleep(for: .milliseconds(200))

        #expect(mock.lastLaunchedSSHKeyNames == ["alex-macbook"])
    }

    @Test("launchInstance() forwards selected image family when set")
    @MainActor
    func launchForwardsImageFamily() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-new-002"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])
        service.selectedSSHKeyName = "my-laptop"
        service.selectedImageFamily = "ubuntu-lts"

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await Task.sleep(for: .milliseconds(200))

        #expect(mock.lastLaunchedSSHKeyNames == ["my-laptop"])
        #expect(mock.lastLaunchedImageFamily == "ubuntu-lts")
    }

    @Test("launchInstance() sends nil image family when default selected")
    @MainActor
    func launchSendsNilForDefaultImage() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-new-003"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])
        service.selectedSSHKeyName = "my-laptop"
        service.selectedImageFamily = ""

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await Task.sleep(for: .milliseconds(200))

        #expect(mock.lastLaunchedImageFamily == nil)
    }

    @Test("launchInstance() shows alert on error")
    @MainActor
    func launchFailure() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .failure(APIError.serverError("No capacity"))
        service.selectedSSHKeyName = "my-laptop"

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

        service.selectedSSHKeyName = ""

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

    // MARK: - Connection state

    /// Regression: with cached instances from a prior successful fetch, a
    /// subsequent network failure must still surface as an error. The
    /// menu-bar icon and "Not connected" footer both key off `error != nil`,
    /// so this guards the contract that the icon shows `icloud.slash`
    /// whenever the footer says "Not connected".
    @Test("fetch() sets error even when instances are already cached")
    @MainActor
    func fetchSetsErrorWithCachedInstances() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!service.instances.isEmpty)
        #expect(service.error == nil)

        mock.instanceTypesResult = .failure(URLError(.notConnectedToInternet))

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!service.instances.isEmpty, "cached instances must be preserved")
        #expect(service.error != nil, "error must be set even though instances is non-empty")
    }

    @Test("fetch() clears error on successful recovery")
    @MainActor
    func fetchClearsErrorOnRecovery() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .failure(URLError(.notConnectedToInternet))
        mock.runningInstancesResult = .success([])

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.error != nil)

        mock.instanceTypesResult = .success(MockData.mixedInstances)

        service.fetch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.error == nil)
    }

    // MARK: - Auto-launch Detection

    @Test("Auto-launch triggers when watched type becomes newly available")
    @MainActor
    func autoLaunchTriggersOnNewAvailability() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedSSHKeyName = "my-laptop"

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
        #expect(mock.lastLaunchedSSHKeyNames == ["my-laptop"])
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
