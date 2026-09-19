import CryptoKit
import Foundation

/// One record: the natural-key columns and the exported non-key columns, both keyed by the
/// registry's column names. Port of the Kotlin `PushMutableRecord`.
public struct PushMutableRecord: Equatable, Sendable {
    public let key: [String: JSONValue]
    public let data: [String: JSONValue]

    public init(key: [String: JSONValue], data: [String: JSONValue]) {
        self.key = key
        self.data = data
    }
}

/// A fully materialized, bounded replace-window request. `startCursor`/`endCursor` are always
/// `null` on the wire for this delivery mode (`docs/PUSH_PROTOCOL.md` — "replace-window parts").
/// This package never has an append batch, so there is no `PushBatch.startCursor`/`endCursor`
/// field at all: it would always be `nil` and the type would say nothing an append batch and a
/// replace-window batch need to say differently.
public struct PushBatch: Equatable, Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let sourceId: String
    public let stream: PushMutableStream
    public let deviceId: String
    public let recordCount: Int
    public let window: PushWindow
    public let replacementId: String
    public let part: Int
    public let parts: Int
    public let body: [UInt8]
}

/// Deterministic, bounded NDJSON encoder for the three replace-window streams. Port of the
/// mutable half of the Kotlin `PushProtocol` object (`android/.../push/PushProtocol.kt`).
public enum PushProtocol {
    public static let version = "1.0"
    public static let maxRecords = 5_000
    /// Hard limit for the decoded UTF-8 NDJSON entity. This package sends identity-encoded
    /// requests only (see the README), so there is no separate wire/gzip bound to track.
    public static let maxBodyBytes = 4 * 1024 * 1024
    public static let maxAckBytes = 16 * 1024

    static let forbiddenRemoteControlMembers: Set<String> = [
        "command", "commands", "endpoint", "url", "cadence", "schema", "fields",
    ]

    /// Java's `Integer.MAX_VALUE`, used as the Kotlin twin uses it: a placeholder large enough
    /// that a header built with it never UNDER-estimates the real (small) part/parts numbers'
    /// encoded width, so the size check made against it stays conservative.
    private static let placeholderPartsValue: Int64 = 2_147_483_647
    private static let uuidPlaceholder = "00000000-0000-0000-0000-000000000000"

    /// Builds every bounded part of one authoritative replacement. An empty snapshot produces one
    /// zero-record part, still authoritative (it deletes every receiver row in the window).
    public static func mutableBatches(
        stream: PushMutableStream,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: [PushMutableRecord]
    ) throws -> [PushBatch] {
        try validateUuid(sourceId, name: "sourceId")
        for record in records {
            try validateRecord(stream: stream, key: record.key, data: record.data)
        }
        var seenKeys = Set<String>()
        for record in records {
            let keyJson = try PushCanonicalJSON.encode(.object(record.key))
            if !seenKeys.insert(keyJson).inserted {
                throw PushProtocolError.invalid("replace_window contains a duplicate key")
            }
        }
        let lines = try records.map(encodeRecordLine)

        let replacementIdentity: [String: JSONValue] = [
            "deviceId": .string(deviceId),
            "delivery": .string("replace_window"),
            "protocolVersion": .string(version),
            "sourceId": .string(sourceId),
            "stream": .string(stream.wireName),
            "window": .object(selectorBounds(stream: stream, window: window)),
        ]
        let replacementId = try stableUuid(header: replacementIdentity, lines: lines)

        var chunks: [[[UInt8]]] = []
        var current: [[UInt8]] = []
        var currentBytes = 0
        for line in lines {
            let nextCount = current.count + 1
            let conservativeHeader = try mutableHeader(
                sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
                replacementId: replacementId, part: placeholderPartsValue, parts: placeholderPartsValue,
                count: nextCount, batchId: uuidPlaceholder
            )
            if nextCount > maxRecords || conservativeHeader.count + currentBytes + line.count > maxBodyBytes {
                if current.isEmpty {
                    throw PushProtocolError.invalid("first replace_window record exceeds the 4 MiB decoded batch limit")
                }
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            let oneHeader = try mutableHeader(
                sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
                replacementId: replacementId, part: placeholderPartsValue, parts: placeholderPartsValue,
                count: 1, batchId: uuidPlaceholder
            )
            if oneHeader.count + line.count > maxBodyBytes {
                throw PushProtocolError.invalid("replace_window record exceeds the 4 MiB decoded batch limit")
            }
            current.append(line)
            currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        let parts = chunks.count
        var batches: [PushBatch] = []
        for (index, partLines) in chunks.enumerated() {
            let part = index + 1
            let identity = mutableIdentity(
                sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
                replacementId: replacementId, part: Int64(part), parts: Int64(parts), count: partLines.count
            )
            let batchId = try stableUuid(header: identity, lines: partLines)
            let header = try mutableHeader(
                sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
                replacementId: replacementId, part: Int64(part), parts: Int64(parts),
                count: partLines.count, batchId: batchId
            )
            var body = header
            for line in partLines { body.append(contentsOf: line) }
            precondition(partLines.count <= maxRecords && body.count <= maxBodyBytes)
            batches.append(PushBatch(
                protocolVersion: version, batchId: batchId, sourceId: sourceId, stream: stream,
                deviceId: deviceId, recordCount: partLines.count, window: window,
                replacementId: replacementId, part: part, parts: parts, body: body
            ))
        }
        return batches
    }

    /// A single-part convenience for callers (and tests) that already know the snapshot fits.
    public static func mutableBatch(
        stream: PushMutableStream,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: [PushMutableRecord]
    ) throws -> PushBatch {
        let batches = try mutableBatches(stream: stream, sourceId: sourceId, deviceId: deviceId, window: window, records: records)
        guard batches.count == 1 else {
            throw PushProtocolError.invalid("replace_window requires multiple parts")
        }
        return batches[0]
    }

    /// Stable local content identity for the upload-elision day hash. Progress metadata only;
    /// never transmitted.
    public static func mutableSnapshotHash(stream: PushMutableStream, records: [PushMutableRecord]) throws -> String {
        var lines = try records.map(encodeRecordLine)
        lines.sort { compareBytes($0, $1) < 0 }
        var hasher = SHA256()
        hasher.update(data: Data("noop-push-day-hash\n\(version)\n\(stream.wireName)\n".utf8))
        for line in lines { hasher.update(data: Data(line)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func mutableRecordEncodedSize(stream: PushMutableStream, record: PushMutableRecord) throws -> Int {
        try validateRecord(stream: stream, key: record.key, data: record.data)
        return try encodeRecordLine(record).count
    }

    static func encodeRecordLine(_ record: PushMutableRecord) throws -> [UInt8] {
        let object: JSONValue = .object(["data": .object(record.data), "key": .object(record.key), "type": .string("record")])
        let json = try PushCanonicalJSON.encode(object)
        return Array((json + "\n").utf8)
    }

    static func selectorBounds(stream: PushMutableStream, window: PushWindow) -> [String: JSONValue] {
        let spec = PushRegistry.spec(for: stream)
        switch spec.windowSelector {
        case .day:
            return [
                "selector": .string("day"),
                "startInclusive": .string(window.fromDay),
                "endExclusive": .string(PushWindow.nextDay(window.toDay)),
            ]
        case .startTs:
            return [
                "selector": .string("startTs"),
                "startInclusive": .int(window.startTsInclusive),
                "endExclusive": .int(window.endTsExclusive),
            ]
        }
    }

    private static func mutableIdentity(
        sourceId: String, stream: PushMutableStream, deviceId: String, window: PushWindow,
        replacementId: String, part: Int64, parts: Int64, count: Int
    ) -> [String: JSONValue] {
        var windowObject = selectorBounds(stream: stream, window: window)
        windowObject["part"] = .int(part)
        windowObject["parts"] = .int(parts)
        windowObject["replacementId"] = .string(replacementId)
        return [
            "delivery": .string("replace_window"),
            "deviceId": .string(deviceId),
            "endCursor": .null,
            "protocolVersion": .string(version),
            "recordCount": .int(Int64(count)),
            "sourceId": .string(sourceId),
            "startCursor": .null,
            "stream": .string(stream.wireName),
            "type": .string("batch"),
            "window": .object(windowObject),
        ]
    }

    private static func mutableHeader(
        sourceId: String, stream: PushMutableStream, deviceId: String, window: PushWindow,
        replacementId: String, part: Int64, parts: Int64, count: Int, batchId: String
    ) throws -> [UInt8] {
        var identity = mutableIdentity(
            sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
            replacementId: replacementId, part: part, parts: parts, count: count
        )
        identity["batchId"] = .string(batchId)
        let json = try PushCanonicalJSON.encode(.object(identity))
        return Array((json + "\n").utf8)
    }

    /// SHA-256(canonical(header) LF lines...), version+variant bits set to look like a UUID v5.
    /// Byte-identical inputs (same header, same lines) always produce the same id, which is what
    /// makes a retried replacement byte-identical to the first attempt.
    static func stableUuid(header: [String: JSONValue], lines: [[UInt8]]) throws -> String {
        var hasher = SHA256()
        let headerJson = try PushCanonicalJSON.encode(.object(header))
        hasher.update(data: Data(headerJson.utf8))
        hasher.update(data: Data([0x0A]))
        for line in lines { hasher.update(data: Data(line)) }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return uuidString(from: bytes)
    }

    private static func uuidString(from bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func slice(_ range: Range<Int>) -> String {
            let start = hex.index(hex.startIndex, offsetBy: range.lowerBound)
            let end = hex.index(hex.startIndex, offsetBy: range.upperBound)
            return String(hex[start..<end])
        }
        return "\(slice(0..<8))-\(slice(8..<12))-\(slice(12..<16))-\(slice(16..<20))-\(slice(20..<32))"
    }

    private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let common = min(a.count, b.count)
        for index in 0..<common where a[index] != b[index] {
            return Int(a[index]) - Int(b[index])
        }
        return a.count - b.count
    }

    static func validateRecord(stream: PushMutableStream, key: [String: JSONValue], data: [String: JSONValue]) throws {
        let spec = PushRegistry.spec(for: stream)
        guard Set(key.keys) == Set(spec.keyColumns), key.count == spec.keyColumns.count else {
            throw PushProtocolError.invalid("\(stream.wireName) key does not match registry")
        }
        let expectedData = Set(spec.dataColumns)
        guard Set(data.keys) == expectedData, data.count == expectedData.count else {
            throw PushProtocolError.invalid("\(stream.wireName) data does not match registry")
        }
        if key["deviceId"] != nil || data["deviceId"] != nil || data["synced"] != nil {
            throw PushProtocolError.invalid("batch-scoped or local-only column in record")
        }
    }

    static func validateUuid(_ value: String, name: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw PushProtocolError.invalid("\(name) must be a lowercase canonical UUID")
        }
    }
}
