import GRDB

/// Reads the three replace-window streams straight from WhoopStore's GRDB tables (typed columns,
/// not the dynamic-cursor building Kotlin's `PushDao.kt` does over Room's SQLite driver — Swift
/// has no equivalent generic cursor type worth introducing for three fixed queries). Ordered by
/// natural key ascending, matching the receiver's SQL `BINARY` collation assumption in
/// `docs/PUSH_PROTOCOL.md`.
public struct PushSnapshotSource: Sendable {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    public func mutableRows(stream: PushMutableStream, deviceId: String, window: PushWindow) throws -> [PushMutableRecord] {
        try reader.read { db in
            switch stream {
            case .dailyMetric: return try Self.dailyMetricRows(db, deviceId: deviceId, window: window)
            case .sleepSession: return try Self.sleepSessionRows(db, deviceId: deviceId, window: window)
            case .workout: return try Self.workoutRows(db, deviceId: deviceId, window: window)
            }
        }
    }

    private static func dailyMetricRows(_ db: Database, deviceId: String, window: PushWindow) throws -> [PushMutableRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                   restingHr, avgHrv, recovery, strain, exerciseCount, spo2Pct, skinTempDevC,
                   respRateBpm, steps, activeKcalEst, spo2Red, spo2Ir
            FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day ASC
            """,
            arguments: [deviceId, window.fromDay, window.toDay]
        )
        return rows.map { row in
            let day: String = row["day"]
            let totalSleepMin: Double? = row["totalSleepMin"]
            let efficiency: Double? = row["efficiency"]
            let deepMin: Double? = row["deepMin"]
            let remMin: Double? = row["remMin"]
            let lightMin: Double? = row["lightMin"]
            let disturbances: Int? = row["disturbances"]
            let restingHr: Int? = row["restingHr"]
            let avgHrv: Double? = row["avgHrv"]
            let recovery: Double? = row["recovery"]
            let strain: Double? = row["strain"]
            let exerciseCount: Int? = row["exerciseCount"]
            let spo2Pct: Double? = row["spo2Pct"]
            let skinTempDevC: Double? = row["skinTempDevC"]
            let respRateBpm: Double? = row["respRateBpm"]
            let steps: Int? = row["steps"]
            let activeKcalEst: Double? = row["activeKcalEst"]
            let spo2Red: Int? = row["spo2Red"]
            let spo2Ir: Int? = row["spo2Ir"]
            return PushMutableRecord(
                key: ["day": .string(day)],
                data: [
                    "totalSleepMin": jDouble(totalSleepMin), "efficiency": jDouble(efficiency),
                    "deepMin": jDouble(deepMin), "remMin": jDouble(remMin), "lightMin": jDouble(lightMin),
                    "disturbances": jInt(disturbances), "restingHr": jInt(restingHr), "avgHrv": jDouble(avgHrv),
                    "recovery": jDouble(recovery), "strain": jDouble(strain), "exerciseCount": jInt(exerciseCount),
                    "spo2Pct": jDouble(spo2Pct), "skinTempDevC": jDouble(skinTempDevC),
                    "respRateBpm": jDouble(respRateBpm), "steps": jInt(steps), "activeKcalEst": jDouble(activeKcalEst),
                    "spo2Red": jInt(spo2Red), "spo2Ir": jInt(spo2Ir),
                ]
            )
        }
    }

    private static func sleepSessionRows(_ db: Database, deviceId: String, window: PushWindow) throws -> [PushMutableRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
                   startTsAdjusted, motionJSON, sleepStateJSON, stagingSparse
            FROM sleepSession WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs ASC
            """,
            arguments: [deviceId, window.startTsInclusive, window.endTsExclusive]
        )
        return rows.map { row in
            let startTs: Int = row["startTs"]
            let endTs: Int = row["endTs"]
            let efficiency: Double? = row["efficiency"]
            let restingHr: Int? = row["restingHr"]
            let avgHrv: Double? = row["avgHrv"]
            let stagesJSON: String? = row["stagesJSON"]
            let userEdited: Bool = row["userEdited"]
            let startTsAdjusted: Int? = row["startTsAdjusted"]
            let motionJSON: String? = row["motionJSON"]
            let sleepStateJSON: String? = row["sleepStateJSON"]
            let stagingSparse: Bool? = row["stagingSparse"]
            return PushMutableRecord(
                key: ["startTs": .int(Int64(startTs))],
                data: [
                    "endTs": .int(Int64(endTs)), "efficiency": jDouble(efficiency), "restingHr": jInt(restingHr),
                    "avgHrv": jDouble(avgHrv), "stagesJSON": jString(stagesJSON), "userEdited": .bool(userEdited),
                    "startTsAdjusted": jInt(startTsAdjusted), "motionJSON": jString(motionJSON),
                    "sleepStateJSON": jString(sleepStateJSON), "stagingSparse": jBool(stagingSparse),
                ]
            )
        }
    }

    private static func workoutRows(_ db: Database, deviceId: String, window: PushWindow) throws -> [PushMutableRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr, strain,
                   distanceM, zonesJSON, notes, steps
            FROM workout WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs ASC, sport ASC
            """,
            arguments: [deviceId, window.startTsInclusive, window.endTsExclusive]
        )
        return rows.map { row in
            let startTs: Int = row["startTs"]
            let endTs: Int = row["endTs"]
            let sport: String = row["sport"]
            let source: String = row["source"]
            let durationS: Double? = row["durationS"]
            let energyKcal: Double? = row["energyKcal"]
            let avgHr: Int? = row["avgHr"]
            let maxHr: Int? = row["maxHr"]
            let strain: Double? = row["strain"]
            let distanceM: Double? = row["distanceM"]
            let zonesJSON: String? = row["zonesJSON"]
            let notes: String? = row["notes"]
            let steps: Int? = row["steps"]
            return PushMutableRecord(
                key: ["startTs": .int(Int64(startTs)), "sport": .string(sport)],
                data: [
                    "endTs": .int(Int64(endTs)), "source": .string(source), "durationS": jDouble(durationS),
                    "energyKcal": jDouble(energyKcal), "avgHr": jInt(avgHr), "maxHr": jInt(maxHr),
                    "strain": jDouble(strain), "distanceM": jDouble(distanceM), "zonesJSON": jString(zonesJSON),
                    "notes": jString(notes),
                    // The macOS/iOS `workout` cache has no GPS-route column (see the README's
                    // Kotlin-parity note); this field is always null on the wire from this client.
                    "routePolyline": .null,
                    "steps": jInt(steps),
                ]
            )
        }
    }
}

private func jDouble(_ value: Double?) -> JSONValue { value.map(JSONValue.double) ?? .null }
private func jInt(_ value: Int?) -> JSONValue { value.map { JSONValue.int(Int64($0)) } ?? .null }
private func jString(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
private func jBool(_ value: Bool?) -> JSONValue { value.map(JSONValue.bool) ?? .null }
