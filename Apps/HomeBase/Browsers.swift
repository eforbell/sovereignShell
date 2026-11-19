import SafariServices
import SovereignShell
import SwiftUI

/// What the launcher opens: a household page in the app's web view, or Home Base's admin in a Safari view.
struct BrowserPage: Identifiable {
    enum Kind { case inApp, safari }
    let id = UUID()
    let title: String
    let url: URL
    let kind: Kind
}

/// A household app full screen in the shell's web view, with a way back to the launcher.
struct AppBrowser: View {
    let page: BrowserPage
    let householdHosts: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShellWebView(url: page.url, householdHosts: householdHosts, trust: householdTrust)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Apps", systemImage: "square.grid.2x2") { dismiss() }
                            .labelStyle(.titleAndIcon)
                    }
                }
        }
    }
}

/// Safari's own view. Used for administration until phase 3 settles how passkeys reach the app: an app's
/// web view can't use passkeys scoped to the tailnet domain (docs/plan.md), and Safari can.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
