import Foundation
import os
import Security

/// Household trust (sovereignAuth docs/native-handoff.md, "Household trust"). The app attests a handoff only
/// for a real household page, so nobody may show it a fake one: a root certificate the phone's owner
/// installed would otherwise let a forged page on a household host hand the app another client's handoff.
/// So household hosts are trusted only when their chain ends at one of these certificate authorities.
/// User-installed and other system roots don't count, and a failure never falls back to the system's trust.
/// Other sites keep the system's trust (they open in Safari anyway).
///
/// The anchors are the operator's: by default Let's Encrypt's ISRG Root X1 and X2, which Tailscale's
/// certificates chain to, bundled as DER files. If the household's certificate authority changes, the
/// operator replaces them and ships a build.
public struct HouseholdTrust: Sendable {
    /// The pinned roots, DER. Kept as bytes so the value is Sendable; certificates are made per evaluation.
    public let anchors: [Data]

    public init(anchors: [Data]) {
        self.anchors = anchors
    }

    /// The anchors bundled with the app: `<name>.der` for each name.
    public static func bundled(_ bundle: Bundle = .main, names: [String] = ["isrg-root-x1", "isrg-root-x2"]) -> HouseholdTrust {
        HouseholdTrust(anchors: names.compactMap { name in
            bundle.url(forResource: name, withExtension: "der").flatMap { try? Data(contentsOf: $0) }
        })
    }

    /// Whether `trust` holds for `host` against the pinned anchors only. `at` is for tests: the date the
    /// chain is evaluated at.
    public func evaluate(_ trust: SecTrust, host: String, at date: Date? = nil) -> Bool {
        let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return false }
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        if let date, SecTrustSetVerifyDate(trust, date as CFDate) != errSecSuccess { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// The answer to a server-trust challenge: household hosts through `evaluate`, anything else as the
    /// system would. A refused household host is cancelled, never passed to default handling.
    public func answer(_ challenge: URLAuthenticationChallenge, isHousehold: (String) -> Bool)
        -> (URLSession.AuthChallengeDisposition, URLCredential?, refused: Bool) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil, false) }
        let host = challenge.protectionSpace.host.lowercased()
        guard isHousehold(host) else { return (.performDefaultHandling, nil, false) }
        guard evaluate(serverTrust, host: host) else { return (.cancelAuthenticationChallenge, nil, true) }
        return (.useCredential, URLCredential(trust: serverTrust), false)
    }
}

/// Server trust for the app's own requests. Every native request goes to a household host, so every host is
/// held to the pinned anchors. It remembers refusals, so a cancelled request can say why.
public final class HouseholdTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    public let trust: HouseholdTrust
    private let refusedHosts = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(trust: HouseholdTrust) {
        self.trust = trust
    }

    /// Whether a request to `host` was refused for its certificate.
    public func refused(_ host: String) -> Bool {
        refusedHosts.withLock { $0.contains(host.lowercased()) }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let (disposition, credential, refused) = trust.answer(challenge) { _ in true }
        let host = challenge.protectionSpace.host.lowercased()
        refusedHosts.withLock { if refused { $0.insert(host) } else if disposition == .useCredential { $0.remove(host) } }
        return (disposition, credential)
    }
}
