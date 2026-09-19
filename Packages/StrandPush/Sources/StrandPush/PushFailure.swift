import Foundation

/// Port of the Kotlin `PushFailureCode`/`PushFailure` (`PushFailure.kt`) retryable taxonomy.
public enum PushFailureCode: String, Sendable {
    case dnsLookup
    case tlsCertificate
    case tlsHandshake
    case networkTimeout
    case connectionRefused
    case networkUnreachable
    case connectionReset
    case networkIO
    case httpAuth
    case httpNotFound
    case httpTimeout
    case httpTooLarge
    case httpMediaType
    case httpProtocolRejected
    case httpRateLimit
    case httpServer
    case httpClient
    case capabilitiesInvalid
    case ackInvalid
    case localData
    case localDatabase
}

public struct PushFailure: Equatable, Sendable {
    public let code: PushFailureCode
    public let httpStatus: Int?
    public let receiverCode: String?

    public init(code: PushFailureCode, httpStatus: Int? = nil, receiverCode: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus
        self.receiverCode = receiverCode
    }

    /// Whether the same request is worth retrying unmodified after a backoff. Auth, 404, payload
    /// too large, unsupported media type, and generic 4xx failures are NOT retryable — retrying
    /// them cannot succeed without a human or a code change.
    public var retryable: Bool {
        switch code {
        case .dnsLookup, .tlsHandshake, .networkTimeout, .connectionRefused, .networkUnreachable,
             .connectionReset, .networkIO, .httpTimeout, .httpRateLimit, .httpServer:
            return true
        case .tlsCertificate, .httpAuth, .httpNotFound, .httpTooLarge, .httpMediaType,
             .httpProtocolRejected, .httpClient, .capabilitiesInvalid, .ackInvalid, .localData,
             .localDatabase:
            return false
        }
    }

    public static func http(status: Int, receiverCode: String?) -> PushFailure {
        let code: PushFailureCode
        switch status {
        case 401, 403: code = .httpAuth
        case 404: code = .httpNotFound
        case 408: code = .httpTimeout
        case 413: code = .httpTooLarge
        case 415: code = .httpMediaType
        case 400, 409, 422: code = .httpProtocolRejected
        case 429: code = .httpRateLimit
        case 500...599: code = .httpServer
        case 402, 405, 406, 410, 411, 412, 414, 416, 417, 421, 423...499:
            code = .httpClient
        default:
            code = .httpClient
        }
        return PushFailure(code: code, httpStatus: status, receiverCode: receiverCode)
    }

    public static func classify(_ error: Error) -> PushFailure {
        guard let urlError = error as? URLError else { return PushFailure(code: .networkIO) }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return PushFailure(code: .dnsLookup)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return PushFailure(code: .tlsCertificate)
        case .secureConnectionFailed:
            return PushFailure(code: .tlsHandshake)
        case .timedOut:
            return PushFailure(code: .networkTimeout)
        case .cannotConnectToHost:
            return PushFailure(code: .connectionRefused)
        case .networkConnectionLost:
            return PushFailure(code: .connectionReset)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return PushFailure(code: .networkUnreachable)
        default:
            return PushFailure(code: .networkIO)
        }
    }
}

/// A receiver-declared error body, e.g. `{"type":"error","protocolVersion":"1.0","code":"..."}`.
/// Parsed defensively: a malformed or oversize body yields `nil`, never a thrown diagnostic that
/// could leak transport internals.
public enum PushError {
    public static func parseCode(_ bytes: [UInt8], expectedVersion: String = PushProtocol.version) -> String? {
        guard !bytes.isEmpty, bytes.count <= PushProtocol.maxAckBytes else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        guard object["type"] as? String == "error", object["protocolVersion"] as? String == expectedVersion,
              let code = object["code"] as? String,
              code.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil
        else {
            return nil
        }
        return code
    }
}
