import Foundation
import GRDB
import StrandPush
import WhoopStore
import XCTest

final class PushCoordinatorTests: XCTestCase {
    let endpoint = PushEndpointPolicy.ValidEndpoint(url: "http://127.0.0.1:9999/push", host: "127.0.0.1")
    let receiverStateId = "6f1b8f0a-3c2d-4e5f-9a1b-2c3d4e5f6a7b"

    func testSuccessfulNegotiationSendsAndAcceptsEachDeclaredStream() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES (?, ?)", arguments: ["device-1", "2026-09-05"])
        }
        let client = ScriptedHTTPClient()
        let result = await PushCoordinator.push(
            endpoint: endpoint, token: "t", deviceId: "device-1", sourceId: "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11",
            store: store, httpClient: client,
            today: Date(timeIntervalSince1970: 1_757_500_000), timeZone: .utc
        )
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.outcomes[0].stream, .dailyMetric)
        XCTAssertEqual(result.outcomes[0].sent, 1)
        XCTAssertEqual(result.outcomes[0].accepted, 1)
        XCTAssertNil(result.outcomes[0].failure)
    }

    func testVersionMismatchProducesTheHttpClientFailureAndReadsNoHealthData() async throws {
        let store = try await WhoopStore.inMemory()
        let client = FakeHTTPClient(responses: [PushHTTPResponse(statusCode: 406, body: [])])
        let result = await PushCoordinator.push(
            endpoint: endpoint, token: "t", deviceId: "device-1", sourceId: "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11",
            store: store, httpClient: client
        )
        XCTAssertTrue(result.outcomes.allSatisfy { $0.sent == 0 && $0.accepted == 0 })
        XCTAssertTrue(result.outcomes.allSatisfy { $0.failure?.code == .httpClient })
        XCTAssertEqual(client.postCount, 0, "capability negotiation failed before any batch was built or sent")
    }

    func testOversizeCapabilitiesDocumentIsRejectedAndReadsNoHealthData() async throws {
        let store = try await WhoopStore.inMemory()
        let padding = String(repeating: "a", count: PushProtocol.maxAckBytes + 1)
        let oversizeBody = Array("""
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)","streams":["dailyMetric"],"padding":"\(padding)"}
        """.utf8)
        let client = FakeHTTPClient(responses: [PushHTTPResponse(statusCode: 200, body: oversizeBody)])
        let result = await PushCoordinator.push(
            endpoint: endpoint, token: "t", deviceId: "device-1", sourceId: "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11",
            store: store, httpClient: client
        )
        XCTAssertTrue(result.outcomes.allSatisfy { $0.failure?.code == .capabilitiesInvalid })
        XCTAssertEqual(client.postCount, 0)
    }

    func testMalformedCapabilitiesDocumentIsRejectedAndReadsNoHealthData() async throws {
        let store = try await WhoopStore.inMemory()
        let client = FakeHTTPClient(responses: [PushHTTPResponse(statusCode: 200, body: Array("{not json".utf8))])
        let result = await PushCoordinator.push(
            endpoint: endpoint, token: "t", deviceId: "device-1", sourceId: "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11",
            store: store, httpClient: client
        )
        XCTAssertTrue(result.outcomes.allSatisfy { $0.failure?.code == .capabilitiesInvalid })
        XCTAssertEqual(client.postCount, 0)
    }

    func testMismatchedAckFailsTheStreamWithoutCrashing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES (?, ?)", arguments: ["device-1", "2026-09-05"])
        }
        let capabilitiesBody = Array("""
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)","streams":["dailyMetric"]}
        """.utf8)
        let badAck = Array("""
        {"protocolVersion":"1.0","batchId":"not-the-batch-id","stream":"dailyMetric","deviceId":"device-1","endCursor":null,"acceptedRows":1,"status":"accepted"}
        """.utf8)
        let client = FakeHTTPClient(responses: [
            PushHTTPResponse(statusCode: 200, body: capabilitiesBody),
            PushHTTPResponse(statusCode: 200, body: badAck),
        ])
        let result = await PushCoordinator.push(
            endpoint: endpoint, token: "t", deviceId: "device-1", sourceId: "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11",
            store: store, httpClient: client,
            today: Date(timeIntervalSince1970: 1_757_500_000), timeZone: .utc
        )
        XCTAssertEqual(result.outcomes[0].failure?.code, .ackInvalid)
        XCTAssertEqual(result.outcomes[0].accepted, 0)
    }
}

/// Serves a fixed capabilities response, then a correctly matching ack for every subsequent POST.
/// The ack is read back out of the request body it just received (its `batchId` etc.) rather than
/// scripted in advance, since the deterministic batch id can't be known ahead of the coordinator
/// run without duplicating `PushProtocol.stableUuid` here.
private final class ScriptedHTTPClient: PushHTTPClient, @unchecked Sendable {
    private let receiverStateId = "6f1b8f0a-3c2d-4e5f-9a1b-2c3d4e5f6a7b"

    func send(_ request: PushHTTPRequest) async throws -> PushHTTPResponse {
        if request.method == .get {
            let body = """
            {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)","streams":["dailyMetric","sleepSession","workout"]}
            """
            return PushHTTPResponse(statusCode: 200, body: Array(body.utf8))
        }
        let batchId = try firstMatch(in: request.body ?? [], pattern: "\"batchId\":\"([0-9a-f-]{36})\"")
        let recordCount = try firstMatch(in: request.body ?? [], pattern: "\"recordCount\":([0-9]+)")
        let stream = try firstMatch(in: request.body ?? [], pattern: "\"stream\":\"([a-zA-Z]+)\"")
        let ack = """
        {"protocolVersion":"1.0","batchId":"\(batchId)","stream":"\(stream)","deviceId":"device-1","endCursor":null,"acceptedRows":\(recordCount),"status":"accepted"}
        """
        return PushHTTPResponse(statusCode: 200, body: Array(ack.utf8))
    }

    private func firstMatch(in body: [UInt8], pattern: String) throws -> String {
        let text = String(decoding: body, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let captured = Range(match.range(at: 1), in: text) else {
            throw PushProtocolError.invalid("could not find \(pattern) in scripted request body")
        }
        return String(text[captured])
    }
}
