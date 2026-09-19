import StrandPush
import XCTest

/// Mirrors the capability-parsing cases from `PushHttpTransportPolicyTest.kt`.
final class PushCapabilitiesTests: XCTestCase {
    let receiverStateId = "6f1b8f0a-3c2d-4e5f-9a1b-2c3d4e5f6a7b"

    func testValidDocumentNarrowsToTheStreamsThisPackageImplements() throws {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric","sleepSession","workout","hrSample","journal"]}
        """
        let capabilities = try PushCapabilities.parse(Array(json.utf8))
        XCTAssertEqual(capabilities.mutableStreams, Set(PushMutableStream.allCases))
    }

    func testMissingRequiredMemberIsRejected() {
        let json = #"{"type":"capabilities","protocolVersion":"1.0","streams":["dailyMetric"]}"#
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testForbiddenRemoteControlMemberIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric"],"command":"do-something"}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testUnsupportedProtocolVersionIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"2.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric"]}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testUnknownStreamNameIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric","totallyMadeUpStream"]}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testDuplicateStreamNameIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric","dailyMetric"]}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testNonArrayStreamsIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)","streams":"hrSample"}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testMalformedJsonIsRejected() {
        let json = "{not json"
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testOversizeDocumentIsRejected() {
        let padding = String(repeating: "a", count: PushProtocol.maxAckBytes + 1)
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\(receiverStateId)",
         "streams":["dailyMetric"],"padding":"\(padding)"}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }

    func testNonCanonicalReceiverStateIdIsRejected() {
        let json = """
        {"type":"capabilities","protocolVersion":"1.0","receiverStateId":"NOT-A-UUID",
         "streams":["dailyMetric"]}
        """
        XCTAssertThrowsError(try PushCapabilities.parse(Array(json.utf8)))
    }
}
