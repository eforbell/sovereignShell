#if canImport(UIKit)
import AuthenticationServices
import SwiftUI
import UIKit
import WebKit

/// A web view for household pages. It keeps cookies between launches (the default data store), sends
/// other sites to Safari, opens `target=_blank` household links in place and supports pull to refresh.
/// Household hosts load only over chains to the household's pinned authorities (HouseholdTrust), for
/// every load, subresources included; one that fails doesn't load, and the page says why. Which hosts that
/// covers comes from Home Base's address (every host under the tailnet's domain), plus every household host
/// this view was ever given: it never shrinks, so no connection is ever opened to one on the system's trust.
public struct ShellWebView: UIViewRepresentable {
    public let url: URL
    public let householdHosts: Set<String>
    public let homeBase: HomeBaseAddress
    public let trust: HouseholdTrust
    /// The native handoff (`window.sovereign`, version 1) for household pages: called with the id a page's
    /// main frame asked for and the page's host. Without it, pages get no bridge.
    public let handoff: Handoff?
    /// Called once with the underlying web view, for callers that need to evaluate script or observe it.
    public var onCreate: @MainActor (WKWebView) -> Void

    public typealias Handoff = @MainActor (_ id: String, _ host: String) async throws(HandoffError) -> Void

    public init(url: URL, householdHosts: Set<String>, homeBase: HomeBaseAddress, trust: HouseholdTrust, handoff: Handoff? = nil,
                onCreate: @escaping @MainActor (WKWebView) -> Void = { _ in }) {
        self.url = url
        self.householdHosts = Set(householdHosts.map { $0.lowercased() })
        self.homeBase = homeBase
        self.trust = trust
        self.handoff = handoff
        self.onCreate = onCreate
    }

    public func makeCoordinator() -> Coordinator { Coordinator(householdHosts: householdHosts, homeBase: homeBase, trust: trust, handoff: handoff) }

    /// `window.sovereign` for household pages: defined only in the main frame, only on an https household
    /// host, and fixed so a page can't replace it. The app checks the same again for every call.
    static func bridgeScript(hosts: Set<String>) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: hosts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const hosts = \(list);
          if (location.protocol !== 'https:' || !hosts.includes(location.hostname)) return;
          const post = (id) => window.webkit.messageHandlers.sovereign.postMessage({ id: String(id) }).then(() => undefined);
          Object.defineProperty(window, 'sovereign', { value: Object.freeze({ version: 1, handoff: post }), writable: false, configurable: false });
        })();
        """
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if handoff != nil {
            let controller = configuration.userContentController
            controller.addUserScript(WKUserScript(source: Self.bridgeScript(hosts: householdHosts), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "sovereign")
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        onCreate(webView)
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.householdHosts = householdHosts
        context.coordinator.pinnedHosts.formUnion(householdHosts)
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        var householdHosts: Set<String>
        /// Every household host this view was given; only ever added to.
        var pinnedHosts: Set<String>
        let homeBase: HomeBaseAddress
        let trust: HouseholdTrust
        let handoff: Handoff?
        weak var webView: WKWebView?
        /// Household hosts whose certificate was refused on their latest challenge, so a failed load can say why.
        private var refused: Set<String> = []

        init(householdHosts: Set<String>, homeBase: HomeBaseAddress, trust: HouseholdTrust, handoff: Handoff?) {
            self.householdHosts = householdHosts
            self.pinnedHosts = householdHosts
            self.homeBase = homeBase
            self.trust = trust
            self.handoff = handoff
        }

        /// `window.sovereign.handoff(id)`. Only from this web view's main frame, on an https household host
        /// (whose load passed household trust): anything else is refused before the app attests anything.
        /// The reply is nothing on success, or the rejection's message (`cancelled`, `unavailable`, or why).
        public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            let origin = message.frameInfo.securityOrigin
            let host = origin.host.lowercased()
            guard let handoff, message.webView === webView, message.frameInfo.isMainFrame,
                  origin.protocol == "https", origin.port == 0 || origin.port == 443, householdHosts.contains(host), pinned(host),
                  let id = (message.body as? [String: Any])?["id"] as? String
            else { return (nil, "This page can't ask the app to confirm anything.") }
            do throws(HandoffError) {
                try await handoff(id, host)
                return (nil, nil)
            } catch {
                return (nil, error.message)
            }
        }

        func pinned(_ host: String) -> Bool { homeBase.trustCovers(host) || pinnedHosts.contains(host) }

        /// Every server-trust challenge the web view meets: household hosts against the pinned anchors only.
        public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let host = challenge.protectionSpace.host.lowercased()
            let covered = pinned(host)
            let (disposition, credential, refused) = trust.answer(challenge) { _ in covered }
            if refused { self.refused.insert(host) } else { self.refused.remove(host) }
            return (disposition, credential)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            // A refused challenge ends the load as cancelled; anything else (offline, a timeout) isn't ours to explain.
            let error = error as NSError
            guard error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled,
                  let host = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host()?.lowercased(),
                  refused.contains(host) else { return }
            webView.loadHTMLString(Self.untrustedPage(host), baseURL: nil)
        }

        /// What a refused household host shows instead of its page. Never the system's trust instead.
        static func untrustedPage(_ host: String) -> String {
            let safe = host.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark"></head>
            <body style="font: 17px/1.45 -apple-system, system-ui, sans-serif; margin: 0; padding: 32px 16px;">
            <h1 style="font-size: 1.3rem;">Can't verify your household's certificate</h1>
            <p>\(safe) didn't present a certificate from the authorities this app trusts for your household, so it wasn't loaded.</p>
            <p style="opacity: 0.7;">If your household changed its certificate authority, this app needs an update. Otherwise, something between this phone and Home Base isn't what it should be.</p>
            </body></html>
            """
        }

        @objc func reload(_ control: UIRefreshControl) {
            webView?.reload()
            control.endRefreshing()
        }

        public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let route = LinkRoute.of(url, householdHosts: householdHosts)
            // Frames inside a page may embed other sites, but never blocked schemes (a data: frame runs script).
            // Only top-level navigation is sent out to Safari.
            guard action.targetFrame?.isMainFrame ?? true else { return route == .block ? .cancel : .allow }
            switch route {
            case .stay: return .allow
            case .external:
                await UIApplication.shared.open(url)
                return .cancel
            case .block: return .cancel
            }
        }

        /// `target=_blank` and `window.open`: household pages load here, everything else goes out.
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                            for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            switch LinkRoute.of(url, householdHosts: householdHosts) {
            case .stay: webView.load(action.request)
            case .external: UIApplication.shared.open(url)
            case .block: break
            }
            return nil
        }
    }
}

/// The handoff's Safari sheet: an ephemeral ASWebAuthenticationSession (no cookies needed, and no "wants to
/// use … to sign in" alert), closed when the page reaches the app's callback scheme.
@MainActor
public final class HandoffSheetPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    public override init() {}

    public func present(_ url: URL, callbackScheme: String) async throws(HandoffError) {
        let result: Result<Void, HandoffError> = await withCheckedContinuation { continuation in
            // Resumed once: a session that fails to start may also call its completion handler.
            var resumed = false
            let finish: @MainActor (Result<Void, HandoffError>) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { _, error in
                let outcome: Result<Void, HandoffError>
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    outcome = .failure(cancelled ? .cancelled : .failed("The confirmation sheet closed: \(error.localizedDescription)"))
                } else {
                    outcome = .success(())
                }
                Task { @MainActor in finish(outcome) }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(.failed("The confirmation sheet couldn't open."))) }
        }
        session = nil
        try result.get()
    }

    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif
