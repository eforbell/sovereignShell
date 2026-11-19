import CryptoKit
import Foundation
import os
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The native handoff, the app's side (sovereignAuth wire contract, section 13; docs/native-handoff.md). A
/// household page in the app's web view can't run a passkey ceremony, so it calls `window.sovereign
/// .handoff(id)`. The app then:
/// 1. registers this installation with Home Base once (an app instance: an App Attest key, attested over
///    `sovereign-app-instance/1\n<household>\n<user_id>\n<challenge>`);
/// 2. attests the page's handoff id with that key, over `sovereign-handoff/1\n<host>\n<id>`, to the page's
///    own host;
/// 3. opens an ephemeral Safari sheet on that host's handoff page, which runs the ceremony and returns to
///    the app's callback scheme (the callback carries nothing).
/// The page then redeems the result itself. The app attests only ids its own web view hands it from a
/// household page's main frame: never from a URL, a link or a notification.

/// Why a handoff didn't happen, as the page's `window.sovereign.handoff(id)` rejects with it: `cancelled`
/// and `unavailable` by those names, anything else as its message.
public enum HandoffError: Error, Equatable, Sendable {
    /// The member closed the sheet.
    case cancelled
    /// App Attest isn't possible on this phone, or this Home Base doesn't take part in the handoff.
    case unavailable
    case failed(String)

    public var message: String {
        switch self {
        case .cancelled: "cancelled"
        case .unavailable: "unavailable"
        case .failed(let message): message
        }
    }
}

/// App Attest, as the handoff uses it (DCAppAttestService on a phone; a fake in tests).
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck)
/// The phone's App Attest.
public struct SystemAppAttest: AppAttesting {
    public init() {}
    public var isSupported: Bool { DCAppAttestService.shared.isSupported }
    public func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }
    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
#endif

/// A JSON POST to `/_sovereign/auth/<path>` on a household host, as Home Base's own client: the status and
/// the decoded body (an empty one when it isn't JSON).
public typealias HandoffTransport = @Sendable (_ host: String, _ path: String, _ body: [String: String]) async throws(HomeBaseError) -> (status: Int, body: [String: Any])

/// The sheet: opens `url` in an ephemeral web authentication session and returns when it reaches
/// `callbackScheme`, or throws `HandoffError.cancelled` when the member closes it.
public typealias HandoffSheet = @MainActor (_ url: URL, _ callbackScheme: String) async throws(HandoffError) -> Void

/// The registered App Attest key for each Home Base, by its host. A key ID names a key in this phone's Secure
/// Enclave; it isn't secret, and it doesn't survive a reinstall or a new phone (Home Base then says it's
/// unknown, and the app registers again).
// UserDefaults is thread-safe; Swift just doesn't know it.
public struct AppInstanceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ homeBase: String) -> String { "appInstanceKeyId.\(homeBase.lowercased())" }
    public func keyId(for homeBase: String) -> String? { defaults.string(forKey: key(homeBase)) }
    public func remember(_ keyId: String, for homeBase: String) { defaults.set(keyId, forKey: key(homeBase)) }
    public func forget(for homeBase: String) { defaults.removeObject(forKey: key(homeBase)) }
}

/// Whether App Attest says the key is gone (DCError.invalidKey): only then is a key replaced.
func isInvalidKey(_ error: any Error) -> Bool {
    #if canImport(DeviceCheck)
    if let error = error as? DCError { return error.code == .invalidKey }
    #endif
    return false
}

/// The handoff for one household, one at a time.
@MainActor
public final class HandoffAgent {
    static let idPattern = /^[A-Za-z0-9_-]{43}$/
    static let log = Logger(subsystem: "SovereignShell", category: "handoff")

    let homeBase: HomeBaseAddress
    let callbackScheme: String
    let label: String
    let attest: any AppAttesting
    let transport: HandoffTransport
    let store: AppInstanceStore
    let sheet: HandoffSheet
    private var busy = false

    /// callbackScheme: what the sheet returns to, Home Base's `HOME_BASE_NATIVE_APP_SCHEME` (this app uses
    /// its bundle ID). label: the device name Home Base shows on the Members card.
    public init(homeBase: HomeBaseAddress, callbackScheme: String, label: String, attest: any AppAttesting,
                transport: @escaping HandoffTransport, store: AppInstanceStore = AppInstanceStore(), sheet: @escaping HandoffSheet) {
        self.homeBase = homeBase
        self.callbackScheme = callbackScheme.lowercased()
        self.label = label
        self.attest = attest
        self.transport = transport
        self.store = store
        self.sheet = sheet
    }

    static func sha256(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    /// The handoff `id` a household page on `host` asked for. The caller has checked that the page is a
    /// household page in the web view's main frame.
    public func handoff(id: String, host: String) async throws(HandoffError) {
        guard id.wholeMatch(of: Self.idPattern) != nil else { throw .failed("That isn't a handoff.") }
        guard !busy else { throw .failed("Another confirmation is already open.") }
        busy = true
        defer { busy = false }
        guard attest.isSupported else { throw .unavailable }
        let host = host.lowercased()
        try await attestHandoff(id: id, host: host, retry: true)
        guard let url = URL(string: "https://\(host)/_sovereign/auth/handoff/sheet#\(id)") else { throw .failed("That isn't a household host.") }
        try await sheet(url, callbackScheme)
    }

    /// Step 3a: an assertion over the handoff, sent to the page's own host. An unknown or invalid key means
    /// this installation must register (again), once.
    private func attestHandoff(id: String, host: String, retry: Bool) async throws(HandoffError) {
        let keyId = try await registeredKey()
        let assertion: Data
        do {
            assertion = try await attest.generateAssertion(keyId, clientDataHash: Self.sha256("sovereign-handoff/1\n\(host)\n\(id)"))
        } catch {
            // The key is gone from the Secure Enclave (restored from a backup, say): register a new one. Any
            // other failure leaves the key, which Home Base still holds.
            guard retry, isInvalidKey(error) else { throw .failed("App Attest couldn't sign this: \(error.localizedDescription)") }
            store.forget(for: homeBase.host)
            return try await attestHandoff(id: id, host: host, retry: false)
        }
        let answer = try await post(host, "handoff/attest", ["id": id, "keyId": keyId, "assertion": assertion.base64EncodedString()])
        if answer.status == 200 { return }
        let reason = answer.body["reason"] as? String
        // Unknown (revoked, or a reinstall), or another member's (the phone's tailnet account changed):
        // this installation registers for whoever it is now, once.
        if retry, answer.status == 403, answer.body["error"] as? String == "app_instance_refused", reason == "unknown_key" || reason == "wrong_member" {
            store.forget(for: homeBase.host)
            return try await attestHandoff(id: id, host: host, retry: false)
        }
        throw .failed(Self.describe(answer, what: "Home Base didn't accept the app"))
    }

    /// This installation's key for this Home Base, registering it first if there isn't one (Part 1). An
    /// installation that has no key and can't register one is `unavailable` (the page then says the check
    /// can't be done in the app on this phone); why goes to the log. Not reaching Home Base is its own error.
    private func registeredKey() async throws(HandoffError) -> String {
        if let keyId = store.keyId(for: homeBase.host) { return keyId }
        func cannotRegister(_ why: String) -> HandoffError {
            Self.log.error("can't register this app instance: \(why, privacy: .public)")
            return .unavailable
        }
        let issued = try await post(homeBase.host, "app/challenge", [:])
        guard issued.status == 200,
              let challenge = issued.body["challenge"] as? String,
              let household = issued.body["household"] as? String,
              let userId = issued.body["userId"] as? String
        else { throw cannotRegister(Self.describe(issued, what: "Home Base didn't start registering the app")) }
        let keyId: String
        let attestation: Data
        do {
            keyId = try await attest.generateKey()
            attestation = try await attest.attestKey(keyId, clientDataHash: Self.sha256("sovereign-app-instance/1\n\(household)\n\(userId)\n\(challenge)"))
        } catch {
            throw cannotRegister("App Attest: \(error.localizedDescription)")
        }
        let registered = try await post(homeBase.host, "app/register", ["challenge": challenge, "keyId": keyId, "attestation": attestation.base64EncodedString(), "label": label])
        guard registered.status == 201 else { throw cannotRegister(Self.describe(registered, what: "Home Base didn't register the app")) }
        store.remember(keyId, for: homeBase.host)
        return keyId
    }

    private func post(_ host: String, _ path: String, _ body: [String: String]) async throws(HandoffError) -> (status: Int, body: [String: Any]) {
        do {
            return try await transport(host, path, body)
        } catch .untrusted {
            throw .failed("Can't verify your household's certificate.")
        } catch {
            throw .failed("Couldn't reach Home Base.")
        }
    }

    static func describe(_ answer: (status: Int, body: [String: Any]), what: String) -> String {
        if let reason = answer.body["reason"] as? String { return "\(what) (\(reason))." }
        if let error = answer.body["error"] as? String { return "\(what): \(error)" }
        return "\(what) (\(answer.status))."
    }
}

extension HomeBaseClient {
    /// The handoff's requests: a JSON POST to `/_sovereign/auth/<path>` on `host`, a household host, with the
    /// headers Home Base's mutation guard asks of its own pages (wire contract, section 4).
    public func authPost(host: String, path: String, body: [String: String]) async throws(HomeBaseError) -> (status: Int, body: [String: Any]) {
        guard let url = URL(string: "https://\(host)/_sovereign/auth/\(path)") else { throw .unreadable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        for (name, value) in Self.firstPartyFetchMetadata { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw failure(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, decoded)
    }
}
