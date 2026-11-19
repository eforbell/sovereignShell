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
    let homeBase: HomeBaseAddress
    /// Passkey checks household pages ask for (`window.sovereign.handoff`).
    let handoff: ShellWebView.Handoff
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShellWebView(url: page.url, householdHosts: householdHosts, homeBase: homeBase, trust: householdTrust, handoff: handoff)
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

/// Safari's own view, for what the app's web view can't do: registering a passkey, which is scoped to the
/// tailnet domain (docs/plan.md). Checks go through the handoff's sheet instead.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
