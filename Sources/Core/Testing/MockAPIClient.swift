#if DEBUG
import Foundation

// MARK: - Mock Implementation

public final class MockAPIClient: APIClient, @unchecked Sendable {
    public var instanceTypesResult: Result<[OfferedInstanceType], Error> = .success([])
    public var runningInstancesResult: Result<[RunningInstance], Error> = .success([])
    public var sshKeysResult: Result<[SSHKey], Error> = .success([])
    public var imagesResult: Result<[LambdaImage], Error> = .success([])
    public var launchResult: Result<[String], Error> = .success(["i-mock-00000001"])
    public var terminateResult: Result<Void, Error> = .success(())

    public var delay: Duration = .zero

    /// Optional separate delay for the mutating launch/terminate calls. When
    /// set, these operations sleep for this duration instead of `delay`. UI
    /// tests use this to keep the progress spinner on screen long enough for
    /// XCUITest to observe it, without slowing down the (frequent) fetch calls.
    public var operationDelay: Duration?

    public var fetchInstanceTypesCallCount = 0
    public var fetchRunningInstancesCallCount = 0
    public var launchCallCount = 0
    public var lastLaunchedTypeName: String?
    public var lastLaunchedRegion: String?
    public var lastLaunchedSSHKeyNames: [String]?
    public var lastLaunchedImageFamily: String?
    public var terminateCallCount = 0
    public var lastTerminatedIds: [String]?

    /// When set, called instead of returning `instanceTypesResult`.
    /// Allows responses to change between fetches for simulation scenarios.
    public var onFetchInstanceTypes: ((String) async throws -> [OfferedInstanceType])?

    /// When set, called after a successful launch with the launched type/region.
    /// Allows simulation factories to mutate `runningInstancesResult` so the new
    /// instance appears on the next fetch.
    public var onLaunchInstance: ((_ typeName: String, _ regionName: String) -> Void)?

    public init() {}

    public func fetchInstanceTypes(apiKey: String) async throws -> [OfferedInstanceType] {
        if delay > .zero { try await Task.sleep(for: delay) }
        fetchInstanceTypesCallCount += 1
        if let handler = onFetchInstanceTypes {
            return try await handler(apiKey)
        }
        return try instanceTypesResult.get()
    }

    public func fetchRunningInstances(apiKey: String) async throws -> [RunningInstance] {
        if delay > .zero { try await Task.sleep(for: delay) }
        fetchRunningInstancesCallCount += 1
        return try runningInstancesResult.get()
    }

    public func fetchSSHKeys(apiKey: String) async throws -> [SSHKey] {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try sshKeysResult.get()
    }

    public func fetchImages(apiKey: String) async throws -> [LambdaImage] {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try imagesResult.get()
    }

    public func launchInstance(
        apiKey: String,
        typeName: String,
        regionName: String,
        sshKeyNames: [String],
        imageFamily: String?
    ) async throws -> [String] {
        let opDelay = operationDelay ?? delay
        if opDelay > .zero { try await Task.sleep(for: opDelay) }
        launchCallCount += 1
        lastLaunchedTypeName = typeName
        lastLaunchedRegion = regionName
        lastLaunchedSSHKeyNames = sshKeyNames
        lastLaunchedImageFamily = imageFamily
        let result = try launchResult.get()
        onLaunchInstance?(typeName, regionName)
        return result
    }

    public func terminateInstance(apiKey: String, instanceIds: [String]) async throws {
        let opDelay = operationDelay ?? delay
        if opDelay > .zero { try await Task.sleep(for: opDelay) }
        terminateCallCount += 1
        lastTerminatedIds = instanceIds
        try terminateResult.get()
        if case .success(let existing) = runningInstancesResult {
            let toRemove = Set(instanceIds)
            runningInstancesResult = .success(existing.filter { !toRemove.contains($0.id) })
        }
    }
}
#endif
