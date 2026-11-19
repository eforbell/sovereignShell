import Foundation
import Security
import Testing
@testable import SovereignShell

/// Household trust against a test chain: a root pinned only here, and a leaf for one household host.
@Suite struct HouseholdTrustTests {
    static let host = "home.example-tailnet.ts.net"
    /// Inside the leaf's validity, so these tests don't expire with it.
    static let date = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A fresh SecTrust for the leaf (with the root sent along, as a server might), under default policies.
    static func serverTrust() throws -> SecTrust {
        let leaf = try #require(SecCertificateCreateWithData(nil, try fixture("test-leaf") as CFData))
        let root = try #require(SecCertificateCreateWithData(nil, try fixture("test-root") as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        return try #require(trust)
    }

    @Test func aChainToAPinnedRootPasses() throws {
        let trust = HouseholdTrust(anchors: [try Self.fixture("test-root")])
        #expect(trust.evaluate(try Self.serverTrust(), host: Self.host, at: Self.date))
    }

    @Test func anotherHostnameFails() throws {
        let trust = HouseholdTrust(anchors: [try Self.fixture("test-root")])
        #expect(!trust.evaluate(try Self.serverTrust(), host: "other.example-tailnet.ts.net", at: Self.date))
    }

    @Test func aRootThatIsNotPinnedFailsEvenWhenTheServerSendsIt() throws {
        // ISRG Root X1 pinned, as the app does: the test chain, root included, doesn't reach it.
        let isrg = HouseholdTrust(anchors: [try Self.fixture("isrg-root-x1")])
        #expect(!isrg.evaluate(try Self.serverTrust(), host: Self.host, at: Self.date))
        #expect(!HouseholdTrust(anchors: []).evaluate(try Self.serverTrust(), host: Self.host, at: Self.date), "no anchors, no trust")
        #expect(!HouseholdTrust(anchors: [Data("not a certificate".utf8)]).evaluate(try Self.serverTrust(), host: Self.host, at: Self.date))
    }

    @Test func outsideTheLeafsValidityFails() throws {
        let trust = HouseholdTrust(anchors: [try Self.fixture("test-root")])
        let later = ISO8601DateFormatter().date(from: "2028-01-01T00:00:00Z")!
        #expect(!trust.evaluate(try Self.serverTrust(), host: Self.host, at: later))
    }

    @Test func bundledAnchorsAreReadAndMissingOnesSkipped() throws {
        let bundled = HouseholdTrust.bundled(Bundle.module, names: ["Fixtures/test-root", "Fixtures/no-such-anchor"])
        #expect(bundled.anchors == [try Self.fixture("test-root")])
        #expect(bundled.evaluate(try Self.serverTrust(), host: Self.host, at: Self.date))
    }
}
