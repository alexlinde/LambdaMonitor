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
    private static let baseURL = "https://cloud.lambda.ai/api/v1"

    /// Builds the configuration used by the production session. Exposed at
    /// package level so tests can verify the cookie-isolation settings.
    ///
    /// Why disable cookies? `cloud.lambda.ai` returns a `sessionid` cookie
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
        try Self.validate(data: data, response: response)
        let decoded = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)
        return Array(decoded.data.values)
    }

    public func fetchRunningInstances(apiKey: String) async throws -> [RunningInstance] {
        let request = Self.makeRequest(path: "/instances", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validate(data: data, response: response)
        let decoded = try JSONDecoder().decode(RunningInstancesResponse.self, from: data)
        return decoded.data
    }

    public func fetchSSHKeys(apiKey: String) async throws -> [SSHKey] {
        let request = Self.makeRequest(path: "/ssh-keys", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validate(data: data, response: response)
        let decoded = try JSONDecoder().decode(SSHKeysResponse.self, from: data)
        return decoded.data
    }

    public func fetchImages(apiKey: String) async throws -> [LambdaImage] {
        let request = Self.makeRequest(path: "/images", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validate(data: data, response: response)
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

        try Self.validate(data: data, response: response)

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

        try Self.validate(data: data, response: response)
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

    /// Single place that maps HTTP failures to `APIError`.
    /// Non-HTTP -> invalidResponse; 2xx -> ok; 401 -> unauthorized; a
    /// decodable error body -> serverError(message); 403 -> unauthorized;
    /// anything else -> httpError(code).
    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        let code = http.statusCode
        if (200..<300).contains(code) { return }
        if code == 401 { throw APIError.unauthorized }
        if let err = try? JSONDecoder().decode(LambdaErrorResponse.self, from: data) {
            throw APIError.serverError(err.error.message)
        }
        if code == 403 { throw APIError.unauthorized }
        throw APIError.httpError(code)
    }
}
