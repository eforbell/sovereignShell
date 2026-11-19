import CryptoKit
import DeviceCheck
import Foundation
import Testing
@testable import SovereignShell

/// The app's side of the native handoff, with a fake App Attest, a fake Home Base and a fake sheet.
@MainActor
@Suite struct HandoffAgentTests {
    static let homeBase = HomeBaseAddress("smith-homebase.example-tailnet.ts.net")!
    static let pulse = "smith-pulse.example-tailnet.ts.net"
    static let id = String(repeating: "I", count: 42) + "E"

    /// App Attest: records what it was asked to sign (as the client data's SHA-256).
    final class FakeAttest: AppAttesting, @unchecked Sendable {
        var isSupported = true
        var keys = 0
        var attested: [(keyId: String, hash: Data)] = []
        var asserted: [(keyId: String, hash: Data)] = []
        var assertionFails: [String: any Error] = [:]
        var attestFails = false
        func generateKey() async throws -> String { keys += 1; return "key-\(keys)" }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            if attestFails { throw DCError(.serverUnavailable) }
            attested.append((keyId, clientDataHash))
            return Data("attestation-\(keyId)".utf8)
        }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            if let error = assertionFails[keyId] { throw error }
            asserted.append((keyId, clientDataHash))
            return Data("assertion-\(keyId)".utf8)
        }
    }

    /// Home Base: answers by path, records every request.
    final class FakeHomeBase: @unchecked Sendable {
        var requests: [(host: String, path: String, body: [String: String])] = []
        var answers: [String: [(Int, [String: Any])]] = [:]
        var untrusted = false
        func answer(_ path: String, _ status: Int, _ body: [String: Any] = [:]) { answers[path, default: []].append((status, body)) }
        lazy var transport: HandoffTransport = { [unowned self] host, path, body throws(HomeBaseError) in
            if self.untrusted { throw .untrusted }
            self.requests.append((host, path, body))
            var queue = self.answers[path] ?? []
            let next = queue.isEmpty ? (404, [String: Any]()) : queue.removeFirst()
            self.answers[path] = queue
            return (next.0, next.1)
        }
    }

    final class FakeSheet: @unchecked Sendable {
        var opened: [(URL, String)] = []
        var outcome: HandoffError?
        var sheet: HandoffSheet {
            { [unowned self] url, scheme throws(HandoffError) in
                self.opened.append((url, scheme))
                if let outcome = self.outcome { throw outcome }
            }
        }
    }

    struct Rig {
        let attest: FakeAttest
        let home: FakeHomeBase
        let sheet: FakeSheet
        let store: AppInstanceStore
        let agent: HandoffAgent
    }

    static func rig(registered: String? = nil) -> Rig {
        let defaults = UserDefaults(suiteName: "handoff-tests-\(UUID().uuidString)")!
        let store = AppInstanceStore(defaults: defaults)
        if let registered { store.remember(registered, for: homeBase.host) }
        let attest = FakeAttest()
        let home = FakeHomeBase()
        let sheet = FakeSheet()
        let agent = HandoffAgent(homeBase: homeBase, callbackScheme: "Org.Example.HomeBase", label: "Eric's iPhone",
                                 attest: attest, transport: home.transport, store: store, sheet: sheet.sheet)
        return Rig(attest: attest, home: home, sheet: sheet, store: store, agent: agent)
    }

    static func sha(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    static func registration(_ home: FakeHomeBase) {
        home.answer("app/challenge", 200, ["challenge": "CHALLENGE", "household": "smith", "userId": "1001", "expiresInSeconds": 300])
        home.answer("app/register", 201, ["ok": true])
    }

    @Test func firstUseRegistersThenAttestsToThePagesHostThenOpensTheSheet() async throws {
        let rig = Self.rig()
        Self.registration(rig.home)
        rig.home.answer("handoff/attest", 200, ["ok": true])
        try await rig.agent.handoff(id: Self.id, host: Self.pulse.uppercased())

        #expect(rig.home.requests.map { "\($0.host) \($0.path)" } == [
            "\(Self.homeBase.host) app/challenge",
            "\(Self.homeBase.host) app/register",
            "\(Self.pulse) handoff/attest",
        ])
        #expect(rig.attest.attested.map(\.hash) == [Self.sha("sovereign-app-instance/1\nsmith\n1001\nCHALLENGE")])
        let register = rig.home.requests[1].body
        #expect(register == ["challenge": "CHALLENGE", "keyId": "key-1", "attestation": Data("attestation-key-1".utf8).base64EncodedString(), "label": "Eric's iPhone"])
        #expect(rig.attest.asserted.map(\.hash) == [Self.sha("sovereign-handoff/1\n\(Self.pulse)\n\(Self.id)")])
        #expect(rig.home.requests[2].body == ["id": Self.id, "keyId": "key-1", "assertion": Data("assertion-key-1".utf8).base64EncodedString()])
        #expect(rig.sheet.opened.map(\.0.absoluteString) == ["https://\(Self.pulse)/_sovereign/auth/handoff/sheet#\(Self.id)"])
        #expect(rig.sheet.opened.map(\.1) == ["org.example.homebase"])
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-1")
    }

    @Test func aRegisteredInstanceOnlyAttests() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 200, ["ok": true])
        try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host)
        #expect(rig.home.requests.map(\.path) == ["handoff/attest"])
        #expect(rig.attest.keys == 0)
    }

    @Test func anUnknownKeyRegistersAgainOnce() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 403, ["error": "app_instance_refused", "reason": "unknown_key"])
        Self.registration(rig.home)
        rig.home.answer("handoff/attest", 200, ["ok": true])
        try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host)
        #expect(rig.home.requests.map(\.path) == ["handoff/attest", "app/challenge", "app/register", "handoff/attest"])
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-1")

        let again = Self.rig(registered: "key-9")
        again.home.answer("handoff/attest", 403, ["error": "app_instance_refused", "reason": "unknown_key"])
        Self.registration(again.home)
        again.home.answer("handoff/attest", 403, ["error": "app_instance_refused", "reason": "unknown_key"])
        await #expect(throws: HandoffError.failed("Home Base didn't accept the app (unknown_key).")) { try await again.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(again.sheet.opened.isEmpty)
    }

    @Test func aKeyTheSecureEnclaveLostRegistersAgain() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.attest.assertionFails = ["key-9": DCError(.invalidKey)]
        Self.registration(rig.home)
        rig.home.answer("handoff/attest", 200, ["ok": true])
        try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host)
        #expect(rig.attest.asserted.map(\.keyId) == ["key-1"])
    }

    @Test func anyOtherAssertionErrorKeepsTheKey() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.attest.assertionFails = ["key-9": DCError(.serverUnavailable)]
        await #expect(throws: HandoffError.self) { try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-9")
        #expect(rig.home.requests.isEmpty, "no new registration")
    }

    @Test func anotherMembersKeyRegistersForThisMemberOnce() async throws {
        // The phone's tailnet account changed since the key was registered.
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 403, ["error": "app_instance_refused", "reason": "wrong_member"])
        Self.registration(rig.home)
        rig.home.answer("handoff/attest", 200, ["ok": true])
        try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host)
        #expect(rig.home.requests.map(\.path) == ["handoff/attest", "app/challenge", "app/register", "handoff/attest"])
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-1")
    }

    @Test func aRecordOfAnotherMemberIsNotTheKeysFault() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 403, ["error": "handoff_refused", "reason": "wrong_member"])
        await #expect(throws: HandoffError.failed("Home Base didn't accept the app (wrong_member).")) { try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-9")
    }

    @Test func anInstanceThatCantRegisterIsUnavailable() async throws {
        let refused = Self.rig()
        refused.home.answer("app/challenge", 200, ["challenge": "C", "household": "smith", "userId": "1001"])
        refused.home.answer("app/register", 403, ["error": "app_instance_refused", "reason": "wrong_environment"])
        await #expect(throws: HandoffError.unavailable) { try await refused.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(refused.store.keyId(for: Self.homeBase.host) == nil)

        let notActive = Self.rig()
        notActive.home.answer("app/challenge", 409, ["error": "Home Base is in setup", "code": "BOOTSTRAP_STATE"])
        await #expect(throws: HandoffError.unavailable) { try await notActive.agent.handoff(id: Self.id, host: Self.homeBase.host) }

        let attestFails = Self.rig()
        attestFails.attest.attestFails = true
        attestFails.home.answer("app/challenge", 200, ["challenge": "C", "household": "smith", "userId": "1001"])
        await #expect(throws: HandoffError.unavailable) { try await attestFails.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(attestFails.sheet.opened.isEmpty)
    }

    @Test func otherRefusalsStopBeforeTheSheet() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 403, ["error": "handoff_refused", "reason": "not_pending"])
        await #expect(throws: HandoffError.failed("Home Base didn't accept the app (not_pending).")) { try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(rig.sheet.opened.isEmpty)
        #expect(rig.store.keyId(for: Self.homeBase.host) == "key-9", "only unknown_key forgets the key")
    }

    @Test func unavailableWithoutAppAttestOrWithoutTheAppRoutes() async throws {
        let unsupported = Self.rig()
        unsupported.attest.isSupported = false
        await #expect(throws: HandoffError.unavailable) { try await unsupported.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(unsupported.home.requests.isEmpty)

        let noRoutes = Self.rig()
        await #expect(throws: HandoffError.unavailable) { try await noRoutes.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(noRoutes.home.requests.map(\.path) == ["app/challenge"])
    }

    @Test func theSheetsCancelIsTheHandoffsCancel() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.answer("handoff/attest", 200, ["ok": true])
        rig.sheet.outcome = .cancelled
        await #expect(throws: HandoffError.cancelled) { try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host) }
        #expect(HandoffError.cancelled.message == "cancelled")
        #expect(HandoffError.unavailable.message == "unavailable")
    }

    @Test func onlyAHandoffIdAndOnlyOneAtATime() async throws {
        let rig = Self.rig(registered: "key-9")
        await #expect(throws: HandoffError.failed("That isn't a handoff.")) { try await rig.agent.handoff(id: "not-an-id", host: Self.homeBase.host) }
        await #expect(throws: HandoffError.failed("That isn't a handoff.")) { try await rig.agent.handoff(id: Self.id + "#x", host: Self.homeBase.host) }
        #expect(rig.home.requests.isEmpty)

        // The first handoff waits in its sheet; a second is refused meanwhile.
        rig.home.answer("handoff/attest", 200, ["ok": true])
        var release: CheckedContinuation<Void, Never>?
        let waiting = HandoffAgent(homeBase: Self.homeBase, callbackScheme: "x.y", label: "p", attest: rig.attest, transport: rig.home.transport, store: rig.store) { _, _ throws(HandoffError) in
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await waiting.handoff(id: Self.id, host: Self.homeBase.host) }
        while release == nil { await Task.yield() }
        await #expect(throws: HandoffError.failed("Another confirmation is already open.")) { try await waiting.handoff(id: Self.id, host: Self.homeBase.host) }
        release?.resume()
        try await first.value
    }

    @Test func anUntrustedCertificateSaysSo() async throws {
        let rig = Self.rig(registered: "key-9")
        rig.home.untrusted = true
        await #expect(throws: HandoffError.failed("Can't verify your household's certificate.")) { try await rig.agent.handoff(id: Self.id, host: Self.homeBase.host) }
    }
}
