import StrandPush

/// Hermetic stand-in for the network. Scripted responses are consumed in order; a `post` beyond
/// the script throws, so a test that expects zero POSTs fails loudly if the coordinator sends one.
final class FakeHTTPClient: PushHTTPClient, @unchecked Sendable {
    private var responses: [PushHTTPResponse]
    private(set) var requests: [PushHTTPRequest] = []

    init(responses: [PushHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: PushHTTPRequest) async throws -> PushHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw PushProtocolError.invalid("FakeHTTPClient script exhausted")
        }
        return responses.removeFirst()
    }

    var postCount: Int { requests.filter { $0.method == .post }.count }
}
