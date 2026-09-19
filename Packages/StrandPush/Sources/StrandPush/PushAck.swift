import Foundation

/// A receiver's per-batch acknowledgement. Port of the Kotlin `PushAck` (`PushModels.kt`).
/// `endCursor` is validated when present (an object needs a well-formed `rowId`/`keySha256`) even
/// though, for replace-window batches, only a `null` `endCursor` can ever count as a match.
public struct PushAck: Equatable, Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let stream: String
    public let deviceId: String
    public let endCursorPresent: Bool
    public let acceptedRows: Int
    public let status: String

    public init(protocolVersion: String, batchId: String, stream: String, deviceId: String, endCursorPresent: Bool, acceptedRows: Int, status: String) {
        self.protocolVersion = protocolVersion
        self.batchId = batchId
        self.stream = stream
        self.deviceId = deviceId
        self.endCursorPresent = endCursorPresent
        self.acceptedRows = acceptedRows
        self.status = status
    }

    public static func fromBatch(_ batch: PushBatch) -> PushAck {
        PushAck(
            protocolVersion: batch.protocolVersion, batchId: batch.batchId, stream: batch.stream.wireName,
            deviceId: batch.deviceId, endCursorPresent: false, acceptedRows: batch.recordCount, status: "accepted"
        )
    }

    /// The only receiver response that lets a replace-window batch be considered delivered:
    /// every identity field echoed back exactly, `endCursor` still `null`, all rows accepted.
    public func exactlyMatches(_ batch: PushBatch) -> Bool {
        protocolVersion == batch.protocolVersion
            && batchId == batch.batchId
            && stream == batch.stream.wireName
            && deviceId == batch.deviceId
            && !endCursorPresent
            && acceptedRows == batch.recordCount
            && status == "accepted"
    }

    public func encode() throws -> [UInt8] {
        let object: JSONValue = .object([
            "acceptedRows": .int(Int64(acceptedRows)),
            "batchId": .string(batchId),
            "deviceId": .string(deviceId),
            "endCursor": .null,
            "protocolVersion": .string(protocolVersion),
            "status": .string(status),
            "stream": .string(stream),
        ])
        return Array(try PushCanonicalJSON.encode(object).utf8)
    }

    public static func parse(_ bytes: [UInt8]) throws -> PushAck {
        guard bytes.count <= PushProtocol.maxAckBytes else {
            throw PushProtocolError.invalid("ack exceeds the 16 KiB control-message limit")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) as? [String: Any] else {
            throw PushProtocolError.invalid("ack is not a valid JSON object")
        }
        let required: Set<String> = ["protocolVersion", "batchId", "stream", "deviceId", "endCursor", "acceptedRows", "status"]
        guard required.isSubset(of: Set(object.keys)) else {
            throw PushProtocolError.invalid("ack is missing required protocol 1.0 members")
        }
        guard !object.keys.contains(where: PushProtocol.forbiddenRemoteControlMembers.contains) else {
            throw PushProtocolError.invalid("ack contains forbidden remote-control metadata")
        }

        func requiredString(_ name: String) throws -> String {
            guard let value = object[name] as? String, !value.isEmpty else {
                throw PushProtocolError.invalid("ack.\(name) must be a non-empty string")
            }
            return value
        }
        func requiredInt(_ name: String) throws -> Int {
            guard let number = object[name] as? NSNumber, Double(number.intValue) == number.doubleValue else {
                throw PushProtocolError.invalid("ack.\(name) must be an integer")
            }
            return number.intValue
        }

        let endCursorPresent: Bool
        switch object["endCursor"] {
        case nil, is NSNull:
            endCursorPresent = false
        case let cursor as [String: Any]:
            let requiredCursor: Set<String> = ["rowId", "keySha256"]
            guard requiredCursor.isSubset(of: Set(cursor.keys)) else {
                throw PushProtocolError.invalid("ack.endCursor is missing required protocol 1.0 members")
            }
            guard cursor["rowId"] is NSNumber else {
                throw PushProtocolError.invalid("ack.endCursor.rowId must be an integer")
            }
            guard let sha = cursor["keySha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw PushProtocolError.invalid("ack.endCursor.keySha256 must be a lowercase SHA-256 hex digest")
            }
            endCursorPresent = true
        default:
            throw PushProtocolError.invalid("ack.endCursor must be an object or null")
        }

        return PushAck(
            protocolVersion: try requiredString("protocolVersion"),
            batchId: try requiredString("batchId"),
            stream: try requiredString("stream"),
            deviceId: try requiredString("deviceId"),
            endCursorPresent: endCursorPresent,
            acceptedRows: try requiredInt("acceptedRows"),
            status: try requiredString("status")
        )
    }
}
