import Foundation

public enum PushProtocolError: Error, Equatable, Sendable {
    case invalid(String)
}

/// A minimal JSON value tree. NDJSON records/headers are built from this rather than `Any?`
/// (as the Kotlin twin uses `Map<String, Any?>`) because Swift has no ergonomic untyped map.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Deterministic, alphabetically-sorted-key JSON encoder. Port of the Kotlin
/// `PushProtocol.canonicalJson` (`sortMaps = true` path) — object member order is not semantically
/// significant on the wire, but the same records must always encode to the same bytes so a retry is
/// byte identical and `stableUuid` is reproducible.
enum PushCanonicalJSON {
    static func encode(_ value: JSONValue) throws -> String {
        var out = ""
        try append(value, to: &out)
        return out
    }

    private static func append(_ value: JSONValue, to out: inout String) throws {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            guard d.isFinite else {
                throw PushProtocolError.invalid("non-finite number is not valid JSON")
            }
            out += d.description
        case .string(let s):
            appendQuoted(s, to: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try append(item, to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                appendQuoted(key, to: &out)
                out += ":"
                try append(members[key]!, to: &out)
            }
            out += "}"
        }
    }

    private static func appendQuoted(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
