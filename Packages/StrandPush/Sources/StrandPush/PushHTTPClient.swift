import Foundation

public struct PushHTTPRequest: Sendable {
    public enum Method: String, Equatable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let method: Method
    public let url: String
    public let headers: [String: String]
    public let body: [UInt8]?

    public init(method: Method, url: String, headers: [String: String], body: [UInt8]? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct PushHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: [UInt8]

    public init(statusCode: Int, body: [UInt8]) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Seam for injecting a fake transport in tests. No test in this package makes a real network
/// call — see `docs/CROSS_PLATFORM.md`'s hermetic-test discipline.
public protocol PushHTTPClient: Sendable {
    func send(_ request: PushHTTPRequest) async throws -> PushHTTPResponse
}

/// `URLSession`-backed implementation. Redirects are never followed (a redirected capabilities
/// or batch request could silently retarget the destination), mirroring the Kotlin OkHttp
/// transport's `followRedirects(false)`.
public struct URLSessionPushHTTPClient: PushHTTPClient {
    private let session: URLSession
    private let redirectBlockingDelegate = RedirectBlockingDelegate()

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return configuration
    }

    public func send(_ request: PushHTTPRequest) async throws -> PushHTTPResponse {
        guard let url = URL(string: request.url) else {
            throw PushProtocolError.invalid("invalid endpoint URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }
        let (data, response) = try await session.data(for: urlRequest, delegate: redirectBlockingDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw PushProtocolError.invalid("non-HTTP response")
        }
        let bounded = data.prefix(PushProtocol.maxAckBytes + 1)
        return PushHTTPResponse(statusCode: http.statusCode, body: Array(bounded))
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
