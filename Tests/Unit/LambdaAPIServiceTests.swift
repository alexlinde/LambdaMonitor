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
    // Tests assert progress clears within ~200ms, so disable the production
    // minimum spinner-visibility hold.
    service.minimumSpinnerDuration = .zero
    return (service, mock)
}

@MainActor
private func cleanupTestState() {
    KeychainService.delete()
    for key in LambdaAPIService.persistedDefaultsKeys {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Polls `condition` every ~10ms until it holds, recording an issue if it
/// doesn't within `timeout`. Replaces fixed sleeps, which flake under load.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ description: String = "condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Thread-safe recorder for values reported from mock callbacks, which run
/// off the main actor.
private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.withLock { storage.append(value) } }
    var values: [T] { lock.withLock { storage } }
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

        await service.refresh()

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

        await service.refresh()

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

        await service.refresh()

        #expect(service.error != nil)
    }

    @Test("fetch() without API key sets error and clears data")
    @MainActor
    func fetchWithoutAPIKey() async throws {
        KeychainService.delete()
        defer { cleanupTestState() }

        let mock = MockAPIClient()
        let service = LambdaAPIService(client: mock)

        await service.refresh()

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
        try await waitUntil("running instances to load") { service.runningInstances.count == 1 }

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
        try await waitUntil("SSH keys to load") { !service.isLoadingSSHKeys }

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
        try await waitUntil("SSH keys to load") { !service.isLoadingSSHKeys }

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
        try await waitUntil("images to load") { !service.isLoadingImages }

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
        try await waitUntil("images to load") { !service.isLoadingImages }

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
        try await waitUntil("images to load") { !service.isLoadingImages }

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

    @Test("configureAutoLaunch enables, stores per-type config, and updates last-used")
    @MainActor
    func configureAutoLaunchStoresConfig() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        service.configureAutoLaunch(
            typeName: "gpu_1x_h100_sxm5",
            sshKeyName: "work-desktop",
            imageFamily: "ubuntu-lts"
        )

        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))
        #expect(service.autoLaunchConfigs["gpu_1x_h100_sxm5"]
            == AutoLaunchConfig(sshKeyName: "work-desktop", imageFamily: "ubuntu-lts"))
        // Remembered as the new last-used selection.
        #expect(service.selectedSSHKeyName == "work-desktop")
        #expect(service.selectedImageFamily == "ubuntu-lts")
    }

    @Test("Disabling auto-launch clears its stored config")
    @MainActor
    func disableAutoLaunchClearsConfig() async throws {
        let (service, _) = setUpTestService()
        defer { cleanupTestState() }

        service.configureAutoLaunch(
            typeName: "gpu_1x_h100_sxm5", sshKeyName: "my-laptop", imageFamily: ""
        )
        #expect(service.autoLaunchConfigs["gpu_1x_h100_sxm5"] != nil)

        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))
        #expect(service.autoLaunchConfigs["gpu_1x_h100_sxm5"] == nil)
    }

    @Test("Auto-launch uses the per-type config's SSH key and image")
    @MainActor
    func autoLaunchUsesPerTypeConfig() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        // A different global selection should be ignored in favor of the
        // per-type config captured when auto-launch was enabled.
        service.selectedSSHKeyName = "my-laptop"
        service.selectedImageFamily = ""

        let h100Unavailable = OfferedInstanceType(
            instanceType: MockData.h100x1Info,
            regionsWithCapacityAvailable: []
        )
        mock.instanceTypesResult = .success([h100Unavailable])
        mock.runningInstancesResult = .success([])

        await service.refresh()

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        service.configureAutoLaunch(
            typeName: "gpu_1x_h100_sxm5", sshKeyName: "work-desktop", imageFamily: "ubuntu-lts"
        )

        mock.instanceTypesResult = .success([MockData.h100x1Available])
        mock.launchResult = .success(["i-auto-config"])

        await service.refresh()
        try await waitUntil("auto-launch to finish") {
            mock.launchCallCount == 1 && service.launchingTypeNames.isEmpty
        }

        #expect(mock.launchCallCount == 1)
        #expect(mock.lastLaunchedSSHKeyNames == ["work-desktop"])
        #expect(mock.lastLaunchedImageFamily == "ubuntu-lts")
        #expect(!service.isAutoLaunch("gpu_1x_h100_sxm5"))
    }

    @Test("launchInstance() honors explicit SSH key and image overrides")
    @MainActor
    func launchHonorsOverrides() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-override"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])
        service.selectedSSHKeyName = "my-laptop"
        service.selectedImageFamily = ""

        service.launchInstance(
            typeName: "gpu_1x_h100_sxm5",
            regionName: "us-west-1",
            sshKeyName: "work-desktop",
            imageFamily: "ubuntu-lts"
        )
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

        #expect(mock.lastLaunchedSSHKeyNames == ["work-desktop"])
        #expect(mock.lastLaunchedImageFamily == "ubuntu-lts")
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

        service.launchInstance(
            typeName: "gpu_1x_h100_sxm5",
            regionName: "us-west-1",
            instanceDescription: "1x H100",
            regionDescription: "US West"
        )
        #expect(service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))
        #expect(service.activeLaunchProgress?.typeName == "gpu_1x_h100_sxm5")
        #expect(service.activeLaunchProgress?.instanceDescription == "1x H100")
        #expect(service.activeLaunchProgress?.regionDescription == "US West")
        #expect(service.activeLaunchProgress?.sshKeyName == "my-laptop")
        #expect(service.activeLaunchProgress?.imageDescription == "Lambda Stack (latest)")

        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

        #expect(!service.launchingTypeNames.contains("gpu_1x_h100_sxm5"))
        #expect(service.activeLaunchProgress == nil)
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
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

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
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

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
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

        #expect(mock.lastLaunchedImageFamily == nil)
    }

    @Test("Launch dialog selecting a different SSH key and image forwards and remembers them")
    @MainActor
    func dialogSelectionForwardsAndRemembers() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .success(["i-dialog-pick"])
        mock.instanceTypesResult = .success([])
        mock.runningInstancesResult = .success([])

        // Preselected defaults the dialog opens with.
        service.selectedSSHKeyName = "my-laptop"
        service.selectedImageFamily = ""

        // Emulate the dialog's confirm() after the user picks different values:
        // it remembers the choice as last-used and launches with explicit
        // overrides.
        let chosenKey = "work-desktop"
        let chosenImage = "ubuntu-lts"
        service.selectedSSHKeyName = chosenKey
        service.selectedImageFamily = chosenImage
        service.launchInstance(
            typeName: "gpu_1x_h100_sxm5",
            regionName: "us-west-1",
            sshKeyName: chosenKey,
            imageFamily: chosenImage
        )
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

        // Forwarded to the API…
        #expect(mock.lastLaunchedSSHKeyNames == [chosenKey])
        #expect(mock.lastLaunchedImageFamily == chosenImage)
        // …and remembered for next time.
        #expect(service.selectedSSHKeyName == chosenKey)
        #expect(service.selectedImageFamily == chosenImage)
    }

    @Test("launchInstance() shows alert on error")
    @MainActor
    func launchFailure() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .failure(APIError.serverError("No capacity"))
        service.selectedSSHKeyName = "my-laptop"

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await waitUntil("launch to finish") { service.launchingTypeNames.isEmpty }

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

        service.terminateInstance(id: "i-abc123", description: "1x H100", regionDescription: "US West")
        #expect(service.terminatingInstanceIds.contains("i-abc123"))
        #expect(service.activeTerminateProgress?.instanceId == "i-abc123")
        #expect(service.activeTerminateProgress?.regionDescription == "US West")

        try await waitUntil("terminate to finish") { service.terminatingInstanceIds.isEmpty }

        #expect(mock.terminateCallCount == 1)
        #expect(mock.lastTerminatedIds == ["i-abc123"])
        #expect(!service.terminatingInstanceIds.contains("i-abc123"))
        #expect(service.activeTerminateProgress == nil)
    }

    @Test("terminateInstance() shows alert on failure")
    @MainActor
    func terminateFailure() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.terminateResult = .failure(APIError.serverError("Cannot terminate"))

        service.terminateInstance(id: "i-abc123", description: "1x H100")
        try await waitUntil("terminate to finish") { service.terminatingInstanceIds.isEmpty }

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

        await service.refresh()

        #expect(!service.instances.isEmpty)
        #expect(service.error == nil)

        mock.instanceTypesResult = .failure(URLError(.notConnectedToInternet))

        await service.refresh()

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

        await service.refresh()
        #expect(service.error != nil)

        mock.instanceTypesResult = .success(MockData.mixedInstances)

        await service.refresh()

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

        await service.refresh()

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")
        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))

        mock.instanceTypesResult = .success([MockData.h100x1Available])
        mock.launchResult = .success(["i-auto-launched"])

        await service.refresh()
        try await waitUntil("auto-launch to finish") {
            mock.launchCallCount == 1 && service.launchingTypeNames.isEmpty
        }

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

        await freshService.refresh()

        // launchInstance() inserts into launchingTypeNames synchronously, so an
        // empty set right after the fetch applies proves nothing was launched.
        #expect(freshService.launchingTypeNames.isEmpty)
        #expect(mock.launchCallCount == 0)
    }

    @Test("Auto-launch launches every newly available candidate in one poll")
    @MainActor
    func autoLaunchAllCandidates() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedSSHKeyName = "my-laptop"
        let h100Name = MockData.h100x1Available.instanceType.name
        let a6000Name = MockData.a6000Available.instanceType.name
        let unavailable = [MockData.h100x1Available, MockData.a6000Available].map {
            OfferedInstanceType(instanceType: $0.instanceType, regionsWithCapacityAvailable: [])
        }
        mock.instanceTypesResult = .success(unavailable)
        await service.refresh()

        for name in [h100Name, a6000Name] {
            service.toggleWatch(for: name)
            service.toggleAutoLaunch(for: name)
        }

        let launched = Recorder<String>()
        mock.onLaunchInstance = { typeName, _ in launched.append(typeName) }
        mock.instanceTypesResult = .success([MockData.h100x1Available, MockData.a6000Available])
        await service.refresh()
        try await waitUntil("both auto-launches to finish") {
            mock.launchCallCount == 2 && service.launchingTypeNames.isEmpty
        }

        #expect(mock.launchCallCount == 2)
        #expect(Set(launched.values) == [h100Name, a6000Name])
        #expect(!service.isAutoLaunch(h100Name))
        #expect(!service.isAutoLaunch(a6000Name))
    }

    @Test("Auto-launch with no SSH key does not launch and stays enabled")
    @MainActor
    func autoLaunchWithoutSSHKeySkips() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        service.selectedSSHKeyName = ""
        let h100Unavailable = OfferedInstanceType(
            instanceType: MockData.h100x1Info,
            regionsWithCapacityAvailable: []
        )
        mock.instanceTypesResult = .success([h100Unavailable])
        await service.refresh()

        service.toggleWatch(for: "gpu_1x_h100_sxm5")
        service.toggleAutoLaunch(for: "gpu_1x_h100_sxm5")

        mock.instanceTypesResult = .success([MockData.h100x1Available])
        await service.refresh()

        // launchInstance() would have inserted into launchingTypeNames
        // synchronously while the fetch applied.
        #expect(service.launchingTypeNames.isEmpty)
        #expect(mock.launchCallCount == 0)
        #expect(service.isAutoLaunch("gpu_1x_h100_sxm5"))
    }

    // MARK: - Running instances failure

    @Test("Running-instances failure keeps previous list and sets runningInstancesError")
    @MainActor
    func runningInstancesFailurePreservesList() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.instanceTypesResult = .success(MockData.mixedInstances)
        mock.runningInstancesResult = .success([MockData.runningH100])
        await service.refresh()
        #expect(service.runningInstances.count == 1)
        #expect(service.runningInstancesError == nil)

        mock.runningInstancesResult = .failure(URLError(.timedOut))
        await service.refresh()
        #expect(service.runningInstances.map(\.id) == [MockData.runningH100.id])
        #expect(service.runningInstancesError != nil)
        #expect(service.error == nil)

        mock.runningInstancesResult = .success([])
        await service.refresh()
        #expect(service.runningInstances.isEmpty)
        #expect(service.runningInstancesError == nil)
    }

    // MARK: - Fetch ordering

    @Test("Stale fetch results that complete late are discarded")
    @MainActor
    func staleFetchDiscarded() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        let stale = [OfferedInstanceType(instanceType: MockData.h100x1Info, regionsWithCapacityAvailable: [])]
        let fresh = MockData.mixedInstances
        // First call is slow and returns stale data; later calls are fast.
        mock.onFetchInstanceTypes = { [mock] _ in
            if mock.fetchInstanceTypesCallCount == 1 {
                try await Task.sleep(for: .milliseconds(300))
                return stale
            }
            return fresh
        }

        let slow = Task { await service.refresh() }
        try await waitUntil("slow fetch to start") { mock.fetchInstanceTypesCallCount == 1 }

        await service.refresh()
        #expect(service.instances.count == fresh.count)
        #expect(service.isLoading, "older fetch is still in flight")

        await slow.value
        #expect(service.instances.count == fresh.count, "stale result must not overwrite newer one")
        #expect(!service.isLoading)
    }

    @Test("clearAPIKey() discards in-flight fetch results and resets state")
    @MainActor
    func clearAPIKeyDiscardsInFlight() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.runningInstancesResult = .success([MockData.runningH100])
        mock.onFetchInstanceTypes = { _ in
            try await Task.sleep(for: .milliseconds(200))
            return MockData.mixedInstances
        }
        service.sshKeys = [MockData.sshKey1]
        service.selectedSSHKeyName = "my-laptop"
        #expect(service.hasAPIKey)

        let inFlight = Task { await service.refresh() }
        try await waitUntil("fetch to start") { mock.fetchInstanceTypesCallCount == 1 }

        service.clearAPIKey()
        await inFlight.value

        #expect(!service.hasAPIKey)
        #expect(!service.hasStoredAPIKey)
        #expect(service.resolvedAPIKey == nil)
        #expect(service.instances.isEmpty)
        #expect(service.runningInstances.isEmpty)
        #expect(service.sshKeys.isEmpty)
        #expect(service.selectedSSHKeyName == "")
        #expect(service.lastUpdated == nil)
        #expect(service.error == "No API key configured")
    }

    // MARK: - API key override

    @Test("saveAPIKey()/clearAPIKey() never touch Keychain with an override")
    @MainActor
    func saveAPIKeyWithOverrideIsNoOp() async throws {
        defer { cleanupTestState() }
        KeychainService.delete()

        let service = LambdaAPIService(client: MockAPIClient(), apiKeyOverride: "override-key")
        #expect(service.hasStoredAPIKey)

        #expect(service.saveAPIKey("fake-key"))
        #expect(KeychainService.load() == nil, "override mode must not write the Keychain")
        #expect(service.resolvedAPIKey == "override-key")
        #expect(service.hasAPIKey)

        service.clearAPIKey()
        #expect(service.hasAPIKey)
        #expect(service.resolvedAPIKey == "override-key")
    }

    // MARK: - Launch outcome unknown

    @Test("Timed-out launch warns it may have launched and refreshes")
    @MainActor
    func launchTimeoutWarnsAndRefreshes() async throws {
        let (service, mock) = setUpTestService()
        defer { cleanupTestState() }

        mock.launchResult = .failure(URLError(.timedOut))
        mock.runningInstancesResult = .success([MockData.runningH100])
        service.selectedSSHKeyName = "my-laptop"

        service.launchInstance(typeName: "gpu_1x_h100_sxm5", regionName: "us-west-1")
        try await waitUntil("launch failure and follow-up refresh") {
            service.pendingAlert != nil && service.runningInstances.count == 1
        }

        #expect(service.pendingAlert?.title == "Launch Failed")
        #expect(service.pendingAlert?.message.contains("may still have launched") == true)
        #expect(mock.fetchRunningInstancesCallCount >= 1)
    }

    @Test("Definitive launch failure does not add the may-have-launched hint")
    @MainActor
    func launchDefinitiveFailureNoHint() async throws {
        #expect(LambdaAPIService.launchMayHaveSucceeded(despite: URLError(.timedOut)))
        #expect(LambdaAPIService.launchMayHaveSucceeded(despite: URLError(.networkConnectionLost)))
        #expect(!LambdaAPIService.launchMayHaveSucceeded(despite: URLError(.notConnectedToInternet)))
        #expect(!LambdaAPIService.launchMayHaveSucceeded(despite: APIError.serverError("No capacity")))
        #expect(!LambdaAPIService.launchMayHaveSucceeded(despite: APIError.unauthorized))
    }
}
