import AuthenticationServices
import CryptoKit
import DeviceCheck
import os
import SovereignShell
import SwiftUI
import WebKit

/// Phase 3 spikes (sovereignAuth docs/native-handoff.md, "Spikes before slice 1"). Throwaway.
/// Nothing here sends a credential anywhere. The App Attest fixtures stay on the phone until shared on purpose.
struct HandoffSpikeView: View {
    @AppStorage("homeBaseAddress") private var addressText = ""
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.dismiss) private var dismiss

    @State private var results: [String: String] = [:]
    @State private var outcomes: [String: Outcome] = [:]
    @State private var fixtures: URL?
    @State private var busy = false
    @State private var trustMode: PinnedTrust.Mode = .pinned
    @State private var pinnedPage: PinnedPage?

    enum Outcome: String, CaseIterable { case untried = "Not tried", yes = "Yes", no = "No" }

    private var address: HomeBaseAddress? { HomeBaseAddress(addressText) }

    var body: some View {
        NavigationStack {
            Form {
                appAttest
                ephemeralSheet
                sheetIdentity
                Section {
                    Text("Folded into Home Base slice 4: the sheet page is ours, so it tries to return on its own and always shows a \"Return to Home Base\" button too.")
                        .foregroundStyle(.secondary)
                } header: { Text("4 · Closing the sheet") }
                pinning
                Section {
                    Button("Copy results") { UIPasteboard.general.string = summary }
                    Text(summary).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .disabled(busy)
            .navigationTitle("Phase 3 spikes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $pinnedPage) { page in
                PinnedWebSheet(page: page) { results["5 web view"] = $0 }
            }
        }
    }

    // MARK: 1 · App Attest

    private var appAttest: some View {
        Section {
            Button("Attest a key, then assert 3 times") { Task { await runAppAttest() } }
            result("1")
            if let fixtures {
                ShareLink("Share fixtures (AirDrop to the Mac)", item: fixtures)
            }
        } header: { Text("1 · App Attest") } footer: {
            Text("The fixtures contain the household App ID, so they stay out of public repos. AirDrop them to the Mac for the Node check.")
        }
    }

    private func runAppAttest() async {
        busy = true
        defer { busy = false }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            results["1"] = "App Attest is not supported on this device"
            return
        }
        do {
            let keyId = try await service.generateKey()
            let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let attestClientData = "sovereign-app-instance/1\nspike-household\nspike-user\n" + challenge.base64URL
            let attestation = try await service.attestKey(keyId, clientDataHash: Self.sha256(attestClientData))
            var assertions: [[String: String]] = []
            for index in 1...3 {
                let clientData = "sovereign-handoff/1\n\(address?.host ?? "spike-host")\nspike-\(index)"
                let assertion = try await service.generateAssertion(keyId, clientDataHash: Self.sha256(clientData))
                assertions.append(["clientData": clientData, "assertion": assertion.base64EncodedString()])
            }
            let fixture: [String: Any] = [
                "spike": "app-attest/1",
                "created": ISO8601DateFormatter().string(from: .now),
                "note": "Real App Attest output. Contains the household App ID (receipt, rpIdHash): keep it out of public repos.",
                "keyId": keyId,
                "attestationClientData": attestClientData,
                "attestation": attestation.base64EncodedString(),
                "assertions": assertions,
            ]
            let url = FileManager.default.temporaryDirectory.appending(path: "appattest-fixtures.json")
            try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            fixtures = url
            results["1"] = "attested (\(attestation.count) bytes) and asserted 3 times; fixtures ready to share"
        } catch {
            results["1"] = "failed: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)"
        }
    }

    private static func sha256(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    // MARK: 2 · Ephemeral sheet

    private var ephemeralSheet: some View {
        Section {
            Button("Open Admin in an ephemeral sheet") { Task { await openSheet("admin", key: "2") } }
            outcome("2 alert", "\"Wants to use … to sign in\" alert shown")
            outcome("2 icloud", "Unlock with iCloud Keychain")
            outcome("2 1password", "Unlock with 1Password")
            outcome("2 yubikey nfc", "Unlock with YubiKey (NFC)")
            outcome("2 yubikey usb", "Unlock with YubiKey (USB-C)")
            result("2")
        } header: { Text("2 · Ephemeral sheet") } footer: {
            Text("Unlock administration in the sheet once per method (reopen it each time), then tap Cancel to come back. Cancel is expected.")
        }
    }

    // MARK: 3 · Sheet identity

    private var sheetIdentity: some View {
        Section {
            Button("Ask Home Base natively (pinned)") { Task { await askNatively(key: "3 native") } }
            result("3 native")
            Button("Open /api/home in an ephemeral sheet") { Task { await openSheet("api/home", key: "3") } }
            outcome("3 same", "Sheet shows the same member")
        } header: { Text("3 · The sheet's identity") } footer: {
            Text("The sheet shows Home Base's raw answer. Compare its caller with the native one, then tap Cancel.")
        }
    }

    private func openSheet(_ path: String, key: String) async {
        guard let url = address?.resolving(path) else { return }
        do {
            let returned = try await webAuthenticationSession.authenticate(
                using: url, callback: .customScheme("sovereignshell-spike"),
                preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
            results[key] = "sheet returned \(returned.absoluteString)"
        } catch {
            results[key] = "sheet ended: \((error as NSError).domain) \((error as NSError).code)"
        }
    }

    // MARK: 5 · Pinning

    private var pinning: some View {
        Section {
            Picker("Trust", selection: $trustMode) {
                ForEach(PinnedTrust.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            Button("Ask Home Base natively with this trust") { Task { await askNatively(key: "5 native") } }
            result("5 native")
            Button("Load Home Base in a pinned web view") {
                if let address { pinnedPage = PinnedPage(url: address.url, host: address.host, mode: trustMode) }
            }
            result("5 web view")
        } header: { Text("5 · Pinning") } footer: {
            Text("Run both with Pinned (everything should load) and with Refuse everything (nothing should load). Each web view load starts with a fresh connection.")
        }
    }

    private func askNatively(key: String) async {
        guard let address else { return }
        busy = true
        defer { busy = false }
        let mode = key.hasPrefix("3") ? PinnedTrust.Mode.pinned : trustMode
        let delegate = PinningDelegate(trust: PinnedTrust(mode: mode), host: address.host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let home = try await HomeBaseClient(address: address, session: session).home()
            let who = home.caller.map { "\($0.name ?? "(no name)") · \($0.login)" } ?? "no caller"
            results[key] = "[\(mode.rawValue)] state=\(home.state) · \(who) · trust: \(delegate.log)"
        } catch {
            results[key] = "[\(mode.rawValue)] \(error) · trust: \(delegate.log)"
        }
    }

    // MARK: Rows and summary

    private func result(_ key: String) -> some View {
        Text(results[key] ?? "—").font(.footnote.monospaced()).foregroundStyle(.secondary)
    }

    private func outcome(_ key: String, _ label: String) -> some View {
        Picker(label, selection: Binding(get: { outcomes[key] ?? .untried }, set: { outcomes[key] = $0 })) {
            ForEach(Outcome.allCases, id: \.self) { Text($0.rawValue) }
        }
    }

    private var summary: String {
        let device = UIDevice.current
        var lines = ["Phase 3 spikes · \(device.systemName) \(device.systemVersion)"]
        for key in results.keys.sorted() { lines.append("\(key): \(results[key]!)") }
        for key in outcomes.keys.sorted() where outcomes[key] != .untried { lines.append("\(key): \(outcomes[key]!.rawValue)") }
        return lines.joined(separator: "\n")
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Server trust for native requests: the household host only through `PinnedTrust`, everything else as usual.
private final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let trust: PinnedTrust
    let host: String
    private let entries = OSAllocatedUnfairLock(initialState: [String]())

    init(trust: PinnedTrust, host: String) {
        self.trust = trust
        self.host = host
    }

    var log: String { entries.withLock { $0.isEmpty ? "no challenge" : $0.joined(separator: "; ") } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let challenged = challenge.protectionSpace.host
        guard challenged.lowercased() == host else { return (.performDefaultHandling, nil) }
        let (ok, detail) = trust.evaluate(serverTrust, host: challenged)
        entries.withLock { $0.append("\(ok ? "pass" : "REFUSED") \(detail)") }
        return ok ? (.useCredential, URLCredential(trust: serverTrust)) : (.cancelAuthenticationChallenge, nil)
    }
}

struct PinnedPage: Identifiable {
    let id = UUID()
    let url: URL
    let host: String
    let mode: PinnedTrust.Mode
}

/// Loads Home Base in a web view with its own, empty data store (so fresh connections) and records every
/// server-trust challenge it's asked to decide, then what loaded.
private struct PinnedWebSheet: View {
    let page: PinnedPage
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var log: [String] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PinnedWebView(page: page) { line in
                    log.append(line)
                    report("[\(page.mode.rawValue)] " + log.joined(separator: " | "))
                }
                ScrollView {
                    Text(log.joined(separator: "\n")).font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 160)
                .background(.background.secondary)
            }
            .navigationTitle(page.mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PinnedWebView: UIViewRepresentable {
    let page: PinnedPage
    let record: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(page: page, record: record) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: page.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let page: PinnedPage
        let record: @MainActor (String) -> Void
        private var challenges = 0

        init(page: PinnedPage, record: @escaping @MainActor (String) -> Void) {
            self.page = page
            self.record = record
        }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            let host = challenge.protectionSpace.host
            guard host.lowercased() == page.host else {
                record("other host \(host): default trust")
                return (.performDefaultHandling, nil)
            }
            challenges += 1
            let (ok, detail) = PinnedTrust(mode: page.mode).evaluate(serverTrust, host: host)
            record("challenge \(challenges): \(ok ? "pass" : "REFUSED") \(ok ? "" : detail)")
            return ok ? (.useCredential, URLCredential(trust: serverTrust)) : (.cancelAuthenticationChallenge, nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let script = """
                const resources = performance.getEntriesByType('resource').length;
                let api = 'n/a';
                try { api = String((await fetch('/api/home', { headers: { accept: 'application/json' } })).status); }
                catch (e) { api = 'failed: ' + e.message; }
                return 'loaded "' + document.title + '", ' + resources + ' resources, page fetch /api/home → ' + api;
                """
                let answer = try? await webView.callAsyncJavaScript(script, contentWorld: .page)
                record("\(answer as? String ?? "loaded"); challenges so far: \(challenges)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            record("did not load: \((error as NSError).domain) \((error as NSError).code); challenges: \(challenges)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            record("failed: \((error as NSError).domain) \((error as NSError).code); challenges: \(challenges)")
        }
    }
}
