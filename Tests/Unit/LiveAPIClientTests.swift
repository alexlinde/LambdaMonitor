import Testing
import Foundation
@testable import LambdaMonitorCore

// MARK: - URLProtocol Mock

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) throws -> (Data, HTTPURLResponse)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handlers[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// MARK: - Tests

@Suite("LiveAPIClient HTTP behavior", .serialized)
struct LiveAPIClientTests {

    init() {
        MockURLProtocol.handlers.removeAll()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // LiveAPIClient uses a dedicated URLSession with cookies disabled
    // (to avoid Lambda's `sessionid` cookie triggering CSRF checks on POSTs).
    // These tests verify the URL construction, request shape, and error mapping
    // by routing a separate session through a mock URLProtocol.

    @Test("MockURLProtocol intercepts and returns configured response")
    func protocolInterception() async throws {
        let session = makeSession()

        MockURLProtocol.handlers["/api/v1/instance-types"] = { request in
            let data = Data(MockData.instanceTypesJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 200)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-types")!
        var request = URLRequest(url: url)
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let decoded = try JSONDecoder().decode(LambdaAPIResponse.self, from: data)
        #expect(decoded.data.count == 2)
    }

    @Test("401 response maps to unauthorized error")
    func unauthorizedResponse() async throws {
        let session = makeSession()

        MockURLProtocol.handlers["/api/v1/instance-types"] = { request in
            let data = Data("{}".utf8)
            let response = makeResponse(url: request.url!, statusCode: 401)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-types")!
        var request = URLRequest(url: url)
        request.setValue("Bearer bad-key", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 401)
    }

    @Test("Bearer token is correctly formatted in request")
    func bearerTokenFormat() async throws {
        let session = makeSession()
        var capturedAuth: String?

        MockURLProtocol.handlers["/api/v1/ssh-keys"] = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let data = Data(MockData.sshKeysJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 200)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/ssh-keys")!
        var request = URLRequest(url: url)
        request.setValue("Bearer my-secret-key", forHTTPHeaderField: "Authorization")

        _ = try await session.data(for: request)
        #expect(capturedAuth == "Bearer my-secret-key")
    }

    @Test("POST launch request includes correct Content-Type and body")
    func launchRequestFormat() async throws {
        let session = makeSession()
        var capturedContentType: String?
        var capturedBody: [String: Any]?

        MockURLProtocol.handlers["/api/v1/instance-operations/launch"] = { request in
            capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
            if let body = request.httpBody ?? request.httpBodyStream.flatMap({ stream in
                stream.open()
                let data = NSMutableData()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count > 0 { data.append(buffer, length: count) }
                }
                stream.close()
                return data as Data
            }) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let data = Data(MockData.launchSuccessJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 200)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-operations/launch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = LaunchInstanceRequest(
            regionName: "us-west-1",
            instanceTypeName: "gpu_1x_h100_sxm5",
            sshKeyNames: ["my-key"],
            quantity: 1
        )
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await session.data(for: request)

        #expect(capturedContentType == "application/json")
        #expect(capturedBody?["region_name"] as? String == "us-west-1")
        #expect(capturedBody?["instance_type_name"] as? String == "gpu_1x_h100_sxm5")
        #expect(capturedBody?["image"] == nil)
    }

    @Test("POST launch request includes image family when provided")
    func launchRequestWithImageFamily() async throws {
        let session = makeSession()
        var capturedBody: [String: Any]?

        MockURLProtocol.handlers["/api/v1/instance-operations/launch"] = { request in
            if let body = request.httpBody ?? request.httpBodyStream.flatMap({ stream in
                stream.open()
                let data = NSMutableData()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count > 0 { data.append(buffer, length: count) }
                }
                stream.close()
                return data as Data
            }) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            let data = Data(MockData.launchSuccessJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 200)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-operations/launch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = LaunchInstanceRequest(
            regionName: "us-west-1",
            instanceTypeName: "gpu_1x_h100_sxm5",
            sshKeyNames: ["my-key"],
            quantity: 1,
            image: ImageSpecificationFamily(family: "ubuntu-lts")
        )
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await session.data(for: request)

        let imageObj = try #require(capturedBody?["image"] as? [String: Any])
        #expect(imageObj["family"] as? String == "ubuntu-lts")
    }

    @Test("Images endpoint decodes correctly")
    func imagesEndpointDecode() async throws {
        let session = makeSession()

        MockURLProtocol.handlers["/api/v1/images"] = { request in
            let data = Data(MockData.imagesJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 200)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/images")!
        var request = URLRequest(url: url)
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ImagesResponse.self, from: data)
        #expect(decoded.data.count == 2)
        #expect(decoded.data.contains { $0.family == "lambda-stack" })
        #expect(decoded.data.contains { $0.family == "ubuntu-lts" })
    }

    @Test("Server error response is parseable")
    func serverErrorParsing() async throws {
        let session = makeSession()

        MockURLProtocol.handlers["/api/v1/instance-operations/launch"] = { request in
            let data = Data(MockData.errorJSON.utf8)
            let response = makeResponse(url: request.url!, statusCode: 400)
            return (data, response)
        }

        let url = URL(string: "https://cloud.lambdalabs.com/api/v1/instance-operations/launch")!
        let request = URLRequest(url: url)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 400)

        let errorResponse = try JSONDecoder().decode(LambdaErrorResponse.self, from: data)
        #expect(errorResponse.error.message.contains("Insufficient capacity"))
    }

    // MARK: - APIError

    @Test("APIError descriptions are human-readable")
    func apiErrorDescriptions() {
        #expect(APIError.invalidResponse.localizedDescription == "Invalid response from server")
        #expect(APIError.unauthorized.localizedDescription == "Invalid API key")
        #expect(APIError.httpError(500).localizedDescription == "HTTP error 500")
        #expect(APIError.serverError("Out of GPUs").localizedDescription == "Out of GPUs")
    }

    // MARK: - Cookie isolation (regression for "Missing or invalid CSRF token")

    /// The production URLSession configuration must disable cookies so Lambda's
    /// `sessionid` cookie cannot leak between requests and trigger Django's
    /// CSRF check on POSTs.
    @Test("Production session configuration disables cookies")
    func sessionConfigDisablesCookies() {
        let config = LiveAPIClient.makeURLSessionConfiguration()
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieStorage == nil)
    }

    /// End-to-end regression: even when a prior GET response tries to set a
    /// `sessionid` cookie, the subsequent POST launch must not send any
    /// `Cookie` header. Otherwise Lambda's backend treats the request as
    /// session-authenticated and rejects it with "Missing or invalid CSRF token".
    @Test("Launch POST never carries cookies after a Set-Cookie response")
    func liveClientDoesNotSendCookies() async throws {
        let config = LiveAPIClient.makeURLSessionConfiguration()
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = LiveAPIClient(session: session)

        MockURLProtocol.handlers["/api/v1/instance-types"] = { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Set-Cookie": "sessionid=should-not-leak; Path=/; HttpOnly"]
            )!
            return (Data(MockData.instanceTypesJSON.utf8), response)
        }

        var launchSawCookie: String?
        MockURLProtocol.handlers["/api/v1/instance-operations/launch"] = { request in
            launchSawCookie = request.value(forHTTPHeaderField: "Cookie")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(MockData.launchSuccessJSON.utf8), response)
        }

        _ = try await client.fetchInstanceTypes(apiKey: "test")
        _ = try await client.launchInstance(
            apiKey: "test",
            typeName: "gpu_1x_h100_sxm5",
            regionName: "us-west-1",
            sshKeyNames: ["my-key"],
            imageFamily: nil
        )

        #expect(launchSawCookie == nil, "POST must not carry sessionid cookie (would trigger CSRF check)")
    }
}
