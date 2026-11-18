#if canImport(UIKit)
import SwiftUI
import UIKit
import WebKit

/// A web view for household pages. It keeps cookies between launches (the default data store), sends
/// other sites to Safari, opens `target=_blank` household links in place and supports pull to refresh.
public struct ShellWebView: UIViewRepresentable {
    public let url: URL
    public let householdHosts: Set<String>
    /// Called once with the underlying web view, for callers that need to evaluate script or observe it.
    public var onCreate: @MainActor (WKWebView) -> Void

    public init(url: URL, householdHosts: Set<String>, onCreate: @escaping @MainActor (WKWebView) -> Void = { _ in }) {
        self.url = url
        self.householdHosts = Set(householdHosts.map { $0.lowercased() })
        self.onCreate = onCreate
    }

    public func makeCoordinator() -> Coordinator { Coordinator(householdHosts: householdHosts) }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
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
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var householdHosts: Set<String>
        weak var webView: WKWebView?

        init(householdHosts: Set<String>) { self.householdHosts = householdHosts }

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
#endif
