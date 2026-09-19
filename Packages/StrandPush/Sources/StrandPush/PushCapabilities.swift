import Foundation

/// The receiver's negotiated support, narrowed to the streams this package can send. Port of
/// the Kotlin `PushCapabilities` (`PushCapabilities.kt`), minus the append-stream fields.
public struct PushCapabilities: Equatable, Sendable {
    public let mutableStreams: Set<PushMutableStream>
    public let protocolVersion: String
    public let receiverStateId: String

    public init(mutableStreams: Set<PushMutableStream>, protocolVersion: String, receiverStateId: String) {
        self.mutableStreams = mutableStreams
        self.protocolVersion = protocolVersion
        self.receiverStateId = receiverStateId
    }

    /// Parses and validates a `GET` capabilities document. Fails closed: an unknown member name
    /// (`command`, `endpoint`, ...), an unrecognized stream name, a duplicate stream name, or a
    /// body over the 16 KiB ack/control-message bound is rejected rather than partially accepted.
    public static func parse(_ bytes: [UInt8]) throws -> PushCapabilities {
        guard bytes.count <= PushProtocol.maxAckBytes else {
            throw PushProtocolError.invalid("capabilities exceed the 16 KiB control-message limit")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) as? [String: Any] else {
            throw PushProtocolError.invalid("capabilities are not a valid JSON object")
        }

        let required: Set<String> = ["type", "protocolVersion", "receiverStateId", "streams"]
        guard required.isSubset(of: Set(object.keys)) else {
            throw PushProtocolError.invalid("capabilities are missing required protocol 1.0 members")
        }
        guard !object.keys.contains(where: PushProtocol.forbiddenRemoteControlMembers.contains) else {
            throw PushProtocolError.invalid("capabilities contain forbidden remote-control metadata")
        }
        guard (object["type"] as? String) == "capabilities" else {
            throw PushProtocolError.invalid("capabilities.type must be \"capabilities\"")
        }
        guard let protocolVersion = object["protocolVersion"] as? String, protocolVersion == PushProtocol.version else {
            throw PushProtocolError.invalid("capabilities.protocolVersion is not a supported major version")
        }
        guard let receiverStateId = object["receiverStateId"] as? String, isCanonicalUuid(receiverStateId) else {
            throw PushProtocolError.invalid("capabilities.receiverStateId must be a lowercase canonical UUID")
        }
        guard let streamNames = object["streams"] as? [Any] else {
            throw PushProtocolError.invalid("capabilities.streams must be an array")
        }

        var seen = Set<String>()
        var mutableStreams = Set<PushMutableStream>()
        for entry in streamNames {
            guard let name = entry as? String else {
                throw PushProtocolError.invalid("capabilities.streams entries must be strings")
            }
            guard seen.insert(name).inserted else {
                throw PushProtocolError.invalid("capabilities.streams contains a duplicate stream name")
            }
            guard PushWireVocabulary.allStreamNames.contains(name) else {
                throw PushProtocolError.invalid("capabilities.streams contains an unrecognized stream name")
            }
            if let stream = PushMutableStream(rawValue: name) {
                mutableStreams.insert(stream)
            }
        }
        return PushCapabilities(mutableStreams: mutableStreams, protocolVersion: protocolVersion, receiverStateId: receiverStateId)
    }

    private static func isCanonicalUuid(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}
