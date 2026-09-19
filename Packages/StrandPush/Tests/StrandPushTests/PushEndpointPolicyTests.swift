import StrandPush
import XCTest

/// Mirrors `android/app/src/test/java/com/noop/push/PushEndpointPolicyTest.kt`.
final class PushEndpointPolicyTests: XCTestCase {
    func testMalformedShapesReportTheirOwnProblem() {
        let cases: [(String, PushEndpointPolicy.Problem?)] = [
            ("", .missingScheme),
            ("not a url", .malformedURL),
            ("ftp://192.168.1.2/push", .unsupportedScheme),
            ("http://user:pass@192.168.1.2/push", .userInfoNotAllowed),
            ("http://192.168.1.2/push#secret", .fragmentNotAllowed),
            ("https:///push", .missingHost),
            ("http://192.168.1.2/push", nil),
        ]
        for (input, expected) in cases {
            let result = PushEndpointPolicy.validate(input)
            switch (result, expected) {
            case (.valid, nil):
                continue
            case (.invalid(let problem), .some(let expectedProblem)):
                XCTAssertEqual(problem, expectedProblem, "for input \(input)")
            default:
                XCTFail("unexpected result \(result) for input \(input)")
            }
        }
    }

    func testHttpsNormalizesSchemeCaseHostCaseAndDefaultPort() {
        guard case .valid(let endpoint) = PushEndpointPolicy.validate(" HTTPS://Example.COM:443/push ") else {
            return XCTFail("expected a valid endpoint")
        }
        XCTAssertEqual(endpoint.url, "https://example.com/push")
        XCTAssertEqual(endpoint.host, "example.com")
    }

    func testPrivateIpv4RangesAreAcceptedForPlainHttp() {
        for host in ["10.1.2.3", "172.16.1.2", "172.31.255.2", "192.168.4.2", "127.0.0.1", "169.254.1.2"] {
            guard case .valid = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) to be accepted for plain http")
            }
        }
    }

    func testPublicAndNearBoundaryIpv4RangesAreRejectedForPlainHttp() {
        for host in ["8.8.8.8", "172.15.255.255", "172.32.0.1", "192.169.1.1"] {
            guard case .invalid = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) to be rejected for plain http")
            }
        }
    }

    func testLocalIpv6LiteralsAreAcceptedForPlainHttp() {
        for host in ["[::1]", "[fc00::1]", "[fe80::1]"] {
            guard case .valid = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) to be accepted for plain http")
            }
        }
    }

    func testPublicAndNearBoundaryIpv6LiteralsAreRejectedForPlainHttp() {
        for host in ["[::]", "[2001:4860:4860::8888]", "[fec0::1]"] {
            guard case .invalid = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) to be rejected for plain http")
            }
        }
    }

    func testCleartextHostnamesAreRejectedToRemoveDnsRebindingAndPreResolution() {
        for host in ["localhost", "receiver.local", "example.com"] {
            guard case .invalid = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) to be rejected for plain http (no DNS resolution before validation)")
            }
        }
    }

    func testPublicHttpsHostnameIsAccepted() {
        guard case .valid = PushEndpointPolicy.validate("https://push.example.com/push") else {
            return XCTFail("expected a public HTTPS hostname to be accepted")
        }
    }

    /// Tailscale's `100.64.0.0/10` CGNAT range is deliberately absent from the allow list: a
    /// Tailscale-assigned address is reachable over the WAN via Tailscale's relay/DERP path in
    /// some configurations, so it is not automatically "local" the way RFC 1918 is.
    func testTailscaleCgnatRangeIsRejectedForPlainHttp() {
        for host in ["100.64.0.1", "100.100.100.100", "100.127.255.255"] {
            guard case .invalid(let problem) = PushEndpointPolicy.validate("http://\(host)/push") else {
                return XCTFail("expected \(host) (Tailscale CGNAT) to be rejected for plain http")
            }
            XCTAssertEqual(problem, .httpRequiresLocalAddress)
        }
    }
}
