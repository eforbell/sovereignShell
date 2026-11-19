import Foundation
import Security

/// Household trust (sovereignAuth native-handoff, "Household trust"): household hosts are trusted only when
/// their chain ends at one of these certificate authorities. User-installed and other system roots don't
/// count. The defaults are Let's Encrypt's ISRG Root X1 and X2, which Tailscale's certificates chain to.
///
/// Phase 3 spike 5 version: it lives in the app for now and moves into SovereignShell with slice 6.
struct PinnedTrust: Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case pinned = "Pinned (ISRG X1, X2)"
        /// No anchors at all: every household load must fail. Proves the handler sees the load.
        case refuseAll = "Refuse everything"
    }

    let mode: Mode

    /// The pinned roots, bundled as DER files under TrustAnchors/.
    static let anchors: [SecCertificate] = ["isrg-root-x1", "isrg-root-x2"].compactMap { name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "der"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    /// Whether this server trust passes for `host`, and why not when it doesn't.
    func evaluate(_ trust: SecTrust, host: String) -> (ok: Bool, detail: String) {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        let anchors = mode == .pinned ? Self.anchors : []
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? [])
            .map { SecCertificateCopySubjectSummary($0) as String? ?? "?" }
            .joined(separator: " ← ")
        return (ok, ok ? chain : (error.map { CFErrorCopyDescription($0) as String } ?? "refused"))
    }
}
