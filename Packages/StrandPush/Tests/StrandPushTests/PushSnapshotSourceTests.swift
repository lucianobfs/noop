import GRDB
import StrandPush
import WhoopStore
import XCTest

final class PushSnapshotSourceTests: XCTestCase {
    func testDailyMetricWindowIncludesTheBoundaryDayAndExcludesOutsideDays() async throws {
        let store = try await WhoopStore.inMemory()
        try store.registryWriter.write { db in
            for day in ["2026-08-31", "2026-09-01", "2026-09-14", "2026-09-15"] {
                try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES (?, ?)", arguments: ["device-1", day])
            }
        }
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        let source = PushSnapshotSource(reader: store.registryWriter)
        let records = try source.mutableRows(stream: .dailyMetric, deviceId: "device-1", window: window)
        let days = records.map { record -> String in
            guard case .string(let day)? = record.key["day"] else { XCTFail("missing day"); return "" }
            return day
        }
        XCTAssertEqual(days, ["2026-09-01", "2026-09-14"])
    }

    func testSleepSessionWindowIsHalfOpenOnStartTs() async throws {
        let store = try await WhoopStore.inMemory()
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        try store.registryWriter.write { db in
            for startTs in [window.startTsInclusive - 1, window.startTsInclusive, window.endTsExclusive - 1, window.endTsExclusive] {
                try db.execute(
                    sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES (?, ?, ?, 0)",
                    arguments: ["device-1", startTs, startTs + 1]
                )
            }
        }
        let source = PushSnapshotSource(reader: store.registryWriter)
        let records = try source.mutableRows(stream: .sleepSession, deviceId: "device-1", window: window)
        let starts = records.compactMap { record -> Int64? in
            guard case .int(let value)? = record.key["startTs"] else { return nil }
            return value
        }
        XCTAssertEqual(starts, [window.startTsInclusive, window.endTsExclusive - 1])
    }

    func testWorkoutRoutePolylineIsAlwaysNullOnTheWire() async throws {
        let store = try await WhoopStore.inMemory()
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        try store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES (?, ?, ?, ?, ?)",
                arguments: ["device-1", window.startTsInclusive, window.startTsInclusive + 100, "running", "apple"]
            )
        }
        let source = PushSnapshotSource(reader: store.registryWriter)
        let records = try source.mutableRows(stream: .workout, deviceId: "device-1", window: window)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].data["routePolyline"], .null)
    }

    func testDeviceIdFiltersOtherDevicesOut() async throws {
        let store = try await WhoopStore.inMemory()
        let window = try PushWindow.days(from: "2026-09-01", to: "2026-09-14", timeZone: .utc)
        try store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES (?, ?)", arguments: ["device-1", "2026-09-05"])
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES (?, ?)", arguments: ["device-2", "2026-09-05"])
        }
        let source = PushSnapshotSource(reader: store.registryWriter)
        let records = try source.mutableRows(stream: .dailyMetric, deviceId: "device-1", window: window)
        XCTAssertEqual(records.count, 1)
    }
}
