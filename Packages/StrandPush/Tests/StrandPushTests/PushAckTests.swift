import StrandPush
import XCTest

final class PushAckTests: XCTestCase {
    let sourceId = "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11"
    let deviceId = "device-1"

    func testAckExactlyMatchingTheBatchIsAccepted() throws {
        let batch = try makeBatch()
        let ack = PushAck.fromBatch(batch)
        XCTAssertTrue(ack.exactlyMatches(batch))
    }

    func testRoundTripThroughEncodeAndParsePreservesTheMatch() throws {
        let batch = try makeBatch()
        let ack = PushAck.fromBatch(batch)
        let parsed = try PushAck.parse(try ack.encode())
        XCTAssertEqual(ack, parsed)
        XCTAssertTrue(parsed.exactlyMatches(batch))
    }

    func testMismatchedBatchIdIsRejected() throws {
        let batch = try makeBatch()
        let ack = PushAck(protocolVersion: batch.protocolVersion, batchId: "wrong-id", stream: batch.stream.wireName, deviceId: batch.deviceId, endCursorPresent: false, acceptedRows: batch.recordCount, status: "accepted")
        XCTAssertFalse(ack.exactlyMatches(batch))
    }

    func testMismatchedAcceptedRowsIsRejected() throws {
        let batch = try makeBatch()
        let ack = PushAck(protocolVersion: batch.protocolVersion, batchId: batch.batchId, stream: batch.stream.wireName, deviceId: batch.deviceId, endCursorPresent: false, acceptedRows: batch.recordCount + 1, status: "accepted")
        XCTAssertFalse(ack.exactlyMatches(batch))
    }

    func testNonNullEndCursorIsRejectedForAReplaceWindowBatch() throws {
        let batch = try makeBatch()
        let ack = PushAck(protocolVersion: batch.protocolVersion, batchId: batch.batchId, stream: batch.stream.wireName, deviceId: batch.deviceId, endCursorPresent: true, acceptedRows: batch.recordCount, status: "accepted")
        XCTAssertFalse(ack.exactlyMatches(batch))
    }

    func testNonAcceptedStatusIsRejected() throws {
        let batch = try makeBatch()
        let ack = PushAck(protocolVersion: batch.protocolVersion, batchId: batch.batchId, stream: batch.stream.wireName, deviceId: batch.deviceId, endCursorPresent: false, acceptedRows: batch.recordCount, status: "rejected")
        XCTAssertFalse(ack.exactlyMatches(batch))
    }

    func testMissingRequiredMemberIsRejected() {
        let json = #"{"protocolVersion":"1.0","batchId":"x","stream":"dailyMetric","deviceId":"d","endCursor":null,"acceptedRows":1}"#
        XCTAssertThrowsError(try PushAck.parse(Array(json.utf8)))
    }

    func testForbiddenRemoteControlMemberIsRejected() {
        let json = """
        {"protocolVersion":"1.0","batchId":"x","stream":"dailyMetric","deviceId":"d","endCursor":null,
         "acceptedRows":1,"status":"accepted","command":"do-something"}
        """
        XCTAssertThrowsError(try PushAck.parse(Array(json.utf8)))
    }

    func testMalformedEndCursorObjectIsRejected() {
        let json = """
        {"protocolVersion":"1.0","batchId":"x","stream":"dailyMetric","deviceId":"d",
         "endCursor":{"rowId":1},"acceptedRows":1,"status":"accepted"}
        """
        XCTAssertThrowsError(try PushAck.parse(Array(json.utf8)))
    }

    func testWellFormedEndCursorObjectParsesAsPresent() throws {
        let json = """
        {"protocolVersion":"1.0","batchId":"x","stream":"dailyMetric","deviceId":"d",
         "endCursor":{"rowId":1,"keySha256":"\(String(repeating: "a", count: 64))"},
         "acceptedRows":1,"status":"accepted"}
        """
        let ack = try PushAck.parse(Array(json.utf8))
        XCTAssertTrue(ack.endCursorPresent)
    }

    func testOversizeAckIsRejected() {
        let padding = String(repeating: "a", count: PushProtocol.maxAckBytes + 1)
        let json = """
        {"protocolVersion":"1.0","batchId":"x","stream":"dailyMetric","deviceId":"d","endCursor":null,
         "acceptedRows":1,"status":"accepted","padding":"\(padding)"}
        """
        XCTAssertThrowsError(try PushAck.parse(Array(json.utf8)))
    }

    private func makeBatch() throws -> PushBatch {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let record = PushMutableRecord(key: ["day": .string("2026-09-05")], data: [
            "totalSleepMin": .null, "efficiency": .null, "deepMin": .null, "remMin": .null,
            "lightMin": .null, "disturbances": .null, "restingHr": .null, "avgHrv": .null,
            "recovery": .null, "strain": .null, "exerciseCount": .null, "spo2Pct": .null,
            "skinTempDevC": .null, "respRateBpm": .null, "steps": .null, "activeKcalEst": .null,
            "spo2Red": .null, "spo2Ir": .null,
        ])
        return try PushProtocol.mutableBatch(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: [record])
    }
}
