import Foundation

public protocol APIClient: Sendable {
    func fetchInstanceTypes(apiKey: String) async throws -> [OfferedInstanceType]
    func fetchRunningInstances(apiKey: String) async throws -> [RunningInstance]
    func fetchSSHKeys(apiKey: String) async throws -> [SSHKey]
    func fetchImages(apiKey: String) async throws -> [LambdaImage]
    func launchInstance(
        apiKey: String,
        typeName: String,
        regionName: String,
        sshKeyNames: [String],
        imageFamily: String?
    ) async throws -> [String]
    func terminateInstance(apiKey: String, instanceIds: [String]) async throws
}

// MARK: - Live Implementation

public struct LiveAPIClient: APIClient {
    private static let baseURL = "https://cloud.lambdalabs.com/api/v1"

    /// Builds the configuration used by the production session. Exposed at
    /// package level so tests can verify the cookie-isolation settings.
    ///
    /// Why disable cookies? `cloud.lambdalabs.com` returns a `sessionid` cookie
    /// on every response (it's the same origin as the web dashboard). If we used
    /// `URLSession.shared`, that cookie would be stored in
    /// `HTTPCookieStorage.shared` and re-sent on subsequent requests. Lambda's
    /// backend then treats those requests as session-authenticated and requires
    /// a CSRF token for state-changing POSTs, producing "Missing or invalid
    /// CSRF token" on launch/terminate. Disabling cookies entirely ensures the
    /// API only ever sees Bearer auth.
    static func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return config
    }

    private static let defaultSession = URLSession(configuration: makeURLSessionConfiguration())

    private let session: URLSession

    public init() {
        self.session = Self.defaultSession
    }

    /// Test-only initializer that lets tests route requests through a mock
    /// `URLProtocol`. Production code uses the parameterless `init()`.
    init(session: URLSession) {
        self.session = session
    }

    public func fetchInstanceTypes(apiKey: String) async throws -> [OfferedInstanceType] {
        let request = Self.makeRequest(path: "/instance-types", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response)
        let decoded = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)
        return Array(decoded.data.values)
    }

    public func fetchRunningInstances(apiKey: String) async throws -> [RunningInstance] {
        let request = Self.makeRequest(path: "/instances", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response)
        let decoded = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)
        return decoded.data
    }

    public func fetchSSHKeys(apiKey: String) async throws -> [SSHKey] {
        let request = Self.makeRequest(path: "/ssh-keys", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response)
        let decoded = try JSONDecoder().decode(SSHKeysResponse.self, from: data)
        return decoded.data
    }

    public func fetchImages(apiKey: String) async throws -> [LambdaImage] {
        let request = Self.makeRequest(path: "/images", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ImagesResponse.self, from: data)
        return decoded.data
    }

    public func launchInstance(
        apiKey: String,
        typeName: String,
        regionName: String,
        sshKeyNames: [String],
        imageFamily: String?
    ) async throws -> [String] {
        var request = Self.makeRequest(
            path: "/instance-operations/launch", apiKey: apiKey, method: "POST"
        )
        let body = LaunchInstanceRequest(
            regionName: regionName,
            instanceTypeName: typeName,
            sshKeyNames: sshKeyNames,
            quantity: 1,
            image: imageFamily.map { ImageSpecificationFamily(family: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(LambdaErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error.message)
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(LaunchInstanceResponse.self, from: data)
        return decoded.data.instanceIds
    }

    public func terminateInstance(apiKey: String, instanceIds: [String]) async throws {
        var request = Self.makeRequest(
            path: "/instance-operations/terminate", apiKey: apiKey, method: "POST"
        )
        let body = TerminateInstanceRequest(instanceIds: instanceIds)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(LambdaErrorResponse.self, from: data) {
                throw APIError.serverError(errorResponse.error.message)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - Helpers

    private static func makeRequest(path: String, apiKey: String, method: String = "GET") -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = method == "GET" ? 15 : 30
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Mock Implementation

public final class MockAPIClient: APIClient, @unchecked Sendable {
    public var instanceTypesResult: Result<[OfferedInstanceType], Error> = .success([])
    public var runningInstancesResult: Result<[RunningInstance], Error> = .success([])
    public var sshKeysResult: Result<[SSHKey], Error> = .success([])
    public var imagesResult: Result<[LambdaImage], Error> = .success([])
    public var launchResult: Result<[String], Error> = .success(["i-mock-00000001"])
    public var terminateResult: Result<Void, Error> = .success(())

    public var delay: Duration = .zero

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
        if delay > .zero { try await Task.sleep(for: delay) }
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
        if delay > .zero { try await Task.sleep(for: delay) }
        terminateCallCount += 1
        lastTerminatedIds = instanceIds
        try terminateResult.get()
        if case .success(let existing) = runningInstancesResult {
            let toRemove = Set(instanceIds)
            runningInstancesResult = .success(existing.filter { !toRemove.contains($0.id) })
        }
    }
}
