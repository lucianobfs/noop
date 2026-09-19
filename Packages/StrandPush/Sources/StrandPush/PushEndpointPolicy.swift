import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Security boundary for the user-supplied destination. Validation happens before DNS or HTTP.
/// Port of the Kotlin `PushEndpointPolicy` (`android/.../push/PushEndpointPolicy.kt`) — the local
/// allow list (loopback, link-local, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, IPv6 ULA
/// `fc00::/7`) is copied VALUE FOR VALUE. Tailscale's `100.64.0.0/10` CGNAT range is deliberately
/// NOT in that list; see `PushEndpointPolicyTests.tailscaleCgnatRangeIsRejectedForPlainHttp`.
public enum PushEndpointPolicy {
    public struct ValidEndpoint: Equatable, Sendable {
        public let url: String
        public let host: String

        public init(url: String, host: String) {
            self.url = url
            self.host = host
        }
    }

    public enum Problem: Equatable, Sendable {
        case malformedURL
        case missingScheme
        case unsupportedScheme
        case userInfoNotAllowed
        case fragmentNotAllowed
        case missingHost
        case invalidHost
        case invalidPort
        case httpRequiresLocalAddress
    }

    public enum ValidationResult: Equatable, Sendable {
        case valid(ValidEndpoint)
        case invalid(Problem)
    }

    public static func validate(_ raw: String) -> ValidationResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            return .invalid(.malformedURL)
        }
        guard let generic = splitGeneric(trimmed) else { return .invalid(.malformedURL) }

        guard let schemeRaw = generic.scheme, !schemeRaw.isEmpty else { return .invalid(.missingScheme) }
        let scheme = schemeRaw.lowercased()
        guard scheme == "http" || scheme == "https" else { return .invalid(.unsupportedScheme) }

        guard generic.hasAuthority, let authorityRaw = generic.authority else { return .invalid(.missingHost) }
        let authority = parseAuthority(authorityRaw)
        if authority.malformed { return .invalid(.malformedURL) }
        if authority.userInfo != nil { return .invalid(.userInfoNotAllowed) }
        if generic.fragment != nil { return .invalid(.fragmentNotAllowed) }
        guard let hostRaw = authority.host, !hostRaw.isEmpty else { return .invalid(.missingHost) }

        let rawHost = hostRaw.lowercased()
        let asciiHost: String
        if rawHost.contains(":") || rawHost.unicodeScalars.allSatisfy(\.isASCII) {
            asciiHost = rawHost
        } else {
            // No IDNA/punycode conversion is implemented (no test exercises a non-ASCII hostname);
            // a real Unicode hostname is rejected rather than silently mis-encoded. See the README.
            return .invalid(.invalidHost)
        }

        guard let port = authority.port, (-1...65535).contains(port) else { return .invalid(.invalidPort) }

        let literal = parseLiteralAddress(asciiHost)
        let literalAllowed = literal.map(isLocalAddress) ?? false
        if scheme == "http" && !literalAllowed {
            return .invalid(.httpRequiresLocalAddress)
        }

        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let authorityHost = asciiHost.contains(":") ? "[\(asciiHost)]" : asciiHost
        let authorityString = authorityHost + (port >= 0 && !defaultPort ? ":\(port)" : "")
        let path = generic.path.isEmpty ? "/" : generic.path
        var normalized = "\(scheme)://\(authorityString)\(path)"
        if let query = generic.query { normalized += "?\(query)" }
        return .valid(ValidEndpoint(url: normalized, host: asciiHost))
    }

    // MARK: - Generic URI decomposition (RFC 3986 Appendix B), without DNS or percent-decoding.

    private struct GenericURI {
        let scheme: String?
        let hasAuthority: Bool
        let authority: String?
        let path: String
        let query: String?
        let fragment: String?
    }

    private static func splitGeneric(_ s: String) -> GenericURI? {
        let pattern = "^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\\?([^#]*))?(#(.*))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range), match.range == range else {
            return nil
        }
        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: s) else { return nil }
            return String(s[r])
        }
        return GenericURI(
            scheme: group(2),
            hasAuthority: match.range(at: 3).location != NSNotFound,
            authority: group(4),
            path: group(5) ?? "",
            query: group(7),
            fragment: group(9)
        )
    }

    private struct ParsedAuthority {
        let userInfo: String?
        let host: String?
        let port: Int?
        let malformed: Bool
    }

    private static func parseAuthority(_ authority: String) -> ParsedAuthority {
        var rest = Substring(authority)
        var userInfo: String?
        if let at = rest.firstIndex(of: "@") {
            userInfo = String(rest[rest.startIndex..<at])
            rest = rest[rest.index(after: at)...]
        }

        let host: String
        var portPart: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else {
                return ParsedAuthority(userInfo: userInfo, host: nil, port: nil, malformed: true)
            }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let afterBracket = rest[rest.index(after: close)...]
            if afterBracket.isEmpty {
                portPart = nil
            } else if afterBracket.hasPrefix(":") {
                portPart = afterBracket.dropFirst()
            } else {
                return ParsedAuthority(userInfo: userInfo, host: nil, port: nil, malformed: true)
            }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[rest.startIndex..<colon])
            portPart = rest[rest.index(after: colon)...]
        } else {
            host = String(rest)
        }

        var port = -1
        if let raw = portPart {
            if raw.isEmpty {
                port = -1
            } else if raw.allSatisfy(\.isNumber) {
                port = Int(raw) ?? Int.max
            } else {
                return ParsedAuthority(userInfo: userInfo, host: host, port: nil, malformed: true)
            }
        }
        return ParsedAuthority(userInfo: userInfo, host: host, port: port, malformed: false)
    }

    // MARK: - Literal address recognition (never a DNS lookup).

    private enum Literal {
        case v4([UInt8])
        case v6([UInt8])
    }

    private static func parseLiteralAddress(_ host: String) -> Literal? {
        if host.contains(":") {
            guard let bytes = parseIPv6Literal(host) else { return nil }
            return .v6(bytes)
        }
        guard host.range(of: "^[0-9.]+$", options: .regularExpression) != nil else { return nil }
        guard let bytes = parseIPv4Literal(host) else { return nil }
        return .v4(bytes)
    }

    private static func parseIPv4Literal(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &addr.s_addr) { Array($0) }
    }

    private static func parseIPv6Literal(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// The allow list. VALUE FOR VALUE with the Kotlin `isLocalAddress` — do not add
    /// `100.64.0.0/10` (Tailscale CGNAT) here; that is the one deliberate omission.
    private static func isLocalAddress(_ literal: Literal) -> Bool {
        switch literal {
        case .v4(let b):
            if b[0] == 127 { return true } // loopback
            if b[0] == 169 && b[1] == 254 { return true } // link-local
            if b[0] == 10 { return true } // RFC 1918
            if b[0] == 172 && (16...31).contains(Int(b[1])) { return true }
            if b[0] == 192 && b[1] == 168 { return true }
            return false
        case .v6(let b):
            let isLoopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
            if isLoopback { return true }
            let isLinkLocal = b[0] == 0xFE && (b[1] & 0xC0) == 0x80 // fe80::/10
            if isLinkLocal { return true }
            return (b[0] & 0xFE) == 0xFC // fc00::/7 ULA
        }
    }
}
