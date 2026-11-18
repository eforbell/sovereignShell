import AuthenticationServices
import SafariServices
import SovereignShell
import SwiftUI
import WebKit

/// Phase 0 (docs/plan.md): answers the four spike questions on a real phone. Throwaway.
/// Nothing here sends a credential anywhere; the passkey probe only reports what WebKit allowed.
struct SpikeView: View {
    @AppStorage("homeBaseAddress") private var addressText = ""
    @State private var results: [String: String] = [:]
    @State private var unlocked: [String: Outcome] = [:]
    @State private var webPage: WebPage?
    @State private var safariPage: WebPage?
    @State private var busy = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    enum Outcome: String, CaseIterable { case untried = "Not tried", worked = "Worked", failed = "Failed" }

    private var address: HomeBaseAddress? { HomeBaseAddress(addressText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("home.example.ts.net", text: $addressText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !addressText.isEmpty && address == nil {
                        Text("Enter an https address.").foregroundStyle(.red)
                    }
                } header: { Text("Home Base address") }

                Section {
                    Button("Ask Home Base who I am") { Task { await askWhoIAm() } }
                    Button("Open Home Base in the web view") { open(webView: "", probe: false) }
                    result("a")
                } header: { Text("a · Identity over the tailnet") } footer: {
                    Text("The native answer and the web page should show the same state and name.")
                }

                Section {
                    Button("Open Home Base with the passkey probe") { open(webView: "", probe: true) }
                    Button("Open Admin in the web view") { open(webView: "admin", probe: false) }
                    outcome("b", "Unlock in the web view")
                    result("b")
                } header: { Text("b · Passkeys in the web view") } footer: {
                    Text("Probe: tap the blue button the page shows. Admin: try Unlock administration with 1Password, iCloud Keychain and a YubiKey, then record what happened.")
                }

                Section {
                    Button("Open Admin in a sign-in session") { Task { await openAuthSession() } }
                    outcome("c", "Unlock in the sign-in session")
                    result("c")
                } header: { Text("c · ASWebAuthenticationSession") } footer: {
                    Text("Unlock administration there, then tap Cancel to come back. Cancel is expected: Home Base has no return link yet.")
                }

                Section {
                    Button("Open Admin in a Safari view") { if let url = address?.resolving("admin") { safariPage = WebPage(url: url, probe: false) } }
                    outcome("d", "Unlock in the Safari view")
                } header: { Text("d · SFSafariViewController") }

                Section {
                    Button("Copy results") { UIPasteboard.general.string = summary }
                    Text(summary).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .disabled(busy)
            .navigationTitle("Home Base spikes")
            .sheet(item: $webPage) { page in
                WebSpikeSheet(page: page, host: address?.host ?? "") { results["b"] = $0 }
            }
            .sheet(item: $safariPage) { page in SafariView(url: page.url).ignoresSafeArea() }
        }
    }

    // MARK: Spikes

    private func askWhoIAm() async {
        guard let address else { return }
        busy = true
        defer { busy = false }
        do {
            let home = try await HomeBaseClient(address: address).home()
            let who = home.caller.map { "\($0.name ?? "(no name)") · \($0.login)" } ?? "no caller"
            results["a"] = "native: state=\(home.state) · \(who) · \(home.apps.count) apps"
        } catch {
            results["a"] = "native: \(error)"
        }
    }

    private func openAuthSession() async {
        guard let url = address?.resolving("admin") else { return }
        do {
            let returned = try await webAuthenticationSession.authenticate(
                using: url, callback: .customScheme("sovereignshell-spike"),
                preferredBrowserSession: .shared, additionalHeaderFields: [:])
            results["c"] = "session returned \(returned.absoluteString)"
        } catch {
            results["c"] = "session ended: \((error as NSError).domain) \((error as NSError).code)"
        }
    }

    private func open(webView path: String, probe: Bool) {
        guard let address else { return }
        webPage = WebPage(url: path.isEmpty ? address.url : address.resolving(path), probe: probe)
    }

    // MARK: Rows and summary

    private func result(_ key: String) -> some View {
        Text(results[key] ?? "—").font(.footnote.monospaced()).foregroundStyle(.secondary)
    }

    private func outcome(_ key: String, _ label: String) -> some View {
        Picker(label, selection: Binding(get: { unlocked[key] ?? .untried }, set: { unlocked[key] = $0 })) {
            ForEach(Outcome.allCases, id: \.self) { Text($0.rawValue) }
        }
    }

    private var summary: String {
        let device = UIDevice.current
        var lines = ["Home Base spikes · \(device.systemName) \(device.systemVersion)"]
        for key in ["a", "b", "c", "d"] {
            if let text = results[key] { lines.append("\(key): \(text)") }
            if let done = unlocked[key], done != .untried { lines.append("\(key) unlock: \(done.rawValue)") }
        }
        return lines.joined(separator: "\n")
    }
}

struct WebPage: Identifiable {
    let id = UUID()
    let url: URL
    let probe: Bool
}

/// A household page in the shell's web view. With `probe`, adds an in-page button that asks WebKit for a
/// passkey. It's a button the person taps, because WebKit may refuse a request no gesture started.
private struct WebSpikeSheet: View {
    let page: WebPage
    let host: String
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var relay = ProbeRelay()

    var body: some View {
        NavigationStack {
            ShellWebView(url: page.url, householdHosts: [host]) { created in
                relay.report = report
                created.configuration.userContentController.add(relay, name: "spike")
                // Called while SwiftUI builds the view: keep the reference on the next turn instead.
                Task { @MainActor in webView = created }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if page.probe {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add probe") { webView?.evaluateJavaScript(Self.probeButton) }
                    }
                }
            }
        }
        .onDisappear { webView?.configuration.userContentController.removeScriptMessageHandler(forName: "spike") }
    }

    /// Puts a button on the page. Tapping it asks for any passkey for this host and reports the outcome.
    /// A returned credential is described, never sent anywhere.
    static let probeButton = """
    (() => {
      if (document.getElementById('spike-probe')) return;
      const b = document.createElement('button');
      b.id = 'spike-probe';
      b.textContent = 'Run passkey probe';
      b.style.cssText = 'position:fixed;left:16px;right:16px;bottom:24px;z-index:99999;padding:14px;font-size:17px;border-radius:12px;border:0;background:#4f7eff;color:#fff';
      b.addEventListener('click', async () => {
        const out = { origin: location.origin, secureContext: window.isSecureContext,
                      publicKeyCredential: typeof PublicKeyCredential !== 'undefined' };
        if (out.publicKeyCredential) {
          try { out.platformAuthenticator = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(); }
          catch (e) { out.platformAuthenticator = String(e); }
          try {
            const cred = await navigator.credentials.get({ publicKey: {
              challenge: crypto.getRandomValues(new Uint8Array(32)), rpId: location.hostname,
              userVerification: 'preferred', timeout: 60000 } });
            out.get = cred ? 'returned a credential (' + cred.type + ')' : 'returned null';
          } catch (e) { out.get = (e && e.name) + ': ' + (e && e.message); }
        }
        window.webkit.messageHandlers.spike.postMessage(JSON.stringify(out));
        b.textContent = 'Probe done: see the spike screen';
      });
      document.body.appendChild(b);
    })();
    """
}

/// Receives the probe's report. A separate object so the web view's strong reference to its message
/// handler never holds the SwiftUI view.
@MainActor
private final class ProbeRelay: NSObject, WKScriptMessageHandler {
    var report: (String) -> Void = { _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        report("probe: \(message.body)")
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
