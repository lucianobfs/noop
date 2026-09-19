import StrandPush
import XCTest

/// Mirrors the mutable-stream cases of `android/app/src/test/java/com/noop/push/PushProtocolTest.kt`.
final class PushProtocolTests: XCTestCase {
    let sourceId = "5b1c9e0a-df9a-4a6b-8f7e-8f2b6a2e9c11"
    let deviceId = "device-1"

    func testDailyMetricRecordEncodesSortedKeysAsNdjson() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let record = PushMutableRecord(
            key: ["day": .string("2026-09-05")],
            data: [
                "totalSleepMin": .double(420), "efficiency": .double(91.5), "deepMin": .double(80),
                "remMin": .double(90), "lightMin": .double(250), "disturbances": .int(2),
                "restingHr": .int(52), "avgHrv": .double(61.5), "recovery": .double(72),
                "strain": .double(9.8), "exerciseCount": .int(1), "spo2Pct": .double(97.2),
                "skinTempDevC": .double(0.3), "respRateBpm": .double(14.5), "steps": .int(8000),
                "activeKcalEst": .double(340), "spo2Red": .null, "spo2Ir": .null,
            ]
        )
        let batch = try PushProtocol.mutableBatch(
            stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: [record]
        )
        let bodyString = String(decoding: batch.body, as: UTF8.self)
        let lines = bodyString.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"type\":\"batch\""))
        XCTAssertTrue(lines[0].contains("\"delivery\":\"replace_window\""))
        XCTAssertTrue(lines[0].contains("\"endCursor\":null"))
        XCTAssertTrue(lines[0].contains("\"startCursor\":null"))
        XCTAssertTrue(lines[1].contains("\"type\":\"record\""))
        XCTAssertTrue(lines[1].contains("\"day\":\"2026-09-05\""))
        XCTAssertTrue(lines[1].hasPrefix("{\"data\":{"), "member order within an object must be alphabetical")
    }

    func testDeterministicBatchIdIsStableAcrossTwoIndependentBuildsOfTheSameWindow() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let records = [
            PushMutableRecord(key: ["day": .string("2026-09-05")], data: dailyMetricData()),
            PushMutableRecord(key: ["day": .string("2026-09-06")], data: dailyMetricData()),
        ]
        let first = try PushProtocol.mutableBatch(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: records)
        let second = try PushProtocol.mutableBatch(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: records)
        XCTAssertEqual(first.batchId, second.batchId)
        XCTAssertEqual(first.replacementId, second.replacementId)
        XCTAssertEqual(first.body, second.body)
    }

    func testBatchIdChangesWhenAnyRecordChanges() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        var data = dailyMetricData()
        let first = try PushProtocol.mutableBatch(
            stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window,
            records: [PushMutableRecord(key: ["day": .string("2026-09-05")], data: data)]
        )
        data["strain"] = .double(11.0)
        let second = try PushProtocol.mutableBatch(
            stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window,
            records: [PushMutableRecord(key: ["day": .string("2026-09-05")], data: data)]
        )
        XCTAssertNotEqual(first.batchId, second.batchId)
    }

    func testEmptySnapshotStillProducesOneAuthoritativePart() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let batches = try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: [])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].recordCount, 0)
        XCTAssertEqual(batches[0].parts, 1)
        XCTAssertEqual(batches[0].part, 1)
    }

    func testDuplicateKeyIsRejected() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let records = [
            PushMutableRecord(key: ["day": .string("2026-09-05")], data: dailyMetricData()),
            PushMutableRecord(key: ["day": .string("2026-09-05")], data: dailyMetricData()),
        ]
        XCTAssertThrowsError(try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: records))
    }

    func testRecordWithWrongDataColumnsIsRejected() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let record = PushMutableRecord(key: ["day": .string("2026-09-05")], data: ["onlyOneField": .int(1)])
        XCTAssertThrowsError(try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: [record]))
    }

    func testDeviceIdOrSyncedColumnIsRejected() throws {
        var data = dailyMetricData()
        data["deviceId"] = .string(deviceId)
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let record = PushMutableRecord(key: ["day": .string("2026-09-05")], data: data)
        XCTAssertThrowsError(try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: [record]))
    }

    func testNonUuidSourceIdIsRejected() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let record = PushMutableRecord(key: ["day": .string("2026-09-05")], data: dailyMetricData())
        XCTAssertThrowsError(try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: "not-a-uuid", deviceId: deviceId, window: window, records: [record]))
    }

    func testRecordCountAboveTheLimitSplitsIntoMultipleParts() throws {
        let window = try PushWindow.days(from: "2026-01-01", to: "2026-12-31", timeZone: .utc)
        var records: [PushMutableRecord] = []
        for day in 1...(PushProtocol.maxRecords + 10) {
            records.append(PushMutableRecord(key: ["day": .string(String(format: "day-%06d", day))], data: dailyMetricData()))
        }
        let batches = try PushProtocol.mutableBatches(stream: .dailyMetric, sourceId: sourceId, deviceId: deviceId, window: window, records: records)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.reduce(0) { $0 + $1.recordCount }, records.count)
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.recordCount, PushProtocol.maxRecords)
            XCTAssertLessThanOrEqual(batch.body.count, PushProtocol.maxBodyBytes)
            XCTAssertEqual(batch.parts, batches.count)
        }
    }

    func testMutableSnapshotHashIsOrderIndependent() throws {
        let a = PushMutableRecord(key: ["day": .string("2026-09-05")], data: dailyMetricData())
        let b = PushMutableRecord(key: ["day": .string("2026-09-06")], data: dailyMetricData())
        let hash1 = try PushProtocol.mutableSnapshotHash(stream: .dailyMetric, records: [a, b])
        let hash2 = try PushProtocol.mutableSnapshotHash(stream: .dailyMetric, records: [b, a])
        XCTAssertEqual(hash1, hash2)
    }

    func testSleepSessionAndWorkoutKeysUseTheRegistryColumns() throws {
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let sleep = PushMutableRecord(
            key: ["startTs": .int(1_756_000_000)],
            data: [
                "endTs": .int(1_756_030_000), "userEdited": .bool(false), "efficiency": .null,
                "restingHr": .null, "avgHrv": .null, "stagesJSON": .null, "startTsAdjusted": .null,
                "motionJSON": .null, "sleepStateJSON": .null, "stagingSparse": .null,
            ]
        )
        XCTAssertNoThrow(try PushProtocol.mutableBatch(stream: .sleepSession, sourceId: sourceId, deviceId: deviceId, window: window, records: [sleep]))

        let workout = PushMutableRecord(
            key: ["startTs": .int(1_756_000_000), "sport": .string("running")],
            data: [
                "endTs": .int(1_756_030_000), "source": .string("apple"), "durationS": .null,
                "energyKcal": .null, "avgHr": .null, "maxHr": .null, "strain": .null,
                "distanceM": .null, "zonesJSON": .null, "notes": .null, "routePolyline": .null,
                "steps": .null,
            ]
        )
        XCTAssertNoThrow(try PushProtocol.mutableBatch(stream: .workout, sourceId: sourceId, deviceId: deviceId, window: window, records: [workout]))
    }

    private func dailyMetricData() -> [String: JSONValue] {
        [
            "totalSleepMin": .null, "efficiency": .null, "deepMin": .null, "remMin": .null,
            "lightMin": .null, "disturbances": .null, "restingHr": .null, "avgHrv": .null,
            "recovery": .null, "strain": .null, "exerciseCount": .null, "spo2Pct": .null,
            "skinTempDevC": .null, "respRateBpm": .null, "steps": .null, "activeKcalEst": .null,
            "spo2Red": .null, "spo2Ir": .null,
        ]
    }
}

extension TimeZone {
    static let utc = TimeZone(identifier: "UTC")!
}
