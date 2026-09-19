import Foundation

public enum PushCapabilitiesResult: Sendable {
    case available(PushCapabilities)
    case rejected(PushFailure)
}

public struct PushTransportError: Error, Sendable {
    public let failure: PushFailure
}

/// The two HTTP calls this package makes: `GET` capabilities and `POST` one replace-window
/// batch. Port of the request-shaping half of the Kotlin `PushHttpTransport`
/// (`PushHttpTransport.kt`) — no gzip: this package sends identity-encoded requests only, always
/// within the 4 MiB decoded bound, so there is no wire/decoded distinction to carry.
public struct PushTransport: Sendable {
    public static let acceptVersionHeader = "NOOP-Push-Accept-Version"

    private let endpoint: PushEndpointPolicy.ValidEndpoint
    private let token: String
    private let client: any PushHTTPClient

    public init(endpoint: PushEndpointPolicy.ValidEndpoint, token: String, client: any PushHTTPClient) {
        self.endpoint = endpoint
        self.token = token
        self.client = client
    }

    public func capabilities() async -> PushCapabilitiesResult {
        let request = PushHTTPRequest(
            method: .get,
            url: endpoint.url,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                Self.acceptVersionHeader: PushProtocol.version,
            ]
        )
        let response: PushHTTPResponse
        do {
            response = try await client.send(request)
        } catch {
            return .rejected(PushFailure.classify(error))
        }
        guard (200...299).contains(response.statusCode) else {
            return .rejected(PushFailure.http(status: response.statusCode, receiverCode: PushError.parseCode(response.body)))
        }
        do {
            return .available(try PushCapabilities.parse(response.body))
        } catch {
            return .rejected(PushFailure(code: .capabilitiesInvalid))
        }
    }

    public func post(_ batch: PushBatch) async throws -> PushHTTPResponse {
        let request = PushHTTPRequest(
            method: .post,
            url: endpoint.url,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "Content-Type": "application/x-ndjson; charset=utf-8",
            ],
            body: batch.body
        )
        do {
            return try await client.send(request)
        } catch {
            throw PushTransportError(failure: PushFailure.classify(error))
        }
    }
}
