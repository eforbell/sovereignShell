import SafariServices
import SovereignShell
import SwiftUI
import WebKit

/// What the launcher opens: a household page in the app's web view, or Home Base's admin in a Safari view.
struct BrowserPage: Identifiable {
    enum Kind { case inApp, safari }
    let id = UUID()
    let title: String
    let url: URL
    let kind: Kind
}

/// A household app full screen in the shell's web view, with a way back to the launcher.
///
/// Until phase 3 brings passkeys to the app's web view, a page that asks for one (a parent's step-up in
/// Pulse, say) can't finish here. The Safari button reopens the current page in a Safari view, where
/// passkeys and hardware keys work. That page then has its own sign-in, separate from this web view's.
struct AppBrowser: View {
    let page: BrowserPage
    let householdHosts: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var safariURL: SafariTarget?

    var body: some View {
        NavigationStack {
            ShellWebView(url: page.url, householdHosts: householdHosts) { created in
                // Called while SwiftUI builds the view: keep the reference on the next turn instead.
                Task { @MainActor in webView = created }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Apps", systemImage: "square.grid.2x2") { dismiss() }
                        .labelStyle(.titleAndIcon)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Safari view", systemImage: "safari") {
                        safariURL = SafariTarget(url: Self.safariURL(current: webView?.url, fallback: page.url))
                    }
                    .accessibilityHint("For pages that ask for a passkey")
                }
            }
        }
        .sheet(item: $safariURL) { target in SafariView(url: target.url).ignoresSafeArea() }
    }

    /// The page on screen, if it's an https page; otherwise the app's start page. A Safari view only takes
    /// http(s), and an about:blank or a page still loading has nothing better to offer.
    static func safariURL(current: URL?, fallback: URL) -> URL {
        guard let current, current.scheme?.lowercased() == "https", current.host() != nil else { return fallback }
        return current
    }

    struct SafariTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
}

/// Safari's own view. Used for administration until phase 3 settles how passkeys reach the app: an app's
/// web view can't use passkeys scoped to the tailnet domain (docs/plan.md), and Safari can.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
