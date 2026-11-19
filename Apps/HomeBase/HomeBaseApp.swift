import SovereignShell
import SwiftUI

/// The certificate authorities household hosts must chain to: the operator's, bundled under TrustAnchors/
/// (Let's Encrypt's ISRG Root X1 and X2 by default, which Tailscale's certificates use).
let householdTrust = HouseholdTrust.bundled()

@main
struct HomeBaseApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// The household address is the app's only setting. Without one, the person joins a household; with one,
/// they get its home.
struct RootView: View {
    @AppStorage("homeBaseAddress") private var addressText = ""

    var body: some View {
        if let address = HomeBaseAddress(addressText) {
            HomeView(address: address) { addressText = "" }
                .id(address)
        } else {
            SetupView { addressText = $0.url.absoluteString }
        }
    }
}
